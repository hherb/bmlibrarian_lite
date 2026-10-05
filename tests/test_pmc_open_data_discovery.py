# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""PMC's open-data bucket inside the full-text chain (#480, stage A).

The bucket is asked only after Europe PMC's XML gave nothing usable and only
for a PMC ID. Its answer is recorded as Europe PMC's is: served text wins,
an absence adds nothing, and a failure keeps "no full text" from being
established. No test touches the network: the client is a stub.
"""

from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.constants import SERVICE_EUROPE_PMC, SERVICE_PMC_OPEN_DATA
from bmlibrarian_lite.data_models import (
    LookupRecord,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from bmlibrarian_lite.europepmc import ArticleInfo
from bmlibrarian_lite.fulltext_discovery import (
    FulltextDiscoverer,
    FulltextResult,
    FulltextSourceType,
)
from bmlibrarian_lite.pmc_open_data import PmcOpenDataFetch

_JATS = (
    "<article><front><article-meta><title-group><article-title>A trial"
    "</article-title></title-group></article-meta></front><body><sec><title>Methods"
    "</title><p>We randomised 40 patients.</p></sec></body></article>"
)
_THROTTLED = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)


class _StubBucket:
    """Answers every fetch the same way and records what was asked."""

    def __init__(self, fetch: PmcOpenDataFetch) -> None:
        self.fetch = fetch
        self.asked: list[str] = []

    def fetch_xml(self, pmcid: str) -> PmcOpenDataFetch:
        self.asked.append(pmcid)
        return self.fetch


def _europepmc_absent() -> FulltextResult:
    """Europe PMC answered and served nothing: no failure recorded."""
    return FulltextResult(success=False, source_type=FulltextSourceType.NOT_ASSESSED)


def _discoverer(
    bucket: _StubBucket, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> FulltextDiscoverer:
    """A discoverer with Europe PMC absent, empty caches and no PDF stage."""
    monkeypatch.setattr("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", lambda _d: None)
    monkeypatch.setattr("bmlibrarian_lite.fulltext_discovery.find_existing_pdf", lambda _d: None)
    monkeypatch.setattr(
        "bmlibrarian_lite.fulltext_discovery.save_fulltext_markdown",
        lambda _d, _m: tmp_path / "cached.md",
    )
    discoverer = FulltextDiscoverer(use_browser_fallback=False, pmc_open_data=bucket)  # type: ignore[arg-type]
    discoverer._try_europepmc_xml = lambda *_a, **_k: _europepmc_absent()  # type: ignore[method-assign]
    return discoverer


def test_served_text_is_the_result(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """The bucket's JATS, converted, under its own source."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))

    result = _discoverer(bucket, monkeypatch, tmp_path).discover_fulltext(
        pmcid="PMC123", skip_pdf=True
    )

    assert result.success
    assert result.source_type is FulltextSourceType.PMC_OPEN_DATA_XML
    assert "We randomised 40 patients." in (result.markdown_content or "")
    assert bucket.asked == ["PMC123"]


