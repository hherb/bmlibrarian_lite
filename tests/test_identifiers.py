"""A PMID is canonical ASCII digits, or it is not sent (bmlib#470, bmlib#472, bmlib#478)."""

from __future__ import annotations

import json
import logging
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest
import requests

from bmlibrarian_lite.identifiers import (
    PmidReading,
    canonical_pmid,
    is_canonical_pmid,
    no_usable_identifier_text,
    read_caller_ids,
    refused_pmid_sentence,
)
from tests.mcp_retraction_fixture import mcp_retraction_clear  # noqa: F401

pytestmark = pytest.mark.usefixtures("mcp_retraction_clear")

CONTRACT = (
    Path(__file__).resolve().parent.parent
    / "doc" / "cross_platform" / "fulltext_parity" / "pmid_canonical.json"
)
DOCUMENT = json.loads(CONTRACT.read_text(encoding="utf-8"))
CASES = DOCUMENT["cases"]
CASE_KEYS = {"name", "input", "pmid", "pmc_id", "refused"}
# Prose for the reader of the contract, read by no suite.
OPTIONAL_CASE_KEYS = {"note"}


def test_every_contract_key_is_read_here() -> None:
    """The contract holds exactly the keys this file reads."""
    assert set(DOCUMENT) == {
        "schema_version", "description", "source", "stripped_whitespace", "cases",
    }


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_every_case_has_every_key(case: dict) -> None:
    """Each case carries exactly the keys a suite reads, and perhaps a note."""
    assert set(case) - OPTIONAL_CASE_KEYS == CASE_KEYS


def test_case_names_are_unique() -> None:
    """Each case is named once."""
    names = [c["name"] for c in CASES]
    assert len(names) == len(set(names))


def test_stripped_whitespace_is_what_str_strip_removes() -> None:
    """The apps' trim set is exactly the code points Python's strip() removes.

    Foundation's whitespace set also strips U+200B and keeps U+001C-U+001F;
    Kotlin's trim() keeps U+0085. The apps trim this list instead.
    """
    removed = [c for c in range(sys.maxunicode + 1) if not chr(c).strip()]
    assert DOCUMENT["stripped_whitespace"] == removed


def test_the_contract_has_the_required_cases() -> None:
    """The contract has the required cases."""
    inputs = {c["input"] for c in CASES}
    for required in (
        "33301246", " 33301246 ", "0033301246", "", "0000", "PMID:33301246",
        "33301246abc", "1 OR 2", "1\u0661\u0662", "-5", "PMC7745181",
        "33301246\u200b", "PMC0",
    ):
        assert required in inputs


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_contract_case(case: dict) -> None:
    """Contract case."""
    reading = canonical_pmid(case["input"])
    assert reading == PmidReading(case["pmid"], case["pmc_id"], case["refused"])


def test_integers() -> None:
    """Integers."""
    assert canonical_pmid(33301246).pmid == "33301246"
    assert canonical_pmid(0).pmid is None and not canonical_pmid(0).refused
    assert canonical_pmid(True).refused
    assert canonical_pmid(-5).refused


def test_an_integer_too_long_to_print_is_refused_not_raised() -> None:
    """An int past the int-to-str digit limit is refused, never a ValueError.

    ``str(10**5000)`` raises ValueError (the 4300-digit conversion limit), so
    "it never raises" was not true of a huge int (as bmlib#479 found).
    """
    assert canonical_pmid(10**5000) == PmidReading(refused=True)


@pytest.mark.parametrize("value", [1.5, b"123", ["1"], object()])
def test_other_types_are_refused(value: object) -> None:
    """Other types are refused."""
    assert canonical_pmid(value).refused


def test_none_is_no_pmid() -> None:
    """None is no pmid."""
    assert canonical_pmid(None) == PmidReading()


def test_is_canonical_pmid() -> None:
    """Is canonical pmid."""
    assert is_canonical_pmid("33301246")
    assert not is_canonical_pmid("0033301246")
    assert not is_canonical_pmid(" 1 ")
    assert not is_canonical_pmid("PMC1")
    assert not is_canonical_pmid(33301246)
    assert not is_canonical_pmid(None)


def test_read_caller_ids_logs_a_refusal_naming_the_value(caplog) -> None:
    """Read caller ids logs a refusal naming the value."""
    with caplog.at_level(logging.WARNING):
        assert read_caller_ids("1 OR 2", "PMC9") == (None, "PMC9")
    assert "'1 OR 2'" in caplog.text


