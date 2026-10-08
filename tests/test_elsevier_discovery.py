# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Elsevier's place in the desktop's chain (#480, stage C2).

Elsevier's Article API is asked inside PDF discovery, once, by the cleaned
DOI, before PMC's and Unpaywall's lookups, only for an Elsevier DOI and only
with a key. A PDF it serves is the article's; a first page, a 404 or another
publisher's DOI adds nothing and the chain goes on; a configured Elsevier that
could not be asked, or refused the key or the network, is unsettled. No test
touches the network: Elsevier is a stub or a scripted loopback server.
"""

from __future__ import annotations

from collections.abc import Callable
from contextlib import ExitStack
from http import HTTPStatus
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from bmlibrarian_lite import elsevier_api
from bmlibrarian_lite.analysis_failures import configuration_nudge, not_saved_note
from bmlibrarian_lite.config import DiscoveryConfig, LiteConfig
from bmlibrarian_lite.constants import (
    ELSEVIER_HOST,
    ELSEVIER_STATUS_HEADER,
    PDF_BASE_DIR_ENV_VAR,
    SERVICE_ELSEVIER,
    SERVICE_UNPAYWALL,
    SERVICE_UNPAYWALL_PDF,
)
from bmlibrarian_lite.core_api import CoreFetch
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from bmlibrarian_lite.elsevier_api import (
    ElsevierArticleClient,
    ElsevierCredentials,
    ElsevierFetch,
    ElsevierSession,
    elsevier_article_url,
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

from .scripted_http_server import ScriptedAnswer, running, status_answer

#: An Elsevier DOI, as a source may write it, and the path Elsevier is asked at.
DOI = "10.1016/j.cell.2020.02.052"
PATH = f"/content/article/doi/{DOI}"
#: The article URL a size or caching note names: it carries no key.
ARTICLE_URL = elsevier_article_url(DOI)
#: Another publisher's DOI.
FOREIGN_DOI = "10.1371/journal.pone.0000217"
#: A key and a token no test ever sends anywhere real.
KEY = "test-elsevier-key-0123456789"
TOKEN = "test-elsevier-token-ABCDEF"
#: What the scripted Elsevier serves as the article's PDF.
PDF = b"%PDF-1.7\n" + b"0123456789" * 200
#: The text the article's PDF yields.
TEXT = "The article's own text, extracted from Elsevier's PDF."
#: Elsevier's answer to a requestor not entitled to the article.
FIRST_PAGE = (
    (ELSEVIER_STATUS_HEADER, "WARNING - Response limited to first page because "
     "requestor not entitled to resource"),
)
#: A 403 body naming the network refusal.
AUTHENTICATION_ERROR = (
    b"<service-error><status><statusCode>AUTHENTICATION_ERROR</statusCode>"
    b"</status></service-error>"
)
UNREACHABLE = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
#: An Unpaywall PDF refused, the copy every "tried sources" test tries next.
REFUSED_COPY_URL = "https://walled.example.org/a.pdf"


class _Elsevier:
    """Elsevier answering one scripted fetch, and counting what it is asked.

    A served fetch writes the PDF where the discovery asked it to, as the
    real client does.
    """

    def __init__(self, fetch: ElsevierFetch | None = None, served: bool = False) -> None:
        self.fetch = fetch
        self.served = served
        self.asked: list[str] = []

    def article_url(self, doi: str) -> str:
        """Elsevier's own article URL, as the real client's default base gives it."""
        return elsevier_article_url(doi)

    def fetch_pdf(
        self, doi: str, output_path: Path, cancelled: Callable[[], bool]
    ) -> ElsevierFetch:
        """Answer the scripted fetch, recording the DOI asked."""
        self.asked.append(doi)
        if self.served:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(PDF)
            return ElsevierFetch.served(output_path)
        assert self.fetch is not None
        return self.fetch


def _client(base_url: str, token: str | None = None) -> ElsevierArticleClient:
    """The real client on a scripted server, with a fresh session and no retries."""
    return ElsevierArticleClient(
        ElsevierCredentials(KEY, token),
        base_url=base_url,
        max_retries=0,
        session_state=ElsevierSession(),
    )


class _Chain:
    """PDF discovery with Elsevier, and the sources after it stubbed.

    ``_discover_sources`` stands for PMC's and Unpaywall's lookups: it
    records that it was asked and answers ``sources`` and ``lookups``. Every
    download refuses the copy, so no copy after Elsevier ever serves.
    """

    def __init__(
        self,
        sources: tuple[PDFSource, ...] = (),
        lookups: LookupRecord | None = None,
    ) -> None:
        self.sources = sources
        self.lookups = lookups or LookupRecord()
        self.order: list[str] = []

    def discover(
        self,
        elsevier: Any,
        tmp_path: Path,
        doi: str | None = DOI,
        core_text: Callable[[str], CoreFetch] | None = None,
        discoverer: PDFDiscoverer | None = None,
        title: str | None = None,
    ) -> DiscoveryResult:
        """Run one discovery to ``tmp_path / 'a.pdf'``."""
        chain = self

        def discover_sources(
            self: PDFDiscoverer, doi: Any, pmid: Any, pmcid: Any
        ) -> tuple[list[PDFSource], LookupRecord]:
            chain.order.append("unpaywall")
            return list(chain.sources), chain.lookups

        def try_download(
            self: PDFDiscoverer, source: PDFSource, output_path: Any, title: Any
        ) -> DiscoveryResult:
            chain.order.append("download")
            return DiscoveryResult(
                success=False, failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 403)
            )

        discoverer = discoverer or PDFDiscoverer(use_browser_fallback=False, elsevier=elsevier)
        with patch.object(PDFDiscoverer, "_discover_sources", discover_sources), \
             patch.object(PDFDiscoverer, "_try_download", try_download):
            return discoverer.discover_and_download(
                tmp_path / "a.pdf", doi=doi, pmid="12345", core_text=core_text,
                expected_title=title,
            )


def _refused_copy() -> PDFSource:
    return PDFSource(
        url=REFUSED_COPY_URL, source_type=PDFSourceType.UNPAYWALL_OA, is_open_access=True
    )


def _never_leaks(*texts: object) -> None:
    """Neither the key nor the token, nor any query string, is in what the reader gets."""
    for text in texts:
        shown = str(text)
        assert KEY not in shown
        assert TOKEN not in shown
        assert "apiKey" not in shown and "insttoken=" not in shown


# ---- served -----------------------------------------------------------------


def test_a_served_pdf_ends_the_walk(tmp_path: Path) -> None:
    """Served: the article's PDF, Elsevier's source, nothing after it asked."""
    chain = _Chain(sources=(_refused_copy(),))
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF, "application/pdf")]}) as server:
        result = chain.discover(_client(server.url), tmp_path)
    assert result.success
    assert result.file_path == tmp_path / "a.pdf"
    assert result.file_path.read_bytes() == PDF
    assert result.source is not None
    assert result.source.source_type is PDFSourceType.ELSEVIER_API
    assert chain.order == [], "Unpaywall is never asked after Elsevier served"
    assert result.lookups == LookupRecord()


def test_the_desktop_source_type_is_the_contracts() -> None:
    """``elsevier_api``, as fulltext_parity/elsevier_article.json names it."""
    assert PDFSourceType.ELSEVIER_API.value == "elsevier_api"


def test_a_served_pdf_is_named_by_its_article_url_without_the_key(tmp_path: Path) -> None:
    """The source's address is the article URL; neither secret is in it."""
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF, "application/pdf")]}) as server:
        result = _Chain().discover(
            ElsevierArticleClient(
                ElsevierCredentials(KEY, TOKEN), base_url=server.url, max_retries=0,
                session_state=ElsevierSession(),
            ),
            tmp_path,
        )
    assert result.source is not None
    assert result.source.url == elsevier_article_url(DOI, server.url)
    _never_leaks(result.source.url, result)


