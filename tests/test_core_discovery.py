# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""CORE's place in the desktop's chain (#480, stage C).

CORE's extracted text is the last full-text source before the link: asked
inside PDF discovery, by DOI, at the first exit that obtained no PDF and
served no copy. A configured CORE that could not be asked is an unsettled
lookup; a missing key asks nothing and records nothing. No test touches the
network: CORE is a stub or a scripted loopback server.
"""

from __future__ import annotations

from contextlib import ExitStack
from http import HTTPStatus
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from bmlibrarian_lite.analysis_failures import (
    configuration_nudge,
    unestablished_access_clause,
)
from bmlibrarian_lite.constants import (
    CORE_SEARCH_PATH,
    CORE_TEXT_CACHE_STAMP,
    PDF_BASE_DIR_ENV_VAR,
    SERVICE_CORE,
    SERVICE_OPENALEX,
    SERVICE_UNPAYWALL_PDF,
)
from bmlibrarian_lite.core_api import CoreFetch, CoreTextClient, CoreThrottle
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from bmlibrarian_lite.fulltext_discovery import (
    FulltextDiscoverer,
    FulltextResult,
    FulltextSourceType,
)
from bmlibrarian_lite.pdf_discovery import (
    DiscoveryResult,
    PDFDiscoverer,
    PDFSource,
    PDFSourceType,
)
from bmlibrarian_lite.pdf_utils import (
    find_existing_fulltext,
    generate_core_text_path,
    read_cached_core_text,
    save_core_text,
)

from .scripted_http_server import json_answer, running, status_answer

DOI = "10.1159/000513404"
TEXT = "The article's extracted text."
#: A key no test ever sends anywhere real.
KEY = "test-core-key-0123456789"
#: Long enough for CORE's text to be served, were it this article's.
LONG_TEXT_CHARS = 6000


class _Core:
    """CORE answering one scripted fetch, and counting what it is asked."""

    def __init__(self, fetch: CoreFetch) -> None:
        self.fetch = fetch
        self.asked: list[str] = []

    def fetch_full_text(self, doi: str) -> CoreFetch:
        """Answer the scripted fetch, recording the DOI asked."""
        self.asked.append(doi)
        return self.fetch


def _no_pdf_sources(
    self: PDFDiscoverer, doi: Any, pmid: Any, pmcid: Any
) -> tuple[list[PDFSource], LookupRecord]:
    """No PDF source and nothing unasked."""
    return [], LookupRecord()


def _open_access_source(url: str) -> PDFSource:
    return PDFSource(url=url, source_type=PDFSourceType.UNPAYWALL_OA, is_open_access=True)


def _publisher_source(url: str) -> PDFSource:
    return PDFSource(url=url, source_type=PDFSourceType.DOI_DIRECT, is_open_access=False)


def _europepmc_absent(*_args: Any, **_kwargs: Any) -> FulltextResult:
    """Europe PMC answered and served nothing: no failure recorded."""
    return FulltextResult(success=False, source_type=FulltextSourceType.NOT_ASSESSED)


def _discover_with(
    discoverer: FulltextDiscoverer, tmp_path: Path, **kwargs: Any
) -> FulltextResult:
    """A discovery in which Europe PMC, the bucket, the caches and every PDF source find nothing.

    As tests/test_pmc_open_data_discovery.py stops them: both caches empty,
    Europe PMC absent. With no PMC ID the bucket is not asked; OpenAlex is
    conftest's, which knows no work. CORE's cache lives under ``tmp_path``.
    """
    doc = {"doi": DOI, "id": "d1"}
    discoverer._try_europepmc_xml = _europepmc_absent  # type: ignore[method-assign]
    with ExitStack() as stack:
        stack.enter_context(patch.object(PDFDiscoverer, "_discover_sources", _no_pdf_sources))
        stack.enter_context(patch.dict("os.environ", {PDF_BASE_DIR_ENV_VAR: str(tmp_path / "pdf")}))
        stack.enter_context(
            patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", lambda _d: None)
        )
        stack.enter_context(
            patch("bmlibrarian_lite.fulltext_discovery.find_existing_pdf", lambda _d: None)
        )
        stack.enter_context(
            patch(
                "bmlibrarian_lite.fulltext_discovery.save_fulltext_markdown",
                lambda _d, _m: tmp_path / "cached.md",
            )
        )
        stack.enter_context(
            patch("bmlibrarian_lite.pdf_utils.get_fulltext_base_dir", return_value=tmp_path)
        )
        return discoverer.discover_fulltext(doc_dict=doc, doi=DOI, **kwargs)


def _discover(core: Any, tmp_path: Path, **kwargs: Any) -> FulltextResult:
    """:func:`_discover_with`, with this CORE."""
    return _discover_with(FulltextDiscoverer(use_browser_fallback=False, core=core), tmp_path, **kwargs)


def test_cores_text_is_the_full_text_when_nothing_else_has_it(tmp_path: Path) -> None:
    """Served: the article's text, labelled CORE's, asked by the DOI."""
    core = _Core(CoreFetch.served(TEXT))
    result = _discover(core, tmp_path)
    assert result.success
    assert result.source_type is FulltextSourceType.CORE_TEXT
    assert result.markdown_content == TEXT
    assert core.asked == [DOI]


def test_core_knowing_nothing_adds_nothing(tmp_path: Path) -> None:
    """Absent: the result is what it was without CORE, and absence holds."""
    core = _Core(CoreFetch.absent())
    result = _discover(core, tmp_path)
    assert core.asked == [DOI], "else the absence proves nothing"
    assert not result.success
    assert SERVICE_CORE not in {f.service for f in result.lookups.failures}
    assert result.absence_established


def test_an_unreachable_core_is_told_and_blocks_absence(tmp_path: Path) -> None:
    """The maintainer's decision: a configured CORE that could not be asked is unsettled."""
    failure = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
    result = _discover(_Core(CoreFetch.unreachable(failure)), tmp_path)
    assert SourceLookupFailure(SERVICE_CORE, failure) in result.lookups.failures
    assert not result.absence_established
    assert "CORE (HTTP 503 Service Unavailable) could not be asked" in (result.error or "")