def test_read_caller_ids_pmc_id_fills_only_a_missing_pmcid(caplog) -> None:
    """Read caller ids pmc id fills only a missing pmcid."""
    assert read_caller_ids("PMC7745181", None) == (None, "PMC7745181")
    with caplog.at_level(logging.WARNING):
        assert read_caller_ids("PMC7745181", "PMC1") == (None, "PMC1")
    assert "PMC7745181" in caplog.text


def test_read_caller_ids_canonicalises_and_keeps_pmcid() -> None:
    """Read caller ids canonicalises and keeps pmcid."""
    assert read_caller_ids("0033301246", "PMC5") == ("33301246", "PMC5")
    assert read_caller_ids(None, None) == (None, None)


def test_read_caller_ids_newline_in_value_is_not_interpolated_raw(caplog) -> None:
    """Read caller ids newline in value is not interpolated raw."""
    with caplog.at_level(logging.WARNING):
        read_caller_ids("1\nFAKE LOG LINE x", None)
    assert "\nFAKE LOG LINE" not in caplog.text


def test_refused_pmid_sentence_names_the_value() -> None:
    """A typed ``PMID:33301246`` is named to the reader as not a PubMed ID."""
    sentence = refused_pmid_sentence("PMID:33301246")
    assert sentence is not None
    assert "'PMID:33301246'" in sentence and "not a PubMed ID" in sentence


@pytest.mark.parametrize("value", ["33301246", "0033301246", "PMC7745181", "", "  ", None])
def test_refused_pmid_sentence_is_silent_for_usable_or_blank(value) -> None:
    """Control: a PMID, a PMC ID or nothing is not called a wrong PMID."""
    assert refused_pmid_sentence(value) is None


def test_no_usable_identifier_text() -> None:
    """Only a refused PMID with nothing beside it is an error of its own."""
    error = no_usable_identifier_text(None, "PMID:33301246", None)
    assert error is not None and "'PMID:33301246'" in error
    assert no_usable_identifier_text("10.1/x", "PMID:33301246", None) is None
    assert no_usable_identifier_text(None, "PMID:33301246", "PMC1") is None
    assert no_usable_identifier_text(None, "33301246", None) is None
    assert no_usable_identifier_text(None, None, None) is None


# --- the entries ----------------------------------------------------------

def test_mcp_refused_pmid_makes_no_request() -> None:
    """Mcp refused pmid makes no request."""
    from bmlibrarian_lite.mcp_server import _handle_fulltext

    ctx = MagicMock()
    result = _handle_fulltext({"pmid": "1 OR 2"}, ctx)
    assert result["success"] is False
    assert "'1 OR 2'" in result["error"]
    ctx.fulltext_discoverer.discover_fulltext.assert_not_called()


def test_mcp_blank_pmid_is_not_called_a_wrong_one() -> None:
    """Whitespace is no PMID: the error asks for an identifier, naming none."""
    from bmlibrarian_lite.mcp_server import _handle_fulltext

    ctx = MagicMock()
    result = _handle_fulltext({"pmid": "   "}, ctx)
    assert result["success"] is False
    assert "not a PubMed ID" not in result["error"]
    assert "At least one of" in result["error"]
    ctx.fulltext_discoverer.discover_fulltext.assert_not_called()


def test_mcp_padded_pmid_is_sent_canonical() -> None:
    """Mcp padded pmid is sent canonical."""
    from bmlibrarian_lite.mcp_server import _handle_fulltext

    ctx = MagicMock()
    ctx.fulltext_discoverer.discover_fulltext.return_value = MagicMock(
        success=False, markdown_content=None, lookups=None,
        absence_established=False, error="x", set_aside_pdf_note=None,
    )
    try:
        _handle_fulltext({"pmid": "0033301246"}, ctx)
    except Exception:
        pass
    kwargs = ctx.fulltext_discoverer.discover_fulltext.call_args.kwargs
    assert kwargs["pmid"] == "33301246"


def test_mcp_refused_pmid_keeps_a_doi() -> None:
    """Mcp refused pmid keeps a doi."""
    from bmlibrarian_lite.mcp_server import _handle_fulltext

    ctx = MagicMock()
    try:
        _handle_fulltext({"pmid": "1 OR 2", "doi": "10.1/x"}, ctx)
    except Exception:
        pass
    kwargs = ctx.fulltext_discoverer.discover_fulltext.call_args.kwargs
    assert kwargs["pmid"] is None and kwargs["doi"] == "10.1/x"


