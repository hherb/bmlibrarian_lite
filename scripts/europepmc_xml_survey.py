#!/usr/bin/env python3
r"""Which Europe PMC search fields predict that ``fullTextXML`` will serve (#432).

Before #432, ``ArticleInfo.has_fulltext_xml`` read ``inEPMC`` or ``inPMC``
only. Europe PMC holds the text of many such articles without serving it:
``fullTextXML`` answers **HTTP 500** (not 404) for a closed-access PMC article
and for most preprints whose text arrived before 2026, steadily (probed
2026-09-28 and 2026-09-30). Since #445 a 500 "could not be asked", so the
chain could never settle an absence for these articles, and every fetch spent
the session's retries first. ``europepmc.offers_fulltext_xml`` is the rule
this survey chose, and it still scores the shipped function itself.

This script measures instead of guessing. It samples search records by
stratum, keeps every availability flag the ``core`` result carries, asks
``fullTextXML`` **once, without retries**, and records what came back. The
analysis then cross-tabulates flag combinations against the answer, and
scores candidate rules. Build a rule on one fetch, then check it on a held-out
one (another date range): a rule fitted to one sample overfits it.

Usage:
    # Fetch a sample (writes JSON lines, one record per article).
    python scripts/europepmc_xml_survey.py fetch --years 2019-2020 \\
        --per-stratum 80 --seed 1 --out tmp/epmc-xml-432/dev.jsonl
    python scripts/europepmc_xml_survey.py fetch --years 2021-2022 \\
        --per-stratum 80 --seed 2 --out tmp/epmc-xml-432/heldout.jsonl

    # One stratum only: recent preprints, which older samples miss.
    python scripts/europepmc_xml_survey.py fetch --years 2025-2026 \\
        --per-stratum 120 --seed 3 --strata preprint pmc-not-epmc \\
        --out tmp/epmc-xml-432/recent.jsonl

    # Analyse one or more samples. "shipped" scores the code's own rule.
    python scripts/europepmc_xml_survey.py analyse tmp/epmc-xml-432/*.jsonl

The 2026-09-30 runs (80 per stratum for 2019–20 and 2021–22, 120 recent
preprints; 761 records) found: PMC open access 160/160 served, PMC closed
access 1/320, preprints 2019–22 0/160, preprints 2025–26 79/120 (every one
whose text arrived in 2026, 15 of 56 from 2025). The ``pmc-not-epmc`` stratum
is rare (one record found). The rows are kept in
``doc/developer/europepmc_xml_survey/``: re-analyse those rather than
re-fetch to check a figure, since the index moves.

A probe that got no answer from Europe PMC (a transport error, a throttle, a
server fault other than the steady 500) says nothing about the article, so
it is left out of every count and reported as unanswered.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from collections import Counter, defaultdict
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from bmlibrarian_lite.constants import (
    EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
    EUROPEPMC_REST_BASE_URL,
    EUROPEPMC_SEARCH_URL,
    EUROPEPMC_SOURCE_PREPRINT,
    EUROPEPMC_USER_AGENT,
    HTTP_UNSETTLED_CLIENT_STATUSES,
    POLITE_THROTTLE_STATUSES,
    UNANSWERED_HTTP_STATUSES,
)
from bmlibrarian_lite.europepmc import offers_fulltext_xml
from bmlibrarian_lite.polite_session import retry_after_seconds
from bmlibrarian_lite.rate_limit import RateLimiter, limiter_for

_FULLTEXT_URL = EUROPEPMC_REST_BASE_URL + "/{accession}/fullTextXML"
_HEADERS = {"User-Agent": EUROPEPMC_USER_AGENT}

# Requests are paced by the application's own limiter for Europe PMC's host,
# so the survey is no less polite than the app; workers only overlap the
# waits for answers (a 500 takes ~1.5 s).
_WORKERS = 3
_RECORDS_PER_DAY = 10
# Some days hold fewer than _RECORDS_PER_DAY matches, so fetch draws this
# many times the days a full sample needs, plus a few for tiny samples.
_DAY_DRAW_FACTOR = 4
_SPARE_DAYS = 4
_HTTP_OK = 200
# ``fullTextXML``'s steady answer for text it holds and will not serve: the
# signal the survey measures, so an answer here, unlike every other 5xx.
_HTTP_STEADY_REFUSAL = 500
# Leading bytes read to tell a JATS article with a <body> from a body-less one.
_BODY_MARKER = b"<body"

# The Y/N flags of a ``core`` search result that could bear on availability.
FLAGS: tuple[str, ...] = (
    "isOpenAccess",
    "inEPMC",
    "inPMC",
    "hasPDF",
    "authMan",
    "epmcAuthMan",
    "nihAuthMan",
    "hasReferences",
    "hasTextMinedTerms",
    "hasSuppl",
)

# Each stratum is a query that fetch narrows to one random first-publication
# day at a time, so a sample is not the first relevance-ranked page.
# Europe PMC holds no text outside PMC but preprints' (``IN_EPMC:Y AND
# IN_PMC:N`` is all ``SRC:PPR``), so the non-open-access group is split by
# where its text came from instead.
STRATA: dict[str, str] = {
    "pmc-oa": "IN_PMC:Y AND OPEN_ACCESS:Y",
    "pmc-non-oa": "IN_PMC:Y AND OPEN_ACCESS:N AND AUTH_MAN:N",
    "author-ms": "IN_PMC:Y AND OPEN_ACCESS:N AND AUTH_MAN:Y",
    "pmc-not-epmc": "IN_PMC:Y AND IN_EPMC:N",
    "preprint": "SRC:PPR AND IN_EPMC:Y",
}


def _limiter() -> RateLimiter:
    """The application's shared limiter for Europe PMC's host.

    Returns:
        The limiter every survey request waits on.

    Raises:
        RuntimeError: If the configured base URL names no host.
    """
    host = urlparse(EUROPEPMC_REST_BASE_URL).hostname
    if not host:
        raise RuntimeError(f"no host in {EUROPEPMC_REST_BASE_URL!r}")
    return limiter_for(host)


def _requests() -> Any:
    """Import ``requests``, or explain how to get it.

    Returns:
        The ``requests`` module.

    Raises:
        SystemExit: If ``requests`` is not installed.
    """
    try:
        import requests
    except ImportError as error:  # pragma: no cover - depends on the environment
        raise SystemExit("this script needs `requests`: pip install requests") from error
    return requests


def fulltext_accession(result: dict[str, Any]) -> str | None:
    """The identifier discovery would ask ``fullTextXML`` by.

    Mirrors ``ArticleInfo.fulltext_accession``: the PMC ID, else a preprint's
    ``PPR`` record ID.

    Args:
        result: One ``core`` search result, untrusted.

    Returns:
        The accession, or ``None`` when discovery would have nothing to send.
    """
    pmcid = result.get("pmcid")
    if isinstance(pmcid, str) and pmcid:
        return pmcid
    record_id = result.get("id")
    if (
        result.get("source") == EUROPEPMC_SOURCE_PREPRINT
        and isinstance(record_id, str)
        and record_id
    ):
        return record_id
    return None


def availability_codes(result: dict[str, Any]) -> list[str]:
    """The sorted, distinct ``availabilityCode`` values of a result's URL list.

    Args:
        result: One ``core`` search result, untrusted.

    Returns:
        Codes such as ``OA``, ``F`` or ``S``; empty when there are none.
    """
    url_list = result.get("fullTextUrlList")
    urls = url_list.get("fullTextUrl") if isinstance(url_list, dict) else None
    if not isinstance(urls, list):
        return []
    return sorted(
        {
            url["availabilityCode"]
            for url in urls
            if isinstance(url, dict) and isinstance(url.get("availabilityCode"), str)
        }
    )


def record_features(result: dict[str, Any]) -> dict[str, Any]:
    """What a search result says about the article, reduced to the survey's fields.

    Args:
        result: One ``core`` search result, untrusted.

    Returns:
        The identifiers, every flag in ``FLAGS`` (``"?"`` when absent), the
        licence and the URL list's availability codes.
    """
    id_list = result.get("fullTextIdList")
    return {
        "id": result.get("id"),
        "source": result.get("source"),
        "pmcid": result.get("pmcid"),
        "accession": fulltext_accession(result),
        **{flag: result.get(flag, "?") for flag in FLAGS},
        "license": result.get("license"),
        "fullTextReceivedDate": result.get("fullTextReceivedDate"),
        "hasFullTextIdList": isinstance(id_list, dict) and bool(id_list.get("fullTextId")),
        "availabilityCodes": availability_codes(result),
    }


def _random_days(years: tuple[int, int], count: int, rng: random.Random) -> list[date]:
    """Distinct random days within an inclusive year range.

    Args:
        years: First and last year.
        count: How many days to draw.
        rng: The seeded source of randomness.

    Returns:
        The days, in drawing order.
    """
    first = date(years[0], 1, 1)
    span = (date(years[1], 12, 31) - first).days + 1
    offsets = rng.sample(range(span), min(count, span))
    return [first + timedelta(days=offset) for offset in offsets]


def sample_stratum(
    query: str,
    years: tuple[int, int],
    limit: int,
    rng: random.Random,
    limiter: RateLimiter,
) -> list[dict[str, Any]]:
    """Draw up to ``limit`` records matching ``query``, a few per random day.

    Args:
        query: The stratum's Europe PMC expression.
        years: First and last publication year to draw days from.
        limit: How many records to return at most.
        rng: The seeded source of randomness.
        limiter: The shared request limiter.

    Returns:
        ``core`` search results with an accession to fetch by.

    Raises:
        requests.HTTPError: If a search fails; a sample with a day missing
            would not be the sample asked for.
    """
    requests = _requests()
    found: list[dict[str, Any]] = []
    seen: set[str] = set()
    days = _DAY_DRAW_FACTOR * limit // _RECORDS_PER_DAY + _SPARE_DAYS
    for day in _random_days(years, days, rng):
        if len(found) >= limit:
            break
        limiter.acquire()
        response = requests.get(
            EUROPEPMC_SEARCH_URL,
            params={
                "query": f"({query}) AND FIRST_PDATE:{day.isoformat()}",
                "format": "json",
                "resultType": "core",
                "pageSize": _RECORDS_PER_DAY,
            },
            headers=_HEADERS,
            timeout=EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        for result in _search_results(response.json()):
            accession = fulltext_accession(result)
            if accession and accession not in seen and len(found) < limit:
                seen.add(accession)
                found.append(result)
    return found


def _search_results(data: object) -> list[dict[str, Any]]:
    """The records of a search answer, ignoring anything that is not one.

    Args:
        data: The decoded JSON answer, untrusted.

    Returns:
        The result entries that are objects; empty when there is no list.
    """
    result_list = data.get("resultList") if isinstance(data, dict) else None
    results = result_list.get("result") if isinstance(result_list, dict) else None
    if not isinstance(results, list):
        return []
    return [result for result in results if isinstance(result, dict)]


def probe(accession: str, limiter: RateLimiter) -> dict[str, Any]:
    """Ask ``fullTextXML`` once, without retries, and describe the answer.

    A throttle is not retried, since the survey records what one request
    got, but it slows every later request down as the app would.

    Args:
        accession: A PMC ID or preprint record ID.
        limiter: The shared request limiter.

    Returns:
        ``status`` (``None`` when no answer came), ``hasBody`` for a 200 whose
        XML has a ``<body>``, ``seconds`` and, on a transport error, ``error``.
    """
    requests = _requests()
    limiter.acquire()
    started = time.monotonic()
    try:
        response = requests.get(
            _FULLTEXT_URL.format(accession=accession),
            headers=_HEADERS,
            timeout=EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
        )
    except requests.RequestException as error:
        return {
            "status": None,
            "hasBody": False,
            "seconds": round(time.monotonic() - started, 2),
            "error": type(error).__name__,
        }
    if response.status_code in POLITE_THROTTLE_STATUSES:
        limiter.penalise(retry_after_seconds(response))
    return {
        "status": response.status_code,
        "hasBody": response.status_code == _HTTP_OK and _BODY_MARKER in response.content,
        "seconds": round(time.monotonic() - started, 2),
    }


def fetch_sample(
    years: tuple[int, int],
    per_stratum: int,
    seed: int,
    out: Path,
    strata: Sequence[str] = tuple(STRATA),
) -> None:
    """Sample the chosen strata, probe each record, and write JSON lines.

    The rows go to a ``.partial`` file beside ``out``, which replaces
    ``out`` only once every stratum is written: a run that stops half way
    leaves an existing sample (such as a committed one) as it was.

    Args:
        years: First and last publication year.
        per_stratum: Records to draw per stratum.
        seed: Seed for the day draw, so a run can be repeated.
        out: The JSON-lines file to write.
        strata: Names from ``STRATA`` to sample.
    """
    rng = random.Random(seed)
    limiter = _limiter()
    out.parent.mkdir(parents=True, exist_ok=True)
    partial = out.with_name(out.name + ".partial")
    with partial.open("w", encoding="utf-8") as sink, ThreadPoolExecutor(_WORKERS) as pool:
        for stratum in strata:
            query = STRATA[stratum]
            results = sample_stratum(query, years, per_stratum, rng, limiter)
            features = [record_features(result) for result in results]
            answers = pool.map(lambda f: probe(f["accession"], limiter), features)
            for feature, answer in zip(features, answers, strict=True):
                row = {"stratum": stratum, "years": list(years), **feature, **answer}
                sink.write(json.dumps(row) + "\n")
            print(f"  {stratum}: {len(features)} records", file=sys.stderr)
    partial.replace(out)


def load_rows(paths: Sequence[Path]) -> list[dict[str, Any]]:
    """Read the rows of one or more JSON-lines samples.

    Args:
        paths: Files written by ``fetch``.

    Returns:
        Every row, in file order.
    """
    rows: list[dict[str, Any]] = []
    for path in paths:
        with path.open(encoding="utf-8") as source:
            rows.extend(json.loads(line) for line in source if line.strip())
    return rows


def outcome(row: dict[str, Any]) -> str:
    """Name what ``fullTextXML`` did for one row.

    Args:
        row: A sample row.

    Returns:
        ``served`` (200 with a body), ``bodyless`` (200 without one),
        ``http-<status>``, or ``no-answer``.
    """
    status = row.get("status")
    if status is None:
        return "no-answer"
    if status == _HTTP_OK:
        return "served" if row.get("hasBody") else "bodyless"
    return f"http-{status}"


# A candidate rule answers "should discovery ask fullTextXML for this record?".
Rule = Callable[[dict[str, Any]], bool]

# Rows keep the search result's own flag names, so the shipped predicate reads
# them as it reads a search result: the survey measures the code, not a copy.
RULES: dict[str, Rule] = {
    "before #432: inEPMC or inPMC": lambda r: r.get("inEPMC") == "Y"
    or r.get("inPMC") == "Y",
    "shipped: offers_fulltext_xml": offers_fulltext_xml,
    "isOpenAccess": lambda r: r.get("isOpenAccess") == "Y",
    "licence present": lambda r: bool(r.get("license")),
    "URL list has OA": lambda r: "OA" in r.get("availabilityCodes", []),
}

# One field of a row, read as the value it is split on.
FieldReader = Callable[[dict[str, Any]], str]


def _flag_reader(flag: str) -> FieldReader:
    """Read one Y/N flag, ``?`` when the row lacks it.

    Args:
        flag: A name from ``FLAGS``.

    Returns:
        The reader.
    """
    return lambda row: str(row.get(flag, "?"))


FIELDS: dict[str, FieldReader] = {
    **{flag: _flag_reader(flag) for flag in FLAGS},
    "license": lambda row: str(row.get("license")),
    "hasFullTextIdList": lambda row: str(row.get("hasFullTextIdList")),
    "codes": lambda row: ",".join(row.get("availabilityCodes", [])),
    "receivedYear": lambda row: str(row.get("fullTextReceivedDate") or "")[:4],
}


def answered(row: dict[str, Any]) -> bool:
    """Whether ``fullTextXML`` gave a row an answer about the article.

    No status, a throttle or a server fault is the service failing, not
    Europe PMC saying whether it serves the text; counted as "not served",
    it would credit a rule for skipping it. The steady 500 is the exception,
    being what the survey measures.

    Args:
        row: A sample row.

    Returns:
        ``True`` when the status is Europe PMC's answer.
    """
    status = row.get("status")
    if not isinstance(status, int) or isinstance(status, bool):
        return False
    if status == _HTTP_STEADY_REFUSAL:
        return True
    return status not in UNANSWERED_HTTP_STATUSES and status not in HTTP_UNSETTLED_CLIENT_STATUSES


def served(row: dict[str, Any]) -> bool:
    """Whether ``fullTextXML`` answered 200 for a row, with or without a body.

    Args:
        row: A sample row.

    Returns:
        ``True`` for a 200.
    """
    return row.get("status") == _HTTP_OK


@dataclass(frozen=True)
class RuleScore:
    """How a rule's decisions met what ``fullTextXML`` did.

    Attributes:
        ask_hit: Asked, and served.
        ask_miss: Asked, and not served: requests and retries spent.
        skip_hit: Not asked, though it would have been served: text lost.
        skip_miss: Not asked, and would not have been served.
        unanswered: Rows whose probe got no answer, in no other count.
    """

    ask_hit: int
    ask_miss: int
    skip_hit: int
    skip_miss: int
    unanswered: int = 0


def score_rule(rows: Sequence[dict[str, Any]], rule: Rule) -> RuleScore:
    """Score one candidate rule against the rows.

    Args:
        rows: Sample rows.
        rule: Whether to ask, per row.

    Returns:
        The four counts over the answered rows, and how many were not.
    """
    scored = [row for row in rows if answered(row)]
    cells: Counter[tuple[bool, bool]] = Counter((rule(row), served(row)) for row in scored)
    return RuleScore(
        ask_hit=cells[(True, True)],
        ask_miss=cells[(True, False)],
        skip_hit=cells[(False, True)],
        skip_miss=cells[(False, False)],
        unanswered=len(rows) - len(scored),
    )


def served_by_value(
    rows: Sequence[dict[str, Any]], read: FieldReader
) -> dict[str, tuple[int, int]]:
    """Split answered rows by one field, counting how many of each value were served.

    Args:
        rows: Sample rows; unanswered ones are left out.
        read: The field to split on.

    Returns:
        ``value -> (served, total)``, sorted by value.
    """
    counts: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for row in rows:
        if not answered(row):
            continue
        cell = counts[read(row)]
        cell[0] += served(row)
        cell[1] += 1
    return {value: (hit, total) for value, (hit, total) in sorted(counts.items())}


def _combination(row: dict[str, Any]) -> tuple[str, ...]:
    """The source and every recorded field of a row, as one key.

    Args:
        row: A sample row.

    Returns:
        The key.
    """
    return (
        str(row.get("source")),
        *(f"{flag}={row.get(flag, '?')}" for flag in FLAGS),
        f"licence={'Y' if row.get('license') else 'N'}",
        "codes=" + ",".join(row.get("availabilityCodes", [])),
    )


def analyse(rows: Sequence[dict[str, Any]]) -> str:
    """Cross-tabulate flags against answers, and score each candidate rule.

    Args:
        rows: Sample rows.

    Returns:
        A plain-text report.
    """
    by_stratum: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        by_stratum[str(row.get("stratum"))].append(row)

    unanswered = sum(not answered(row) for row in rows)
    lines: list[str] = [f"{len(rows)} records"]
    if unanswered:
        lines.append(
            f"!! {unanswered} got no answer from Europe PMC: left out of every"
            " count below; re-probe them before trusting a rule's score"
        )
    lines.append("\n== Outcome by stratum")
    for stratum, members in by_stratum.items():
        outcomes = Counter(outcome(row) for row in members)
        lines.append(f"  {stratum:12s} {dict(outcomes.most_common())}")

    lines.append("\n== Answered 200 / total, by one field, per stratum")
    for stratum, members in by_stratum.items():
        lines.append(f"  [{stratum}]")
        for name, read in FIELDS.items():
            split = served_by_value(members, read)
            if len(split) > 1:
                shown = ", ".join(f"{value}: {hit}/{total}" for value, (hit, total) in split.items())
                lines.append(f"    {name:18s} {shown}")

    combos: dict[tuple[str, ...], Counter[str]] = defaultdict(Counter)
    for row in rows:
        combos[_combination(row)][outcome(row)] += 1
    lines.append("\n== Outcome by flag combination")
    for key, counts in sorted(combos.items(), key=lambda item: -sum(item[1].values())):
        lines.append(f"  {sum(counts.values()):4d}  {' '.join(key)}")
        lines.append(f"        {dict(counts.most_common())}")

    lines.append("\n== Candidate rules (ask = rule holds; hit = answered 200)")
    lines.append("  rule                            ask&hit ask&miss skip&hit skip&miss")
    for name, rule in RULES.items():
        score = score_rule(rows, rule)
        lines.append(
            f"  {name:31s} {score.ask_hit:7d} {score.ask_miss:8d}"
            f" {score.skip_hit:8d} {score.skip_miss:9d}"
        )
    return "\n".join(lines)


def _year_range(text: str) -> tuple[int, int]:
    """Parse ``2019-2020`` (or ``2019``) into an inclusive year range.

    Args:
        text: The command-line value.

    Returns:
        First and last year.

    Raises:
        argparse.ArgumentTypeError: If the value is not one or two years.
    """
    try:
        parts = [int(part) for part in text.split("-")]
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"not a year range: {text!r}") from error
    if len(parts) == 1:
        return parts[0], parts[0]
    if len(parts) == 2 and parts[0] <= parts[1]:
        return parts[0], parts[1]
    raise argparse.ArgumentTypeError(f"not a year range: {text!r}")


def main(argv: Sequence[str] | None = None) -> int:
    """Run the survey from the command line.

    Args:
        argv: Arguments, without the program name.

    Returns:
        The exit status.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    fetch_cmd = commands.add_parser("fetch", help="sample records and probe fullTextXML")
    fetch_cmd.add_argument("--years", type=_year_range, required=True)
    fetch_cmd.add_argument("--per-stratum", type=int, default=100)
    fetch_cmd.add_argument("--seed", type=int, default=1)
    fetch_cmd.add_argument("--out", type=Path, required=True)
    fetch_cmd.add_argument(
        "--strata", nargs="+", choices=sorted(STRATA), default=list(STRATA)
    )
    analyse_cmd = commands.add_parser("analyse", help="cross-tabulate samples")
    analyse_cmd.add_argument("samples", type=Path, nargs="+")
    args = parser.parse_args(argv)

    if args.command == "fetch":
        fetch_sample(args.years, args.per_stratum, args.seed, args.out, args.strata)
    else:
        print(analyse(load_rows(args.samples)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
