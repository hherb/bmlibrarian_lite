#!/usr/bin/env python3
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

r"""Can the MANTA decision models score relevance and classify study design?

MANTA (gevaertlab/MANTA-4B, gevaertlab/MANTA-27B) is a classifier: it reads
a case and a set of questions with fixed options and returns a probability
for every option in one forward pass, with no text. This script holds it,
and the app's own LLM agents, to human labels on two tasks:

``relevance``
    TREC-COVID (BEIR's copy): 50 research questions, each with CORD-19
    abstracts graded by human assessors 0 (not relevant), 1 (partially
    relevant) or 2 (relevant). The judged documents came from the pooled
    runs of the participating systems, so a grade-0 abstract is a hard
    negative: a search engine ranked it high for that question. MANTA is
    asked the app's five-level relevance question
    (``agents/scoring_agent.py``) as a ``score`` question, lowest level
    first; its score is the expected level, 1 to 5. The app's
    ``LiteScoringAgent`` scores the same pairs with its own prompt.

``design``
    PubMed abstracts (2015-2020) whose study design is stated by NLM's human
    indexers: the record's ``MedlineCitation`` is ``Status="MEDLINE"`` and
    its ``IndexingMethod`` is ``Manual`` or absent, never ``Automated`` or
    ``Curated``. The label comes from the record's publication types and
    MeSH design headings by :func:`design_label`, which refuses a record
    whose headings name two designs. The search query is only a pre-filter:
    every record is labelled again from its own XML. MANTA is asked a
    ``choice`` question over the options of the app's
    ``LiteStudyClassifier``; the classifier answers with its own prompt.
    Neither sees the publication types or the MeSH headings.

Neither corpus is committed with its text (CORD-19 abstracts and PubMed
abstracts carry their publishers' licences): the committed label files hold
identifiers and labels, and ``materialise`` fetches the texts again from the
pinned BEIR revision and from PubMed.

Usage:
    # Build the label files (identifiers, labels) and the local item files
    # (with text). Needs pyarrow for the BEIR parquet files.
    python scripts/manta_benchmark.py build-relevance --per-grade 2 --seed 1 \\
        --labels doc/developer/manta_benchmark/relevance_labels.jsonl \\
        --items tmp/manta_benchmark/relevance_items.jsonl
    python scripts/manta_benchmark.py build-design --per-class 30 --seed 1 \\
        --labels doc/developer/manta_benchmark/design_labels.jsonl \\
        --items tmp/manta_benchmark/design_items.jsonl

    # Re-create the item files of committed labels.
    python scripts/manta_benchmark.py materialise relevance \\
        doc/developer/manta_benchmark/relevance_labels.jsonl \\
        tmp/manta_benchmark/relevance_items.jsonl

    # MANTA, in a venv with MANTA's own requirements (stdlib + manta only;
    # bmlibrarian_lite is not imported). Resumable: done ids are skipped.
    python scripts/manta_benchmark.py run-manta relevance \\
        tmp/manta_benchmark/relevance_items.jsonl preds.jsonl \\
        --model /path/to/MANTA-4B --device cpu

    # The app's embedder (cosine of question and article), a free baseline.
    python scripts/manta_benchmark.py run-embed \\
        tmp/manta_benchmark/relevance_items.jsonl preds.jsonl

    # bmlib's keyword rules for the study design, a free baseline.
    python scripts/manta_benchmark.py run-rules \\
        tmp/manta_benchmark/design_items.jsonl preds.jsonl

    # The app's agents, in the project venv (ANTHROPIC_API_KEY set).
    python scripts/manta_benchmark.py run-llm relevance \\
        tmp/manta_benchmark/relevance_items.jsonl preds.jsonl \\
        --model anthropic:claude-haiku-5-5

    # Metrics against the labels, one column per prediction file.
    python scripts/manta_benchmark.py analyse relevance \\
        doc/developer/manta_benchmark/relevance_labels.jsonl preds_a.jsonl ...
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from collections.abc import Iterable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools" / "manta_server"))
from manta_protocol import (  # noqa: E402, F401
    _HUMAN_INDEXING,
    _MH_CASE_CONTROL,
    _MH_COHORT,
    _MH_CROSS_SECTIONAL,
    _MH_PROSPECTIVE,
    _MH_RETROSPECTIVE,
    _PT_CASE_REPORT,
    _PT_GUIDELINES,
    _PT_META,
    _PT_NOT_PRIMARY,
    _PT_RCT,
    _PT_SR,
    _PT_TRIALS,
    DESIGN_GROUPS,
    DESIGN_INSTRUCTIONS,
    DESIGN_OPTIONS,
    RELEVANCE_INSTRUCTIONS,
    RELEVANCE_LEVELS,
    SCORE_MIN,
    design_label,
    design_request,
    expected_score,
    relevance_request,
)
from manta_stats import (  # noqa: E402, F401
    ECE_BINS,
    WILSON_Z,
    average_ranks,
    expected_calibration_error,
    pearson,
    spearman,
    wilson_interval,
)

# --- Sources -----------------------------------------------------------------

BEIR_CORPUS_REPO = "BeIR/trec-covid"
BEIR_CORPUS_REVISION = "7e16fde3016c639c7f856e803f4bab92645562c4"
BEIR_QRELS_REPO = "BeIR/trec-covid-qrels"
BEIR_QRELS_REVISION = "532ac68ee6756ac22c9346eebf65bd3c6a042e10"
HF_DATASET_FILE_URL = "https://huggingface.co/datasets/{repo}/resolve/{revision}/{path}"
BEIR_CORPUS_PATH = "corpus/corpus-00000-of-00001.parquet"
BEIR_QUERIES_PATH = "queries/queries-00000-of-00001.parquet"
BEIR_QRELS_PATH = "test.tsv"

EUTILS_BASE = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
EUTILS_TOOL = "bmlibrarian_lite_manta_benchmark"
# NCBI allows three requests a second without a key.
EUTILS_MIN_INTERVAL_SECONDS = 0.4
EUTILS_TIMEOUT_SECONDS = 60
EUTILS_FETCH_BATCH = 100
HTTP_TIMEOUT_SECONDS = 300
USER_AGENT = "bmlibrarian-lite-manta-benchmark"

# Publication years drawn from, each year searched on its own so that no
# year is cut by esearch's cap.
DESIGN_YEARS = range(2015, 2021)
# Records drawn per class before labelling: most survive, some are refused.
DESIGN_OVERDRAW = 3
# esearch serves at most this many ids from one query (retstart + retmax).
ESEARCH_MAX_RETRIEVABLE = 9999
# Retries of a throttled (429) or failed (5xx) E-utilities request.
EUTILS_RETRIES = 5
EUTILS_BACKOFF_SECONDS = 2.0
_RETRYABLE_STATUSES = frozenset({429, 500, 502, 503, 504})

# --- Labels ------------------------------------------------------------------

RELEVANCE_GRADES = (0, 1, 2)

# The classes the corpus is drawn for, each with its PubMed pre-filter.
DESIGN_QUERIES: dict[str, str] = {
    "meta_analysis": '"Meta-Analysis"[pt]',
    "systematic_review": '"Systematic Review"[pt] NOT "Meta-Analysis"[pt]',
    "rct": '"Randomized Controlled Trial"[pt] NOT "Review"[pt]',
    "cohort_prospective": '"Prospective Studies"[mh:noexp] AND "Cohort Studies"[mh:noexp]',
    "cohort_retrospective": '"Retrospective Studies"[mh:noexp] AND "Cohort Studies"[mh:noexp]',
    "case_control": '"Case-Control Studies"[mh:noexp] NOT "Cohort Studies"[mh:noexp]',
    "cross_sectional": '"Cross-Sectional Studies"[mh:noexp] NOT "Cohort Studies"[mh:noexp]',
    "case_report": '"Case Reports"[pt] NOT "Review"[pt]',
    "guideline": '("Practice Guideline"[pt] OR "Guideline"[pt])',
}

# --- Analysis ----------------------------------------------------------------

BOOTSTRAP_DRAWS = 1000
BOOTSTRAP_SEED = 20261119
CI_LOWER_QUANTILE = 0.025
CI_UPPER_QUANTILE = 0.975
# A pre-filter may not drop more relevant pairs than this share.
SCREENING_RECALL = 0.95
LLM_WORKERS = 4


# =============================================================================
# Pure helpers
# =============================================================================


@dataclass(frozen=True)
class PubMedRecord:
    """The parts of one PubMed record the design corpus reads."""

    pmid: str
    title: str
    abstract: str
    year: int | None
    status: str | None
    indexing_method: str | None
    publication_types: tuple[str, ...]
    mesh_headings: tuple[str, ...]

    @property
    def human_indexed(self) -> bool:
        """True when NLM's indexers, not its automated indexing, chose the terms."""
        return self.status == "MEDLINE" and self.indexing_method in _HUMAN_INDEXING


