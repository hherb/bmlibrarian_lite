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

"""
PubMed E-utilities API client.

This module provides a client for searching PubMed via the NCBI E-utilities API,
with proper rate limiting, retry logic, and history server support for large
result sets.

Example usage:
    from bmlibrarian_lite.pubmed import PubMedSearchClient, PubMedQuery

    client = PubMedSearchClient(email="user@example.com")

    # Search with a query object
    query = PubMedQuery(
        original_question="cardiovascular exercise",
        query_string='"Exercise"[MeSH] AND "Cardiovascular Diseases"[MeSH]'
    )
    result = client.search(query, max_results=100)

    print(f"Found {result.total_count} articles, retrieved {result.retrieved_count}")
"""

import json
import logging
import os
import re
import time
import xml.etree.ElementTree as ET
from collections.abc import Callable
from typing import Optional, List, Dict, Any
import requests

from .constants import (
    ESEARCH_URL,
    EFETCH_URL,
    REQUEST_TIMEOUT_SECONDS,
    MAX_RETRIES,
    INITIAL_RETRY_DELAY_SECONDS,
    RETRY_BACKOFF_MULTIPLIER,
    REQUEST_DELAY_WITH_KEY,
    REQUEST_DELAY_WITHOUT_KEY,
    DEFAULT_MAX_RESULTS,
    MAX_RESULTS_LIMIT,
    DEFAULT_BATCH_SIZE,
    HISTORY_SERVER_THRESHOLD,
    ENV_NCBI_EMAIL,
    ENV_NCBI_API_KEY,
    EMAIL_VALIDATION_PATTERN,
)
from .data_types import (
    ArticleFetchResult,
    PubMedQuery,
    SearchResult,
    ArticleMetadata,
)
from ..data_models import RequestFailure, RequestFailureKind, SearchProvider
from ..exceptions import SourceRequestError
from ..search_failures import request_failure_from_exception

logger = logging.getLogger(__name__)

# Root elements of an efetch answer: the articles, or the document E-utilities
# sends instead when the fetch failed (with HTTP 400, or with HTTP 200 (#255)).
EFETCH_ARTICLE_SET_ROOT_TAG = "PubmedArticleSet"
EFETCH_ERROR_ROOT_TAG = "eFetchResult"

# Marks an answer body that did not decode as JSON (JSON null is a value).
_NOT_JSON = object()


def _malformed_answer(reason: str) -> SourceRequestError:
    """Build the error for an E-utilities answer that cannot be read, and log why.

    Args:
        reason: What was wrong, naming fields only, never their values.

    Returns:
        The error to raise.
    """
    logger.error(f"Unreadable E-utilities answer: {reason}")
    return SourceRequestError(
        SearchProvider.PUBMED, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
    )


def _incomplete_answer(reason: str) -> SourceRequestError:
    """Build the error for an E-utilities answer that holds less than it says.

    Args:
        reason: What was missing, as counts only.

    Returns:
        The error to raise.
    """
    logger.error(f"Incomplete E-utilities answer: {reason}")
    return SourceRequestError(
        SearchProvider.PUBMED, RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
    )


def expected_esearch_listing(total_count: int, retstart: int, retmax: int) -> int:
    """How many PMIDs an esearch page should list.

    Args:
        total_count: The search's ``count``.
        retstart: The page's offset.
        retmax: The page size asked for.

    Returns:
        The PMIDs PubMed holds from ``retstart`` on, up to ``retmax`` and to
        the first 9,999 records, the most E-utilities lists for one search
        (``MAX_RESULTS_LIMIT``). 0 past the end of what can be listed.
    """
    return max(0, min(retmax, total_count - retstart, MAX_RESULTS_LIMIT - retstart))


def _decoded_json(response: requests.Response) -> Any:
    """Decode a JSON answer without keeping the decoder's exception.

    ``JSONDecodeError`` holds the whole body as ``doc``. Raised inside an
    ``except`` block, any error would keep it reachable as ``__context__``
    even with ``from None``, so it is dropped here.

    Control characters inside strings are accepted: E-utilities writes a raw
    newline into some ``ERROR`` texts (checked live 2026-09-15, past the
    9,999-record cap), and that answer is a service error, not an unreadable
    one.

    Args:
        response: The answer.

    Returns:
        The decoded value, or ``_NOT_JSON`` when the body is not JSON.
    """
    try:
        return json.loads(response.content, strict=False)
    except ValueError:
        return _NOT_JSON


