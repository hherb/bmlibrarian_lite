# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""What a search does when a source fails (#247, #248).

The user's decisions (2026-09-14): a provider that fails in a search of both,
and a batch or page that fails after its retries, let the search proceed on
what was retrieved -- with the shortfall recorded, so the user is told. A
search that failures leave with nothing is an error: "No documents found"
would claim an absence nobody observed.

The clients are replaced by stubs returning the real result types, since the
clients' own failure handling has tests of its own; here only the service's
rule is under test.
"""

from typing import Any

import pytest

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    CursorPaginationState,
    RequestFailure,
    RequestFailureKind,
    RetrievalShortfall,
    SearchProvider,
)
from bmlibrarian_lite.europepmc import ArticleInfo
from bmlibrarian_lite.exceptions import SearchFailedError, SourceRequestError
from bmlibrarian_lite.pubmed.data_types import (
    ArticleFetchResult,
    ArticleMetadata,
    PubMedQuery,
    SearchResult,
)
from bmlibrarian_lite.search_service import SearchService

RATE_LIMITED = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
TIMED_OUT = RequestFailure(RequestFailureKind.TIMEOUT)
UNAVAILABLE = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
QUERY = "aspirin AND stroke"


def distinct_title(pmid: str) -> str:
    """A title no other test article's resembles.

    ``SearchResultMerger`` drops short words, digits included, before comparing
    titles, so "Record 7" and "Record 8" would merge as duplicates even with
    different PMIDs (#258).
    """
    return f"Record pmid{pmid}"


def pubmed_article(pmid: str) -> ArticleMetadata:
    """A PubMed article with an abstract, so it survives the abstract filter."""
    return ArticleMetadata(pmid=pmid, title=distinct_title(pmid), abstract=f"Abstract {pmid}")


def epmc_article(pmid: str) -> ArticleInfo:
    """A Europe PMC article with an abstract, so it survives the abstract filter."""
    return ArticleInfo(pmid=pmid, title=distinct_title(pmid), abstract=f"Abstract {pmid}")


class StubPubMed:
    """Answers ``search`` and ``fetch_articles`` as scripted."""

    def __init__(
        self,
        search: SearchResult | SourceRequestError,
        fetch: ArticleFetchResult | None = None,
    ) -> None:
        """Script the answers.

        Args:
            search: The search result, or the error the search raises.
            fetch: The fetch result; defaults to nothing fetched.
        """
        self._search = search
        self._fetch = fetch or ArticleFetchResult()

    def search(self, query: PubMedQuery, max_results: int) -> SearchResult:
        """Return or raise the scripted search answer."""
        if isinstance(self._search, SourceRequestError):
            raise self._search
        return self._search

    def fetch_articles(self, pmids: list[str]) -> ArticleFetchResult:
        """Return the scripted fetch answer."""
        return self._fetch


class StubEuropePMC:
    """Answers ``search`` as scripted."""

    def __init__(
        self,
        answer: tuple[list[ArticleInfo], CursorPaginationState] | SourceRequestError,
    ) -> None:
        """Script the answer.

        Args:
            answer: The articles and pagination state, or the error to raise.
        """
        self._answer = answer

    def search(self, **kwargs: Any) -> tuple[list[ArticleInfo], CursorPaginationState]:
        """Return or raise the scripted answer."""
        if isinstance(self._answer, SourceRequestError):
            raise self._answer
        return self._answer


def pubmed_hits(pmids: list[str], total: int | None = None, **extra: Any) -> SearchResult:
    """A PubMed search result listing PMIDs."""
    return SearchResult(
        query=PubMedQuery(original_question=QUERY, query_string=QUERY),
        total_count=len(pmids) if total is None else total,
        retrieved_count=len(pmids),
        pmids=pmids,
        **extra,
    )


def epmc_page(
    pmids: list[str], total: int | None = None, **extra: Any
) -> tuple[list[ArticleInfo], CursorPaginationState]:
    """A Europe PMC search answer holding one article per PMID."""
    articles = [epmc_article(pmid) for pmid in pmids]
    pagination = CursorPaginationState(
        total_count=len(pmids) if total is None else total,
        fetched_count=len(articles),
        current_cursor="*",
        next_cursor=None,
        **extra,
    )
    return articles, pagination


def service_with(
    pubmed: StubPubMed | None = None, europepmc: StubEuropePMC | None = None
) -> SearchService:
    """A search service whose clients are the given stubs."""
    service = SearchService(LiteConfig())
    service._pubmed_client = pubmed  # type: ignore[assignment]
    service._europepmc_client = europepmc  # type: ignore[assignment]
    return service


def pubmed_failed(failure: RequestFailure) -> SourceRequestError:
    """The error a PubMed client raises for a failed search."""
    return SourceRequestError(SearchProvider.PUBMED, failure)


def epmc_failed(failure: RequestFailure) -> SourceRequestError:
    """The error a Europe PMC client raises for a failed search."""
    return SourceRequestError(SearchProvider.EUROPEPMC, failure)


class TestASingleProviderSearch:
    """With one provider, its failure leaves nothing to proceed on."""

    def test_a_failed_pubmed_search_raises_not_empty(self) -> None:
        """The #247 symptom: a rate-limited search read "No documents found"."""
        service = service_with(pubmed=StubPubMed(pubmed_failed(RATE_LIMITED)))

        with pytest.raises(SearchFailedError) as raised:
            service.search(QUERY, max_results=10, provider=SearchProvider.PUBMED)

        assert raised.value.shortfalls == (
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED),
        )

    def test_a_failed_europepmc_search_raises_not_empty(self) -> None:
        """The same rule for the other provider."""
        service = service_with(europepmc=StubEuropePMC(epmc_failed(UNAVAILABLE)))

        with pytest.raises(SearchFailedError) as raised:
            service.search(QUERY, max_results=10, provider=SearchProvider.EUROPEPMC)

        assert raised.value.shortfalls == (
            RetrievalShortfall(SearchProvider.EUROPEPMC, UNAVAILABLE),
        )

    def test_a_failed_batch_proceeds_and_is_recorded(self) -> None:
        """#248: the review runs on what was fetched and knows what was not."""
        service = service_with(
            pubmed=StubPubMed(
                pubmed_hits(["1", "2", "3"]),
                ArticleFetchResult(
                    articles=[pubmed_article("1")],
                    pmids_not_fetched=["2", "3"],
                    failure=TIMED_OUT,
                ),
            )
        )

        result = service.search(QUERY, max_results=10, provider=SearchProvider.PUBMED)

        assert [doc.pmid for doc in result.documents] == ["1"]
        assert result.shortfalls == [
            RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT, records_missing=2)
        ]

    def test_pmids_the_history_server_did_not_list_are_recorded(self) -> None:
        """A failed history page is missing records too, before any fetch."""
        service = service_with(
            pubmed=StubPubMed(
                pubmed_hits(
                    ["1"], total=4, unlisted_count=3, listing_failure=RATE_LIMITED
                ),
                ArticleFetchResult(articles=[pubmed_article("1")]),
            )
        )

        result = service.search(QUERY, max_results=10, provider=SearchProvider.PUBMED)

        assert result.shortfalls == [
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=3)
        ]

    def test_a_search_whose_every_batch_failed_raises(self) -> None:
        """Matches were found, none retrieved: that is not "no documents"."""
        service = service_with(
            pubmed=StubPubMed(
                pubmed_hits(["1", "2"]),
                ArticleFetchResult(pmids_not_fetched=["1", "2"], failure=TIMED_OUT),
            )
        )

        with pytest.raises(SearchFailedError) as raised:
            service.search(QUERY, max_results=10, provider=SearchProvider.PUBMED)

        assert raised.value.shortfalls == (
            RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT, records_missing=2),
        )

    def test_a_failed_later_europepmc_page_proceeds_and_is_recorded(self) -> None:
        """A cursor cannot skip a page; what came before it is kept."""
        articles, pagination = epmc_page(
            ["1", "2"], total=40, unretrieved_count=8, failure=UNAVAILABLE
        )
        service = service_with(europepmc=StubEuropePMC((articles, pagination)))

        result = service.search(QUERY, max_results=10, provider=SearchProvider.EUROPEPMC)

        assert len(result.documents) == 2
        assert result.shortfalls == [
            RetrievalShortfall(SearchProvider.EUROPEPMC, UNAVAILABLE, records_missing=8)
        ]

    def test_a_search_that_matched_nothing_is_empty_not_failed(self) -> None:
        """No failure, no shortfall: the only case "No documents found" is true."""
        service = service_with(pubmed=StubPubMed(pubmed_hits([])))

        result = service.search(QUERY, max_results=10, provider=SearchProvider.PUBMED)

        assert result.documents == []
        assert result.shortfalls == []


