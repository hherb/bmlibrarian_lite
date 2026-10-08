#!/usr/bin/env python3
r"""Stage C2 probe: record what Elsevier's Article Retrieval API answers.

The #480 spike recorded only that Elsevier refuses every request from outside
the institution ("AUTHENTICATION_ERROR"), not its status, headers or body,
and nothing from inside. Stage C2's rules and fixtures need those shapes, so
this asks a few DOIs, each as PDF and as JSON metadata, and writes one JSON
row per request: the status, the response headers Elsevier names (`X-ELS-*`,
`Content-Type`), whether the body starts `%PDF`, its size, and, for anything
that is not a PDF, its first bytes.

The key is read from the `ELSEVIER_API_KEY` environment variable (and an
institutional token from `ELSEVIER_INSTTOKEN`, if set). Neither is ever
printed or written: each occurrence in a recorded body or header is replaced
before the row is written.

Run it once off the institution's network and once on it, with a different
`--label`, so both answers are recorded.

Usage:
    ELSEVIER_API_KEY=... python scripts/elsevier_probe.py \
        --label off-network --out tmp/elsevier_probe.jsonl
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import requests

from bmlibrarian_lite.constants import EUROPEPMC_USER_AGENT
from bmlibrarian_lite.elsevier_api import elsevier_article_url

#: Heliyon is fully open access; the AJM articles are subscription content;
#: the last DOI is not Elsevier's, to see how a foreign DOI is answered.
DOIS = (
    "10.1016/j.heliyon.2024.e24778",
    "10.1016/j.amjmed.2018.11.010",
    "10.1016/j.amjmed.2019.08.004",
    "10.1371/journal.pone.0000217",
)
ACCEPTS = ("application/pdf", "application/json")
#: Elsevier allows 10/s; this probe asks one request every two seconds.
PAUSE_SECONDS = 2.0
TIMEOUT_SECONDS = 60.0
#: Bytes of a non-PDF body kept in the row.
BODY_PREVIEW_BYTES = 2000
REDACTED = "<redacted>"


def _redact(text: str, secrets: tuple[str, ...]) -> str:
    """Replace every secret in text."""
    for secret in secrets:
        if secret:
            text = text.replace(secret, REDACTED)
    return text


def probe(doi: str, accept: str, key: str, token: str | None) -> dict[str, object]:
    """Ask one DOI in one format and describe the answer."""
    headers = {"X-ELS-APIKey": key, "Accept": accept, "User-Agent": EUROPEPMC_USER_AGENT}
    if token:
        headers["X-ELS-Insttoken"] = token
    secrets = (key, token or "")
    row: dict[str, object] = {"doi": doi, "accept": accept}
    try:
        # Never followed: a redirect would carry X-ELS-APIKey wherever it
        # points. A 3xx is recorded as its status.
        response = requests.get(
            elsevier_article_url(doi),
            headers=headers,
            timeout=TIMEOUT_SECONDS,
            allow_redirects=False,
        )
    except requests.RequestException as exc:
        row["error"] = _redact(type(exc).__name__ + ": " + str(exc), secrets)
        return row
    body = response.content
    row["status"] = response.status_code
    row["headers"] = {
        name: _redact(value, secrets)
        for name, value in response.headers.items()
        if name.lower().startswith("x-els-") or name.lower() == "content-type"
    }
    row["is_pdf"] = body.startswith(b"%PDF")
    row["bytes"] = len(body)
    if not row["is_pdf"]:
        row["body"] = _redact(body[:BODY_PREVIEW_BYTES].decode("utf-8", "replace"), secrets)
    return row


def main() -> int:
    """Probe every DOI in every format and append the rows.

    Returns:
        0 on a completed run; 2 when no key is in the environment.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--label", required=True, help="where this ran, e.g. off-network")
    parser.add_argument("--out", type=Path, required=True, help="JSONL file to append rows to")
    args = parser.parse_args()

    key = os.environ.get("ELSEVIER_API_KEY", "").strip()
    token = os.environ.get("ELSEVIER_INSTTOKEN", "").strip() or None
    if not key:
        print("Set ELSEVIER_API_KEY (and ELSEVIER_INSTTOKEN, if you have one).")
        return 2

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("a", encoding="utf-8") as out:
        for doi in DOIS:
            for accept in ACCEPTS:
                row = probe(doi, accept, key, token)
                row["label"] = args.label
                row["insttoken"] = token is not None
                out.write(json.dumps(row) + "\n")
                recorded = row.get("headers", {})
                assert isinstance(recorded, dict)
                status_header = next(
                    (v for k, v in recorded.items() if k.lower() == "x-els-status"), ""
                )
                print(row.get("status", row.get("error")), accept, doi, status_header)
                time.sleep(PAUSE_SECONDS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
