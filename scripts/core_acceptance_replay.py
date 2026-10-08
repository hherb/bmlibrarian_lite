#!/usr/bin/env python3
r"""Stage C1 acceptance: replay the #480 spike's not-open-access rows through CORE.

The #480 channels spike (`doc/developer/unpaywall_pdf_survey/spikes/`) found
that CORE's extracted text recovered 14 of the 149 Unpaywall failures whose
Europe PMC record is not open access. This replays those 149 DOIs through the
shipped client (`core_api.CoreTextClient`), so the query form, the field names
and the DOI-match rule are checked against the live service rather than the
fixture written from the spike.

The key is read from `~/.bmlibrarian_lite/config.json` (`discovery.core_api_key`)
or the `CORE_API_KEY` environment variable, and is never printed. Requests are
paced at CORE's 0.4/s, so a full run takes about seven minutes.

Rows are appended to the output file one per DOI, and a re-run skips DOIs
already there: re-analyse, never re-fetch.

Usage:
    python scripts/core_acceptance_replay.py --out tmp/core_acceptance.jsonl

Pass criterion (plan, Task 10): at least 14 of the 149 served, or every one of
the spike's 14 recoveries that CORE did not answer 429 to.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import CORE_MIN_FULLTEXT_CHARS
from bmlibrarian_lite.core_api import CoreFetch, default_core_client

REPO = Path(__file__).resolve().parents[1]
SPIKE_ROWS = REPO / "doc/developer/unpaywall_pdf_survey/spikes/2026-10-04-channels.jsonl"
#: The spike's stratum whose Unpaywall PDF is the article's only free copy.
NOT_OPEN_ACCESS = "epmc-not-oa"


def _outcome(fetch: CoreFetch) -> str:
    """Name a CoreFetch's outcome for the report."""
    if fetch.text is not None:
        return "served"
    if fetch.refused_key:
        return "key_refused"
    return "unreachable" if fetch.failure is not None else "absent"


def main() -> int:
    """Replay the rows, then summarise every row in the output file.

    Returns:
        0 on a completed run; 2 when no CORE key is configured.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True, help="JSONL file to append rows to")
    args = parser.parse_args()

    client = default_core_client(LiteConfig.load().discovery.core_api_key)
    if client is None:
        print("No CORE key configured (config.json discovery.core_api_key or CORE_API_KEY).")
        return 2

    rows = [json.loads(line) for line in SPIKE_ROWS.read_text(encoding="utf-8").splitlines()]
    rows = [row for row in rows if row["stratum"] == NOT_OPEN_ACCESS]
    done: dict[str, dict[str, object]] = {}
    if args.out.exists():
        for line in args.out.read_text(encoding="utf-8").splitlines():
            record = json.loads(line)
            done[record["doi"]] = record

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("a", encoding="utf-8") as out:
        for index, row in enumerate(rows, 1):
            if row["doi"] in done:
                continue
            fetch = client.fetch_full_text(row["doi"])
            record = {
                "doi": row["doi"],
                "spike_chars": row["core"].get("full_text_chars", 0),
                "spike_outcome": row["core"].get("outcome"),
                "outcome": _outcome(fetch),
                "chars": len(fetch.text) if fetch.text else 0,
                "failure": fetch.failure.describe() if fetch.failure else None,
            }
            out.write(json.dumps(record) + "\n")
            out.flush()
            done[row["doi"]] = record
            print(f"{index}/{len(rows)} {record['outcome']} {record['failure'] or ''}", flush=True)

    records = list(done.values())
    print("outcomes:", Counter(r["outcome"] for r in records))
    print("failures:", Counter(r["failure"] for r in records if r["failure"]))
    recoveries = [r for r in records if r["spike_chars"] >= CORE_MIN_FULLTEXT_CHARS]
    served = sum(r["outcome"] == "served" for r in recoveries)
    print(f"spike recoveries: {len(recoveries)}; served now: {served}")
    for record in recoveries:
        if record["outcome"] != "served":
            print("  not served now:", record["doi"], record["outcome"], record["failure"])
    print("served total:", sum(r["outcome"] == "served" for r in records), "of", len(records))
    return 0


if __name__ == "__main__":
    sys.exit(main())