def _discoverer():
    from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer

    return FulltextDiscoverer.__new__(FulltextDiscoverer)


def test_discover_fulltext_canonicalises_before_any_lookup(monkeypatch) -> None:
    """Discover fulltext canonicalises before any lookup."""
    seen: dict = {}
    d = _discoverer()

    def fake(self, doc_dict, pmid, pmcid, doi, title, year, skip_pdf, *, refusals):
        seen.update(doc_dict=doc_dict, pmid=pmid, pmcid=pmcid)
        return MagicMock(
            set_aside_pdf_note=None, success=True,
        )

    monkeypatch.setattr(type(d), "_discover_fulltext", fake)
    monkeypatch.setattr("bmlibrarian_lite.fulltext_discovery.replace", lambda r, **k: r)
    d.discover_fulltext(pmid="0033301246")
    assert seen["pmid"] == "33301246"
    d.discover_fulltext(doc_dict={"pmid": "1 OR 2", "doi": "10.1/x"})
    assert seen["pmid"] is None and "pmid" not in seen["doc_dict"]
    d.discover_fulltext(pmid="PMC7745181")
    assert seen["pmid"] is None and seen["pmcid"] == "PMC7745181"
    d.discover_fulltext(pmid="PMC7745181", pmcid="PMC1")
    assert seen["pmcid"] == "PMC1"


def test_europepmc_lookup_refuses_a_non_canonical_pmid(caplog) -> None:
    """Europepmc lookup refuses a non canonical pmid."""
    from bmlibrarian_lite.europepmc import EuropePMCClient

    client = EuropePMCClient.__new__(EuropePMCClient)
    client._session = MagicMock()
    with caplog.at_level(logging.ERROR):
        fetch = client.fetch_article_info(pmid="0033301246")
    client._session.get.assert_not_called()
    assert fetch.info is None and fetch.failure is not None
    assert "'0033301246'" in caplog.text


def test_europepmc_lookup_sends_a_canonical_pmid() -> None:
    """Europepmc lookup sends a canonical pmid."""
    from bmlibrarian_lite.europepmc import EuropePMCClient

    client = EuropePMCClient.__new__(EuropePMCClient)
    client._session = MagicMock()
    client._session.get.return_value.content = json.dumps({
        "hitCount": 0, "resultList": {"result": []},
    }).encode()
    client.fetch_article_info(pmid="33301246")
    params = client._session.get.call_args.kwargs["params"]
    assert params["query"] == "ext_id:33301246 src:med"


def test_id_converter_refuses_a_non_canonical_pmid(caplog) -> None:
    """Id converter refuses a non canonical pmid."""
    from bmlibrarian_lite.pdf_discovery import PDFDiscoverer

    d = PDFDiscoverer.__new__(PDFDiscoverer)
    d._session = MagicMock()
    with caplog.at_level(logging.ERROR):
        pmcid, failure = d._get_pmcid_from_pmid("1 OR 2")
    d._session.get.assert_not_called()
    assert pmcid is None and failure is not None
    assert "'1 OR 2'" in caplog.text


def test_analyzer_pmid_entry(monkeypatch) -> None:
    """Analyzer pmid entry."""
    from bmlibrarian_lite.study_transparency_analyzer import study_transparency_analyzer as m

    a = m.StudyTransparencyAnalyzer.__new__(m.StudyTransparencyAnalyzer)
    a._auto_discover_fulltext = False
    seen: list = []
    monkeypatch.setattr(
        m.StudyTransparencyAnalyzer, "_fetch_basic_metadata",
        lambda self, report: seen.append((report.pmid, report.doi)) or (_ for _ in ()).throw(StopIteration),
    )
    for kwargs in ({"pmid": "0033301246"}, {"pmid": "1 OR 2", "doi": "10.1/x"}):
        try:
            a.analyze(**kwargs)
        except StopIteration:
            pass
    assert seen == [("33301246", None), (None, "10.1/x")]
    report = a.analyze(pmid="1 OR 2")
    assert report.errors and report.pmid is None