#: CORE's refused key, as the record holds it (#498).
REFUSED = SourceLookupSkipped(SERVICE_CORE, LookupSkipReason.KEY_REFUSED)
#: The sentence the reader is told for it, alone (open_access_unsettled_notice.json).
REFUSED_NOTICE = (
    "CORE (the key in the settings was refused) could not be asked, so a freely "
    "available copy may exist. Whether this document is open access was not established."
)


def test_a_refused_key_is_a_skip_that_blocks_absence(tmp_path: Path) -> None:
    """The maintainer's ruling: a skip of CORE, told as the key, never as a failure (#498)."""
    result = _discover(_Core(CoreFetch.key_refused()), tmp_path)
    assert REFUSED in result.lookups.skipped
    assert SERVICE_CORE not in {f.service for f in result.lookups.failures}
    assert not result.absence_established
    assert unestablished_access_clause(LookupRecord(skipped=(REFUSED,))) == REFUSED_NOTICE
    assert "CORE (the key in the settings was refused) could not be asked" in (result.error or "")
    assert "did not serve it" not in (result.error or "")


def test_a_refused_key_earns_no_configuration_nudge() -> None:
    """The key is configured; the nudge is for a source that is not (#498)."""
    assert configuration_nudge(LookupRecord(skipped=(REFUSED,))) == ""
    assert "Configuring" not in unestablished_access_clause(LookupRecord(skipped=(REFUSED,)))


def test_a_scripted_401_reaches_the_reader_as_a_refused_key(tmp_path: Path) -> None:
    """End to end over loopback: the 401 itself is told as the key (#498)."""
    with running({CORE_SEARCH_PATH: [status_answer(HTTPStatus.UNAUTHORIZED)]}) as server:
        client = CoreTextClient(KEY, base_url=server.url, max_retries=0, throttle=CoreThrottle())
        result = _discover(client, tmp_path)
    assert REFUSED in result.lookups.skipped
    assert "HTTP 401" not in (result.error or "")


