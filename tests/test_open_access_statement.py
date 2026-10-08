# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""What the reader is told once open-access PDFs were tried (#480, stage B).

The maintainer's decisions of 2026-10-05: when PDFs were tried and none
obtained, every source tried is listed, each PDF by host and by who named
it; a lookup-only shortfall keeps today's sentence; a PDF served but not
saved is a caching note of its own. The rows are the shared contract,
``doc/cross_platform/fulltext_parity/open_access_statement.json``; Python
reads its hosts, statements and notes (the stored list is the apps').
"""

import json
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.analysis_failures import (
    TRIED_SOURCES_LEAD,
    address_host,
    not_saved_note,
    paywall_message,
    refused_access_sentence,
    tried_sources_statement,
    unestablished_access_clause,
    unsettled_lookups_clause,
    with_unestablished_access,
)
from bmlibrarian_lite.constants import (
    SERVICE_CORE,
    SERVICE_DOI_RESOLVER,
    SERVICE_ELSEVIER,
    SERVICE_OPENALEX,
    SERVICE_OPENALEX_PDF,
    SERVICE_UNPAYWALL,
    SERVICE_UNPAYWALL_LANDING_PAGE,
    SERVICE_UNPAYWALL_PDF,
)
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc"
        / "cross_platform"
        / "fulltext_parity"
        / "open_access_statement.json"
    ).read_text(encoding="utf-8")
)

SERVICES = {
    "unpaywall": SERVICE_UNPAYWALL,
    "unpaywall_landing_page": SERVICE_UNPAYWALL_LANDING_PAGE,
    "unpaywall_pdf": SERVICE_UNPAYWALL_PDF,
    "openalex": SERVICE_OPENALEX,
    "openalex_pdf": SERVICE_OPENALEX_PDF,
    "core": SERVICE_CORE,
    "elsevier": SERVICE_ELSEVIER,
}
_PDF = "https://repo.example.org/b.pdf"


def _record(entries: list[dict[str, Any]]) -> LookupRecord:
    """The record a contract row's entries describe, failures then skips."""
    failures, skipped = [], []
    for entry in entries:
        service, address = SERVICES[entry["source"]], entry.get("address")
        if entry.get("skipped"):
            skipped.append(SourceLookupSkipped(service, LookupSkipReason(entry["skipped"]), address))
        else:
            failure = RequestFailure(RequestFailureKind(entry["kind"]), entry["status_code"])
            failures.append(SourceLookupFailure(service, failure, address))
    return LookupRecord(tuple(failures), tuple(skipped))


def _not_saved(address: str = _PDF) -> LookupRecord:
    """A record whose only entry is a PDF served and not saved."""
    return LookupRecord(
        skipped=(SourceLookupSkipped(SERVICE_UNPAYWALL_PDF, LookupSkipReason.NOT_SAVED, address),)
    )


def test_every_contract_table_is_read_somewhere() -> None:
    """Python reads three tables; the apps read the stored list too."""
    assert set(CONTRACT) == {
        "schema_version", "description", "lead", "hosts", "statements",
        "not_saved_note", "persisted",
    }
    assert CONTRACT["lead"] == TRIED_SOURCES_LEAD


@pytest.mark.parametrize("row", CONTRACT["hosts"], ids=lambda row: row["address"])
def test_hosts(row: dict[str, Any]) -> None:
    """A tried PDF is named by its host, else as given."""
    assert address_host(row["address"]) == row["host"]


@pytest.mark.parametrize("row", CONTRACT["statements"], ids=lambda row: row["name"])
def test_statements(row: dict[str, Any]) -> None:
    """Each row's entries are told as the contract words them."""
    assert unestablished_access_clause(_record(row["entries"])) == row["statement"]


@pytest.mark.parametrize("row", CONTRACT["not_saved_note"], ids=lambda row: str(row["link_kept"]))
def test_not_saved_note(row: dict[str, Any]) -> None:
    """The caching note names the host and what became of the PDF."""
    assert not_saved_note(_not_saved(row["address"]), link_kept=row["link_kept"]) == row["note"]


def test_a_copy_not_saved_is_a_note_not_a_shortfall() -> None:
    """The copy exists, so access is not left open: only the note is told."""
    record = _not_saved()
    assert record.anything_unsettled, "absence is still not established"
    assert tried_sources_statement(record) == ""
    assert unestablished_access_clause(record) == not_saved_note(record)


def test_the_note_follows_the_statement() -> None:
    """A caching note comes after the access statement."""
    record = _record(CONTRACT["statements"][0]["entries"]).merged(_not_saved())
    assert unestablished_access_clause(record) == (
        f"{CONTRACT['statements'][0]['statement']} {not_saved_note(record)}"
    )


def test_a_refusal_with_tried_pdfs_lists_them() -> None:
    """A refusal with tried PDFs gives the tried-sources list."""
    row = CONTRACT["statements"][1]
    message = paywall_message("Behind a paywall.", _record(row["entries"]))
    assert message == f"A source refused access to this document. {row['statement']}"


def test_a_claim_with_tried_pdfs_is_followed_by_the_list() -> None:
    """A claim about our attempts is followed by the list."""
    row = CONTRACT["statements"][0]
    claim = "Failed to download PDF from any available source."
    assert with_unestablished_access(claim, _record(row["entries"])) == f"{claim} {row['statement']}"


def test_a_blank_address_is_none() -> None:
    """An address is stripped, and blank is no address."""
    failure = RequestFailure(RequestFailureKind.TIMEOUT)
    assert SourceLookupFailure(SERVICE_UNPAYWALL_PDF, failure, "  ").address is None
    assert SourceLookupFailure(SERVICE_UNPAYWALL_PDF, failure, f" {_PDF} ").address == _PDF


def test_the_contract_has_rows() -> None:
    """The contract is not accidentally emptied."""
    assert len(CONTRACT["statements"]) >= 8
    assert len(CONTRACT["hosts"]) >= 5


def _timeout(service: str, address: str | None = None) -> SourceLookupFailure:
    """A timed-out lookup, of a PDF when an address is given."""
    return SourceLookupFailure(service, RequestFailure(RequestFailureKind.TIMEOUT), address)


def test_a_refusal_with_only_a_note_left_is_the_bare_refusal_and_the_note() -> None:
    """No access shortfall remains, so no empty clause is built (#480)."""
    record = _not_saved()
    assert refused_access_sentence(record) == (
        f"A source refused access to this document. {not_saved_note(record)}"
    )


def test_a_refusal_with_a_lookup_and_a_note() -> None:
    """The grouped sentence, then the note."""
    record = LookupRecord((_timeout(SERVICE_OPENALEX),)).merged(_not_saved())
    sentence = refused_access_sentence(record)
    assert sentence.startswith("A source refused access to this document, but OpenAlex")
    assert sentence.endswith(not_saved_note(record))
    assert sentence.count(not_saved_note(record)) == 1


def test_a_paywall_message_carries_the_note_once() -> None:
    """``paywall_message`` builds from the access part, so no doubling."""
    record = _not_saved()
    message = paywall_message("Behind a paywall.", record)
    assert message.count(not_saved_note(record)) == 1
    assert message == f"Behind a paywall. {not_saved_note(record)}"
    both = LookupRecord((_timeout(SERVICE_OPENALEX),)).merged(record)
    assert paywall_message("Behind a paywall.", both).count(not_saved_note(both)) == 1


def test_the_lookups_clause_ignores_a_note() -> None:
    """A PDF served but not saved is not a lookup that could not be asked."""
    assert unsettled_lookups_clause(_not_saved()) == ""


def test_the_transparency_caveat_has_the_note_not_a_lookup() -> None:
    """The analyser's caveat tells a caching note, not 'could not be asked'."""
    from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
        _full_text_unassessed_caveat,
    )

    record = _not_saved()
    caveat = _full_text_unassessed_caveat(record)
    assert "could not be asked" not in caveat
    assert caveat.count(not_saved_note(record)) == 1