@pytest.mark.parametrize(
    ("given", "read"), [("0033301246", "33301246"), ("1 OR 2", None)]
)
def test_discover_fulltext_reads_the_pmid_into_a_copy(monkeypatch, given, read) -> None:
    """The lookups see the canonical PMID; the caller's dict keeps its own.

    The GUI's dict is read on the main thread while discovery runs on a
    worker's, so the canonicalisation never writes to or pops from it.
    """
    d = _discoverer()
    seen: dict = {}

    def inner(self, doc_dict, pmid, *a, refusals):
        seen.update(dict_pmid=doc_dict.get("pmid"), pmid=pmid)
        return MagicMock(set_aside_pdf_note=None, success=True)

    monkeypatch.setattr(type(d), "_discover_fulltext", inner)
    monkeypatch.setattr("bmlibrarian_lite.fulltext_discovery.replace", lambda r, **k: r)
    doc = {"pmid": given, "doi": "10.1/x"}
    d.discover_fulltext(doc_dict=doc)
    assert doc == {"pmid": given, "doi": "10.1/x"}
    assert seen == {"dict_pmid": read, "pmid": read}


def test_discover_fulltext_keeps_a_canonical_callers_dict(monkeypatch) -> None:
    """Control: a dict whose PMID is already canonical is the one passed on."""
    d = _discoverer()
    passed: list = []
    monkeypatch.setattr(
        type(d), "_discover_fulltext",
        lambda self, doc_dict, *a, refusals: passed.append(doc_dict)
        or MagicMock(set_aside_pdf_note=None, success=True),
    )
    monkeypatch.setattr("bmlibrarian_lite.fulltext_discovery.replace", lambda r, **k: r)
    doc = {"pmid": "33301246"}
    d.discover_fulltext(doc_dict=doc)
    assert passed[0] is doc


def test_an_object_whose_text_is_digits_is_still_refused() -> None:
    """Only text and integers are PMIDs; ``str()`` of anything else is not asked."""
    import decimal

    class Digits:
        def __str__(self) -> str:
            return "33301246"

    assert canonical_pmid(Digits()).refused
    assert canonical_pmid(decimal.Decimal(33301246)).refused


def test_discover_and_download_canonicalises_at_its_entry(monkeypatch) -> None:
    """A stored padded PMID reaches the ID Converter canonical, with no ERROR."""
    from bmlibrarian_lite import pdf_discovery
    from bmlibrarian_lite.pdf_discovery import PDFDiscoverer

    d = PDFDiscoverer.__new__(PDFDiscoverer)
    d._session = MagicMock()
    d._session.get.return_value.content = json.dumps({"records": []}).encode()
    monkeypatch.setattr(pdf_discovery, "replace", lambda r, **k: r)
    asked: list = []

    def fake_inner(self, output_path, doi, pmid, pmcid, *a, **k):
        asked.append(self._get_pmcid_from_pmid(pmid) if pmid else None)
        return MagicMock()

    monkeypatch.setattr(PDFDiscoverer, "_discover_and_download", fake_inner)
    d.discover_and_download(Path("/x.pdf"), pmid="0033301246")
    url = d._session.get.call_args.args[0]
    assert "ids=33301246&" in url


def test_discover_and_download_refuses_a_bad_pmid(monkeypatch, caplog) -> None:
    """No ID Converter request, a WARNING and no ERROR."""
    from bmlibrarian_lite import pdf_discovery
    from bmlibrarian_lite.pdf_discovery import PDFDiscoverer

    d = PDFDiscoverer.__new__(PDFDiscoverer)
    d._session = MagicMock()
    monkeypatch.setattr(pdf_discovery, "replace", lambda r, **k: r)
    seen: dict = {}

    def fake_inner(self, output_path, doi, pmid, pmcid, *a, **k):
        seen.update(pmid=pmid, pmcid=pmcid)
        return MagicMock()

    monkeypatch.setattr(PDFDiscoverer, "_discover_and_download", fake_inner)
    with caplog.at_level(logging.WARNING):
        d.discover_and_download(Path("/x.pdf"), pmid="1 OR 2", doi="10.1/x")
    assert seen == {"pmid": None, "pmcid": None}
    d._session.get.assert_not_called()
    assert "'1 OR 2'" in caplog.text
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]