def test_without_a_key_core_is_not_asked_and_nothing_is_recorded(tmp_path: Path) -> None:
    """Spec decision 4: silent, and blocks nothing."""
    discoverer = FulltextDiscoverer(use_browser_fallback=False)  # conftest: no client
    assert discoverer._core is None
    result = _discover_with(discoverer, tmp_path)
    assert SERVICE_CORE not in {f.service for f in result.lookups.failures}
    assert all(s.service != SERVICE_CORE for s in result.lookups.skipped)
    assert result.absence_established


def test_a_downloaded_pdf_means_core_is_never_asked(tmp_path: Path) -> None:
    """The first copy obtained ends the walk."""
    asked: list[str] = []
    source = _open_access_source("https://repo.example.org/a.pdf")
    downloaded = DiscoveryResult(success=True, file_path=tmp_path / "a.pdf", source=source)

    def core(doi: str) -> CoreFetch:
        asked.append(doi)
        return CoreFetch.served(TEXT)

    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", return_value=downloaded):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "a.pdf", doi=DOI, core_text=core
        )
    assert asked == []
    assert result.success
    assert result.text is None


def test_a_copy_served_but_not_saved_means_core_is_never_asked(tmp_path: Path) -> None:
    """A served copy settles the question; CORE could add nothing."""
    core = _Core(CoreFetch.served(TEXT))
    not_saved = DiscoveryResult(success=False, not_saved=True)
    source = _open_access_source("https://repo.example.org/a.pdf")
    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", return_value=not_saved):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=core.fetch_full_text
        )
    assert core.asked == []
    assert not result.success


def test_a_cancel_means_core_is_never_asked(tmp_path: Path) -> None:
    """We stopped asking: CORE is not asked after a cancel."""
    core = _Core(CoreFetch.served(TEXT))
    discoverer = PDFDiscoverer(use_browser_fallback=False)
    source = _open_access_source("https://repo.example.org/a.pdf")

    def cancelled(self: PDFDiscoverer, *_a: Any) -> DiscoveryResult:
        discoverer.cancel()
        return DiscoveryResult(
            success=False, failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 403)
        )

    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source, source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", cancelled):
        result = discoverer.discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=core.fetch_full_text
        )
    assert result.error == "Cancelled"
    assert core.asked == []


def test_core_is_asked_after_every_refused_copy_and_openalex(tmp_path: Path) -> None:
    """Last before the link: Unpaywall's refused PDF and OpenAlex come first."""
    order: list[str] = []
    refused = DiscoveryResult(success=False, failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 403))
    source = _open_access_source("https://walled.example.org/a.pdf")

    def try_download(self: PDFDiscoverer, src: Any, output_path: Any, title: Any) -> DiscoveryResult:
        order.append("pdf")
        return refused

    def openalex(self: PDFDiscoverer, doi: Any, known: Any) -> tuple[list[PDFSource], LookupRecord]:
        order.append("openalex")
        return [], LookupRecord(
            failures=(SourceLookupFailure(SERVICE_OPENALEX, RequestFailure(RequestFailureKind.TIMEOUT)),)
        )

    def core(doi: str) -> CoreFetch:
        order.append("core")
        return CoreFetch.unreachable(RequestFailure(RequestFailureKind.TIMEOUT))

    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", try_download), \
         patch.object(PDFDiscoverer, "_discover_openalex", openalex):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=core
        )
    assert order == ["pdf", "openalex", "core"]
    services = [f.service for f in result.lookups.failures]
    assert services.index(SERVICE_OPENALEX) < services.index(SERVICE_CORE)
    assert result.error is not None and result.error.endswith(
        "Whether this document is open access was not established."
    )
    assert "; CORE (the request timed out)" in result.error


def test_core_serving_drops_the_refused_copies(tmp_path: Path) -> None:
    """A text obtained settles the question, as a downloaded PDF does."""
    refused = DiscoveryResult(success=False, failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 403))
    source = _open_access_source("https://walled.example.org/a.pdf")
    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", return_value=refused):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=lambda doi: CoreFetch.served(TEXT)
        )
    assert result.success and result.text == TEXT and result.file_path is None
    assert result.lookups == LookupRecord()