def _unlisted_or_raise(expected: int, pmids: list[str]) -> int:
    """Compare a page's PMIDs with what its count says it should list.

    Args:
        expected: The PMIDs the page should list.
        pmids: The PMIDs it listed.

    Returns:
        How many it left out.

    Raises:
        SourceRequestError: If it should have listed some and listed none: a
            failed page, not the end of the results.
    """
    if expected and not pmids:
        raise _incomplete_answer(f"esearch listed 0 of {expected} PMIDs")
    unlisted = max(0, expected - len(pmids))
    if unlisted:
        logger.warning(f"esearch listed {len(pmids)} of {expected} PMIDs")
    return unlisted


def _parsed_xml(xml_content: bytes) -> ET.Element | None:
    """Parse XML without keeping the parser's exception.

    Args:
        xml_content: The answer body.

    Returns:
        The root element, or None when the body is not well-formed XML. Only
        the parse error's code and position are logged: its message can
        quote the body, such as the name of an undefined entity.
    """
    try:
        return ET.fromstring(xml_content)
    except ET.ParseError as e:
        line, column = e.position
        logger.error(
            f"efetch answer is not well-formed XML (expat error {e.code} "
            f"at line {line}, column {column})"
        )
        return None


def _esearch_count(result: dict[str, Any]) -> int:
    """Read the total from an esearch result.

    A missing or non-numeric ``count`` is an answer that cannot be read, not a
    total of nothing (#255).

    Args:
        result: An ``esearchresult`` object.

    Returns:
        The number of matching articles.

    Raises:
        SourceRequestError: If ``count`` is missing or not a whole number.
    """
    count = result.get("count")
    if isinstance(count, str) and count.isdecimal():
        return int(count)
    raise _malformed_answer("esearch result has no numeric count")


def _esearch_pmids(result: dict[str, Any]) -> list[str]:
    """Read the PMIDs from an esearch result.

    Args:
        result: An ``esearchresult`` object.

    Returns:
        The PMIDs, in the order PubMed listed them.

    Raises:
        SourceRequestError: If ``idlist`` is missing or not a list of strings.
    """
    pmids = result.get("idlist")
    if isinstance(pmids, list) and all(isinstance(pmid, str) for pmid in pmids):
        return pmids
    raise _malformed_answer("esearch result has no idlist of strings")

# Compiled regex pattern for email validation
_EMAIL_PATTERN = re.compile(EMAIL_VALIDATION_PATTERN)


def validate_email(email: str) -> bool:
    """
    Validate email format for NCBI API requirements.

    NCBI requires a valid email address for identification purposes.
    This validates the basic email format.

    Args:
        email: Email address to validate

    Returns:
        True if email format is valid, False otherwise
    """
    if not email:
        return False
    return bool(_EMAIL_PATTERN.match(email))


