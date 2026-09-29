# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""Europe PMC API client for full-text article retrieval.

Provides access to full-text articles via the Europe PMC REST API,
preferring XML full text over PDF downloads for better text extraction.

The Europe PMC API provides:
- Full-text XML in JATS format (machine-readable, well-structured)
- Article metadata and availability checks
- Open access status information

Usage:
    from bmlibrarian_lite.europepmc import EuropePMCClient

    client = EuropePMCClient()

    # Ask what Europe PMC holds: in PMC or Europe PMC is not yet "has an
    # open-access full text", which only the fetch can say
    info = client.fetch_article_info(pmid="39521399").info
    accession = info.fulltext_accession if info else None
    if info and info.has_fulltext_xml and accession:
        fetch = client.fetch_fulltext_xml(accession)
        if fetch.failure is not None:
            ...  # not read: says nothing about the article
        elif fetch.xml is not None:
            markdown = client.xml_to_markdown(fetch.xml)
"""

import logging
import re
from dataclasses import dataclass, field
from typing import Any

import requests
from urllib3.util.retry import Retry

from .constants import (
    EUROPEPMC_COUNT_PAGE_SIZE,
    EUROPEPMC_DEFAULT_FILTERS,
    EUROPEPMC_INITIAL_CURSOR,
    EUROPEPMC_MAX_RETRIES,
    EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
    EUROPEPMC_REST_BASE_URL,
    EUROPEPMC_RESULT_TYPE,
    EUROPEPMC_SEARCH_PAGE_SIZE,
    EUROPEPMC_SEARCH_URL,
    EUROPEPMC_SORT_ORDER,
    EUROPEPMC_SOURCE_PREPRINT,
    EUROPEPMC_USER_AGENT,
    HTTP_NOT_FOUND,
    RETRYABLE_HTTP_STATUSES,
)
from .data_models import (
    CursorPaginationState,
    RequestFailure,
    RequestFailureKind,
    SearchProvider,
)
from .exceptions import SourceRequestError
from .jats_markdown import jats_to_markdown
from .polite_session import mount_politely
from .search_failures import request_failure_from_exception

logger = logging.getLogger(__name__)


def _malformed_search_answer(reason: str) -> SourceRequestError:
    """Build the error for a search answer that cannot be read, and log why.

    Args:
        reason: What was wrong, naming fields only.

    Returns:
        The error to raise.
    """
    logger.error(f"Unreadable Europe PMC search answer: {reason}")
    return SourceRequestError(
        SearchProvider.EUROPEPMC, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
    )


def _validated_search_page(data: object) -> dict[str, Any]:
    """Check that a search answer has the fields a result depends on.

    Europe PMC answers some failures with HTTP 200: an unknown cursor gets an
    answer holding only a ``version`` field (6.9 when checked live on
    2026-09-14). Read as ``hitCount`` 0, that was a search that matched
    nothing (#247).

    Args:
        data: The decoded JSON answer, untrusted.

    Returns:
        The answer, with a non-negative integer ``hitCount`` and a
        ``resultList.result`` list.

    Raises:
        SourceRequestError: If either is missing or of the wrong type, or
            ``hitCount`` is negative.
    """
    if not isinstance(data, dict):
        raise _malformed_search_answer("answer is not a JSON object")
    hit_count = data.get("hitCount")
    # bool is an int subclass; ``true`` is not a count.
    if not isinstance(hit_count, int) or isinstance(hit_count, bool) or hit_count < 0:
        raise _malformed_search_answer("answer has no non-negative integer hitCount")
    result_list = data.get("resultList")
    if not isinstance(result_list, dict) or not isinstance(result_list.get("result"), list):
        raise _malformed_search_answer("answer has no resultList.result list")
    return data


def _extract_free_pdf_url(result: dict) -> str | None:
    """Extract free PDF URL from Europe PMC fullTextUrlList.

    The Europe PMC search API returns a fullTextUrlList with entries for
    different document formats. This extracts the first free PDF URL,
    which uses the ``?pdf=render`` pattern for articles that have a PDF
    in PMC but may not have JATS XML available.

    Args:
        result: Raw result dict from Europe PMC API

    Returns:
        URL string for the free PDF, or None if not available
    """
    for entry in result.get("fullTextUrlList", {}).get("fullTextUrl", []):
        if (entry.get("documentStyle") == "pdf"
                and entry.get("availability") == "Free"):
            return entry.get("url")
    return None


@dataclass(frozen=True)
class ArticleInfoFetch:
    """What asking Europe PMC about an article produced (#363).

    The sibling of :class:`~bmlibrarian_lite.data_models.RecordFetch`, for
    the availability lookup that precedes a full-text fetch.
    :meth:`EuropePMCClient.get_article_info` answers both "this
    article is not in Europe PMC" and "we could not reach Europe PMC" with
    one ``None``, and its caller read both as the first -- so a throttled
    Europe PMC produced a full-text result whose record said every lookup
    had been made and answered, and the absence was reported as
    established.

    ``get_article_info`` keeps its ``Optional[ArticleInfo]`` signature for
    the callers that only want the record; :meth:`fetch_article_info` is the
    one that can tell the reader which of the two happened.

    Attributes:
        info: What Europe PMC said about the article, when it answered.
        failure: Why it could not be read, when it could not be reached.
            ``None`` with no ``info`` means Europe PMC answered, and holds
            no record of this article.

    Raises:
        ValueError: On construction, if both an info and a failure are
            given.
    """

    # No defaults: a bare ``ArticleInfoFetch()`` would be the absence, the
    # one claim about the article, and must not be what a slip produces.
    info: "ArticleInfo | None"
    failure: RequestFailure | None

    def __post_init__(self) -> None:
        """Refuse the state that would mean two things at once.

        Raises:
            ValueError: If both an info and a failure are given.
        """
        if self.info is not None and self.failure is not None:
            raise ValueError(
                "An article info fetch is served or unreachable, never both"
            )

    @classmethod
    def served(cls, info: "ArticleInfo") -> "ArticleInfoFetch":
        """Europe PMC answered with a record.

        Args:
            info: What it said about the article.

        Returns:
            The fetch.
        """
        return cls(info=info, failure=None)

    @classmethod
    def absent(cls) -> "ArticleInfoFetch":
        """Europe PMC was read, and holds no record of this article.

        Returns:
            The fetch. This is the one state that is about the article.
        """
        return cls(info=None, failure=None)

    @classmethod
    def unreachable(cls, failure: RequestFailure) -> "ArticleInfoFetch":
        """Europe PMC could not be read.

        Args:
            failure: Why.

        Returns:
            The fetch.
        """
        return cls(info=None, failure=failure)

    @property
    def is_unreachable(self) -> bool:
        """Whether Europe PMC could not be read.

        Returns:
            ``True`` when nothing about the article was established.
        """
        return self.failure is not None


@dataclass(frozen=True)
class FullTextXmlFetch:
    """What asking Europe PMC for an article's full-text XML produced (#429).

    The sibling of :class:`ArticleInfoFetch`, for the fetch that follows it.
    A 404, a throttle, a 5xx, a timeout and a dropped connection each tell
    the reader something different -- that Europe PMC answered, that it was
    busy, that it was down -- and one ``None`` cannot carry which.

    The type says what happened, not what it means: whether a 404 settles
    the article is the caller's decision (see
    :class:`~bmlibrarian_lite.fulltext_discovery.FulltextDiscoverer`).

    Attributes:
        xml: The JATS XML, when Europe PMC served it. Never blank: an empty
            answer has told us nothing about the article, so that is an
            incomplete response, not an absence.
        failure: Why it could not be read, or why it was never asked -- the
            identifier was not an accession (#355). ``None`` with no ``xml``
            means Europe PMC answered 404.

    Raises:
        ValueError: On construction, if both XML and a failure are given, or
            if the XML is blank.
    """

    # No defaults, as for ArticleInfoFetch: a slip must not build a 404.
    xml: str | None
    failure: RequestFailure | None

    def __post_init__(self) -> None:
        """Refuse the states that would mean two things at once.

        Raises:
            ValueError: If both XML and a failure are given, or if the XML is
                blank.
        """
        if self.xml is not None and self.failure is not None:
            raise ValueError(
                "A full-text XML fetch is served or unreachable, never both"
            )
        if self.xml is not None and not self.xml.strip():
            raise ValueError(
                "A blank full text is an incomplete answer, not an absence"
            )

    @classmethod
    def served(cls, xml: str) -> "FullTextXmlFetch":
        """Europe PMC served the full text.

        Args:
            xml: The JATS XML, not blank.

        Returns:
            The fetch.
        """
        return cls(xml=xml, failure=None)

    @classmethod
    def absent(cls) -> "FullTextXmlFetch":
        """Europe PMC answered 404 for this accession.

        Its own answer, unlike a failure; but whether it settles the
        article is the caller's call. ``fullTextXML`` serves open-access
        text only, so after a search that says the article is in PMC it
        may mean "not open access" rather than "no full text" (#432).

        Returns:
            The fetch.
        """
        return cls(xml=None, failure=None)

    @classmethod
    def unreachable(cls, failure: RequestFailure) -> "FullTextXmlFetch":
        """Europe PMC's answer is missing.

        It could not be read, its answer held nothing, or it was never asked
        because the identifier was not an accession.

        Args:
            failure: Why, of its real kind.

        Returns:
            The fetch.
        """
        return cls(xml=None, failure=failure)

    @property
    def is_unreachable(self) -> bool:
        """Whether Europe PMC's answer is missing.

        Returns:
            ``True`` when it could not be read or was never asked.
        """
        return self.failure is not None


# A PMC accession, with or without its prefix in any case: "PMC123",
# "pmc123", "123". It goes into a URL path, so nothing else may pass --
# ASCII digits only, as ``\d`` would also admit "PMC١٢٣".
_PMC_ACCESSION_RE = re.compile(r"(?:PMC)?([0-9]+)", re.IGNORECASE)


def pmc_accession(pmcid: str) -> str | None:
    """Normalise a PMC ID to the ``PMC<digits>`` form Europe PMC expects.

    Args:
        pmcid: The identifier, untrusted.

    Returns:
        For example ``"PMC12101959"``, or ``None`` when ``pmcid`` is not a
        PMC accession.
    """
    match = _PMC_ACCESSION_RE.fullmatch(pmcid.strip())
    if match is None:
        return None
    return f"PMC{match.group(1)}"


# A Europe PMC preprint record ID, "PPR1316954", in any case. Its prefix is
# required: bare digits are a PMC accession. ASCII digits only, as above.
_PREPRINT_ACCESSION_RE = re.compile(r"PPR([0-9]+)", re.IGNORECASE)


def fulltext_accession(identifier: str) -> str | None:
    """Normalise an identifier ``fullTextXML`` can be asked about.

    Europe PMC serves full text under a PMC accession, and a preprint's
    under its own ``PPR`` record ID: a preprint has no PMC ID, and refusing
    it left every preprint's full text unfetched.

    Args:
        identifier: The identifier, untrusted.

    Returns:
        For example ``"PMC12101959"`` or ``"PPR1316954"``, or ``None`` when
        ``identifier`` is neither.
    """
    accession = pmc_accession(identifier)
    if accession is not None:
        return accession
    match = _PREPRINT_ACCESSION_RE.fullmatch(identifier.strip())
    if match is None:
        return None
    return f"PPR{match.group(1)}"


@dataclass
class ArticleInfo:
    """Information about an article from Europe PMC.

    Attributes:
        pmid: PubMed ID
        pmcid: PubMed Central ID
        doi: Digital Object Identifier
        title: Article title
        authors: List of author names
        journal: Journal title
        year: Publication year
        abstract: Article abstract
        is_open_access: Whether the article is open access
        has_fulltext_xml: Whether Europe PMC says the article is in PMC or
            Europe PMC. Not whether it will serve the full text: that is
            open-access text only, and a 404 can follow (#432).
        has_pdf: Whether PDF is available
        is_preprint: Whether this is a preprint (from PPR source)
        source: Europe PMC source code (MED, PMC, PPR, etc.)
        pdf_render_url: Free PDF URL from Europe PMC fullTextUrlList
        europepmc_id: Europe PMC's own record ID: the PMID for a MED
            record, ``PPR1316954`` for a preprint.
    """

    pmid: str | None = None
    pmcid: str | None = None
    doi: str | None = None
    title: str = ""
    authors: list[str] = field(default_factory=list)
    journal: str = ""
    year: int | None = None
    abstract: str = ""
    is_open_access: bool = False
    has_fulltext_xml: bool = False
    has_pdf: bool = False
    is_preprint: bool = False
    source: str = ""
    pdf_render_url: str | None = None
    europepmc_id: str | None = None

    @property
    def fulltext_accession(self) -> str | None:
        """The identifier to ask ``fullTextXML`` by, if there is one.

        Returns:
            The PMC ID; for a preprint, which has none, its ``PPR`` record
            ID; otherwise ``None``. Only a preprint's record ID is served
            under: a MED record's is its PMID, which ``fullTextXML`` does
            not take.
        """
        if self.pmcid:
            return self.pmcid
        if self.is_preprint and self.europepmc_id:
            return self.europepmc_id
        return None


def _article_info_from_result(result: dict[str, Any]) -> ArticleInfo:
    """Read one Europe PMC search result.

    Args:
        result: One entry of ``resultList.result``, untrusted.

    Returns:
        What it says about the article.

    Raises:
        AttributeError: If a nested field is not the object it should be.
        TypeError: If an author entry cannot be indexed.
    """
    authors = [
        author["fullName"]
        for author in result.get("authorList", {}).get("author", [])
        if author.get("fullName")
    ]

    year = None
    pub_year = result.get("pubYear")
    if pub_year:
        try:
            year = int(pub_year)
        except ValueError:
            pass

    source = result.get("source", "")
    return ArticleInfo(
        pmid=result.get("pmid"),
        pmcid=result.get("pmcid"),
        doi=result.get("doi"),
        title=result.get("title", ""),
        authors=authors,
        journal=result.get("journalTitle", ""),
        year=year,
        abstract=result.get("abstractText", ""),
        is_open_access=result.get("isOpenAccess") == "Y",
        has_fulltext_xml=result.get("inEPMC") == "Y" or result.get("inPMC") == "Y",
        has_pdf=result.get("hasPDF") == "Y",
        is_preprint=source == EUROPEPMC_SOURCE_PREPRINT,
        source=source,
        pdf_render_url=_extract_free_pdf_url(result),
        europepmc_id=result.get("id"),
    )


class EuropePMCClient:
    """Client for the Europe PMC REST API.

    Provides methods for:
    - Searching for articles by PMID, DOI, or PMC ID
    - Checking full-text availability
    - Retrieving full-text XML
    - Converting JATS XML to markdown
    """

    def __init__(self) -> None:
        """Initialize the Europe PMC client."""
        self._session = self._create_session()

    def _create_session(self) -> requests.Session:
        """Create HTTP session with retry logic."""
        session = requests.Session()
        session.headers.update({
            "User-Agent": EUROPEPMC_USER_AGENT,
            "Accept": "application/json",
        })

        # raise_on_status=False: once the retries are spent, hand back the last
        # response, so raise_for_status() names its status. Otherwise urllib3
        # raises a RetryError that carries no status code to report (#247).
        retry_strategy = Retry(
            total=EUROPEPMC_MAX_RETRIES,
            backoff_factor=1,
            status_forcelist=list(RETRYABLE_HTTP_STATUSES),
            allowed_methods=["HEAD", "GET"],
            raise_on_status=False,
        )
        # Pacing is mounted here so no call site has to remember it. Europe
        # PMC states 10/s per IP; we ask for 1/s, which is inside that and
        # avoids the load-shedding seen under large full-text fetches (#341)
        return mount_politely(session, retry=retry_strategy)

    def get_article_info(
        self,
        pmid: str | None = None,
        pmcid: str | None = None,
        doi: str | None = None,
    ) -> ArticleInfo | None:
        """Get article information from Europe PMC.

        Searches by PMID, PMC ID, or DOI and returns availability information.

        Args:
            pmid: PubMed ID
            pmcid: PubMed Central ID (with or without 'PMC' prefix)
            doi: Digital Object Identifier

        Returns:
            ArticleInfo with availability details, or None if not found.

        Note:
            The ``None`` answers two questions -- "not in Europe PMC" and
            "we could not ask" -- so a caller that reports an absence to a
            reader must use :meth:`fetch_article_info` instead and branch on
            its three states (#363).
        """
        return self.fetch_article_info(pmid=pmid, pmcid=pmcid, doi=doi).info

    def fetch_article_info(
        self,
        pmid: str | None = None,
        pmcid: str | None = None,
        doi: str | None = None,
    ) -> ArticleInfoFetch:
        """Ask Europe PMC about an article, and say which answer we got.

        Args:
            pmid: PubMed ID
            pmcid: PubMed Central ID (with or without 'PMC' prefix)
            doi: Digital Object Identifier

        Returns:
            The fetch: what Europe PMC said, its answer that it holds no
            such record, or why it could not be read. An empty result list
            is Europe PMC's own answer and stays an absence; a transport
            failure does not, because a throttled search establishes nothing
            about the article (#346, #363).
        """
        # Build search query
        if pmcid:
            accession = pmc_accession(pmcid)
            if accession is None:
                # Garbled into a query, it matched nothing, and that empty
                # list was returned as Europe PMC holding no such record --
                # an absence from a question it was never put ("pmc123"
                # became "PMCID:PMCpmc123"). Not asking is not absent (#355).
                logger.warning(
                    "Not a PMC accession, so Europe PMC was not asked about "
                    "it: %r",
                    pmcid,
                )
                return ArticleInfoFetch.unreachable(
                    RequestFailure(RequestFailureKind.REQUEST_FAILED)
                )
            query = f"PMCID:{accession}"
        elif pmid:
            query = f"ext_id:{pmid} src:med"
        elif doi:
            query = f'DOI:"{doi}"'
        else:
            # Nothing to ask about is not Europe PMC answering "no such
            # article": we never put a question (#355).
            logger.warning("No identifier provided for article lookup")
            return ArticleInfoFetch.unreachable(
                RequestFailure(RequestFailureKind.REQUEST_FAILED)
            )

        try:
            response = self._session.get(
                EUROPEPMC_SEARCH_URL,
                params={
                    "query": query,
                    "format": "json",
                    "resultType": "core",
                },
                timeout=EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
            )
            response.raise_for_status()
            data = response.json()

            results = data.get("resultList", {}).get("result", [])
            if not results:
                # Europe PMC answered, with an empty result list. That is
                # its own statement that it holds no such record.
                logger.debug(f"No results found for query: {query}")
                return ArticleInfoFetch.absent()

            # The same reading as a search result's, so a preprint looked up
            # by DOI keeps the source and record ID its full text is fetched
            # by: this path left them unset, and the preprint unfetchable.
            return ArticleInfoFetch.served(_article_info_from_result(results[0]))

        except requests.exceptions.RequestException as e:
            # Never an absence: a throttled or unreachable Europe PMC has
            # said nothing about this article, and a caller that read this
            # as "not in Europe PMC" went on to report an established
            # absence (#346, #363).
            failure = request_failure_from_exception(e)
            logger.warning(
                "Europe PMC could not be asked about this article (%s), so "
                "whether it holds a record is not assessed.",
                failure.describe(),
            )
            return ArticleInfoFetch.unreachable(failure)

    def _get_search_page(self, params: dict[str, Any]) -> dict[str, Any]:
        """Request one page of search results.

        Args:
            params: Query parameters for the search endpoint.

        Returns:
            The validated answer.

        Raises:
            SourceRequestError: If the request failed after the session's
                retries, or the answer cannot be read.
        """
        failure: RequestFailure | None = None
        data: object = None
        try:
            response = self._session.get(
                EUROPEPMC_SEARCH_URL,
                params=params,
                timeout=EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
            )
            response.raise_for_status()
            data = response.json()
        except requests.exceptions.RequestException as e:
            failure = request_failure_from_exception(e)
        # Raised here, outside the except block, so the requests exception --
        # holding the request, the response and, for a body that is not
        # JSON, that raw body as JSONDecodeError.doc -- is not kept as the
        # error's __context__.
        if failure is not None:
            logger.warning(f"Europe PMC search request failed: {failure.describe()}")
            raise SourceRequestError(SearchProvider.EUROPEPMC, failure)
        return _validated_search_page(data)

    def search(
        self,
        query: str,
        max_results: int = 100,
        cursor: str | None = None,
        include_preprints: bool = False,
        page_size: int | None = None,
    ) -> tuple[list[ArticleInfo], CursorPaginationState]:
        """Search Europe PMC for articles.

        Performs a search using the Europe PMC REST API with cursor-based
        pagination for efficient retrieval of large result sets.

        A cursor cannot skip a page, so a later page that fails, or comes
        back empty, ends the search there: the articles already retrieved are
        returned, and the pagination state records how many more were wanted
        and why they are missing (#247). So does a cursor that ends before
        ``min(max_results, hitCount)`` results arrived.

        Args:
            query: Search query in Europe PMC syntax
            max_results: Maximum number of results to return
            cursor: Pagination cursor (None for first page)
            include_preprints: Whether to include preprints in results
            page_size: Results per page (default from constants)

        Returns:
            Tuple of (list of ArticleInfo, pagination state)

        Raises:
            SourceRequestError: If the first page failed, could not be read,
                or held no results although ``hitCount`` said it would. A
                failed search is never returned as one with no hits.

        Example:
            client = EuropePMCClient()
            articles, pagination = client.search(
                "TITLE_ABS:covid-19 AND TITLE_ABS:vaccine",
                max_results=50,
            )
        """
        page_size = page_size or EUROPEPMC_SEARCH_PAGE_SIZE
        cursor = cursor or EUROPEPMC_INITIAL_CURSOR

        # Build query with filters
        full_query = self._build_search_query(query, include_preprints)

        all_articles: list[ArticleInfo] = []
        unreadable_count = 0
        current_cursor = cursor
        next_cursor_value: str | None = None
        total_count = 0
        failure: RequestFailure | None = None
        first_page = True

        while len(all_articles) < max_results:
            # Calculate how many results we still need
            remaining = max_results - len(all_articles)
            request_size = min(page_size, remaining)

            try:
                data = self._get_search_page(
                    {
                        "query": full_query,
                        "format": "json",
                        "resultType": EUROPEPMC_RESULT_TYPE,
                        "pageSize": request_size,
                        "cursorMark": current_cursor,
                        "sort": EUROPEPMC_SORT_ORDER,
                    }
                )
            except SourceRequestError as e:
                if first_page:
                    raise
                failure = e.failure
                logger.warning(
                    f"Europe PMC search stopped after {len(all_articles)} results: "
                    f"a later page could not be retrieved ({failure.describe()})"
                )
                break

            if first_page:
                total_count = data["hitCount"]
                logger.info(f"Europe PMC search found {total_count} total results")
            wanted = min(max_results, total_count)

            next_mark = data.get("nextCursorMark")
            next_cursor_value = next_mark if isinstance(next_mark, str) else None

            results = data["resultList"]["result"]
            if not results:
                received = len(all_articles) + unreadable_count
                if received < wanted:
                    logger.error(
                        f"Europe PMC sent an empty page after {received} of {wanted} results"
                    )
                    incomplete = RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
                    if first_page:
                        raise SourceRequestError(SearchProvider.EUROPEPMC, incomplete)
                    failure = incomplete
                break

            for result in results:
                article = self._parse_search_result(result)
                if article:
                    all_articles.append(article)
                else:
                    unreadable_count += 1

            if not next_cursor_value or next_cursor_value == current_cursor:
                # The cursor ends only once every hit was sent (checked live
                # 2026-09-15): ending before that is an answer that held less
                # than it counted, not the end of the results.
                received = len(all_articles) + unreadable_count
                if received < wanted:
                    logger.error(
                        f"Europe PMC's cursor ended after {received} of {wanted} results"
                    )
                    failure = RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
                break

            current_cursor = next_cursor_value
            first_page = False

        unretrieved_count = 0
        if failure is not None:
            unretrieved_count = max(
                0, min(max_results, total_count) - len(all_articles) - unreadable_count
            )

        pagination = CursorPaginationState(
            total_count=total_count,
            fetched_count=len(all_articles),
            current_cursor=current_cursor,
            next_cursor=next_cursor_value,
            unretrieved_count=unretrieved_count,
            failure=failure,
            unreadable_count=unreadable_count,
        )

        logger.info(f"Europe PMC search returned {len(all_articles)} articles")
        return all_articles, pagination

    def search_simple(
        self,
        query: str,
        max_results: int = 100,
        include_preprints: bool = False,
    ) -> list[ArticleInfo]:
        """Simplified search that returns just the articles.

        Convenience method when pagination state is not needed.

        Args:
            query: Search query in Europe PMC syntax
            max_results: Maximum number of results to return
            include_preprints: Whether to include preprints

        Returns:
            List of ArticleInfo objects

        Raises:
            SourceRequestError: If the first page could not be retrieved.
        """
        articles, _ = self.search(
            query=query,
            max_results=max_results,
            include_preprints=include_preprints,
        )
        return articles

    def get_total_count(
        self,
        query: str,
        include_preprints: bool = False,
    ) -> int:
        """Get total count of results for a query without fetching articles.

        Useful for displaying result counts before actually fetching results.

        Args:
            query: Search query in Europe PMC syntax
            include_preprints: Whether to include preprints

        Returns:
            Total number of matching articles

        Raises:
            SourceRequestError: If the count could not be obtained; 0 is only
                ever Europe PMC's own answer.
        """
        full_query = self._build_search_query(query, include_preprints)
        data = self._get_search_page(
            {
                "query": full_query,
                "format": "json",
                "resultType": "lite",  # Faster, less data
                "pageSize": EUROPEPMC_COUNT_PAGE_SIZE,
            }
        )
        return data["hitCount"]

    def _build_search_query(
        self,
        query: str,
        include_preprints: bool = False,
    ) -> str:
        """Build full search query with standard filters.

        Args:
            query: Base search query
            include_preprints: Whether to include preprints

        Returns:
            Full query string with filters applied
        """
        filters = [query]

        # Require abstract
        filters.append(EUROPEPMC_DEFAULT_FILTERS["has_abstract"])

        # Exclude preprints unless explicitly requested
        if not include_preprints:
            filters.append(EUROPEPMC_DEFAULT_FILTERS["exclude_preprints"])

        return " AND ".join(filters)

    def _parse_search_result(self, result: dict) -> ArticleInfo | None:
        """Parse a single search result into ArticleInfo.

        Args:
            result: Raw result dict from Europe PMC API

        Returns:
            ArticleInfo object or None if parsing fails
        """
        try:
            return _article_info_from_result(result)
        except Exception as e:
            logger.warning(f"Failed to parse Europe PMC result: {e}")
            return None

    def fetch_fulltext_xml(self, accession: str) -> FullTextXmlFetch:
        """Ask Europe PMC for an article's full-text XML, and say what we got.

        Takes an accession only: resolving another identifier to one is
        :meth:`fetch_article_info`'s job, whose answer the caller needs
        anyway (see :attr:`ArticleInfo.fulltext_accession`).

        Args:
            accession: A PMC ID, with or without its ``PMC`` prefix, or a
                preprint's ``PPR`` record ID.

        Returns:
            The fetch: the XML; Europe PMC's 404, its answer that it serves
            no open-access full text under this ID; or why it could not be
            read, of its real kind once the session's retries are spent --
            a 429 stays a 429 (#429). A blank answer is an incomplete
            response, and an identifier that is not an accession is a
            request never made (#355), not an absence.
        """
        normalised = fulltext_accession(accession)
        if normalised is None:
            logger.warning(
                "Not a PMC or preprint accession, so Europe PMC was not "
                "asked for its full text: %r",
                accession,
            )
            return FullTextXmlFetch.unreachable(
                RequestFailure(RequestFailureKind.REQUEST_FAILED)
            )
        accession = normalised

        url = f"{EUROPEPMC_REST_BASE_URL}/{accession}/fullTextXML"
        try:
            response = self._session.get(
                url,
                headers={"Accept": "application/xml"},
                timeout=EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
            )
            if response.status_code == HTTP_NOT_FOUND:
                logger.debug("Europe PMC serves no full-text XML for %s", accession)
                return FullTextXmlFetch.absent()
            response.raise_for_status()
            xml = response.text
        except requests.exceptions.RequestException as e:
            failure = request_failure_from_exception(e)
            logger.warning(
                "Europe PMC's full text for %s could not be read (%s).",
                accession,
                failure.describe(),
            )
            return FullTextXmlFetch.unreachable(failure)

        if not xml.strip():
            logger.warning("Europe PMC served an empty full text for %s", accession)
            return FullTextXmlFetch.unreachable(
                RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
            )
        return FullTextXmlFetch.served(xml)

    def xml_to_markdown(self, xml_content: str) -> str:
        """Convert JATS XML to readable markdown.

        Delegates to :func:`bmlibrarian_lite.jats_markdown.jats_to_markdown`,
        which documents what the markdown holds.

        Args:
            xml_content: JATS XML string

        Returns:
            Formatted markdown string, or an empty string when the XML does
            not parse
        """
        return jats_to_markdown(xml_content)