def test_core_serving_at_a_paywall_is_the_result(tmp_path: Path) -> None:
    """At a publisher's paywall, CORE's text is served rather than the paywall."""
    paywalled = DiscoveryResult(success=False, is_paywall=True, error="Paywalled",
                                failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 401))
    source = _publisher_source("https://publisher.example.org/a.pdf")
    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", return_value=paywalled):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=lambda doi: CoreFetch.served(TEXT)
        )
    assert result.success and result.text == TEXT and not result.is_paywall


def test_core_is_asked_once_whatever_the_exit(tmp_path: Path) -> None:
    """A non-open-access paywall after a CORE miss does not ask again."""
    asked: list[str] = []
    paywalled = DiscoveryResult(success=False, is_paywall=True, error="Paywalled",
                                failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 401))
    source = _publisher_source("https://publisher.example.org/a.pdf")

    def core(doi: str) -> CoreFetch:
        asked.append(doi)
        return CoreFetch.absent()

    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", return_value=paywalled):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=core,
        )
    assert asked == [DOI]
    assert result.is_paywall


def test_no_doi_no_core(tmp_path: Path) -> None:
    """CORE is searched by DOI alone."""
    asked: list[str] = []

    def core(doi: str) -> CoreFetch:
        asked.append(doi)
        return CoreFetch.absent()

    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([], LookupRecord())):
        PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", pmid="123", core_text=core,
        )
    assert asked == []


def test_core_is_asked_by_the_cleaned_doi(tmp_path: Path) -> None:
    """The DOI the discovery cleaned, not the resolver URL it was given."""
    asked: list[str] = []

    def core(doi: str) -> CoreFetch:
        asked.append(doi)
        return CoreFetch.absent()

    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([], LookupRecord())):
        PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=f"https://doi.org/{DOI}", core_text=core,
        )
    assert asked == [DOI]


def test_another_articles_text_is_not_served_through_the_chain(tmp_path: Path) -> None:
    """Review focus 1, end to end: a search hit for another DOI is an absence."""
    answer = {"results": [{"doi": "10.1159/999999", "fullText": "x" * LONG_TEXT_CHARS}]}
    with running({CORE_SEARCH_PATH: [json_answer(answer)]}) as server:
        client = CoreTextClient(KEY, base_url=server.url, max_retries=0, throttle=CoreThrottle())
        result = _discover(client, tmp_path)
        received = list(server.received)
    assert not result.success
    assert result.source_type is not FulltextSourceType.CORE_TEXT
    assert len(received) == 1


def test_the_core_cache_is_read_at_cores_place_and_never_shadows_jats(tmp_path: Path) -> None:
    """Cached CORE text is served without asking; find_existing_fulltext never returns it."""
    doc = {"doi": DOI, "id": "d1"}
    path = save_core_text(doc, TEXT, base_dir=tmp_path)
    assert path == generate_core_text_path(doc, base_dir=tmp_path)
    assert path.read_text(encoding="utf-8").startswith(CORE_TEXT_CACHE_STAMP + "\n")
    assert read_cached_core_text(path) == TEXT
    assert find_existing_fulltext(doc, base_dir=tmp_path) is None
    core = _Core(CoreFetch.served("live text"))
    result = _discover(core, tmp_path)
    assert result.markdown_content == TEXT
    assert core.asked == []


def test_cores_served_text_is_cached(tmp_path: Path) -> None:
    """Served once, read from the cache the next time."""
    _discover(_Core(CoreFetch.served(TEXT)), tmp_path)
    path = generate_core_text_path({"doi": DOI, "id": "d1"}, base_dir=tmp_path)
    assert read_cached_core_text(path) == TEXT