def test_a_served_pdf_has_its_title_checked(tmp_path: Path) -> None:
    """As any downloaded PDF: a doubt about the title is a warning on the result."""
    discoverer = PDFDiscoverer(use_browser_fallback=False, elsevier=_Elsevier(served=True))
    with patch.object(
        PDFDiscoverer, "_verify_pdf_content", return_value=(False, "Title match: 10%")
    ) as verify:
        result = _Chain().discover(None, tmp_path, discoverer=discoverer, title="A title")
        assert result.success
    verify.assert_called_once_with(tmp_path / "a.pdf", "A title")
    assert result.verification_warning == "Title match: 10%"


# ---- absent ------------------------------------------------------------------


def test_a_first_page_is_never_served_and_unpaywall_is_asked_next(tmp_path: Path) -> None:
    """Review focus 1: the first page is no article; nothing about Elsevier is kept."""
    chain = _Chain(lookups=LookupRecord(failures=(
        SourceLookupFailure(SERVICE_UNPAYWALL, RequestFailure(RequestFailureKind.TIMEOUT)),
    )))
    answer = ScriptedAnswer(HTTPStatus.OK, PDF, "application/pdf", FIRST_PAGE)
    with running({PATH: [answer]}) as server:
        result = chain.discover(_client(server.url), tmp_path)
    assert chain.order == ["unpaywall"]
    assert not result.success
    assert not (tmp_path / "a.pdf").exists()
    assert SERVICE_ELSEVIER not in {f.service for f in result.lookups.failures}
    assert SERVICE_ELSEVIER not in {s.service for s in result.lookups.skipped}
    assert "Elsevier" not in (result.error or "")