def _all_text(element: ET.Element | None) -> str:
    """The text of an element and its descendants, whitespace collapsed."""
    if element is None:
        return ""
    return " ".join("".join(element.itertext()).split())


def parse_pubmed_xml(xml_bytes: bytes) -> list[PubMedRecord]:
    """The records of an efetch ``PubmedArticleSet`` (book records skipped).

    A structured abstract keeps its section labels as ``LABEL: text``.

    Args:
        xml_bytes: The efetch answer.

    Returns:
        One PubMedRecord per ``PubmedArticle``.
    """
    root = ET.fromstring(xml_bytes)
    records: list[PubMedRecord] = []
    for article in root.iter("PubmedArticle"):
        citation = article.find("MedlineCitation")
        if citation is None:
            continue
        pmid = _all_text(citation.find("PMID"))
        art = citation.find("Article")
        title = _all_text(art.find("ArticleTitle")) if art is not None else ""
        parts = []
        if art is not None:
            for node in art.findall("Abstract/AbstractText"):
                text = _all_text(node)
                if not text:
                    continue
                label = node.get("Label")
                parts.append(f"{label}: {text}" if label else text)
        year_text = _all_text(art.find("Journal/JournalIssue/PubDate/Year")) if art is not None else ""
        pts = tuple(_all_text(p) for p in citation.findall("Article/PublicationTypeList/PublicationType"))
        mhs = tuple(_all_text(d) for d in citation.findall("MeshHeadingList/MeshHeading/DescriptorName"))
        records.append(
            PubMedRecord(
                pmid=pmid,
                title=title,
                abstract="\n".join(parts),
                year=int(year_text) if year_text.isdigit() else None,
                status=citation.get("Status"),
                indexing_method=citation.get("IndexingMethod"),
                publication_types=pts,
                mesh_headings=mhs,
            )
        )
    return records


def auc(positives: Sequence[float], negatives: Sequence[float]) -> float | None:
    """The area under the ROC curve: P(positive > negative), ties counting half.

    Args:
        positives: Scores of the positive items.
        negatives: Scores of the negative items.

    Returns:
        The AUC, or None when either side is empty.
    """
    if not positives or not negatives:
        return None
    ranks = average_ranks(list(positives) + list(negatives))
    rank_sum = math.fsum(ranks[: len(positives)])
    n_pos, n_neg = len(positives), len(negatives)
    return (rank_sum - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)


def screening_at_recall(
    positives: Sequence[float],
    negatives: Sequence[float],
    recall: float = SCREENING_RECALL,
) -> float | None:
    """The share of negatives a cut-off drops while it keeps ``recall`` of the positives.

    The cut-off is the highest score that still keeps at least ``recall`` of
    the positives at or above it: what a pre-filter in front of a costlier
    scorer would save.

    Args:
        positives: Scores of the relevant items.
        negatives: Scores of the irrelevant items.
        recall: Share of positives that must be kept.

    Returns:
        The share of negatives below the cut-off, or None when either side is
        empty.
    """
    if not positives or not negatives:
        return None
    ordered = sorted(positives, reverse=True)
    keep = math.ceil(recall * len(ordered))
    cut = ordered[keep - 1]
    return sum(1 for v in negatives if v < cut) / len(negatives)