def test_a_damaged_core_cache_is_asked_again(tmp_path: Path) -> None:
    """No stamp, another stamp or an empty body is no cached text."""
    doc = {"doi": DOI, "id": "d1"}
    path = generate_core_text_path(doc, base_dir=tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    assert read_cached_core_text(path) is None, "a missing file is no cached text"
    for content in ("plain text", "<!-- other v1 -->\ntext", f"{CORE_TEXT_CACHE_STAMP}\n  \n"):
        path.write_text(content, encoding="utf-8")
        assert read_cached_core_text(path) is None


def test_core_is_told_last_in_chain_order() -> None:
    """CORE after every open-access source, whatever order it was recorded in.

    Chain order is the tried-sources statement's (a PDF was tried); a
    lookup-only clause keeps the record's order, which discovery makes the
    chain's (the next test).
    """
    record = LookupRecord(failures=(
        SourceLookupFailure(SERVICE_CORE, RequestFailure(RequestFailureKind.HTTP_STATUS, 503)),
        SourceLookupFailure(SERVICE_OPENALEX, RequestFailure(RequestFailureKind.TIMEOUT)),
        SourceLookupFailure(
            SERVICE_UNPAYWALL_PDF,
            RequestFailure(RequestFailureKind.HTTP_STATUS, 403),
            "https://walled.example.org/a.pdf",
        ),
    ))
    clause = unestablished_access_clause(record)
    assert clause.index("walled.example.org") < clause.index("OpenAlex") < clause.index("CORE")


def test_with_no_pdf_found_core_is_told_after_openalex(tmp_path: Path) -> None:
    """No PDF tried: OpenAlex then CORE, the order discovery asked them in."""

    def openalex(self: PDFDiscoverer, doi: Any, known: Any) -> tuple[list[PDFSource], LookupRecord]:
        return [], LookupRecord(
            failures=(SourceLookupFailure(SERVICE_OPENALEX, RequestFailure(RequestFailureKind.TIMEOUT)),)
        )

    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([], LookupRecord())), \
         patch.object(PDFDiscoverer, "_discover_openalex", openalex):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI,
            core_text=lambda doi: CoreFetch.unreachable(RequestFailure(RequestFailureKind.HTTP_STATUS, 503)),
        )
    error = result.error or ""
    assert "CORE (HTTP 503 Service Unavailable)" in error
    assert error.index("OpenAlex") < error.index("CORE")


@pytest.mark.real_core_client
def test_the_key_reaches_the_discoverer_from_each_caller(monkeypatch: pytest.MonkeyPatch) -> None:
    """Workers, MCP and the transparency analyser pass the configured key."""
    seen: list[str | None] = []

    def recording(key: str | None) -> None:
        seen.append(key)
        return None

    monkeypatch.setattr("bmlibrarian_lite.fulltext_discovery.default_core_client", recording)
    FulltextDiscoverer(core_api_key="k1")
    from bmlibrarian_lite.gui.workers import FulltextDiscoveryWorker
    FulltextDiscoveryWorker({"doi": DOI}, core_api_key="k2")._build_discoverer()
    from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
        StudyTransparencyAnalyzer,
    )
    StudyTransparencyAnalyzer("a@b.org", core_api_key="k3")._fulltext_discoverer()
    assert seen == ["k1", "k2", "k3"]


@pytest.mark.real_core_client
def test_the_mcp_server_passes_the_configured_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """The MCP server's discoverer is built with the configured CORE key."""
    pytest.importorskip("mcp")
    from bmlibrarian_lite import mcp_server
    from bmlibrarian_lite.config import LiteConfig

    seen: list[str | None] = []

    def recording(key: str | None) -> None:
        seen.append(key)
        return None

    monkeypatch.setattr("bmlibrarian_lite.fulltext_discovery.default_core_client", recording)
    for name in (
        "LiteStorage", "LLMClient", "LiteSearchAgent", "LiteScoringAgent",
        "LiteCitationAgent", "LiteReportingAgent", "LiteInterrogationAgent",
    ):
        monkeypatch.setattr(mcp_server, name, MagicMock())
    config = LiteConfig()
    config.discovery.core_api_key = "k4"
    mcp_server._make_server(config)
    assert seen == ["k4"]


