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
PubMed E-utilities API client module for BMLibrarian Lite.

Provides search functionality against PubMed via NCBI E-utilities API,
with proper rate limiting, retry logic, and batch fetching.

Usage:
    from bmlibrarian_lite.pubmed import PubMedSearchClient, PubMedQuery

    client = PubMedSearchClient(email="user@example.com")
    result = client.search_simple("cardiovascular exercise", max_results=100)
    articles = client.fetch_articles(result.pmids)
"""

from .data_types import (
    ArticleMetadata,
    DateRange,
    ImportResult,
    MeSHTerm,
    PublicationType,
    PubMedQuery,
    QueryConcept,
    QueryConversionResult,
    SearchResult,
    SearchSession,
    SearchStatus,
)
from .search_client import PubMedSearchClient, validate_email
from .constants import (
    DEFAULT_MAX_RESULTS,
    DEFAULT_BATCH_SIZE,
    ESEARCH_URL,
    EFETCH_URL,
)

__all__ = [
    # Data types
    "ArticleMetadata",
    "DateRange",
    "ImportResult",
    "MeSHTerm",
    "PublicationType",
    "PubMedQuery",
    "QueryConcept",
    "QueryConversionResult",
    "SearchResult",
    "SearchSession",
    "SearchStatus",
    # Client
    "PubMedSearchClient",
    "validate_email",
    # Constants
    "DEFAULT_MAX_RESULTS",
    "DEFAULT_BATCH_SIZE",
    "ESEARCH_URL",
    "EFETCH_URL",
]
