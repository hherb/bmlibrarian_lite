"""Tests for the bmlib sync ledger and its CI checker.

The ledger (``doc/cross_platform/bmlib_sync/ledger.json``) records, for every
change in bmlib's CHANGELOG, what became of it on each platform here.
"""

from __future__ import annotations

import importlib.util
import json
import re
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parent.parent
LEDGER_PATH = ROOT / "doc" / "cross_platform" / "bmlib_sync" / "ledger.json"
SCRIPT_PATH = ROOT / "scripts" / "check_bmlib_ledger.py"


def _load_script() -> ModuleType:
    """Import the checker script by path (``scripts/`` is not a package)."""
    spec = importlib.util.spec_from_file_location("check_bmlib_ledger", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_script = _load_script()
changelog_issue_ids = _script.changelog_issue_ids
missing_entries = _script.missing_entries

CHANGELOG = """## [Unreleased]
### Fixed
- **The PubMed record read is the one asked about** (`transparency`, #474).
  Body mentioning #999 in prose only.
## [0.10.0] — 2026-08-15
- **Old entry** (#79).
"""

# A title whose parenthesised group runs over several lines, and a pull
# request number inside the group, which is not an issue.
WRAPPED = """## [Unreleased]
- **An article's funding is stored** (issue
  #284, found by PR #256's review).
  Prose naming #1000.
- **A title (with parens) of its own** (#12, #13).
- **No group follows this title.** Prose naming #2000.
"""


def test_ids_come_from_entry_titles_newer_than_0_10_0() -> None:
    """Only title groups newer than 0.10.0 give ids."""
    assert changelog_issue_ids(CHANGELOG) == {"bmlib#474"}


def test_an_unledgered_id_is_missing() -> None:
    """An id with no ledger entry is reported."""
    assert missing_entries(CHANGELOG, {"from_bmlib": []}) == ["bmlib#474"]


def test_a_ledgered_id_is_not_missing() -> None:
    """An id with a ledger entry is not reported."""
    ledger = {"from_bmlib": [{"id": "bmlib#474"}]}
    assert missing_entries(CHANGELOG, ledger) == []


def test_a_group_wrapped_over_lines_is_read_and_prose_is_not() -> None:
    """A wrapped group is read, a PR number and body prose are not."""
    assert changelog_issue_ids(WRAPPED) == {"bmlib#284", "bmlib#12", "bmlib#13"}


def test_the_committed_ledger_is_well_formed() -> None:
    """Every committed entry carries valid statuses, an id, a title and a reason for a decline."""
    ledger = json.loads(LEDGER_PATH.read_text())
    statuses = {"owed", "ported", "equivalent", "n/a", "declined"}
    for e in ledger["from_bmlib"]:
        assert {e["python"], e["swift"], e["android"]} <= statuses
    for e in ledger["to_bmlib"]:
        assert e["bmlib"] in statuses
    for e in ledger["from_bmlib"] + ledger["to_bmlib"]:
        assert e["id"] and e["title"]
        assert "declined" not in e.values() or e["note"]


def test_the_committed_ledger_has_a_commit_and_unique_ids() -> None:
    """The ledger names its bmlib commit in full and has no duplicate ids."""
    ledger = json.loads(LEDGER_PATH.read_text())
    assert ledger["schema"] == 1
    # actions/checkout takes the ledger's value as its ref, and a commit ref
    # must be the full SHA there: an abbreviated one fails the checkout.
    assert re.fullmatch(r"[0-9a-f]{40}", ledger["bmlib_commit"])
    for key in ("from_bmlib", "to_bmlib"):
        ids = [e["id"] for e in ledger[key]]
        assert len(ids) == len(set(ids)), key


def test_pull_requests_in_a_title_group_are_not_issues() -> None:
    """A PR list inside the title group is not read as issues."""
    text = (
        "## [Unreleased]\n"
        "- **Metadata is not prose** (issues #241 and #248, filed by the reviews\n"
        "  of PRs #239 and #246).\n"
    )
    assert changelog_issue_ids(text) == {"bmlib#241", "bmlib#248"}