def test_the_analyser_factory_passes_the_key() -> None:
    """The background analyser keeps the key it was built with."""
    from bmlibrarian_lite.transparency.assessment import create_background_analyzer

    analyzer = create_background_analyzer("a@b.org", core_api_key="k5")
    assert analyzer._core_api_key == "k5"


def test_the_transparency_manager_passes_the_configured_key() -> None:
    """The manager builds its analyser with the configured CORE key."""
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.transparency.transparency_manager import TransparencyManager

    config = LiteConfig()
    config.discovery.core_api_key = "k6"
    with patch(
        "bmlibrarian_lite.transparency.transparency_manager.create_background_analyzer"
    ) as factory:
        TransparencyManager(storage=MagicMock(), config=config, email="a@b.org")
    assert factory.call_args.kwargs["core_api_key"] == "k6"


def test_the_reanalysis_worker_passes_the_configured_key() -> None:
    """A reanalysis pass builds its analyser with the configured CORE key."""
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.gui.workers import TransparencyReanalysisWorker

    config = LiteConfig()
    config.discovery.core_api_key = "k7"
    worker = TransparencyReanalysisWorker(config=config, storage=MagicMock(), documents=[])
    with patch(
        "bmlibrarian_lite.transparency.assessment.create_background_analyzer"
    ) as factory:
        worker.run()
    assert factory.call_args.kwargs["core_api_key"] == "k7"


def test_an_unreachable_core_at_a_paywall_is_recorded_and_told(tmp_path: Path) -> None:
    """At a publisher's paywall, a CORE that could not be asked is in the record and the sentence."""
    failure = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
    paywalled = DiscoveryResult(success=False, is_paywall=True, error="Paywalled",
                                failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 401))
    source = _publisher_source("https://publisher.example.org/a.pdf")
    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", return_value=paywalled):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=lambda doi: CoreFetch.unreachable(failure)
        )
    assert result.is_paywall
    assert SourceLookupFailure(SERVICE_CORE, failure) in result.lookups.failures
    assert "CORE (HTTP 503 Service Unavailable)" in (result.error or "")


def test_a_cancel_during_the_last_download_means_core_is_never_asked(tmp_path: Path) -> None:
    """A cancel that lands after the last copy was tried stops CORE too."""
    core = _Core(CoreFetch.served(TEXT))
    discoverer = PDFDiscoverer(use_browser_fallback=False)
    source = _publisher_source("https://publisher.example.org/a.pdf")

    def cancelled(self: PDFDiscoverer, *_a: Any) -> DiscoveryResult:
        discoverer.cancel()
        return DiscoveryResult(
            success=False, failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 500)
        )

    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", cancelled):
        discoverer.discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=core.fetch_full_text
        )
    assert core.asked == []


def test_the_core_fallback_asks_once() -> None:
    """However many exits reach it, CORE is asked once per discovery."""
    from bmlibrarian_lite.pdf_discovery import _CoreFallback

    core = _Core(CoreFetch.unreachable(RequestFailure(RequestFailureKind.TIMEOUT)))
    fallback = _CoreFallback(core.fetch_full_text, DOI)
    first = fallback.ask()
    assert first[1].failures and fallback.ask() == (None, LookupRecord())
    assert core.asked == [DOI]


# ---- #499: a downloaded PDF that yields no text ---------------------------


def _try_with_downloaded_pdf(
    core: Any, tmp_path: Path, extracted: Any, doi: str = f"https://doi.org/{DOI}"
) -> FulltextResult:
    """``_try_pdf_download`` where discovery succeeded with a PDF file.

    Args:
        core: The CORE client, or ``None`` for no key.
        tmp_path: Where the PDF stands.
        extracted: What ``extract_pdf_text`` returns, or the exception it raises.
        doi: The DOI as the caller holds it.

    Returns:
        The result of the PDF step.
    """
    pdf = tmp_path / "a.pdf"
    pdf.write_bytes(b"%PDF-1.4")
    downloaded = DiscoveryResult(
        success=True,
        file_path=pdf,
        source=_open_access_source("https://repo.example.org/a.pdf"),
    )
    discoverer = FulltextDiscoverer(use_browser_fallback=False, core=core)
    extractor: dict[str, Any] = (
        {"side_effect": extracted}
        if isinstance(extracted, Exception)
        else {"return_value": extracted}
    )
    with patch.dict("os.environ", {PDF_BASE_DIR_ENV_VAR: str(tmp_path / "pdf")}), \
         patch.object(PDFDiscoverer, "discover_and_download", return_value=downloaded), \
         patch("bmlibrarian_lite.fulltext_discovery.extract_pdf_text", **extractor), \
         patch("bmlibrarian_lite.pdf_utils.get_fulltext_base_dir", return_value=tmp_path), \
         patch("bmlibrarian_lite.fulltext_discovery.save_core_text"), \
         patch("bmlibrarian_lite.fulltext_discovery.read_cached_core_text", lambda _p: None):
        return discoverer._try_pdf_download({"doi": DOI, "id": "d1"}, None, None, doi, "T")