class PubMedSearchClient:
    """
    Client for searching PubMed via E-utilities API.

    Provides methods for searching PubMed with structured queries,
    fetching article metadata, and handling large result sets using
    the NCBI history server.
    """

    def __init__(
        self,
        email: Optional[str] = None,
        api_key: Optional[str] = None,
        timeout: float = REQUEST_TIMEOUT_SECONDS,
        max_retries: int = MAX_RETRIES,
    ) -> None:
        """
        Initialize the PubMed search client.

        Args:
            email: Email for NCBI (recommended for identification)
            api_key: NCBI API key for higher rate limits (10/sec vs 3/sec)
            timeout: Request timeout in seconds
            max_retries: Maximum retry attempts for failed requests
        """
        self.email = email or os.environ.get(ENV_NCBI_EMAIL, "")
        self.api_key = api_key or os.environ.get(ENV_NCBI_API_KEY, "")
        self.timeout = timeout
        self.max_retries = max_retries

        # Validate email format if provided
        if self.email and not validate_email(self.email):
            logger.warning(
                f"Email '{self.email}' does not appear to be a valid email format. "
                "NCBI recommends providing a valid email for identification."
            )

        # Rate limiting based on API key presence
        self.request_delay = REQUEST_DELAY_WITH_KEY if self.api_key else REQUEST_DELAY_WITHOUT_KEY

        rate_desc = f"{1/self.request_delay:.1f} req/s" if self.request_delay > 0 else "unlimited"
        logger.info(f"PubMed search client initialized (rate limit: {rate_desc})")

    def _make_request(
        self,
        url: str,
        params: Dict[str, Any],
    ) -> requests.Response:
        """
        Make an HTTP request with retry logic and rate limiting.

        Every request is a POST with the parameters in the body. The API key
        is among them, and a query string is part of the URL that urllib3
        writes to any DEBUG-level log and that ``requests`` embeds in its
        exception text (#196). POST also avoids the HTTP 414 a long query
        would meet as a GET.

        A redirect is a failed request, never followed: a 307 or 308 would
        re-send the body, key included, to whatever host it names, and a 301,
        302 or 303 would re-send the request as a GET without its parameters.

        Args:
            url: An E-utilities endpoint that accepts POST. Today that is
                ``esearch.fcgi`` (history-server requests included) and
                ``efetch.fcgi``.
            params: Request parameters, sent as a form-encoded body.
                ``email`` and ``api_key`` are added to this dict in place.

        Returns:
            The response to the first attempt that succeeded. Every HTTP error
            is retried, a refused redirect and a non-retryable 4xx included.

        Raises:
            SourceRequestError: When every attempt failed. It carries only the
                failure's kind and status, never the ``requests`` exception,
                whose request body holds the key (#247).
        """
        # Add authentication
        if self.email:
            params["email"] = self.email
        if self.api_key:
            params["api_key"] = self.api_key

        delay = INITIAL_RETRY_DELAY_SECONDS
        failure = RequestFailure(RequestFailureKind.REQUEST_FAILED)

        for attempt in range(self.max_retries):
            try:
                # Rate limiting
                time.sleep(self.request_delay)

                response = requests.post(
                    url, data=params, timeout=self.timeout, allow_redirects=False
                )
                if response.is_redirect:
                    raise requests.HTTPError(
                        f"{response.status_code} redirect not followed for url: {url}",
                        response=response,
                    )
                response.raise_for_status()
                return response

            except requests.exceptions.RequestException as e:
                failure = request_failure_from_exception(e)
                logger.warning(
                    f"PubMed API request failed (attempt {attempt + 1}/{self.max_retries}): "
                    f"{failure.describe()}"
                )
                if attempt < self.max_retries - 1:
                    time.sleep(delay)
                    delay *= RETRY_BACKOFF_MULTIPLIER

        logger.error(
            f"PubMed API request failed after {self.max_retries} attempts: {failure.describe()}"
        )
        raise SourceRequestError(SearchProvider.PUBMED, failure)

    def _esearch(self, params: dict[str, Any]) -> dict[str, Any]:
        """Run an esearch request and return its ``esearchresult`` object.

        E-utilities reports some failures inside an HTTP 200, as an ``ERROR``
        field and no ``count`` (#255). That answer is a failed search, not a
        search that matched nothing. Its text is neither logged nor shown:
        what NCBI writes into a failed answer can repeat the request.

        Args:
            params: esearch parameters, sent as a form-encoded body.

        Returns:
            The ``esearchresult`` object of a successful answer.

        Raises:
            SourceRequestError: If the request failed, the answer reports an
                error, or the answer is not esearch's JSON.
        """
        response = self._make_request(ESEARCH_URL, params)
        data = _decoded_json(response)
        if data is _NOT_JSON:
            raise _malformed_answer("esearch answer is not JSON")

        result = data.get("esearchresult") if isinstance(data, dict) else None
        if not isinstance(result, dict):
            raise _malformed_answer("esearch answer has no esearchresult object")
        if "ERROR" in result:
            logger.error(
                "E-utilities esearch answered with an ERROR instead of a result "
                "(its text is not logged: it can repeat the request)"
            )
            raise SourceRequestError(
                SearchProvider.PUBMED, RequestFailure(RequestFailureKind.SERVICE_ERROR)
            )
        return result

    def search(
        self,
        query: PubMedQuery,
        max_results: int = DEFAULT_MAX_RESULTS,
        use_history: bool = True,
        sort: str = "relevance",
        progress_callback: Optional[Callable[[str, str], None]] = None,
    ) -> SearchResult:
        """
        Search PubMed with a structured query.

        Args:
            query: PubMedQuery object with search parameters
            max_results: Maximum number of results to retrieve
            use_history: Use history server for large result sets
            sort: Sort order ('relevance', 'pub_date', 'first_author')
            progress_callback: Optional callback(step, message) for progress updates

        Returns:
            SearchResult with PMIDs and metadata. PMIDs PubMed counted but did
            not list -- on a history-server page that failed, or on any page
            that listed fewer than its count said -- are counted in
            ``unlisted_count``, and later history pages are still listed.

        Raises:
            SourceRequestError: If the search itself failed. A failed search
                is never returned as zero results (#247).
        """
        def report_progress(step: str, message: str) -> None:
            logger.info(f"[{step}] {message}")
            if progress_callback:
                progress_callback(step, message)

        # Validate max_results
        max_results = min(max_results, MAX_RESULTS_LIMIT)

        report_progress("search", f"Searching PubMed: {query.query_string[:100]}...")

        start_time = time.time()

        # Build search parameters
        params = query.to_url_params()
        params["retmax"] = max_results
        params["sort"] = sort

        # Use history server for large result sets
        history_requested = use_history and max_results > HISTORY_SERVER_THRESHOLD
        if history_requested:
            params["usehistory"] = "y"
            params["retmax"] = 0  # Just get count and WebEnv

        result = self._esearch(params)
        total_count = _esearch_count(result)
        pmids = _esearch_pmids(result)

        # Get history server info
        web_env = result.get("webenv")
        query_key = result.get("querykey")

        report_progress("results", f"Found {total_count} total results")

        unlisted_count = 0
        listing_failure: RequestFailure | None = None
        if not history_requested:
            expected = expected_esearch_listing(total_count, 0, max_results)
            unlisted_count = _unlisted_or_raise(expected, pmids)
            if unlisted_count:
                listing_failure = RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
        elif total_count > len(pmids):
            if not isinstance(web_env, str) or not isinstance(query_key, str):
                raise _malformed_answer("esearch answer lacks the history-server WebEnv")
            report_progress("fetch", "Fetching additional PMIDs from history server...")
            listing = self._fetch_pmids_from_history(
                web_env=web_env,
                query_key=query_key,
                total_count=min(total_count, max_results),
                progress_callback=progress_callback,
            )
            pmids, unlisted_count, listing_failure = listing

        search_time = time.time() - start_time
        report_progress("complete", f"Retrieved {len(pmids)} PMIDs in {search_time:.2f}s")

        return SearchResult(
            query=query,
            total_count=total_count,
            retrieved_count=len(pmids),
            pmids=pmids,
            search_time_seconds=search_time,
            web_env=web_env,
            query_key=query_key,
            unlisted_count=unlisted_count,
            listing_failure=listing_failure,
        )

    def _fetch_pmids_from_history(
        self,
        web_env: str,
        query_key: str,
        total_count: int,
        progress_callback: Optional[Callable[[str, str], None]] = None,
    ) -> tuple[list[str], int, RequestFailure | None]:
        """
        Fetch PMIDs from history server in batches.

        A page that fails is counted and the pages after it are still asked
        for: ending the list there would drop every later page without a word
        (#248).

        Args:
            web_env: WebEnv from initial search
            query_key: QueryKey from initial search
            total_count: Total number of PMIDs to fetch
            progress_callback: Optional progress callback

        Returns:
            The PMIDs listed; how many PMIDs the pages left out, whether a
            page failed or listed fewer than its size; and why the first
            such page fell short, or None.
        """
        all_pmids: list[str] = []
        unlisted_count = 0
        first_failure: RequestFailure | None = None
        batch_size = DEFAULT_BATCH_SIZE

        for start in range(0, total_count, batch_size):
            page_size = min(batch_size, total_count - start)
            params = {
                "db": "pubmed",
                "WebEnv": web_env,
                "query_key": query_key,
                "retstart": start,
                "retmax": page_size,
                "retmode": "json",
            }

            try:
                batch_pmids = _esearch_pmids(self._esearch(params))
            except SourceRequestError as e:
                logger.warning(
                    f"PubMed history page at offset {start} ({page_size} PMIDs) "
                    f"could not be listed: {e.failure.describe()}"
                )
                unlisted_count += page_size
                if first_failure is None:
                    first_failure = e.failure
                continue

            short_by = max(0, page_size - len(batch_pmids))
            if short_by:
                logger.warning(
                    f"PubMed history page at offset {start} listed "
                    f"{len(batch_pmids)} of {page_size} PMIDs"
                )
                unlisted_count += short_by
                if first_failure is None:
                    first_failure = RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)

            all_pmids.extend(batch_pmids)
            if progress_callback:
                progress_callback("fetch", f"Retrieved {len(all_pmids)}/{total_count} PMIDs")

        return all_pmids, unlisted_count, first_failure

    def search_simple(
        self,
        query_string: str,
        max_results: int = DEFAULT_MAX_RESULTS,
    ) -> SearchResult:
        """
        Simple search with just a query string.

        Args:
            query_string: PubMed query string
            max_results: Maximum results to retrieve

        Returns:
            SearchResult with PMIDs

        Raises:
            SourceRequestError: If the search failed.
        """
        query = PubMedQuery(
            original_question=query_string,
            query_string=query_string,
        )
        return self.search(query, max_results=max_results)

    def search_with_offset(
        self,
        query_string: str,
        max_results: int = DEFAULT_MAX_RESULTS,
        start_offset: int = 0,
        progress_callback: Optional[Callable[[str, str], None]] = None,
    ) -> SearchResult:
        """
        Search with offset for paginated retrieval.

        Useful for incremental searches where earlier results
        have already been processed.

        Args:
            query_string: PubMed query string
            max_results: Maximum results to retrieve from this offset
            start_offset: Starting position in result set
            progress_callback: Optional progress callback

        Returns:
            SearchResult with PMIDs starting from offset

        Raises:
            SourceRequestError: If the search failed. A failed page is never
                returned as an empty one, which a caller would read as the
                end of the results (#247).
        """
        query = PubMedQuery(
            original_question=query_string,
            query_string=query_string,
        )

        def report_progress(step: str, message: str) -> None:
            logger.info(f"[{step}] {message}")
            if progress_callback:
                progress_callback(step, message)

        # Validate offset
        start_offset = max(0, min(start_offset, MAX_RESULTS_LIMIT - 1))

        report_progress("search", f"Searching PubMed (offset {start_offset})...")

        start_time = time.time()

        # Build search parameters with offset
        retmax = min(max_results, MAX_RESULTS_LIMIT)
        params = query.to_url_params()
        params["retmax"] = retmax
        params["retstart"] = start_offset
        params["sort"] = "relevance"

        result = self._esearch(params)
        total_count = _esearch_count(result)
        pmids = _esearch_pmids(result)
        unlisted_count = _unlisted_or_raise(
            expected_esearch_listing(total_count, start_offset, retmax), pmids
        )

        search_time = time.time() - start_time
        report_progress(
            "complete",
            f"Retrieved {len(pmids)} PMIDs (offset {start_offset}) in {search_time:.2f}s"
        )

        return SearchResult(
            query=query,
            total_count=total_count,
            retrieved_count=len(pmids),
            pmids=pmids,
            search_time_seconds=search_time,
            unlisted_count=unlisted_count,
            listing_failure=(
                RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE) if unlisted_count else None
            ),
        )

    def get_count(self, query: PubMedQuery) -> int:
        """
        Get the count of results for a query without retrieving PMIDs.

        Args:
            query: PubMedQuery to count

        Returns:
            Number of matching articles

        Raises:
            SourceRequestError: If the count could not be obtained; 0 is only
                ever PubMed's own answer.
        """
        params = query.to_url_params()
        params["retmax"] = 0
        params["rettype"] = "count"

        return _esearch_count(self._esearch(params))

    def fetch_articles(
        self,
        pmids: List[str],
        batch_size: int = DEFAULT_BATCH_SIZE,
        progress_callback: Optional[Callable[[str, str], None]] = None,
    ) -> ArticleFetchResult:
        """
        Fetch article metadata for a list of PMIDs.

        A batch that fails after its retries is recorded and the batches after
        it are still fetched, so a transient failure costs one batch, not the
        rest of the list (#248).

        Args:
            pmids: List of PubMed IDs
            batch_size: Number of articles per request
            progress_callback: Optional progress callback

        Returns:
            The articles fetched, the PMIDs whose batch failed, why the first
            failed batch failed, and how many articles could not be read.
        """
        result = ArticleFetchResult()
        if not pmids:
            return result

        def report_progress(step: str, message: str) -> None:
            logger.info(f"[{step}] {message}")
            if progress_callback:
                progress_callback(step, message)

        total_batches = (len(pmids) + batch_size - 1) // batch_size

        for batch_num, i in enumerate(range(0, len(pmids), batch_size), 1):
            batch = pmids[i:i + batch_size]
            report_progress("fetch", f"Fetching batch {batch_num}/{total_batches}...")

            params = {
                "db": "pubmed",
                "id": ",".join(batch),
                "retmode": "xml",
            }

            try:
                response = self._make_request(EFETCH_URL, params)
                articles, unreadable = self._parse_articles_xml(response.content)
            except SourceRequestError as e:
                logger.warning(
                    f"PubMed batch {batch_num}/{total_batches} ({len(batch)} PMIDs) "
                    f"could not be fetched: {e.failure.describe()}"
                )
                result.pmids_not_fetched.extend(batch)
                if result.failure is None:
                    result.failure = e.failure
                continue

            result.articles.extend(articles)
            result.records_unreadable += unreadable
            report_progress(
                "progress",
                f"Fetched {len(result.articles)}/{len(pmids)} articles"
            )

        return result

    def _parse_articles_xml(self, xml_content: bytes) -> tuple[list[ArticleMetadata], int]:
        """
        Parse an efetch answer to ArticleMetadata objects.

        Args:
            xml_content: Raw XML response content

        Returns:
            The articles, and how many ``PubmedArticle`` records could not be
            read. No articles and none unreadable when the
            ``PubmedArticleSet`` holds no ``PubmedArticle``: PubMed's answer
            for PMIDs it does not hold, or for book records
            (``PubmedBookArticle``), which are not read.

        Raises:
            SourceRequestError: If the answer is not XML, is efetch's
                ``eFetchResult`` error document (which E-utilities can send
                with HTTP 200, #255), or has any other root than
                ``PubmedArticleSet``. Neither the error's text nor the root's
                tag is logged: a namespaced tag holds text the server chose.
        """
        root = _parsed_xml(xml_content)
        if root is None:
            raise SourceRequestError(
                SearchProvider.PUBMED, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
            )
        if root.tag == EFETCH_ERROR_ROOT_TAG:
            logger.error(
                "E-utilities efetch answered with an error document instead of articles "
                "(its text is not logged: it can repeat the request)"
            )
            raise SourceRequestError(
                SearchProvider.PUBMED, RequestFailure(RequestFailureKind.SERVICE_ERROR)
            )
        if root.tag != EFETCH_ARTICLE_SET_ROOT_TAG:
            raise _malformed_answer("efetch answer has an unexpected root element")

        articles = []
        unreadable = 0
        for article_elem in root.findall(".//PubmedArticle"):
            metadata = self._parse_single_article(article_elem)
            if metadata:
                articles.append(metadata)
            else:
                unreadable += 1

        return articles, unreadable

    def _parse_single_article(
        self,
        article_elem: ET.Element,
    ) -> Optional[ArticleMetadata]:
        """
        Parse a single PubmedArticle XML element.

        Args:
            article_elem: XML element for a PubmedArticle

        Returns:
            ArticleMetadata or None if parsing failed
        """
        try:
            # Extract PMID
            pmid_elem = article_elem.find(".//PMID")
            if pmid_elem is None or not pmid_elem.text:
                return None
            pmid = pmid_elem.text

            # Extract title
            title_elem = article_elem.find(".//ArticleTitle")
            title = self._get_element_text(title_elem) if title_elem is not None else ""

            # Extract abstract with Markdown formatting
            abstract = self._format_abstract_markdown(article_elem)

            # Extract authors
            authors = []
            for author in article_elem.findall(".//Author"):
                last_name = author.find(".//LastName")
                fore_name = author.find(".//ForeName")

                author_name = ""
                if last_name is not None:
                    author_name = self._get_element_text(last_name)
                if fore_name is not None:
                    fore_text = self._get_element_text(fore_name)
                    author_name = f"{author_name} {fore_text}" if author_name else fore_text

                if author_name:
                    authors.append(author_name)

            # Extract publication date
            pubdate_elem = article_elem.find(".//PubDate")
            publication_date = self._extract_date(pubdate_elem)

            # Extract journal name
            journal_elem = article_elem.find(".//Journal/Title")
            journal = self._get_element_text(journal_elem) if journal_elem is not None else "PubMed"

            # Extract DOI
            doi = None
            for article_id in article_elem.findall(".//ArticleId"):
                if article_id.get("IdType") == "doi":
                    doi = article_id.text
                    break

            # Extract PMC ID
            pmc_id = None
            for article_id in article_elem.findall(".//ArticleId"):
                if article_id.get("IdType") == "pmc":
                    pmc_id = article_id.text
                    break

            # Extract MeSH terms
            mesh_terms = []
            for descriptor in article_elem.findall(".//MeshHeading/DescriptorName"):
                mesh_term = self._get_element_text(descriptor)
                if mesh_term:
                    mesh_terms.append(mesh_term)

            # Extract keywords
            keywords = []
            for keyword in article_elem.findall(".//Keyword"):
                kw = self._get_element_text(keyword)
                if kw:
                    keywords.append(kw)

            return ArticleMetadata(
                pmid=pmid,
                doi=doi,
                title=title,
                abstract=abstract,
                authors=authors,
                publication=journal,
                publication_date=publication_date,
                mesh_terms=mesh_terms,
                keywords=keywords,
                pmc_id=pmc_id,
            )

        except Exception as e:
            logger.error(f"Error parsing article: {e}")
            return None

    def _get_element_text(self, elem: Optional[ET.Element]) -> str:
        """Get complete text from an XML element, handling mixed content."""
        if elem is None:
            return ""

        if not list(elem):
            return elem.text or ""

        text = elem.text or ""
        for child in elem:
            text += self._get_element_text(child)
            if child.tail:
                text += child.tail

        return text

    def _get_element_text_with_formatting(self, elem: Optional[ET.Element]) -> str:
        """
        Extract text with inline formatting converted to Markdown.

        Handles: <b>/<bold> → **text**, <i>/<italic> → *text*,
                 <sup> → ^text^, <sub> → ~text~
        """
        if elem is None:
            return ""

        if not list(elem):
            return (elem.text or "").strip()

        parts = []
        if elem.text:
            parts.append(elem.text)

        for child in elem:
            tag = child.tag.lower()
            child_text = self._get_element_text_with_formatting(child)

            if tag in ("b", "bold"):
                parts.append(f"**{child_text}**")
            elif tag in ("i", "italic"):
                parts.append(f"*{child_text}*")
            elif tag == "sup":
                parts.append(f"^{child_text}^")
            elif tag == "sub":
                parts.append(f"~{child_text}~")
            elif tag in ("u", "underline"):
                parts.append(f"__{child_text}__")
            else:
                parts.append(child_text)

            if child.tail:
                parts.append(child.tail)

        return "".join(parts).strip()

    def _format_abstract_markdown(self, article_elem: ET.Element) -> str:
        """
        Format abstract with section labels and Markdown formatting.
        """
        abstract_texts = article_elem.findall(".//AbstractText")
        if not abstract_texts:
            return ""

        markdown_parts = []

        for abstract_text in abstract_texts:
            label = abstract_text.get("Label", "").strip()
            if not label:
                nlm_category = abstract_text.get("NlmCategory", "").strip()
                if nlm_category and nlm_category not in ("UNASSIGNED", "UNLABELLED"):
                    label = nlm_category

            text = self._get_element_text_with_formatting(abstract_text)
            if not text:
                continue

            if label:
                markdown_parts.append(f"**{label.upper()}:** {text}")
            else:
                markdown_parts.append(text)

        return "\n\n".join(markdown_parts)

    def _extract_date(self, date_elem: Optional[ET.Element]) -> Optional[str]:
        """Extract date from a PubMed date element."""
        if date_elem is None:
            return None

        year = date_elem.find("Year")
        month = date_elem.find("Month")
        day = date_elem.find("Day")

        if year is not None and year.text:
            year_text = year.text

            month_text = "01"
            if month is not None and month.text:
                month_val = month.text.strip()
                month_map = {
                    "Jan": "01", "Feb": "02", "Mar": "03", "Apr": "04",
                    "May": "05", "Jun": "06", "Jul": "07", "Aug": "08",
                    "Sep": "09", "Oct": "10", "Nov": "11", "Dec": "12",
                }
                month_text = month_map.get(
                    month_val,
                    month_val.zfill(2) if month_val.isdigit() else "01"
                )

            day_text = (
                day.text.zfill(2)
                if day is not None and day.text and day.text.isdigit()
                else "01"
            )

            try:
                return f"{year_text}-{month_text}-{day_text}"
            except Exception:
                return year_text

        return None

    def test_connection(self) -> bool:
        """
        Test connection to PubMed API.

        Returns:
            True if PubMed answered; False if the request failed, which has
            already been logged with its reason.
        """
        params = {
            "db": "pubmed",
            "term": "test",
            "retmax": 1,
            "retmode": "json",
        }
        try:
            self._make_request(ESEARCH_URL, params)
        except SourceRequestError:
            return False
        return True