def test_a_404_is_an_absence(tmp_path: Path) -> None:
    """As the first page: Unpaywall next, and nothing about Elsevier."""
    chain = _Chain()
    with running({PATH: [status_answer(HTTPStatus.NOT_FOUND)]}) as server:
        result = chain.discover(_client(server.url), tmp_path)
    assert chain.order == ["unpaywall"]
    assert result.lookups == LookupRecord()
    assert "Elsevier" not in (result.error or "")


# ---- unreachable and refused -------------------------------------------------


def test_an_unreachable_elsevier_is_recorded_and_told_before_unpaywall(tmp_path: Path) -> None:
    """A 503: a failure of Elsevier's, named before Unpaywall's lookup."""
    chain = _Chain(lookups=LookupRecord(failures=(
        SourceLookupFailure(SERVICE_UNPAYWALL, RequestFailure(RequestFailureKind.TIMEOUT)),
    )))
    with running({PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE)]}) as server:
        result = chain.discover(_client(server.url), tmp_path)
    assert chain.order == ["unpaywall"]
    assert SourceLookupFailure(SERVICE_ELSEVIER, UNREACHABLE) in result.lookups.failures
    services = [f.service for f in result.lookups.failures]
    assert services.index(SERVICE_ELSEVIER) < services.index(SERVICE_UNPAYWALL)
    error = result.error or ""
    assert "Elsevier's API (HTTP 503 Service Unavailable)" in error
    assert error.index("Elsevier's API") < error.index("Unpaywall")
    _never_leaks(error, result.lookups)


def test_an_unreachable_elsevier_is_first_among_the_tried_sources(tmp_path: Path) -> None:
    """With a copy tried: Elsevier's entry comes before Unpaywall's in "Tried sources"."""
    chain = _Chain(sources=(_refused_copy(),))
    result = chain.discover(_Elsevier(ElsevierFetch.unreachable(UNREACHABLE)), tmp_path)
    assert chain.order == ["unpaywall", "download"]
    error = result.error or ""
    assert error.startswith("Failed to obtain a PDF from the following tried sources: ")
    assert error.index("Elsevier's API (HTTP 503") < error.index("walled.example.org")


def test_an_unreachable_elsevier_blocks_absence_at_the_end_of_the_chain(tmp_path: Path) -> None:
    """Nothing else serves: the chain's result does not establish an absence."""
    result = _discover_fulltext(_Elsevier(ElsevierFetch.unreachable(UNREACHABLE)), tmp_path)
    assert not result.success
    assert SourceLookupFailure(SERVICE_ELSEVIER, UNREACHABLE) in result.lookups.failures
    assert not result.absence_established


