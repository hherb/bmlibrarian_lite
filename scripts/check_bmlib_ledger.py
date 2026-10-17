#!/usr/bin/env python3
"""Check that every bmlib change since 0.10.0 has an entry in the sync ledger.

bmlib's ``CHANGELOG.md`` names each change by a bold title line followed by a
parenthesised group that carries the bmlib issue numbers, for example
``- **The PubMed record read is the one asked about** (`transparency`, #474).``
Every such number must appear as ``bmlib#N`` among the ``from_bmlib`` entries
of ``doc/cross_platform/bmlib_sync/ledger.json``, so that a bmlib fix this
repository has not ported cannot go unnoticed.

Usage:
    python scripts/check_bmlib_ledger.py --bmlib ~/src/bmlib

Exit status is 1 when ids are missing, 2 when the inputs cannot be read.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

LEDGER_PATH = (
    Path(__file__).resolve().parent.parent
    / "doc" / "cross_platform" / "bmlib_sync" / "ledger.json"
)

# Entries older than this release are out of scope; the ledger starts after it.
OLDEST_RELEASE_HEADING = "## [0.10.0]"
ENTRY_START = "- **"
PLATFORMS = ("python", "swift", "android")
OWED = "owed"

_ISSUE_NUMBER = re.compile(r"#(\d+)")
# "PR #195", "PRs #213 and #219": pull requests, not issues of the entry.
_PULL_REQUESTS = re.compile(
    r"\bPRs?\s*#\d+(?:(?:,\s*(?:and\s+)?|\s+and\s+)#\d+)*")
_BOLD = re.compile(r"\*\*.+?\*\*", re.DOTALL)


def _entries(changelog_text: str) -> list[str]:
    """Return the first paragraph of each entry newer than the oldest release.

    Args:
        changelog_text: The whole ``CHANGELOG.md``.

    Returns:
        One string per ``- **`` entry, its lines joined by single spaces,
        ending at the first blank line or the next list item or heading.
    """
    entries: list[str] = []
    current: list[str] | None = None
    for line in changelog_text.splitlines():
        if line.startswith(OLDEST_RELEASE_HEADING):
            break
        if line.startswith(ENTRY_START):
            if current is not None:
                entries.append(" ".join(current))
            current = [line.strip()]
        elif current is not None:
            if not line.strip() or line.startswith(("- ", "#")):
                entries.append(" ".join(current))
                current = None
            else:
                current.append(line.strip())
    if current is not None:
        entries.append(" ".join(current))
    return entries


def _title_group(entry: str) -> str:
    """Return the parenthesised group that follows an entry's bold title.

    Args:
        entry: An entry as joined by ``_entries``.

    Returns:
        The text inside the balanced parentheses directly after the bold
        title, or an empty string when none follows it.
    """
    bold = _BOLD.match(entry, len(ENTRY_START) - 2)
    if bold is None:
        return ""
    rest = entry[bold.end():].lstrip()
    if not rest.startswith("("):
        return ""
    depth = 0
    for index, char in enumerate(rest):
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return rest[1:index]
    return rest[1:]


def changelog_issue_ids(changelog_text: str) -> set[str]:
    """Return the bmlib issue ids named in entry titles newer than 0.10.0.

    Only the parenthesised group after the bold title is read; numbers in the
    body prose, and pull requests (``PR #N``), are not issues of the entry.

    Args:
        changelog_text: The whole ``CHANGELOG.md``.

    Returns:
        Ids of the form ``bmlib#N``.
    """
    ids: set[str] = set()
    for entry in _entries(changelog_text):
        group = _PULL_REQUESTS.sub("", _title_group(entry))
        for number in _ISSUE_NUMBER.findall(group):
            ids.add(f"bmlib#{number}")
    return ids


def _sort_key(entry_id: str) -> tuple[int, str]:
    """Order ``bmlib#N`` ids numerically."""
    return (int(entry_id.split("#", 1)[1]), entry_id)


def missing_entries(changelog_text: str, ledger: dict) -> list[str]:
    """Return changelog issue ids that have no ``from_bmlib`` entry.

    Args:
        changelog_text: The whole ``CHANGELOG.md``.
        ledger: The parsed ledger.

    Returns:
        The missing ids, in ascending issue order.
    """
    known = {entry["id"] for entry in ledger.get("from_bmlib", [])}
    return sorted(changelog_issue_ids(changelog_text) - known, key=_sort_key)


def owed_counts(ledger: dict) -> dict[str, int]:
    """Count the entries still owed on each platform.

    Args:
        ledger: The parsed ledger.

    Returns:
        ``from_bmlib`` owed counts per platform, plus ``bmlib`` for the
        ``to_bmlib`` entries owed to bmlib.
    """
    counts = {
        platform: sum(1 for e in ledger["from_bmlib"] if e[platform] == OWED)
        for platform in PLATFORMS
    }
    counts["bmlib"] = sum(1 for e in ledger["to_bmlib"] if e["bmlib"] == OWED)
    return counts


def main(argv: list[str] | None = None) -> int:
    """Run the check and print what is missing and what is owed.

    Args:
        argv: Command-line arguments; ``sys.argv[1:]`` when omitted.

    Returns:
        0 when every id is ledgered, 1 when some are missing, 2 when an input
        cannot be read.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bmlib", required=True, type=Path,
                        help="path to a bmlib checkout")
    parser.add_argument("--ledger", type=Path, default=LEDGER_PATH,
                        help="path to ledger.json")
    args = parser.parse_args(argv)
    try:
        changelog = (args.bmlib.expanduser() / "CHANGELOG.md").read_text(
            encoding="utf-8")
        ledger = json.loads(args.ledger.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"cannot read an input: {exc}", file=sys.stderr)
        return 2

    missing = missing_entries(changelog, ledger)
    if missing:
        print(f"{len(missing)} bmlib issue(s) in CHANGELOG.md have no "
              f"from_bmlib entry in {args.ledger.name}:")
        for entry_id in missing:
            print(f"  {entry_id}")
    counts = owed_counts(ledger)
    print("owed: " + ", ".join(f"{k}={v}" for k, v in counts.items()))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