def macro_f1(truth: Sequence[str], predicted: Sequence[str]) -> float | None:
    """Macro-averaged F1 over the classes present in ``truth``.

    Args:
        truth: The labels.
        predicted: The answers, one per label.

    Returns:
        The macro F1, or None for no labels.
    """
    classes = sorted(set(truth))
    if not classes:
        return None
    scores = []
    for c in classes:
        tp = sum(1 for t, p in zip(truth, predicted, strict=True) if t == c and p == c)
        fp = sum(1 for t, p in zip(truth, predicted, strict=True) if t != c and p == c)
        fn = sum(1 for t, p in zip(truth, predicted, strict=True) if t == c and p != c)
        denom = 2 * tp + fp + fn
        scores.append(2 * tp / denom if denom else 0.0)
    return math.fsum(scores) / len(scores)


def cluster_bootstrap(
    clusters: Mapping[str, Sequence[int]],
    statistic: Any,
    draws: int = BOOTSTRAP_DRAWS,
    seed: int = BOOTSTRAP_SEED,
) -> tuple[float, float] | None:
    """A percentile interval from resampling whole clusters (questions).

    Pairs of one question are not independent, so the question is the unit
    that is resampled.

    Args:
        clusters: Cluster id to the indices of its items.
        statistic: Called with a list of indices; returns a float or None.
        draws: Bootstrap draws.
        seed: Seed of the draws.

    Returns:
        The 2.5 % and 97.5 % quantiles, or None when no draw gave a value.
    """
    rng = random.Random(seed)
    keys = sorted(clusters)
    values = []
    for _ in range(draws):
        indices: list[int] = []
        for _k in keys:
            indices.extend(clusters[rng.choice(keys)])
        v = statistic(indices)
        if v is not None:
            values.append(v)
    if not values:
        return None
    values.sort()
    lo = values[int(CI_LOWER_QUANTILE * (len(values) - 1))]
    hi = values[int(CI_UPPER_QUANTILE * (len(values) - 1))]
    return (lo, hi)