@pytest.mark.parametrize(
    ("answer", "reason", "words"),
    [
        (status_answer(HTTPStatus.UNAUTHORIZED), LookupSkipReason.KEY_REFUSED,
         "Elsevier's API (the key in the settings was refused) could not be asked"),
        (ScriptedAnswer(HTTPStatus.FORBIDDEN, AUTHENTICATION_ERROR, "text/xml"),
         LookupSkipReason.NETWORK_REFUSED,
         "Elsevier's API (not available from this network) could not be asked"),
    ],
    ids=["key refused", "network refused"],
)
def test_a_refusal_is_a_skip_told_in_its_words(
    answer: ScriptedAnswer, reason: LookupSkipReason, words: str, tmp_path: Path
) -> None:
    """A refused key or network: a skip of Elsevier, no failure, no nudge, absence blocked."""
    chain = _Chain()
    with running({PATH: [answer]}) as server:
        result = chain.discover(_client(server.url), tmp_path)
    assert chain.order == ["unpaywall"]
    skip = SourceLookupSkipped(SERVICE_ELSEVIER, reason)
    assert skip in result.lookups.skipped
    assert SERVICE_ELSEVIER not in {f.service for f in result.lookups.failures}
    assert result.lookups.anything_unsettled
    error = result.error or ""
    assert words in error
    assert configuration_nudge(result.lookups) == ""
    assert "Configur" not in error
    _never_leaks(error, result.lookups)


def test_a_refusal_blocks_absence_at_the_end_of_the_chain(tmp_path: Path) -> None:
    """The channel is configured and refused: never an established absence."""
    for fetch in (ElsevierFetch.key_refused(), ElsevierFetch.network_refused()):
        result = _discover_fulltext(_Elsevier(fetch), tmp_path)
        assert not result.absence_established


# ---- not saved, over size ----------------------------------------------------


def test_a_pdf_not_saved_is_the_caching_note_and_nothing_else_is_asked(tmp_path: Path) -> None:
    """Served and not saved: the caching note at api.elsevier.com, nothing asked after it."""
    chain = _Chain(sources=(_refused_copy(),))
    core_asked: list[str] = []

    def core(doi: str) -> CoreFetch:
        core_asked.append(doi)
        return CoreFetch.absent()

    result = chain.discover(_Elsevier(ElsevierFetch.not_saved()), tmp_path, core_text=core)
    assert chain.order == []
    assert core_asked == []
    assert not result.success
    note = SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.NOT_SAVED, ARTICLE_URL)
    assert result.lookups == LookupRecord(skipped=(note,))
    assert result.error == (
        "A PDF of this article was found at api.elsevier.com but could not be "
        "saved on this device, so it could not be read. Check the free storage "
        "space and try again."
    )
    assert result.error == not_saved_note(result.lookups)
    _never_leaks(result.error, result.lookups)


def test_a_pdf_not_saved_keeps_the_absence_open(tmp_path: Path) -> None:
    """A copy exists: the chain's result is never an absence."""
    result = _discover_fulltext(_Elsevier(ElsevierFetch.not_saved()), tmp_path)
    assert not result.absence_established
    assert "api.elsevier.com" in (result.error or "")


def test_a_pdf_over_the_size_limit_is_skipped_and_unpaywall_is_asked(tmp_path: Path) -> None:
    """Our limit: an addressed skip of Elsevier, and the chain goes on."""
    chain = _Chain()
    result = chain.discover(_Elsevier(ElsevierFetch.refused_for_size()), tmp_path)
    assert chain.order == ["unpaywall"]
    skip = SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.OVER_SIZE_LIMIT, ARTICLE_URL)
    assert skip in result.lookups.skipped
    assert result.error == (
        "Failed to obtain a PDF from the following tried sources: api.elsevier.com, "
        "named by Elsevier's API (larger than the download limit). A freely available "
        "copy may exist. Whether this document is open access was not established."
    )
    _never_leaks(result.error, result.lookups)


def test_a_pdf_over_the_size_limit_is_told_beside_the_copies_tried_after_it(
    tmp_path: Path,
) -> None:
    """With an Unpaywall copy refused too, Elsevier's entry comes first."""
    chain = _Chain(sources=(_refused_copy(),))
    result = chain.discover(_Elsevier(ElsevierFetch.refused_for_size()), tmp_path)
    error = result.error or ""
    assert error.index(ELSEVIER_HOST) < error.index("walled.example.org")
    assert SourceLookupFailure(
        SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 403), REFUSED_COPY_URL
    ) in result.lookups.failures


# ---- not asked -----------------------------------------------------------------


def test_another_publishers_doi_never_reaches_the_client(tmp_path: Path) -> None:
    """Not Elsevier's DOI: no request, nothing recorded, absence settles as before."""
    elsevier = _Elsevier(served=True)
    result = _Chain().discover(elsevier, tmp_path, doi=FOREIGN_DOI)
    assert elsevier.asked == []
    assert result.lookups == LookupRecord()
    full = _discover_fulltext(elsevier, tmp_path, doi=FOREIGN_DOI)
    assert elsevier.asked == []
    assert full.absence_established