def test_absent_adds_nothing(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """An answer about this source: no lookup failure recorded."""
    bucket = _StubBucket(PmcOpenDataFetch.absent())

    result = _discoverer(bucket, monkeypatch, tmp_path).discover_fulltext(
        pmcid="PMC123", skip_pdf=True
    )

    assert not result.success
    assert all(f.service != SERVICE_PMC_OPEN_DATA for f in result.lookups.failures)


def test_an_unreachable_bucket_unmakes_an_absence(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The control for the rule: a bucket we could not read is recorded."""
    bucket = _StubBucket(PmcOpenDataFetch.unreachable(_THROTTLED))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    discoverer._try_pdf_download = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=False, source_type=FulltextSourceType.NOT_FOUND
    )

    result = discoverer.discover_fulltext(pmcid="PMC123")

    assert SourceLookupFailure(SERVICE_PMC_OPEN_DATA, _THROTTLED) in result.lookups.failures
    assert not result.absence_established


def test_control_a_clean_chain_still_establishes_an_absence(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Absent bucket, nothing anywhere: the absence stands."""
    bucket = _StubBucket(PmcOpenDataFetch.absent())
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    discoverer._try_pdf_download = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=False, source_type=FulltextSourceType.NOT_FOUND
    )

    result = discoverer.discover_fulltext(pmcid="PMC123")

    assert result.absence_established


@pytest.mark.parametrize(
    "ids", [{"doi": "10.1/x"}, {"pmid": "123"}, {"pmcid": "PPR1316954"}]
)
def test_without_a_pmc_id_the_bucket_is_not_asked(
    ids: dict[str, Any], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The bucket files by PMC ID only; a preprint's PPR ID is never sent."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))

    _discoverer(bucket, monkeypatch, tmp_path).discover_fulltext(skip_pdf=True, **ids)

    assert bucket.asked == []


def test_a_pmc_id_europe_pmc_resolved_is_used(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """``_try_europepmc_xml`` writes a resolved PMC ID into ``doc_dict``."""
    bucket = _StubBucket(PmcOpenDataFetch.absent())
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)

    def europepmc_resolving(doc_dict: dict[str, Any], *_a: object) -> FulltextResult:
        doc_dict["pmcid"] = "PMC777"
        return _europepmc_absent()

    discoverer._try_europepmc_xml = europepmc_resolving  # type: ignore[method-assign]
    discoverer.discover_fulltext(doi="10.1/x", skip_pdf=True)

    assert bucket.asked == ["PMC777"]


def test_europe_pmc_served_so_the_bucket_is_not_asked(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Nothing beats Europe PMC's own text; no second request."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    discoverer._try_europepmc_xml = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=True, source_type=FulltextSourceType.EUROPEPMC_XML, markdown_content="Text."
    )

    discoverer.discover_fulltext(pmcid="PMC123")

    assert bucket.asked == []


def test_unconvertible_xml_is_recorded_not_absent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Our conversion producing nothing is a parse we could not make."""
    bucket = _StubBucket(PmcOpenDataFetch.served("<not-jats/>"))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    monkeypatch.setattr(discoverer._europepmc, "xml_to_markdown", lambda _x: "")

    result = discoverer.discover_fulltext(pmcid="PMC123", skip_pdf=True)

    assert SourceLookupFailure(
        SERVICE_PMC_OPEN_DATA, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
    ) in result.lookups.failures


def test_a_converter_crash_is_contained_and_the_pdf_stage_still_runs(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A raising converter fails the bucket tier only, not the whole chain."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)

    def crash(_x: str) -> str:
        raise AttributeError("converter bug")

    monkeypatch.setattr(discoverer._europepmc, "xml_to_markdown", crash)
    pdf_stage_calls: list[bool] = []

    def pdf_stage(*_a: object, **_k: object) -> FulltextResult:
        pdf_stage_calls.append(True)
        return FulltextResult(success=False, source_type=FulltextSourceType.NOT_FOUND)

    discoverer._try_pdf_download = pdf_stage  # type: ignore[method-assign]

    result = discoverer.discover_fulltext(pmcid="PMC123")

    assert pdf_stage_calls == [True]
    assert SourceLookupFailure(
        SERVICE_PMC_OPEN_DATA, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
    ) in result.lookups.failures
    assert not result.absence_established


def test_a_failed_cache_write_keeps_the_bucket_text(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Losing the cache must not lose the article."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)

    def full_disk(_d: object, _m: object) -> Path:
        raise OSError("disk full")

    monkeypatch.setattr(
        "bmlibrarian_lite.fulltext_discovery.save_fulltext_markdown", full_disk
    )

    result = discoverer.discover_fulltext(pmcid="PMC123", skip_pdf=True)

    assert result.success
    assert result.source_type == FulltextSourceType.PMC_OPEN_DATA_XML
    assert "We randomised 40 patients" in (result.markdown_content or "")
    assert result.file_path is None


def test_europe_pmcs_own_failure_still_travels(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """Asking the bucket does not drop what Europe PMC left unsettled."""
    bucket = _StubBucket(PmcOpenDataFetch.absent())
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    europepmc_failure = SourceLookupFailure(SERVICE_EUROPE_PMC, _THROTTLED)
    discoverer._try_europepmc_xml = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=False,
        source_type=FulltextSourceType.NOT_ASSESSED,
        lookups=LookupRecord(failures=(europepmc_failure,)),
    )

    result = discoverer.discover_fulltext(pmcid="PMC123", skip_pdf=True)

    assert europepmc_failure in result.lookups.failures


def test_a_served_bucket_result_still_carries_europe_pmcs_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Text from the bucket does not erase what Europe PMC left unsettled."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    europepmc_failure = SourceLookupFailure(SERVICE_EUROPE_PMC, _THROTTLED)
    discoverer._try_europepmc_xml = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=False,
        source_type=FulltextSourceType.NOT_ASSESSED,
        lookups=LookupRecord(failures=(europepmc_failure,)),
    )

    result = discoverer.discover_fulltext(pmcid="PMC123", skip_pdf=True)

    assert result.success
    assert europepmc_failure in result.lookups.failures


def test_a_served_bucket_result_keeps_europe_pmcs_metadata(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The title the reader sees comes from Europe PMC's record, as for its PDF."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    info = ArticleInfo(pmcid="PMC123", title="A trial")
    discoverer._try_europepmc_xml = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=False, source_type=FulltextSourceType.NOT_ASSESSED, article_info=info
    )

    result = discoverer.discover_fulltext(pmcid="PMC123", skip_pdf=True)

    assert result.success
    assert result.article_info == info


def test_a_served_pdf_render_still_carries_the_buckets_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Text from the PDF render does not erase the bucket we could not read."""
    bucket = _StubBucket(PmcOpenDataFetch.unreachable(_THROTTLED))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    info = ArticleInfo(
        pmcid="PMC123", has_pdf=True, pdf_render_url="https://example.org/render"
    )
    discoverer._try_europepmc_xml = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=False, source_type=FulltextSourceType.NOT_ASSESSED, article_info=info
    )
    discoverer._try_europepmc_pdf = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=True,
        source_type=FulltextSourceType.EUROPEPMC_PDF,
        markdown_content="We randomised 40 patients.",
    )

    result = discoverer.discover_fulltext(pmcid="PMC123", skip_pdf=True)

    assert result.success
    assert result.source_type is FulltextSourceType.EUROPEPMC_PDF
    assert SourceLookupFailure(SERVICE_PMC_OPEN_DATA, _THROTTLED) in result.lookups.failures