class TestASearchOfBothProviders:
    """One provider failing leaves the other's results, and says so."""

    def test_a_failed_pubmed_proceeds_on_europepmc(self) -> None:
        """The user's decision: proceed on one provider, tell the user."""
        service = service_with(
            pubmed=StubPubMed(pubmed_failed(RATE_LIMITED)),
            europepmc=StubEuropePMC(epmc_page(["7", "8"], total=30)),
        )

        result = service.search(QUERY, max_results=10, provider=SearchProvider.BOTH)

        assert [doc.pmid for doc in result.documents] == ["7", "8"]
        assert result.provider is SearchProvider.BOTH
        assert result.total_count == 30
        assert result.shortfalls == [RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED)]

    def test_a_failed_europepmc_proceeds_on_pubmed(self) -> None:
        """The same rule the other way round."""
        service = service_with(
            pubmed=StubPubMed(
                pubmed_hits(["1"], total=12), ArticleFetchResult(articles=[pubmed_article("1")])
            ),
            europepmc=StubEuropePMC(epmc_failed(TIMED_OUT)),
        )

        result = service.search(QUERY, max_results=10, provider=SearchProvider.BOTH)

        assert [doc.pmid for doc in result.documents] == ["1"]
        assert result.total_count == 12
        assert result.shortfalls == [RetrievalShortfall(SearchProvider.EUROPEPMC, TIMED_OUT)]

    def test_both_failing_raises_with_both_named(self) -> None:
        """Nothing retrieved from anywhere is an error naming every failure."""
        service = service_with(
            pubmed=StubPubMed(pubmed_failed(RATE_LIMITED)),
            europepmc=StubEuropePMC(epmc_failed(UNAVAILABLE)),
        )

        with pytest.raises(SearchFailedError) as raised:
            service.search(QUERY, max_results=10, provider=SearchProvider.BOTH)

        assert raised.value.shortfalls == (
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED),
            RetrievalShortfall(SearchProvider.EUROPEPMC, UNAVAILABLE),
        )

    def test_a_failed_provider_beside_an_empty_one_raises(self) -> None:
        """Europe PMC's zero does not speak for PubMed, which did not answer."""
        service = service_with(
            pubmed=StubPubMed(pubmed_failed(RATE_LIMITED)),
            europepmc=StubEuropePMC(epmc_page([])),
        )

        with pytest.raises(SearchFailedError):
            service.search(QUERY, max_results=10, provider=SearchProvider.BOTH)

    def test_two_providers_that_matched_nothing_are_empty_not_failed(self) -> None:
        """Only a search with no failures may report that it found nothing."""
        service = service_with(
            pubmed=StubPubMed(pubmed_hits([])),
            europepmc=StubEuropePMC(epmc_page([])),
        )

        result = service.search(QUERY, max_results=10, provider=SearchProvider.BOTH)

        assert result.documents == []
        assert result.shortfalls == []

    def test_partial_retrievals_from_both_are_both_recorded(self) -> None:
        """Every shortfall is kept, in provider order."""
        articles, pagination = epmc_page(["7"], total=9, unretrieved_count=4, failure=UNAVAILABLE)
        service = service_with(
            pubmed=StubPubMed(
                pubmed_hits(["1", "2"]),
                ArticleFetchResult(
                    articles=[pubmed_article("1")], pmids_not_fetched=["2"], failure=TIMED_OUT
                ),
            ),
            europepmc=StubEuropePMC((articles, pagination)),
        )

        result = service.search(QUERY, max_results=10, provider=SearchProvider.BOTH)

        assert result.shortfalls == [
            RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT, records_missing=1),
            RetrievalShortfall(SearchProvider.EUROPEPMC, UNAVAILABLE, records_missing=4),
        ]