def test_without_a_key_nothing_is_asked_and_absence_settles(tmp_path: Path) -> None:
    """No key: no client, nothing recorded, the absence established as before."""
    discoverer = FulltextDiscoverer(use_browser_fallback=False)  # conftest: no client
    assert discoverer._elsevier is None
    result = _discover_fulltext_with(discoverer, tmp_path)
    assert all(f.service != SERVICE_ELSEVIER for f in result.lookups.failures)
    assert all(s.service != SERVICE_ELSEVIER for s in result.lookups.skipped)
    assert result.absence_established


def test_elsevier_is_asked_once_even_when_pmc_has_sources(tmp_path: Path) -> None:
    """Once per discovery, before the PMC and Unpaywall copies are tried."""
    pmc = PDFSource(url="https://pmc.example.org/a.pdf", source_type=PDFSourceType.PMC,
                    is_open_access=True)
    chain = _Chain(sources=(pmc, _refused_copy()))
    elsevier = _Elsevier(ElsevierFetch.absent())
    chain.discover(elsevier, tmp_path)
    assert elsevier.asked == [DOI]
    assert chain.order[0] == "unpaywall"
    assert chain.order.count("download") == 2


def test_elsevier_is_asked_by_the_cleaned_doi(tmp_path: Path) -> None:
    """A resolver URL is cleaned as for every other source."""
    elsevier = _Elsevier(ElsevierFetch.absent())
    _Chain().discover(elsevier, tmp_path, doi=f"https://doi.org/{DOI}")
    assert elsevier.asked == [DOI]


def test_no_doi_no_elsevier(tmp_path: Path) -> None:
    """Elsevier is asked by DOI alone."""
    elsevier = _Elsevier(served=True)
    _Chain().discover(elsevier, tmp_path, doi=None)
    assert elsevier.asked == []


# ---- cancel ------------------------------------------------------------------


def test_a_cancel_before_elsevier_means_it_is_never_asked(tmp_path: Path) -> None:
    """Cancelled before Elsevier's turn: not asked, and the result says Cancelled."""
    elsevier = _Elsevier(served=True)
    discoverer: PDFDiscoverer

    def progress(stage: str, status: str) -> None:
        if (stage, status) == ("discovery", "starting"):
            discoverer.cancel()

    discoverer = PDFDiscoverer(
        use_browser_fallback=False, elsevier=elsevier, progress_callback=progress
    )
    chain = _Chain()
    result = chain.discover(None, tmp_path, discoverer=discoverer)
    assert elsevier.asked == []
    assert result.error == "Cancelled"
    assert result.lookups == LookupRecord()


def test_a_cancel_inside_the_fetch_ends_the_discovery(tmp_path: Path) -> None:
    """The client's cancel ends the walk with "Cancelled", recording nothing for Elsevier."""
    chain = _Chain()
    result = chain.discover(_Elsevier(ElsevierFetch.cancelled()), tmp_path)
    assert result.error == "Cancelled"
    assert not result.success
    assert result.lookups == LookupRecord()
    assert chain.order == []


def test_the_discovery_cancel_reaches_the_client(tmp_path: Path) -> None:
    """The client is handed the discovery's own cancel flag."""
    seen: list[bool] = []
    discoverer: PDFDiscoverer

    class _Asks:
        def article_url(self, doi: str) -> str:
            return elsevier_article_url(doi)

        def fetch_pdf(
            self, doi: str, output_path: Path, cancelled: Callable[[], bool]
        ) -> ElsevierFetch:
            seen.append(cancelled())
            discoverer.cancel()
            seen.append(cancelled())
            return ElsevierFetch.cancelled()

    discoverer = PDFDiscoverer(use_browser_fallback=False, elsevier=_Asks())
    _Chain().discover(None, tmp_path, discoverer=discoverer)
    assert seen == [False, True]


# ---- the full chain ------------------------------------------------------------


def _europepmc_absent(*_args: Any, **_kwargs: Any) -> FulltextResult:
    """Europe PMC answered and served nothing: no failure recorded."""
    return FulltextResult(success=False, source_type=FulltextSourceType.NOT_ASSESSED)