def test_a_source_outside_the_chain_is_listed_first() -> None:
    """Chain order puts any other source before the chain's."""
    record = LookupRecord((
        _timeout(SERVICE_UNPAYWALL_PDF, "https://walled.example.org/a.pdf"),
        _timeout(SERVICE_DOI_RESOLVER),
    ))
    statement = tried_sources_statement(record)
    body = statement[len(TRIED_SOURCES_LEAD):]
    assert body.startswith("doi.org (the request timed out); walled.example.org, named by Unpaywall")


def test_a_tried_pdf_over_the_size_limit() -> None:
    """A skipped tried PDF is told by host, with the unasked ending."""
    record = LookupRecord(skipped=(
        SourceLookupSkipped(SERVICE_UNPAYWALL_PDF, LookupSkipReason.OVER_SIZE_LIMIT, _PDF),
    ))
    assert tried_sources_statement(record) == (
        f"{TRIED_SOURCES_LEAD}repo.example.org, named by Unpaywall "
        "(larger than the download limit). A freely available copy may exist. "
        "Whether this document is open access was not established."
    )


def test_a_skip_strips_its_address() -> None:
    """The skip's address is stripped, and blank is none."""
    reason = LookupSkipReason.OVER_SIZE_LIMIT
    assert SourceLookupSkipped(SERVICE_UNPAYWALL_PDF, reason, "  ").address is None
    assert SourceLookupSkipped(SERVICE_UNPAYWALL_PDF, reason, f" {_PDF} ").address == _PDF
    assert SourceLookupSkipped(SERVICE_UNPAYWALL_PDF, reason).address is None