def test_discover_and_download_reads_a_pmc_id_given_as_pmid(monkeypatch) -> None:
    """The PMC ID fills pmcid when the caller gave none."""
    from bmlibrarian_lite import pdf_discovery
    from bmlibrarian_lite.pdf_discovery import PDFDiscoverer

    d = PDFDiscoverer.__new__(PDFDiscoverer)
    monkeypatch.setattr(pdf_discovery, "replace", lambda r, **k: r)
    seen: dict = {}
    monkeypatch.setattr(
        PDFDiscoverer, "_discover_and_download",
        lambda self, o, doi, pmid, pmcid, *a, **k: seen.update(pmid=pmid, pmcid=pmcid) or MagicMock(),
    )
    d.discover_and_download(Path("/x.pdf"), pmid="PMC7745181")
    assert seen == {"pmid": None, "pmcid": "PMC7745181"}


def _analyzer(monkeypatch):
    from bmlibrarian_lite.study_transparency_analyzer import study_transparency_analyzer as m

    a = m.StudyTransparencyAnalyzer.__new__(m.StudyTransparencyAnalyzer)
    a._auto_discover_fulltext = True
    return m, a


def test_analyzer_pmc_id_as_pmid_reaches_full_text_discovery(monkeypatch) -> None:
    """report.pmcid is the caller's PMC ID, passed to discovery, never replaced."""
    m, a = _analyzer(monkeypatch)
    # The real _fetch_basic_metadata: with no PMID it asks neither PubMed
    # nor, without a DOI, CrossRef or the ID converter
    a.pubmed = MagicMock()
    a.pubmed.fetch_article.side_effect = AssertionError("PubMed was asked")
    a.pubmed.convert_ids.side_effect = AssertionError("the converter was asked")
    a.crossref = MagicMock()
    a.crossref.get_work.side_effect = AssertionError("CrossRef was asked")
    seen: dict = {}

    def discover(self, report):
        seen["discover"] = (report.pmid, report.pmcid)
        raise StopIteration

    monkeypatch.setattr(m.StudyTransparencyAnalyzer, "_discover_fulltext", discover)
    with pytest.raises(StopIteration):
        a.analyze(pmid="PMC7745181")
    assert seen["discover"] == (None, "PMC7745181")


def test_analyzer_basic_metadata_keeps_the_callers_pmc_id() -> None:
    """The real _fetch_basic_metadata does not overwrite a caller's PMC ID."""
    from bmlibrarian_lite.study_transparency_analyzer import study_transparency_analyzer as m

    a = m.StudyTransparencyAnalyzer.__new__(m.StudyTransparencyAnalyzer)
    a.pubmed = MagicMock()
    a.crossref = MagicMock()
    a.pubmed.fetch_article.return_value = m.RecordFetch.served({"pmcid": "PMC999", "title": "t"})
    report = m.TransparencyReport()
    report.pmid = "1"
    report.pmcid = "PMC7745181"
    a._fetch_basic_metadata(report)
    assert report.pmcid == "PMC7745181"
    report2 = m.TransparencyReport()
    report2.pmid = "1"
    a._fetch_basic_metadata(report2)
    assert report2.pmcid == "PMC999"


def test_analyzer_error_names_the_refused_pmid() -> None:
    """With nothing else to go on, the error names the value passed."""
    from bmlibrarian_lite.study_transparency_analyzer import study_transparency_analyzer as m

    a = m.StudyTransparencyAnalyzer.__new__(m.StudyTransparencyAnalyzer)
    report = a.analyze(pmid="1 OR 2")
    assert "'1 OR 2'" in report.errors[0]


# ---- A PMID PubMed was owed (#356 kept for a refused or PMC-ID pmid) ----


def _offline_analyzer(pubmed_record: dict | None = None):
    """A real analyzer whose sources are stubs; PubMed raises unless given a record."""
    from bmlibrarian_lite.study_transparency_analyzer import study_transparency_analyzer as m

    a = m.StudyTransparencyAnalyzer("t@example.com", auto_discover_fulltext=False)
    a.pubmed = MagicMock()
    if pubmed_record is None:
        a.pubmed.fetch_article.side_effect = AssertionError("PubMed was asked")
    else:
        a.pubmed.fetch_article.return_value = m.RecordFetch.served(pubmed_record)
    a.pubmed.convert_ids.side_effect = AssertionError("the ID converter was asked")
    a.crossref = MagicMock()
    a.crossref.get_work.return_value = m.RecordFetch.served({"title": ["T"], "funder": []})
    return m, a