def _no_pdf_sources(
    self: PDFDiscoverer, doi: Any, pmid: Any, pmcid: Any
) -> tuple[list[PDFSource], LookupRecord]:
    """No PDF source and nothing unasked."""
    return [], LookupRecord()


def _discover_fulltext_with(
    discoverer: FulltextDiscoverer,
    tmp_path: Path,
    doi: str = DOI,
    extracted: str = TEXT,
) -> FulltextResult:
    """A full-text discovery in which every source but Elsevier and CORE finds nothing.

    Both caches are empty and Europe PMC is absent; OpenAlex is conftest's.
    PDFs are kept under ``tmp_path``; ``extracted`` is what a PDF yields.
    """
    discoverer._try_europepmc_xml = _europepmc_absent  # type: ignore[method-assign]
    with ExitStack() as stack:
        stack.enter_context(patch.object(PDFDiscoverer, "_discover_sources", _no_pdf_sources))
        stack.enter_context(
            patch.dict("os.environ", {PDF_BASE_DIR_ENV_VAR: str(tmp_path / "pdf")})
        )
        stack.enter_context(
            patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", lambda _d: None)
        )
        stack.enter_context(
            patch("bmlibrarian_lite.fulltext_discovery.find_existing_pdf", lambda _d: None)
        )
        stack.enter_context(
            patch(
                "bmlibrarian_lite.fulltext_discovery.extract_pdf_text",
                lambda _p: extracted,
            )
        )
        stack.enter_context(
            patch("bmlibrarian_lite.pdf_utils.get_fulltext_base_dir", return_value=tmp_path)
        )
        stack.enter_context(patch("bmlibrarian_lite.fulltext_discovery.save_core_text"))
        stack.enter_context(
            patch(
                "bmlibrarian_lite.fulltext_discovery.read_cached_core_text",
                lambda _p, _d: None,
            )
        )
        return discoverer.discover_fulltext(doc_dict={"doi": doi, "id": "d1"}, doi=doi)


def _discover_fulltext(
    elsevier: Any, tmp_path: Path, doi: str = DOI, core: Any = None, extracted: str = TEXT
) -> FulltextResult:
    """:func:`_discover_fulltext_with`, with this Elsevier and CORE."""
    discoverer = FulltextDiscoverer(use_browser_fallback=False, elsevier=elsevier, core=core)
    return _discover_fulltext_with(discoverer, tmp_path, doi=doi, extracted=extracted)


class _Core:
    """CORE answering one scripted fetch, and counting what it is asked."""

    def __init__(self, fetch: CoreFetch) -> None:
        self.fetch = fetch
        self.asked: list[str] = []

    def fetch_full_text(self, doi: str) -> CoreFetch:
        self.asked.append(doi)
        return self.fetch


def test_elseviers_pdf_is_the_downloaded_full_text(tmp_path: Path) -> None:
    """Served: its text is extracted as any downloaded PDF's, and nothing is unsettled."""
    core = _Core(CoreFetch.served("CORE's text"))
    result = _discover_fulltext(_Elsevier(served=True), tmp_path, core=core)
    assert result.success
    assert result.source_type is FulltextSourceType.DOWNLOADED_PDF
    assert result.markdown_content == TEXT
    assert result.file_path is not None and result.file_path.read_bytes() == PDF
    assert result.lookups == LookupRecord()
    assert core.asked == []


def test_a_textless_pdf_from_elsevier_is_followed_by_core(tmp_path: Path) -> None:
    """#499's path: a scan is no full text, so CORE is asked; Elsevier's file stays cached."""
    elsevier = _Elsevier(served=True)
    core = _Core(CoreFetch.served("CORE's text of the article."))
    result = _discover_fulltext(elsevier, tmp_path, core=core, extracted="   ")
    assert result.success
    assert result.source_type is FulltextSourceType.CORE_TEXT
    assert core.asked == [DOI]
    cached = list((tmp_path / "pdf").rglob("*.pdf"))
    assert len(cached) == 1 and cached[0].read_bytes() == PDF


def test_the_full_chain_hands_elsevier_to_pdf_discovery(tmp_path: Path) -> None:
    """The discoverer's Elsevier is the one PDF discovery asks."""
    elsevier = _Elsevier(ElsevierFetch.absent())
    _discover_fulltext(elsevier, tmp_path)
    assert elsevier.asked == [DOI]