def test_an_unreadable_pdf_is_followed_by_cores_text(tmp_path: Path) -> None:
    """A scan is no full text obtained: CORE is asked, once, by the cleaned DOI."""
    core = _Core(CoreFetch.served(TEXT))
    result = _try_with_downloaded_pdf(core, tmp_path, "   ")
    assert result.success
    assert result.source_type is FulltextSourceType.CORE_TEXT
    assert result.markdown_content == TEXT
    assert result.file_path is None
    assert core.asked == [DOI]


def test_an_unreadable_pdf_with_core_unreachable_stays_unsettled(tmp_path: Path) -> None:
    """CORE's failure joins the lookups, so no absence is claimed."""
    failure = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=503)
    core = _Core(CoreFetch.unreachable(failure))
    result = _try_with_downloaded_pdf(core, tmp_path, "   ")
    assert not result.success
    assert SourceLookupFailure(SERVICE_CORE, failure) in result.lookups.failures
    assert not result.absence_established
    assert core.asked == [DOI]


def test_an_unreadable_pdf_with_a_refused_key_records_the_skip(tmp_path: Path) -> None:
    """After a scan, a refused key is a skip of CORE, keeping the result unsettled (#498)."""
    core = _Core(CoreFetch.key_refused())
    result = _try_with_downloaded_pdf(core, tmp_path, "   ")
    assert not result.success
    assert REFUSED in result.lookups.skipped
    assert SERVICE_CORE not in {f.service for f in result.lookups.failures}
    assert not result.absence_established


def test_an_unreadable_pdf_with_core_absent_is_as_before(tmp_path: Path) -> None:
    """Control: CORE knowing nothing leaves the unreadable-PDF result unchanged."""
    core = _Core(CoreFetch.absent())
    result = _try_with_downloaded_pdf(core, tmp_path, "   ")
    assert not result.success
    assert result.source_type is FulltextSourceType.NOT_ASSESSED
    assert "no text could be extracted" in (result.error or "")
    assert not result.absence_established
    assert SERVICE_CORE not in {f.service for f in result.lookups.failures}
    assert core.asked == [DOI]


def test_a_pdf_with_text_means_core_is_never_asked(tmp_path: Path) -> None:
    """Control: a PDF that yields text ends the walk."""
    core = _Core(CoreFetch.served(TEXT))
    result = _try_with_downloaded_pdf(core, tmp_path, "The PDF's own text.")
    assert result.source_type is FulltextSourceType.DOWNLOADED_PDF
    assert core.asked == []


def test_an_extraction_that_raises_is_unreadable_and_asks_core(tmp_path: Path) -> None:
    """A raising extractor is an unreadable copy, like an empty one."""
    core = _Core(CoreFetch.served(TEXT))
    result = _try_with_downloaded_pdf(core, tmp_path, RuntimeError("corrupt"))
    assert result.source_type is FulltextSourceType.CORE_TEXT
    assert core.asked == [DOI]


def test_an_unreadable_pdf_without_a_key_asks_nothing(tmp_path: Path) -> None:
    """Without a key nothing changes and nothing is asked."""
    result = _try_with_downloaded_pdf(None, tmp_path, "   ")
    assert not result.success
    assert not result.absence_established