MALFORMED = RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)


class TestWhatTheReviewCannotSee:
    """Records a parser dropped, and the error's own chain (#247)."""

    def test_unreadable_pubmed_articles_are_a_shortfall(self) -> None:
        """A dropped record is missing from the review like a failed batch."""
        service = service_with(
            pubmed=StubPubMed(
                pubmed_hits(["1", "2"]),
                ArticleFetchResult(articles=[pubmed_article("1")], records_unreadable=1),
            )
        )

        result = service.search(QUERY, max_results=10, provider=SearchProvider.PUBMED)

        assert result.shortfalls == [
            RetrievalShortfall(SearchProvider.PUBMED, MALFORMED, records_missing=1)
        ]

    def test_unreadable_europepmc_results_are_a_shortfall(self) -> None:
        """The same for Europe PMC."""
        articles, pagination = epmc_page(["1"], total=2, unreadable_count=1)
        service = service_with(europepmc=StubEuropePMC((articles, pagination)))

        result = service.search(QUERY, max_results=10, provider=SearchProvider.EUROPEPMC)

        assert result.shortfalls == [
            RetrievalShortfall(SearchProvider.EUROPEPMC, MALFORMED, records_missing=1)
        ]

    def test_europepmc_results_all_unreadable_raise(self) -> None:
        """Three hits sent, none readable: the search failed, it did not find nothing."""
        service = service_with(
            europepmc=StubEuropePMC(epmc_page([], total=3, unreadable_count=3))
        )

        with pytest.raises(SearchFailedError) as raised:
            service.search(QUERY, max_results=10, provider=SearchProvider.EUROPEPMC)

        assert raised.value.shortfalls == (
            RetrievalShortfall(SearchProvider.EUROPEPMC, MALFORMED, records_missing=3),
        )

    def test_a_failed_search_error_has_no_exception_chain(self) -> None:
        """The client's error, and the frames holding the request, are not kept."""
        service = service_with(pubmed=StubPubMed(pubmed_failed(RATE_LIMITED)))

        with pytest.raises(SearchFailedError) as raised:
            service.search(QUERY, max_results=10, provider=SearchProvider.PUBMED)

        assert raised.value.__cause__ is None
        assert raised.value.__context__ is None