# ---- the credentials ------------------------------------------------------------


def test_credentials_from_a_config_without_a_key_are_none() -> None:
    """No key in the settings or the environment: Elsevier is not configured."""
    assert ElsevierCredentials.from_config(DiscoveryConfig()) is None
    assert ElsevierCredentials.from_config(
        DiscoveryConfig(elsevier_api_key="  ", elsevier_insttoken=TOKEN)
    ) is None


def test_credentials_from_a_config_are_the_settings_trimmed() -> None:
    """The key and the token as configured, trimmed; a blank token is none."""
    credentials = ElsevierCredentials.from_config(
        DiscoveryConfig(elsevier_api_key=f" {KEY} ", elsevier_insttoken=f" {TOKEN}\n")
    )
    assert credentials == ElsevierCredentials(KEY, TOKEN)
    blank = ElsevierCredentials.from_config(
        DiscoveryConfig(elsevier_api_key=KEY, elsevier_insttoken="  ")
    )
    assert blank == ElsevierCredentials(KEY, None)


def test_credentials_from_a_config_fall_back_to_the_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """As the default client's: the environment's key and token when the settings are blank."""
    monkeypatch.setenv("ELSEVIER_API_KEY", KEY)
    monkeypatch.setenv("ELSEVIER_INSTTOKEN", TOKEN)
    assert ElsevierCredentials.from_config(DiscoveryConfig()) == ElsevierCredentials(KEY, TOKEN)
    assert ElsevierCredentials.from_config(
        DiscoveryConfig(elsevier_api_key="other-key")
    ) == ElsevierCredentials("other-key", TOKEN)


@pytest.mark.real_elsevier_client
def test_the_default_client_applies_the_same_rules(monkeypatch: pytest.MonkeyPatch) -> None:
    """One place applies the environment fallback, for the client and the config alike."""
    monkeypatch.setenv("ELSEVIER_API_KEY", KEY)
    client = elsevier_api.default_elsevier_client(None, None)
    assert client is not None and client.credentials == ElsevierCredentials(KEY, None)
    monkeypatch.delenv("ELSEVIER_API_KEY")
    assert elsevier_api.default_elsevier_client(None, TOKEN) is None


def _recording(seen: list[tuple[str | None, str | None]]) -> Callable[..., None]:
    def record(api_key: str | None, insttoken: str | None) -> None:
        seen.append((api_key, insttoken))
        return None

    return record


CREDENTIALS = ElsevierCredentials(KEY, TOKEN)


