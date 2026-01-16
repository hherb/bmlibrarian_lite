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

    # Check if full text is available
    info = client.get_article_info(pmid="39521399")
    if info and info.has_fulltext_xml:
        xml = client.get_fulltext_xml(pmcid=info.pmcid)
        markdown = client.xml_to_markdown(xml)
"""

import logging
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from html import unescape

import requests
from requests.adapters import HTTPAdapter
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
)
from .data_models import CursorPaginationState

logger = logging.getLogger(__name__)


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
        has_fulltext_xml: Whether JATS XML full text is available
        has_pdf: Whether PDF is available
        is_preprint: Whether this is a preprint (from PPR source)
        source: Europe PMC source code (MED, PMC, PPR, etc.)
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

        retry_strategy = Retry(
            total=EUROPEPMC_MAX_RETRIES,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET"],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)

        return session

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
            ArticleInfo with availability details, or None if not found
        """
        # Build search query
        if pmcid:
            # Normalize PMC ID
            pmc_num = pmcid.replace("PMC", "")
            query = f"PMCID:PMC{pmc_num}"
        elif pmid:
            query = f"ext_id:{pmid} src:med"
        elif doi:
            query = f'DOI:"{doi}"'
        else:
            logger.warning("No identifier provided for article lookup")
            return None

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
                logger.debug(f"No results found for query: {query}")
                return None

            result = results[0]

            # Extract authors
            authors = []
            author_list = result.get("authorList", {}).get("author", [])
            for author in author_list:
                full_name = author.get("fullName", "")
                if full_name:
                    authors.append(full_name)

            # Extract year
            year = None
            pub_year = result.get("pubYear")
            if pub_year:
                try:
                    year = int(pub_year)
                except ValueError:
                    pass

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
            )

        except requests.exceptions.RequestException as e:
            logger.warning(f"Europe PMC API error: {e}")
            return None

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

        Args:
            query: Search query in Europe PMC syntax
            max_results: Maximum number of results to return
            cursor: Pagination cursor (None for first page)
            include_preprints: Whether to include preprints in results
            page_size: Results per page (default from constants)

        Returns:
            Tuple of (list of ArticleInfo, pagination state)

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
        current_cursor = cursor
        total_count = 0

        while len(all_articles) < max_results:
            # Calculate how many results we still need
            remaining = max_results - len(all_articles)
            request_size = min(page_size, remaining)

            try:
                response = self._session.get(
                    EUROPEPMC_SEARCH_URL,
                    params={
                        "query": full_query,
                        "format": "json",
                        "resultType": EUROPEPMC_RESULT_TYPE,
                        "pageSize": request_size,
                        "cursorMark": current_cursor,
                        "sort": EUROPEPMC_SORT_ORDER,
                    },
                    timeout=EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
                )
                response.raise_for_status()
                data = response.json()

                # Get total count from first response
                if total_count == 0:
                    total_count = data.get("hitCount", 0)
                    logger.info(f"Europe PMC search found {total_count} total results")

                # Parse results
                results = data.get("resultList", {}).get("result", [])
                if not results:
                    break

                for result in results:
                    article = self._parse_search_result(result)
                    if article:
                        all_articles.append(article)

                # Get next cursor
                next_cursor = data.get("nextCursorMark")

                # Check if we've reached the end
                if not next_cursor or next_cursor == current_cursor:
                    break

                current_cursor = next_cursor

            except requests.exceptions.RequestException as e:
                logger.warning(f"Europe PMC search error: {e}")
                break

        # Build pagination state
        # Note: next_cursor might not be set if the loop didn't execute
        # or if an error occurred before the last response was parsed
        next_cursor_value = None
        try:
            next_cursor_value = data.get("nextCursorMark")  # noqa: F821
        except NameError:
            # 'data' was never assigned (loop didn't execute or failed early)
            pass

        pagination = CursorPaginationState(
            total_count=total_count,
            fetched_count=len(all_articles),
            current_cursor=current_cursor,
            next_cursor=next_cursor_value,
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
        """
        full_query = self._build_search_query(query, include_preprints)

        try:
            response = self._session.get(
                EUROPEPMC_SEARCH_URL,
                params={
                    "query": full_query,
                    "format": "json",
                    "resultType": "lite",  # Faster, less data
                    "pageSize": EUROPEPMC_COUNT_PAGE_SIZE,
                },
                timeout=EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
            )
            response.raise_for_status()
            data = response.json()
            return data.get("hitCount", 0)

        except requests.exceptions.RequestException as e:
            logger.warning(f"Europe PMC count error: {e}")
            return 0

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
            # Extract authors
            authors = []
            author_list = result.get("authorList", {}).get("author", [])
            for author in author_list:
                full_name = author.get("fullName", "")
                if full_name:
                    authors.append(full_name)

            # Extract year
            year = None
            pub_year = result.get("pubYear")
            if pub_year:
                try:
                    year = int(pub_year)
                except ValueError:
                    pass

            # Check if this is a preprint
            source = result.get("source", "")
            is_preprint = source == EUROPEPMC_SOURCE_PREPRINT

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
                is_preprint=is_preprint,
                source=source,
            )

        except Exception as e:
            logger.warning(f"Failed to parse Europe PMC result: {e}")
            return None

    def get_fulltext_xml(
        self,
        pmcid: str | None = None,
        pmid: str | None = None,
    ) -> str | None:
        """Retrieve full-text XML for an article.

        Args:
            pmcid: PubMed Central ID (preferred)
            pmid: PubMed ID (will be converted to PMC ID)

        Returns:
            JATS XML string, or None if not available
        """
        # Get PMC ID if not provided
        if not pmcid and pmid:
            info = self.get_article_info(pmid=pmid)
            if info and info.pmcid:
                pmcid = info.pmcid
            else:
                logger.debug(f"No PMC ID found for PMID {pmid}")
                return None

        if not pmcid:
            return None

        # Normalize PMC ID
        pmc_num = pmcid.replace("PMC", "")
        pmcid = f"PMC{pmc_num}"

        url = f"{EUROPEPMC_REST_BASE_URL}/{pmcid}/fullTextXML"

        try:
            response = self._session.get(
                url,
                headers={"Accept": "application/xml"},
                timeout=EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
            )

            if response.status_code == 404:
                logger.debug(f"Full text XML not available for {pmcid}")
                return None

            response.raise_for_status()
            return response.text

        except requests.exceptions.RequestException as e:
            logger.warning(f"Failed to fetch full text XML for {pmcid}: {e}")
            return None

    def xml_to_markdown(self, xml_content: str) -> str:
        """Convert JATS XML to readable markdown.

        Extracts and formats the key sections:
        - Title and metadata
        - Abstract
        - Body sections
        - References

        Args:
            xml_content: JATS XML string

        Returns:
            Formatted markdown string
        """
        try:
            root = ET.fromstring(xml_content)
        except ET.ParseError as e:
            logger.error(f"Failed to parse XML: {e}")
            return ""

        sections = []

        # Extract front matter (title, authors, abstract)
        front = root.find(".//front")
        if front is not None:
            sections.append(self._extract_front_matter(front))

        # Extract body
        body = root.find(".//body")
        if body is not None:
            sections.append(self._extract_body(body))

        # Extract references
        back = root.find(".//back")
        if back is not None:
            refs = self._extract_references(back)
            if refs:
                sections.append(refs)

        return "\n\n".join(filter(None, sections))

    def _extract_front_matter(self, front: ET.Element) -> str:
        """Extract title, authors, and abstract from front matter."""
        parts = []

        # Title
        title_group = front.find(".//title-group")
        if title_group is not None:
            article_title = title_group.find("article-title")
            if article_title is not None:
                title_text = self._get_text(article_title)
                parts.append(f"# {title_text}")

        # Authors
        contrib_group = front.find(".//contrib-group")
        if contrib_group is not None:
            authors = []
            for contrib in contrib_group.findall("contrib[@contrib-type='author']"):
                name = contrib.find("name")
                if name is not None:
                    given = name.findtext("given-names", "")
                    surname = name.findtext("surname", "")
                    if surname:
                        authors.append(f"{given} {surname}".strip())
            if authors:
                parts.append(f"**Authors:** {', '.join(authors)}")

        # Journal and date
        journal_meta = front.find(".//journal-meta")
        article_meta = front.find(".//article-meta")

        meta_parts = []
        if journal_meta is not None:
            journal_title = journal_meta.findtext(".//journal-title", "")
            if journal_title:
                meta_parts.append(f"*{journal_title}*")

        if article_meta is not None:
            pub_date = article_meta.find(".//pub-date")
            if pub_date is not None:
                year = pub_date.findtext("year", "")
                if year:
                    meta_parts.append(f"({year})")

            # DOI
            for article_id in article_meta.findall("article-id"):
                if article_id.get("pub-id-type") == "doi":
                    doi = article_id.text
                    if doi:
                        meta_parts.append(f"DOI: {doi}")
                        break

        if meta_parts:
            parts.append(" | ".join(meta_parts))

        # Abstract
        abstract = front.find(".//abstract")
        if abstract is not None:
            abstract_text = self._get_text(abstract)
            if abstract_text:
                parts.append(f"## Abstract\n\n{abstract_text}")

        return "\n\n".join(parts)

    def _extract_body(self, body: ET.Element) -> str:
        """Extract main body content."""
        sections = []

        for sec in body.findall(".//sec"):
            section_content = self._process_section(sec)
            if section_content:
                sections.append(section_content)

        # If no sections found, try to get paragraphs directly
        if not sections:
            paragraphs = []
            for p in body.findall(".//p"):
                text = self._get_text(p)
                if text:
                    paragraphs.append(text)
            if paragraphs:
                sections.append("\n\n".join(paragraphs))

        return "\n\n".join(sections)

    def _process_section(self, sec: ET.Element, level: int = 2) -> str:
        """Process a section element recursively."""
        parts = []

        # Section title
        title = sec.find("title")
        if title is not None:
            title_text = self._get_text(title)
            if title_text:
                prefix = "#" * min(level, 6)
                parts.append(f"{prefix} {title_text}")

        # Direct paragraphs in this section
        for child in sec:
            if child.tag == "p":
                text = self._get_text(child)
                if text:
                    parts.append(text)
            elif child.tag == "sec":
                # Nested section
                nested = self._process_section(child, level + 1)
                if nested:
                    parts.append(nested)
            elif child.tag == "list":
                list_content = self._process_list(child)
                if list_content:
                    parts.append(list_content)
            elif child.tag == "table-wrap":
                table_caption = child.findtext(".//caption/p", "")
                if table_caption:
                    parts.append(f"*Table: {table_caption}*")
            elif child.tag == "fig":
                fig_caption = child.findtext(".//caption/p", "")
                if fig_caption:
                    parts.append(f"*Figure: {fig_caption}*")

        return "\n\n".join(parts)

    def _process_list(self, list_elem: ET.Element) -> str:
        """Process a list element."""
        items = []
        list_type = list_elem.get("list-type", "bullet")

        for i, item in enumerate(list_elem.findall("list-item"), 1):
            text = self._get_text(item)
            if text:
                if list_type == "order":
                    items.append(f"{i}. {text}")
                else:
                    items.append(f"- {text}")

        return "\n".join(items)

    def _extract_references(self, back: ET.Element) -> str:
        """Extract references section."""
        ref_list = back.find(".//ref-list")
        if ref_list is None:
            return ""

        parts = ["## References"]

        for ref in ref_list.findall("ref"):
            citation = ref.find(".//mixed-citation")
            if citation is None:
                citation = ref.find(".//element-citation")

            if citation is not None:
                ref_text = self._get_text(citation)
                if ref_text:
                    # Clean up extra whitespace
                    ref_text = " ".join(ref_text.split())
                    parts.append(f"- {ref_text}")

        if len(parts) == 1:
            return ""

        return "\n".join(parts)

    def _get_text(self, element: ET.Element) -> str:
        """Extract all text content from an element, handling nested elements.

        Preserves inline formatting like italic/bold where appropriate.
        """
        if element is None:
            return ""

        parts = []

        # Get text before first child
        if element.text:
            parts.append(element.text)

        # Process children
        for child in element:
            # Handle inline formatting
            if child.tag == "italic":
                child_text = self._get_text(child)
                if child_text:
                    parts.append(f"*{child_text}*")
            elif child.tag == "bold":
                child_text = self._get_text(child)
                if child_text:
                    parts.append(f"**{child_text}**")
            elif child.tag == "sup":
                child_text = self._get_text(child)
                if child_text:
                    parts.append(f"^{child_text}^")
            elif child.tag == "sub":
                child_text = self._get_text(child)
                if child_text:
                    parts.append(f"_{child_text}_")
            elif child.tag == "xref":
                # Cross-reference (citation, figure, table)
                child_text = self._get_text(child)
                if child_text:
                    parts.append(f"[{child_text}]")
            elif child.tag == "ext-link":
                # External link
                href = child.get("{http://www.w3.org/1999/xlink}href", "")
                child_text = self._get_text(child)
                if child_text and href:
                    parts.append(f"[{child_text}]({href})")
                elif child_text:
                    parts.append(child_text)
            elif child.tag in ("title", "label"):
                # Skip titles and labels (handled separately)
                pass
            else:
                # Recursively get text from other elements
                child_text = self._get_text(child)
                if child_text:
                    parts.append(child_text)

            # Get tail text after this child
            if child.tail:
                parts.append(child.tail)

        text = "".join(parts)
        # Clean up whitespace
        text = re.sub(r'\s+', ' ', text).strip()
        # Unescape HTML entities
        text = unescape(text)

        return text


def get_fulltext_markdown(
    pmid: str | None = None,
    pmcid: str | None = None,
    doi: str | None = None,
) -> tuple[str | None, ArticleInfo | None]:
    """Convenience function to get full-text markdown for an article.

    Args:
        pmid: PubMed ID
        pmcid: PubMed Central ID
        doi: Digital Object Identifier

    Returns:
        Tuple of (markdown_content, article_info) or (None, None) if not available
    """
    client = EuropePMCClient()

    # Get article info
    info = client.get_article_info(pmid=pmid, pmcid=pmcid, doi=doi)
    if not info:
        return None, None

    if not info.has_fulltext_xml:
        logger.debug("No full-text XML available for article")
        return None, info

    # Get XML and convert
    xml = client.get_fulltext_xml(pmcid=info.pmcid)
    if not xml:
        return None, info

    markdown = client.xml_to_markdown(xml)
    return markdown, info