def test_a_pmc_id_given_as_the_pmid_leaves_funding_unassessed() -> None:
    """PubMed was owed and never asked, so funding is never a bare "NO" (#356)."""
    m, a = _offline_analyzer()
    report = a.analyze(pmid="PMC7745181")
    assert report.pmid is None and report.pmcid == "PMC7745181"
    assert not m.funding_was_assessed(report)
    summary = m.format_report_summary(report)
    assert "Industry Funding: Not assessed" in summary
    assert "Industry Funding: NO" not in summary
    assert any("PubMed was not asked" in w for w in report.warnings)


def test_a_refused_pmid_alone_leaves_funding_unassessed() -> None:
    """The error report for a refused PMID does not read as "NO" either."""
    m, a = _offline_analyzer()
    report = a.analyze(pmid="PMID:33301246")
    assert report.errors
    assert not m.funding_was_assessed(report)
    assert "Industry Funding: NO" not in m.format_report_summary(report)


def test_a_refused_pmid_beside_a_doi_does_not_answer_from_crossref_alone() -> None:
    """CrossRef read and PubMed owed but unasked: funding is not assessed."""
    m, a = _offline_analyzer()
    a.pubmed.convert_ids.side_effect = None
    a.pubmed.convert_ids.return_value = {}
    report = a.analyze(doi="10.1/x", pmid="PMID:33301246")
    assert report.crossref_record_read
    assert not m.funding_was_assessed(report)
    assert "Industry Funding: Not assessed" in m.format_report_summary(report)
    assert any("PubMed was not asked" in w for w in report.warnings)


def test_a_doi_alone_still_answers_from_crossref() -> None:
    """Control: no PMID was given, so PubMed was owed nothing and "NO" stands."""
    m, a = _offline_analyzer()
    a.pubmed.convert_ids.side_effect = None
    a.pubmed.convert_ids.return_value = {}
    report = a.analyze(doi="10.1/x")
    assert m.funding_was_assessed(report)
    assert "Industry Funding: NO" in m.format_report_summary(report)
    assert not any("PubMed was not asked" in w for w in report.warnings)


def test_a_real_pmid_whose_record_names_no_funder_still_answers_no() -> None:
    """Control: PubMed served a record with no grants, CrossRef none: "NO"."""
    m, a = _offline_analyzer(pubmed_record={"title": "T", "grants": []})
    report = a.analyze(pmid="33301246")
    assert report.pubmed_record_read
    assert m.funding_was_assessed(report)
    assert "Industry Funding: NO" in m.format_report_summary(report)
    assert not any("PubMed was not asked" in w for w in report.warnings)


# ---- A DOI-only study's PMID, looked up in the ID converter (#785) ----


@pytest.mark.parametrize(
    "answer",
    [
        requests.ConnectionError("down"),
        ValueError("unreadable body"),
        {"10.1/x": "PMC7745181"},
    ],
    ids=["unreachable", "unreadable", "not-a-pmid"],
)
def test_an_unread_id_converter_leaves_funding_unassessed(answer) -> None:
    """Unreachable is not absent: PubMed went unasked, so funding is no "NO"."""
    m, a = _offline_analyzer()
    if isinstance(answer, Exception):
        a.pubmed.convert_ids.side_effect = answer
    else:
        a.pubmed.convert_ids.side_effect = None
        a.pubmed.convert_ids.return_value = answer
    report = a.analyze(doi="10.1/x")
    assert report.pmid is None and report.pubmed_record_unreachable
    assert not m.funding_was_assessed(report)
    assert "Industry Funding: Not assessed" in m.format_report_summary(report)
    assert any("PubMed Central's ID converter" in w for w in report.warnings)
    assert any("PubMed could not be read" in w for w in report.warnings)


def test_a_pmid_the_converter_names_is_read_from_pubmed() -> None:
    """The converted PMID reaches PubMed, whose grants then count."""
    m, a = _offline_analyzer(pubmed_record={"title": "T", "grants": [{"agency": "Pfizer"}]})
    a.pubmed.convert_ids.side_effect = None
    a.pubmed.convert_ids.return_value = {"10.1/x": "0123"}
    report = a.analyze(doi="10.1/x")
    a.pubmed.fetch_article.assert_called_once_with("123")
    assert report.pubmed_record_read and not report.pubmed_record_unreachable
    assert m.funding_was_assessed(report)
    assert "Industry Funding: YES" in m.format_report_summary(report)
    assert not any("PubMed holds no record" in w for w in report.warnings)