def test_the_credentials_reach_the_discoverer_from_each_caller(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The discoverer, the worker and the analyser build Elsevier with the credentials."""
    seen: list[tuple[str | None, str | None]] = []
    monkeypatch.setattr(elsevier_api, "default_elsevier_client", _recording(seen))
    FulltextDiscoverer(elsevier_credentials=CREDENTIALS)
    FulltextDiscoverer()
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.gui.workers import FulltextDiscoveryWorker
    from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
        StudyTransparencyAnalyzer,
    )

    FulltextDiscoveryWorker({"doi": DOI}, elsevier_credentials=CREDENTIALS)._build_discoverer()
    StudyTransparencyAnalyzer("a@b.org", elsevier_credentials=CREDENTIALS)._fulltext_discoverer()
    assert seen == [(KEY, TOKEN), (None, None), (KEY, TOKEN), (KEY, TOKEN)]


def test_an_injected_client_overrides_the_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    """Tests pass their own Elsevier; no default is built beside it."""
    seen: list[tuple[str | None, str | None]] = []
    monkeypatch.setattr(elsevier_api, "default_elsevier_client", _recording(seen))
    stub = _Elsevier(ElsevierFetch.absent())
    assert FulltextDiscoverer(elsevier_credentials=CREDENTIALS, elsevier=stub)._elsevier is stub
    assert seen == []


def test_the_convenience_function_passes_the_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    """``discover_fulltext`` builds its discoverer with the credentials."""
    from bmlibrarian_lite import fulltext_discovery

    built: list[Any] = []

    def recording(**kwargs: Any) -> MagicMock:
        built.append(kwargs.get("elsevier_credentials"))
        return MagicMock()

    monkeypatch.setattr(fulltext_discovery, "FulltextDiscoverer", recording)
    fulltext_discovery.discover_fulltext(doi=DOI, elsevier_credentials=CREDENTIALS)
    assert built == [CREDENTIALS]


def _configured() -> LiteConfig:
    config = LiteConfig()
    config.discovery.elsevier_api_key = KEY
    config.discovery.elsevier_insttoken = TOKEN
    return config


def test_the_mcp_server_passes_the_configured_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    """The MCP server's discoverer is built with the configured key and token."""
    pytest.importorskip("mcp")
    from bmlibrarian_lite import mcp_server

    built: list[Any] = []
    for name in (
        "LiteStorage", "LLMClient", "LiteSearchAgent", "LiteScoringAgent",
        "LiteCitationAgent", "LiteReportingAgent", "LiteInterrogationAgent",
    ):
        monkeypatch.setattr(mcp_server, name, MagicMock())
    monkeypatch.setattr(
        mcp_server, "FulltextDiscoverer",
        lambda **kwargs: built.append(kwargs["elsevier_credentials"]) or MagicMock(),
    )
    mcp_server._make_server(_configured())
    mcp_server._make_server(LiteConfig())
    assert built == [CREDENTIALS, None]


def test_the_analyser_factory_passes_the_credentials() -> None:
    """The background analyser keeps the credentials it was built with."""
    from bmlibrarian_lite.transparency.assessment import create_background_analyzer

    analyzer = create_background_analyzer("a@b.org", elsevier_credentials=CREDENTIALS)
    assert analyzer._elsevier_credentials == CREDENTIALS
    assert create_background_analyzer("a@b.org")._elsevier_credentials is None


def test_the_transparency_manager_passes_the_configured_credentials() -> None:
    """The manager builds its analyser with the configured credentials."""
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.transparency.transparency_manager import TransparencyManager

    with patch(
        "bmlibrarian_lite.transparency.transparency_manager.create_background_analyzer"
    ) as factory:
        TransparencyManager(storage=MagicMock(), config=_configured(), email="a@b.org")
    assert factory.call_args.kwargs["elsevier_credentials"] == CREDENTIALS


def test_a_changed_elsevier_setting_rebuilds_the_analyser() -> None:
    """Either Elsevier setting changed in the live configuration rebuilds the analyser."""
    from bmlibrarian_lite.transparency.transparency_manager import TransparencyManager

    built: list[ElsevierCredentials | None] = []

    def recording(*_args: Any, **kwargs: Any) -> MagicMock:
        built.append(kwargs.get("elsevier_credentials"))
        return MagicMock()

    config = LiteConfig()
    with patch(
        "bmlibrarian_lite.transparency.transparency_manager.create_background_analyzer",
        recording,
    ):
        manager = TransparencyManager(storage=MagicMock(), config=config, email="a@b.org")
        first = manager._current_analyzer()
        assert manager._current_analyzer() is first, "unchanged settings keep the analyser"
        config.discovery.elsevier_api_key = KEY
        with_key = manager._current_analyzer()
        config.discovery.elsevier_insttoken = TOKEN
        with_token = manager._current_analyzer()
    assert first is not with_key is not with_token
    assert built == [None, ElsevierCredentials(KEY), CREDENTIALS]


def test_the_reanalysis_worker_passes_the_configured_credentials() -> None:
    """A reanalysis pass builds its analyser with the configured credentials."""
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.gui.workers import TransparencyReanalysisWorker

    worker = TransparencyReanalysisWorker(config=_configured(), storage=MagicMock(), documents=[])
    with patch(
        "bmlibrarian_lite.transparency.assessment.create_background_analyzer"
    ) as factory:
        worker.run()
    assert factory.call_args.kwargs["elsevier_credentials"] == CREDENTIALS


def test_the_interrogation_tab_passes_the_configured_credentials() -> None:
    """The document tab's full-text worker is built with the configured credentials."""
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.gui import document_interrogation_tab as tab_module

    tab = MagicMock()
    tab.config = _configured()
    with patch.object(tab_module, "FulltextDiscoveryWorker") as worker:
        tab_module.DocumentInterrogationTab._start_fulltext_discovery(
            tab, {"doi": DOI}, "Title", MagicMock()
        )
    assert worker.call_args.kwargs["elsevier_credentials"] == CREDENTIALS