# =============================================================================
# I/O
# =============================================================================


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    """The rows of a JSON-lines file (blank lines skipped).

    Args:
        path: The file.

    Returns:
        One dict per line.
    """
    with path.open(encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def write_jsonl(path: Path, rows: Iterable[Mapping[str, Any]]) -> None:
    """Write rows as JSON lines, replacing the file.

    Args:
        path: The file.
        rows: The rows.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    tmp.replace(path)


def _http_get(url: str, timeout: float = HTTP_TIMEOUT_SECONDS) -> bytes:
    """GET a URL and return its body.

    Args:
        url: The URL.
        timeout: Seconds.

    Returns:
        The body.
    """
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as response:  # noqa: S310 (fixed hosts)
        body: bytes = response.read()
        return body


class EUtils:
    """A paced E-utilities client (three requests a second, no key)."""

    def __init__(self) -> None:
        """Create the client."""
        self._last = 0.0

    def get(self, endpoint: str, params: Mapping[str, str]) -> bytes:
        """One E-utilities request, paced.

        Args:
            endpoint: ``esearch.fcgi`` or ``efetch.fcgi``.
            params: Query parameters.

        Returns:
            The body.
        """
        wait = EUTILS_MIN_INTERVAL_SECONDS - (time.monotonic() - self._last)
        if wait > 0:
            time.sleep(wait)
        query = urllib.parse.urlencode({**params, "tool": EUTILS_TOOL})
        for attempt in range(EUTILS_RETRIES + 1):
            try:
                return _http_get(f"{EUTILS_BASE}{endpoint}?{query}", EUTILS_TIMEOUT_SECONDS)
            except urllib.error.HTTPError as e:
                if e.code not in _RETRYABLE_STATUSES or attempt == EUTILS_RETRIES:
                    raise
                time.sleep(EUTILS_BACKOFF_SECONDS * 2**attempt)
            finally:
                self._last = time.monotonic()
        raise AssertionError("unreachable")

    def count_and_ids(self, term: str, retstart: int, retmax: int) -> tuple[int, list[str]]:
        """esearch: the hit count and one page of PMIDs.

        Args:
            term: The query.
            retstart: First hit.
            retmax: Page size.

        Returns:
            (count, pmids)
        """
        body = self.get("esearch.fcgi", {"db": "pubmed", "term": term, "retmode": "json",
                                         "retstart": str(retstart), "retmax": str(retmax)})
        result = json.loads(body)["esearchresult"]
        return int(result["count"]), list(result.get("idlist", []))

    def fetch(self, pmids: Sequence[str]) -> list[PubMedRecord]:
        """efetch: the records of some PMIDs.

        Args:
            pmids: PMIDs.

        Returns:
            Their records, in PubMed's order.
        """
        records: list[PubMedRecord] = []
        for start in range(0, len(pmids), EUTILS_FETCH_BATCH):
            batch = pmids[start:start + EUTILS_FETCH_BATCH]
            body = self.get("efetch.fcgi", {"db": "pubmed", "id": ",".join(batch), "retmode": "xml"})
            records.extend(parse_pubmed_xml(body))
        return records


# =============================================================================
# Corpora
# =============================================================================


def _beir_file(repo: str, revision: str, path: str, cache: Path) -> Path:
    """A BEIR file at a pinned revision, downloaded once into ``cache``.

    Args:
        repo: The Hugging Face dataset repository.
        revision: The pinned commit.
        path: The file's path in the repository.
        cache: Download folder.

    Returns:
        The local file.
    """
    local = cache / revision / path
    if not local.exists():
        local.parent.mkdir(parents=True, exist_ok=True)
        url = HF_DATASET_FILE_URL.format(repo=repo, revision=revision, path=path)
        tmp = local.with_suffix(local.suffix + ".part")
        tmp.write_bytes(_http_get(url))
        tmp.replace(local)
    return local


def _read_parquet(path: Path) -> list[dict[str, Any]]:
    """The rows of a parquet file (needs pyarrow).

    Args:
        path: The file.

    Returns:
        One dict per row.
    """
    try:
        import pyarrow.parquet as pq
    except ImportError as e:  # pragma: no cover - environment
        raise SystemExit(f"pyarrow is needed to read the BEIR files ({e}): uv pip install pyarrow") from e
    rows: list[dict[str, Any]] = pq.read_table(path).to_pylist()
    return rows


def load_trec_covid(cache: Path) -> tuple[dict[str, str], dict[str, dict[str, str]], list[tuple[str, str, int]]]:
    """TREC-COVID's questions, documents and human grades (BEIR, pinned).

    Args:
        cache: Download folder.

    Returns:
        (topic id -> question, doc id -> {"title", "abstract"}, qrels)
    """
    queries = {
        str(r["_id"]): str(r["text"])
        for r in _read_parquet(_beir_file(BEIR_CORPUS_REPO, BEIR_CORPUS_REVISION, BEIR_QUERIES_PATH, cache))
    }
    corpus = {
        str(r["_id"]): {"title": str(r.get("title") or ""), "abstract": str(r.get("text") or "")}
        for r in _read_parquet(_beir_file(BEIR_CORPUS_REPO, BEIR_CORPUS_REVISION, BEIR_CORPUS_PATH, cache))
    }
    qrels_text = _beir_file(BEIR_QRELS_REPO, BEIR_QRELS_REVISION, BEIR_QRELS_PATH, cache).read_text()
    qrels = []
    for line in qrels_text.splitlines()[1:]:
        topic, doc, grade = line.split("\t")
        qrels.append((topic, doc, int(grade)))
    return queries, corpus, qrels


def sample_relevance(
    qrels: Sequence[tuple[str, str, int]],
    corpus: Mapping[str, Mapping[str, str]],
    per_grade: int,
    seed: int,
) -> list[dict[str, Any]]:
    """Up to ``per_grade`` judged pairs per question and grade, seeded.

    A document without an abstract is never drawn: the app scores abstracts.

    Args:
        qrels: (topic, doc, grade) judgements.
        corpus: Documents by id.
        per_grade: Pairs per question and grade.
        seed: Seed of the draw.

    Returns:
        Label rows: id, topic_id, doc_id, grade.
    """
    rng = random.Random(seed)
    pools: dict[tuple[str, int], list[str]] = defaultdict(list)
    for topic, doc, grade in qrels:
        if grade in RELEVANCE_GRADES and corpus.get(doc, {}).get("abstract", "").strip():
            pools[(topic, grade)].append(doc)
    rows = []
    for (topic, grade) in sorted(pools, key=lambda k: (int(k[0]), k[1])):
        docs = sorted(set(pools[(topic, grade)]))
        for doc in rng.sample(docs, min(per_grade, len(docs))):
            rows.append({"id": f"t{topic}-{doc}", "topic_id": topic, "doc_id": doc, "grade": grade})
    return rows


def relevance_items(
    labels: Sequence[Mapping[str, Any]],
    queries: Mapping[str, str],
    corpus: Mapping[str, Mapping[str, str]],
) -> list[dict[str, Any]]:
    """The label rows with their question and abstract.

    Args:
        labels: Label rows.
        queries: Questions by topic id.
        corpus: Documents by id.

    Returns:
        Item rows: the label row plus question, title, abstract.
    """
    return [
        {**row, "question": queries[row["topic_id"]], "title": corpus[row["doc_id"]]["title"],
         "abstract": corpus[row["doc_id"]]["abstract"]}
        for row in labels
    ]


def sample_design(eutils: EUtils, per_class: int, seed: int) -> list[tuple[str, PubMedRecord]]:
    """Up to ``per_class`` human-indexed, labelled abstracts per design.

    Each class searches its pre-filter once per year of ``DESIGN_YEARS``
    (at most ``ESEARCH_MAX_RETRIEVABLE`` ids a year), draws from the union,
    fetches the records and keeps those whose own indexing gives that class.

    Args:
        eutils: The client.
        per_class: Records per class.
        seed: Seed of the draw.

    Returns:
        (label, record) pairs.
    """
    rng = random.Random(seed)
    chosen: list[tuple[str, PubMedRecord]] = []
    seen: set[str] = set()
    for label, prefilter in DESIGN_QUERIES.items():
        pool: list[str] = []
        total = 0
        for year in DESIGN_YEARS:
            term = f"({prefilter}) AND {year}[dp] AND hasabstract AND english[la] AND medline[sb]"
            count, ids = eutils.count_and_ids(term, 0, ESEARCH_MAX_RETRIEVABLE)
            total += count
            pool.extend(ids)
        pool = sorted(set(pool))
        pmids = rng.sample(pool, min(len(pool), per_class * DESIGN_OVERDRAW))
        kept = 0
        for record in eutils.fetch(pmids):
            if kept >= per_class:
                break
            if record.pmid in seen or not record.human_indexed or not record.abstract:
                continue
            if design_label(record.publication_types, record.mesh_headings) != label:
                continue
            seen.add(record.pmid)
            chosen.append((label, record))
            kept += 1
        print(f"{label}: {total} hits, {len(pmids)} drawn, {kept} kept", file=sys.stderr)
    return chosen


def design_rows(chosen: Sequence[tuple[str, PubMedRecord]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Label rows and item rows of the drawn records.

    Args:
        chosen: (label, record) pairs.

    Returns:
        (labels, items)
    """
    labels, items = [], []
    for label, rec in chosen:
        row = {"id": f"pmid-{rec.pmid}", "pmid": rec.pmid, "label": label,
               "indexing_method": rec.indexing_method}
        labels.append(row)
        items.append({**row, "title": rec.title, "abstract": rec.abstract, "year": rec.year})
    return labels, items


def materialise_design(eutils: EUtils, labels: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Item rows of committed design labels, fetched again from PubMed.

    A record whose indexing no longer gives its label is reported and left
    out rather than relabelled.

    Args:
        eutils: The client.
        labels: Label rows.

    Returns:
        Item rows.
    """
    records = {r.pmid: r for r in eutils.fetch([row["pmid"] for row in labels])}
    items = []
    for row in labels:
        rec = records.get(row["pmid"])
        if rec is None or design_label(rec.publication_types, rec.mesh_headings) != row["label"]:
            print(f"pmid {row['pmid']}: no longer labelled {row['label']}; left out", file=sys.stderr)
            continue
        items.append({**row, "title": rec.title, "abstract": rec.abstract, "year": rec.year})
    return items


# =============================================================================
# Runs
# =============================================================================


def _done_ids(path: Path) -> set[str]:
    """Ids already answered in a prediction file (a resumed run skips them).

    A row marked ``failed`` (no answer: an unreachable provider, a refused
    key) is not done, so a resumed run asks again; the analysis reads the
    last row of each id.

    Args:
        path: The prediction file.

    Returns:
        The ids.
    """
    if not path.exists():
        return set()
    return {row["id"] for row in read_jsonl(path) if not row.get("failed")}


def run_manta(task: str, items: Sequence[Mapping[str, Any]], out: Path, model_path: str, device: str) -> None:
    """MANTA's answers to every item, appended to ``out`` one line each.

    Args:
        task: ``relevance`` or ``design``.
        items: Item rows.
        out: Prediction file (appended; done ids skipped).
        model_path: A local copy of a MANTA repository.
        device: ``cpu`` or ``cuda``.
    """
    sys.path.insert(0, str(Path(model_path).resolve()))
    from manta import Manta  # type: ignore[import-not-found]  # the model repository's own package

    done = _done_ids(out)
    todo = [it for it in items if it["id"] not in done]
    print(f"{len(done)} done, {len(todo)} to go", file=sys.stderr)
    if not todo:
        return
    model = Manta.from_pretrained(model_path, device=device)
    name = Path(model_path).name
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("a", encoding="utf-8") as f:
        for n, it in enumerate(todo, 1):
            if task == "relevance":
                request = relevance_request(it["id"], it["question"], it["title"], it["abstract"])
                qid = "relevance"
            else:
                request = design_request(it["id"], it["title"], it["abstract"])
                qid = "study_design"
            start = time.perf_counter()
            result = model.predict(request)
            seconds = time.perf_counter() - start
            answer = result["questions"][qid]
            row: dict[str, Any] = {
                "id": it["id"],
                "evaluator": name,
                "probabilities": answer["probabilities"],
                "prompt_tokens": result["prompt_tokens"],
                "truncated": result["truncated"],
                "seconds": round(seconds, 3),
            }
            if task == "relevance":
                row["score"] = expected_score(answer["probabilities"])
            else:
                row["design"] = answer["answer"]
                row["confidence"] = answer["probabilities"][answer["answer"]]
            f.write(json.dumps(row, sort_keys=True) + "\n")
            f.flush()
            if n % 10 == 0 or n == len(todo):
                print(f"{n}/{len(todo)} ({seconds:.1f} s last)", file=sys.stderr)


def cosine(a: Sequence[float], b: Sequence[float]) -> float:
    """Cosine similarity of two vectors (0 for a zero vector).

    Args:
        a: First vector.
        b: Second vector.

    Returns:
        The cosine.
    """
    na = math.sqrt(math.fsum(x * x for x in a))
    nb = math.sqrt(math.fsum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return math.fsum(x * y for x, y in zip(a, b, strict=True)) / (na * nb)


def run_embed(items: Sequence[Mapping[str, Any]], out: Path, model: str | None) -> None:
    """The app's embedder as a relevance baseline: cosine(question, article).

    This is what the app computes for free when it indexes a document; a
    decision model has to beat it to earn its cost.

    Args:
        items: Relevance item rows.
        out: Prediction file (replaced).
        model: FastEmbed model name, or None for the app's default.
    """
    from bmlibrarian_lite.embeddings import LiteEmbedder

    embedder = LiteEmbedder(model) if model else LiteEmbedder()
    questions = sorted({it["question"] for it in items})
    qvec = dict(zip(questions, embedder.embed(questions), strict=True))
    start = time.perf_counter()
    dvecs = embedder.embed([f"{it['title']}\n\n{it['abstract']}" for it in items])
    per_item = (time.perf_counter() - start) / max(1, len(items))
    name = f"embedding:{embedder.model_name}"
    write_jsonl(out, [
        {"id": it["id"], "evaluator": name, "score": cosine(qvec[it["question"]], v),
         "failed": False, "seconds": round(per_item, 4)}
        for it, v in zip(items, dvecs, strict=True)
    ])


# bmlib's rule-based types that the app's classifier has no option for.
_RULE_TYPES_AS_OTHER = frozenset({"quasi_experimental", "pilot_feasibility", "interventional_single_arm"})


def rule_design(extracted: str) -> str:
    """The rule-based study type of bmlib as one of the classifier's options.

    Args:
        extracted: ``get_extracted_study_type``'s answer.

    Returns:
        A ``DESIGN_OPTIONS`` key, or ``unknown`` for no match.
    """
    if extracted in DESIGN_OPTIONS:
        return extracted
    return "other" if extracted in _RULE_TYPES_AS_OTHER else "unknown"


def run_rules(items: Sequence[Mapping[str, Any]], out: Path) -> None:
    """The keyword rules of bmlib as a design baseline (no model, no cost).

    Args:
        items: Design item rows.
        out: Prediction file (replaced).
    """
    from bmlib.quality.extractors import extract_study_type, get_extracted_study_type

    rows = []
    for it in items:
        start = time.perf_counter()
        found = get_extracted_study_type(extract_study_type({"title": it["title"], "abstract": it["abstract"]}))
        rows.append({"id": it["id"], "evaluator": "bmlib rules", "design": rule_design(str(found)),
                     "rule_type": found, "seconds": round(time.perf_counter() - start, 4)})
    write_jsonl(out, rows)


def run_llm(task: str, items: Sequence[Mapping[str, Any]], out: Path, model: str) -> None:
    """The app's own agent's answers to every item, appended to ``out``.

    Args:
        task: ``relevance`` (LiteScoringAgent) or ``design``
            (LiteStudyClassifier).
        items: Item rows.
        out: Prediction file (appended; done ids skipped).
        model: ``provider:model``.
    """
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.data_models import LiteDocument

    provider, _, model_name = model.partition(":")
    config = LiteConfig()
    config.models.default_provider = provider
    config.models.default_model = model_name
    if task == "relevance":
        from bmlibrarian_lite.agents.scoring_agent import LiteScoringAgent

        agent: Any = LiteScoringAgent(config)
    else:
        from bmlibrarian_lite.quality.study_classifier import LiteStudyClassifier

        agent = LiteStudyClassifier(config)

    def answer(it: Mapping[str, Any]) -> dict[str, Any]:
        doc = LiteDocument(id=it["id"], title=it["title"], abstract=it["abstract"])
        start = time.perf_counter()
        row: dict[str, Any] = {"id": it["id"], "evaluator": model}
        if task == "relevance":
            scored = agent.score_document(it["question"], doc)
            row.update(score=scored.score, explanation=scored.explanation,
                       failed=scored.score < SCORE_MIN)
        else:
            # The classifier answers "unknown" both for a reply it could not
            # read and for a call that failed; either way the app gets no
            # design. It is retried on resume and counted as no design.
            c = agent.classify(doc)
            row.update(design=c.study_design.value, confidence=c.confidence,
                       raw_response=c.raw_response,
                       failed=c.study_design.value == "unknown")
        row["seconds"] = round(time.perf_counter() - start, 3)
        return row

    done = _done_ids(out)
    todo = [it for it in items if it["id"] not in done]
    print(f"{len(done)} done, {len(todo)} to go", file=sys.stderr)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("a", encoding="utf-8") as f, ThreadPoolExecutor(LLM_WORKERS) as pool:
        for n, row in enumerate(pool.map(answer, todo), 1):
            f.write(json.dumps(row, sort_keys=True) + "\n")
            f.flush()
            if n % 20 == 0 or n == len(todo):
                print(f"{n}/{len(todo)}", file=sys.stderr)


# =============================================================================
# Analysis
# =============================================================================


def _fmt(value: float | None, digits: int = 3) -> str:
    """A number for a table, or an em dash for none."""
    return "—" if value is None else f"{value:.{digits}f}"


def _fmt_ci(ci: tuple[float, float] | None, digits: int = 3) -> str:
    """An interval for a table."""
    return "" if ci is None else f" [{ci[0]:.{digits}f}, {ci[1]:.{digits}f}]"


def _failed(pred: Mapping[str, Any]) -> bool:
    """Whether a relevance row holds no score.

    A row says so itself (``failed``); an older row without the flag failed
    when its score is off the app's scale (the agent's negative error codes).

    Args:
        pred: A prediction row.

    Returns:
        True for no score.
    """
    if "failed" in pred:
        return bool(pred["failed"])
    return bool(pred["score"] < SCORE_MIN)


def relevance_metrics(labels: Sequence[Mapping[str, Any]], preds: Mapping[str, Mapping[str, Any]]) -> dict[str, Any]:
    """Agreement of one evaluator's scores with the human grades.

    A failed scoring (a negative score from the app's agent) is counted
    apart, never as a score.

    Args:
        labels: Label rows (id, topic_id, grade).
        preds: Prediction rows by id.

    Returns:
        The metrics.
    """
    rows = [(r, preds[r["id"]]) for r in labels if r["id"] in preds]
    failed = sum(1 for _, p in rows if _failed(p))
    rows = [(r, p) for r, p in rows if not _failed(p)]
    grades = [r["grade"] for r, _ in rows]
    scores = [float(p["score"]) for _, p in rows]
    clusters: dict[str, list[int]] = defaultdict(list)
    for i, (r, _) in enumerate(rows):
        clusters[r["topic_id"]].append(i)

    def rho(idx: Sequence[int]) -> float | None:
        return spearman([scores[i] for i in idx], [grades[i] for i in idx])

    def auc_at(threshold: int) -> Any:
        def stat(idx: Sequence[int]) -> float | None:
            pos = [scores[i] for i in idx if grades[i] >= threshold]
            neg = [scores[i] for i in idx if grades[i] < threshold]
            return auc(pos, neg)
        return stat

    def screening(idx: Sequence[int]) -> float | None:
        pos = [scores[i] for i in idx if grades[i] >= 1]
        neg = [scores[i] for i in idx if grades[i] < 1]
        return screening_at_recall(pos, neg)

    def within_topic_auc(idx: Sequence[int]) -> float | None:
        per_topic = defaultdict(list)
        for i in idx:
            per_topic[rows[i][0]["topic_id"]].append(i)
        values = [v for t in per_topic.values() if (v := auc_at(1)(t)) is not None]
        return math.fsum(values) / len(values) if values else None

    all_idx = list(range(len(rows)))
    per_grade_mean = {
        g: (math.fsum(s for s, gg in zip(scores, grades, strict=True) if gg == g) / c if (c := grades.count(g)) else None)
        for g in RELEVANCE_GRADES
    }
    seconds = [p["seconds"] for _, p in rows if "seconds" in p]
    return {
        "n": len(rows),
        "failed": failed,
        "missing": sum(1 for r in labels if r["id"] not in preds),
        "spearman": rho(all_idx),
        "spearman_ci": cluster_bootstrap(clusters, rho),
        "auc_relevant": auc_at(1)(all_idx),
        "auc_relevant_ci": cluster_bootstrap(clusters, auc_at(1)),
        "auc_fully_relevant": auc_at(2)(all_idx),
        "auc_fully_relevant_ci": cluster_bootstrap(clusters, auc_at(2)),
        "screened_out": screening(all_idx),
        "screened_out_ci": cluster_bootstrap(clusters, screening),
        "within_topic_auc": within_topic_auc(all_idx),
        "within_topic_auc_ci": cluster_bootstrap(clusters, within_topic_auc),
        "mean_score_by_grade": per_grade_mean,
        "median_seconds": sorted(seconds)[len(seconds) // 2] if seconds else None,
        "truncated": sum(1 for _, p in rows if p.get("truncated")),
    }


def design_metrics(labels: Sequence[Mapping[str, Any]], preds: Mapping[str, Mapping[str, Any]]) -> dict[str, Any]:
    """Agreement of one evaluator's designs with the indexers' labels.

    Args:
        labels: Label rows (id, label).
        preds: Prediction rows by id.

    Returns:
        The metrics, fine-grained and by ``DESIGN_GROUPS``.
    """
    rows = [(r["label"], preds[r["id"]]) for r in labels if r["id"] in preds]
    n = len(rows)
    truth = [t for t, _ in rows]
    answers = [str(p["design"]) for _, p in rows]
    correct = [t == a for t, a in zip(truth, answers, strict=True)]
    truth_g = [DESIGN_GROUPS.get(t, t) for t in truth]
    answers_g = [DESIGN_GROUPS.get(a, a) for a in answers]
    correct_g = [t == a for t, a in zip(truth_g, answers_g, strict=True)]
    stated = [p.get("confidence") for _, p in rows]
    confidences = [float(c) for c in stated if c is not None]
    # ECE only for an evaluator that states a confidence for every answer.
    ece = expected_calibration_error(confidences, correct) if len(confidences) == n else None
    per_class = {}
    for c in sorted(set(truth)):
        idx = [i for i, t in enumerate(truth) if t == c]
        hits = sum(1 for i in idx if correct[i])
        per_class[c] = {"n": len(idx), "recall": hits / len(idx),
                        "answers": dict(Counter(answers[i] for i in idx).most_common())}
    top3 = None
    if rows and all("probabilities" in p for _, p in rows):
        top3 = sum(
            1 for t, (_, p) in zip(truth, rows, strict=True)
            if t in sorted(p["probabilities"], key=p["probabilities"].get, reverse=True)[:3]
        ) / len(rows)
    seconds = [p["seconds"] for _, p in rows if "seconds" in p]
    return {
        "n": n,
        "missing": sum(1 for r in labels if r["id"] not in preds),
        "unknown_answers": answers.count("unknown"),
        "accuracy": sum(correct) / n if n else None,
        "accuracy_ci": wilson_interval(sum(correct), n),
        "macro_f1": macro_f1(truth, answers),
        "group_accuracy": sum(correct_g) / n if n else None,
        "group_accuracy_ci": wilson_interval(sum(correct_g), n),
        "group_macro_f1": macro_f1(truth_g, answers_g),
        "top3_accuracy": top3,
        "ece": ece,
        "per_class": per_class,
        "median_seconds": sorted(seconds)[len(seconds) // 2] if seconds else None,
        "truncated": sum(1 for _, p in rows if p.get("truncated")),
    }


def _relevance_table(results: Mapping[str, Mapping[str, Any]]) -> str:
    """A Markdown table of relevance metrics, one column per evaluator."""
    names = list(results)
    lines = ["| Metric | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]

    def line(label: str, key: str) -> str:
        cells = [_fmt(results[n][key]) + _fmt_ci(results[n].get(f"{key}_ci")) for n in names]
        return f"| {label} | " + " | ".join(cells) + " |"

    lines.append("| Pairs scored | " + " | ".join(str(results[n]["n"]) for n in names) + " |")
    lines.append("| Failed / missing | " + " | ".join(
        f"{results[n]['failed']} / {results[n]['missing']}" for n in names) + " |")
    lines.append(line("Spearman ρ with grade", "spearman"))
    lines.append(line("AUC, grade ≥ 1 vs 0", "auc_relevant"))
    lines.append(line("AUC, grade 2 vs ≤ 1", "auc_fully_relevant"))
    lines.append(line("Mean within-question AUC (≥ 1 vs 0)", "within_topic_auc"))
    lines.append(line("Grade-0 pairs dropped, keeping 95 % of grade ≥ 1", "screened_out"))
    for g in RELEVANCE_GRADES:
        lines.append(f"| Mean score, grade {g} | " + " | ".join(
            _fmt(results[n]["mean_score_by_grade"][g], 2) for n in names) + " |")
    lines.append("| Median seconds per pair | " + " | ".join(
        _fmt(results[n]["median_seconds"], 2) for n in names) + " |")
    return "\n".join(lines)


def _design_table(results: Mapping[str, Mapping[str, Any]]) -> str:
    """A Markdown table of design metrics, one column per evaluator."""
    names = list(results)
    lines = ["| Metric | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]

    def line(label: str, key: str) -> str:
        cells = [_fmt(results[n][key]) + _fmt_ci(results[n].get(f"{key}_ci")) for n in names]
        return f"| {label} | " + " | ".join(cells) + " |"

    lines.append("| Abstracts | " + " | ".join(str(results[n]["n"]) for n in names) + " |")
    lines.append(line("Accuracy (13 options)", "accuracy"))
    lines.append(line("Macro F1", "macro_f1"))
    lines.append(line("Accuracy, grouped designs", "group_accuracy"))
    lines.append(line("Macro F1, grouped designs", "group_macro_f1"))
    lines.append(line("Top-3 accuracy", "top3_accuracy"))
    lines.append(line("ECE-15 of the stated confidence", "ece"))
    lines.append("| \"unknown\" answers | " + " | ".join(
        str(results[n]["unknown_answers"]) for n in names) + " |")
    classes = sorted({c for n in names for c in results[n]["per_class"]})
    for c in classes:
        lines.append(f"| Recall: {c} | " + " | ".join(
            _fmt(results[n]["per_class"].get(c, {}).get("recall"), 2) for n in names) + " |")
    lines.append("| Median seconds per abstract | " + " | ".join(
        _fmt(results[n]["median_seconds"], 2) for n in names) + " |")
    return "\n".join(lines)


def analyse(task: str, labels: Sequence[Mapping[str, Any]], pred_files: Sequence[Path]) -> dict[str, Any]:
    """Metrics of every prediction file against the labels, printed as Markdown.

    Args:
        task: ``relevance`` or ``design``.
        labels: Label rows.
        pred_files: Prediction files.

    Returns:
        Evaluator name to metrics.
    """
    results: dict[str, Any] = {}
    all_preds: dict[str, dict[str, Any]] = {}
    for path in pred_files:
        rows = read_jsonl(path)
        name = rows[0]["evaluator"] if rows else path.stem
        preds = {r["id"]: r for r in rows}
        all_preds[name] = preds
        results[name] = (relevance_metrics if task == "relevance" else design_metrics)(labels, preds)
    print(_relevance_table(results) if task == "relevance" else _design_table(results))
    names = list(all_preds)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            shared = [k for k in all_preds[a] if k in all_preds[b]]
            if task == "relevance":
                pairs = [(all_preds[a][k]["score"], all_preds[b][k]["score"]) for k in shared
                         if not _failed(all_preds[a][k]) and not _failed(all_preds[b][k])]
                r = spearman([x for x, _ in pairs], [y for _, y in pairs])
                print(f"\nSpearman ρ {a} vs {b}: {_fmt(r)} (n={len(pairs)})")
            else:
                same = sum(1 for k in shared if all_preds[a][k]["design"] == all_preds[b][k]["design"])
                print(f"\nSame design {a} vs {b}: {same}/{len(shared)}")
    return results


# =============================================================================
# Command line
# =============================================================================


def main(argv: Sequence[str] | None = None) -> int:
    """The command line.

    Args:
        argv: Arguments (default: ``sys.argv[1:]``).

    Returns:
        The exit code.
    """
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("build-relevance", help="draw TREC-COVID pairs")
    p.add_argument("--per-grade", type=int, default=2)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--labels", type=Path, required=True)
    p.add_argument("--items", type=Path, required=True)
    p.add_argument("--cache", type=Path, default=Path("tmp/manta_benchmark/beir"))

    p = sub.add_parser("build-design", help="draw human-indexed PubMed abstracts")
    p.add_argument("--per-class", type=int, default=30)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--labels", type=Path, required=True)
    p.add_argument("--items", type=Path, required=True)

    p = sub.add_parser("materialise", help="fetch the texts of committed labels")
    p.add_argument("task", choices=("relevance", "design"))
    p.add_argument("labels", type=Path)
    p.add_argument("items", type=Path)
    p.add_argument("--cache", type=Path, default=Path("tmp/manta_benchmark/beir"))

    p = sub.add_parser("run-embed", help="the app's embedder as a relevance baseline")
    p.add_argument("items", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--model", default=None)

    p = sub.add_parser("run-rules", help="bmlib's keyword rules as a design baseline")
    p.add_argument("items", type=Path)
    p.add_argument("out", type=Path)

    for name in ("run-manta", "run-llm"):
        p = sub.add_parser(name)
        p.add_argument("task", choices=("relevance", "design"))
        p.add_argument("items", type=Path)
        p.add_argument("out", type=Path)
        p.add_argument("--model", required=True)
        p.add_argument("--limit", type=int, default=None, help="only the first N items")
        if name == "run-manta":
            p.add_argument("--device", default="cpu")

    p = sub.add_parser("analyse")
    p.add_argument("task", choices=("relevance", "design"))
    p.add_argument("labels", type=Path)
    p.add_argument("preds", type=Path, nargs="+")
    p.add_argument("--json", type=Path, default=None, help="also write the metrics here")

    args = parser.parse_args(argv)
    if args.command == "build-relevance":
        queries, corpus, qrels = load_trec_covid(args.cache)
        labels = sample_relevance(qrels, corpus, args.per_grade, args.seed)
        write_jsonl(args.labels, labels)
        write_jsonl(args.items, relevance_items(labels, queries, corpus))
        print(f"{len(labels)} pairs over {len({r['topic_id'] for r in labels})} questions", file=sys.stderr)
    elif args.command == "build-design":
        labels, items = design_rows(sample_design(EUtils(), args.per_class, args.seed))
        write_jsonl(args.labels, labels)
        write_jsonl(args.items, items)
        print(f"{len(labels)} abstracts", file=sys.stderr)
    elif args.command == "materialise":
        labels = read_jsonl(args.labels)
        if args.task == "relevance":
            queries, corpus, _ = load_trec_covid(args.cache)
            write_jsonl(args.items, relevance_items(labels, queries, corpus))
        else:
            write_jsonl(args.items, materialise_design(EUtils(), labels))
    elif args.command == "run-rules":
        run_rules(read_jsonl(args.items), args.out)
    elif args.command == "run-embed":
        run_embed(read_jsonl(args.items), args.out, args.model)
    elif args.command in ("run-manta", "run-llm"):
        items = read_jsonl(args.items)[: args.limit]
        if args.command == "run-manta":
            run_manta(args.task, items, args.out, args.model, args.device)
        else:
            run_llm(args.task, items, args.out, args.model)
    else:
        results = analyse(args.task, read_jsonl(args.labels), args.preds)
        if args.json:
            args.json.write_text(json.dumps(results, indent=2, sort_keys=True, default=str) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
