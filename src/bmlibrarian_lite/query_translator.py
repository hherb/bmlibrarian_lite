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

"""Query translator for converting between PubMed and Europe PMC search syntax.

Provides bidirectional translation between PubMed E-utilities query syntax
and Europe PMC REST API query syntax, enabling users to write queries in
either format and search both providers.

The two APIs use different field tags and operators:

PubMed syntax:
    - Field tags: [MeSH], [tiab], [ti], [au], [ta], [dp], etc.
    - Boolean: AND, OR, NOT (capitalized)
    - Example: "diabetes mellitus"[MeSH] AND insulin[tiab]

Europe PMC syntax:
    - Field tags: MeSH_TERM:, TITLE_ABS:, TITLE:, AUTH:, JOURNAL:, PUB_YEAR:
    - Boolean: AND, OR, NOT (capitalized)
    - Example: MeSH_TERM:"diabetes mellitus" AND TITLE_ABS:insulin

Usage:
    from bmlibrarian_lite.query_translator import QueryTranslator

    # Detect and convert
    query = '"diabetes"[MeSH] AND metformin[tiab]'
    if QueryTranslator.is_pubmed_syntax(query):
        epmc_query = QueryTranslator.pubmed_to_europepmc(query)
"""

import logging
import re

logger = logging.getLogger(__name__)


class QueryTranslator:
    """Translates search queries between PubMed and Europe PMC syntax.

    This class provides static methods for detecting query syntax and
    converting between the two formats. It handles:
    - Field tags (MeSH, title/abstract, author, journal, date)
    - Boolean operators (preserved as-is)
    - Quoted phrases
    - Parenthetical grouping
    """

    # PubMed field tags and their Europe PMC equivalents
    PUBMED_TO_EUROPEPMC_FIELDS = {
        # MeSH terms
        "[mesh]": "MeSH_TERM:",
        "[mh]": "MeSH_TERM:",
        "[mesh terms]": "MeSH_TERM:",
        "[majr]": "MeSH_TERM:",  # MeSH Major Topic

        # Title and abstract
        "[tiab]": "TITLE_ABS:",
        "[ti]": "TITLE:",
        "[ab]": "ABSTRACT:",

        # Author
        "[au]": "AUTH:",
        "[author]": "AUTH:",
        "[fau]": "AUTH:",  # Full author name

        # Journal
        "[ta]": "JOURNAL:",
        "[journal]": "JOURNAL:",

        # Publication type
        "[pt]": "PUB_TYPE:",
        "[publication type]": "PUB_TYPE:",

        # Language
        "[la]": "LANG:",
        "[language]": "LANG:",

        # Date published - needs special handling
        "[dp]": "PUB_YEAR:",
        "[pdat]": "PUB_YEAR:",

        # PMC/PMID specific
        "[pmid]": "EXT_ID:",
        "[pmcid]": "PMCID:",

        # Affiliation
        "[ad]": "AFF:",
        "[affiliation]": "AFF:",
    }

    # Europe PMC fields and their PubMed equivalents
    EUROPEPMC_TO_PUBMED_FIELDS = {
        "mesh_term:": "[MeSH]",
        "title_abs:": "[tiab]",
        "title:": "[ti]",
        "abstract:": "[ab]",
        "auth:": "[au]",
        "journal:": "[ta]",
        "pub_type:": "[pt]",
        "lang:": "[la]",
        "pub_year:": "[dp]",
        "ext_id:": "[pmid]",
        "pmcid:": "[pmcid]",
        "aff:": "[ad]",
    }

    # Patterns for detecting query syntax
    PUBMED_FIELD_PATTERN = re.compile(r'\[(?:mesh|mh|tiab|ti|ab|au|ta|pt|la|dp|pdat|pmid|ad)\]', re.IGNORECASE)
    EUROPEPMC_FIELD_PATTERN = re.compile(
        r'(?:MeSH_TERM|TITLE_ABS|TITLE|ABSTRACT|AUTH|JOURNAL|PUB_TYPE|LANG|PUB_YEAR|EXT_ID|PMCID|AFF):',
        re.IGNORECASE
    )

    @staticmethod
    def is_pubmed_syntax(query: str) -> bool:
        """Detect if a query uses PubMed syntax.

        Looks for characteristic PubMed field tags in square brackets.

        Args:
            query: Search query string

        Returns:
            True if query appears to use PubMed syntax

        Example:
            >>> QueryTranslator.is_pubmed_syntax('"diabetes"[MeSH]')
            True
            >>> QueryTranslator.is_pubmed_syntax('MeSH_TERM:diabetes')
            False
        """
        return bool(QueryTranslator.PUBMED_FIELD_PATTERN.search(query))

    @staticmethod
    def is_europepmc_syntax(query: str) -> bool:
        """Detect if a query uses Europe PMC syntax.

        Looks for characteristic Europe PMC field prefixes.

        Args:
            query: Search query string

        Returns:
            True if query appears to use Europe PMC syntax

        Example:
            >>> QueryTranslator.is_europepmc_syntax('MeSH_TERM:diabetes')
            True
            >>> QueryTranslator.is_europepmc_syntax('"diabetes"[MeSH]')
            False
        """
        return bool(QueryTranslator.EUROPEPMC_FIELD_PATTERN.search(query))

    @staticmethod
    def detect_syntax(query: str) -> str | None:
        """Detect the syntax type of a query.

        Args:
            query: Search query string

        Returns:
            "pubmed", "europepmc", or None if unrecognized
        """
        if QueryTranslator.is_pubmed_syntax(query):
            return "pubmed"
        elif QueryTranslator.is_europepmc_syntax(query):
            return "europepmc"
        return None

    @staticmethod
    def pubmed_to_europepmc(query: str) -> str:
        """Convert a PubMed query to Europe PMC syntax.

        Translates field tags from PubMed bracket notation to Europe PMC
        prefix notation. Preserves boolean operators and grouping.

        Args:
            query: PubMed query string

        Returns:
            Equivalent Europe PMC query string

        Example:
            >>> QueryTranslator.pubmed_to_europepmc('"diabetes mellitus"[MeSH] AND metformin[tiab]')
            'MeSH_TERM:"diabetes mellitus" AND TITLE_ABS:metformin'
        """
        result = query

        # Handle date ranges specially (e.g., 2020:2024[dp] -> PUB_YEAR:[2020 TO 2024])
        date_range_pattern = re.compile(r'(\d{4}):(\d{4})\s*\[(dp|pdat)\]', re.IGNORECASE)
        result = date_range_pattern.sub(r'PUB_YEAR:[\1 TO \2]', result)

        # Handle single year dates (e.g., 2024[dp] -> PUB_YEAR:2024)
        single_date_pattern = re.compile(r'(\d{4})\s*\[(dp|pdat)\]', re.IGNORECASE)
        result = single_date_pattern.sub(r'PUB_YEAR:\1', result)

        # Convert field tags - quoted terms first
        # Pattern: "term"[field] -> FIELD:"term"
        quoted_field_pattern = re.compile(r'"([^"]+)"\s*(\[[^\]]+\])', re.IGNORECASE)

        def replace_quoted_field(match: re.Match) -> str:
            term = match.group(1)
            field = match.group(2).lower()
            epmc_field = QueryTranslator.PUBMED_TO_EUROPEPMC_FIELDS.get(field, "")
            if epmc_field:
                return f'{epmc_field}"{term}"'
            return match.group(0)

        result = quoted_field_pattern.sub(replace_quoted_field, result)

        # Convert field tags - unquoted terms
        # Pattern: term[field] -> FIELD:term
        unquoted_field_pattern = re.compile(r'(\S+)\s*(\[[^\]]+\])', re.IGNORECASE)

        def replace_unquoted_field(match: re.Match) -> str:
            term = match.group(1)
            field = match.group(2).lower()
            epmc_field = QueryTranslator.PUBMED_TO_EUROPEPMC_FIELDS.get(field, "")
            if epmc_field:
                return f'{epmc_field}{term}'
            return match.group(0)

        result = unquoted_field_pattern.sub(replace_unquoted_field, result)

        # Handle special PubMed filters
        # hasabstract -> HAS_ABSTRACT:Y
        result = re.sub(r'\bhasabstract\b', 'HAS_ABSTRACT:Y', result, flags=re.IGNORECASE)

        # "free full text"[sb] -> OPEN_ACCESS:Y
        result = re.sub(
            r'"?free full text"?\s*\[sb\]',
            'OPEN_ACCESS:Y',
            result,
            flags=re.IGNORECASE
        )

        # english[la] -> LANG:"eng"
        result = re.sub(r'\benglish\b', '"eng"', result, flags=re.IGNORECASE)

        logger.debug(f"Converted PubMed query to Europe PMC: {query} -> {result}")
        return result

    @staticmethod
    def europepmc_to_pubmed(query: str) -> str:
        """Convert a Europe PMC query to PubMed syntax.

        Translates field prefixes from Europe PMC notation to PubMed
        bracket notation. Preserves boolean operators and grouping.

        Args:
            query: Europe PMC query string

        Returns:
            Equivalent PubMed query string

        Example:
            >>> QueryTranslator.europepmc_to_pubmed('MeSH_TERM:"diabetes" AND TITLE_ABS:metformin')
            '"diabetes"[MeSH] AND metformin[tiab]'
        """
        result = query

        # Handle date ranges specially (e.g., PUB_YEAR:[2020 TO 2024] -> 2020:2024[dp])
        date_range_pattern = re.compile(r'PUB_YEAR:\s*\[(\d{4})\s+TO\s+(\d{4})\]', re.IGNORECASE)
        result = date_range_pattern.sub(r'\1:\2[dp]', result)

        # Handle single year dates (e.g., PUB_YEAR:2024 -> 2024[dp])
        single_date_pattern = re.compile(r'PUB_YEAR:\s*(\d{4})(?!\s*\])', re.IGNORECASE)
        result = single_date_pattern.sub(r'\1[dp]', result)

        # Convert field tags - quoted terms
        # Pattern: FIELD:"term" -> "term"[field]
        for epmc_field, pubmed_field in QueryTranslator.EUROPEPMC_TO_PUBMED_FIELDS.items():
            # Quoted pattern
            quoted_pattern = re.compile(
                rf'{re.escape(epmc_field)}\s*"([^"]+)"',
                re.IGNORECASE
            )
            result = quoted_pattern.sub(rf'"\1"{pubmed_field}', result)

            # Unquoted pattern (word followed by space or end)
            unquoted_pattern = re.compile(
                rf'{re.escape(epmc_field)}\s*(\S+)',
                re.IGNORECASE
            )
            result = unquoted_pattern.sub(rf'\1{pubmed_field}', result)

        # Handle special Europe PMC filters
        # HAS_ABSTRACT:Y -> hasabstract
        result = re.sub(r'HAS_ABSTRACT:\s*Y', 'hasabstract', result, flags=re.IGNORECASE)

        # OPEN_ACCESS:Y -> "free full text"[sb]
        result = re.sub(r'OPEN_ACCESS:\s*Y', '"free full text"[sb]', result, flags=re.IGNORECASE)

        # LANG:"eng" -> english[la]
        result = re.sub(r'LANG:\s*"?eng"?', 'english[la]', result, flags=re.IGNORECASE)

        logger.debug(f"Converted Europe PMC query to PubMed: {query} -> {result}")
        return result

    @staticmethod
    def normalize_query(query: str, target_syntax: str = "pubmed") -> str:
        """Normalize a query to the specified syntax.

        Detects the current syntax and converts if necessary.

        Args:
            query: Search query in any syntax
            target_syntax: Target syntax ("pubmed" or "europepmc")

        Returns:
            Query in the target syntax
        """
        current_syntax = QueryTranslator.detect_syntax(query)

        if current_syntax == target_syntax:
            return query

        if target_syntax == "europepmc":
            if current_syntax == "pubmed":
                return QueryTranslator.pubmed_to_europepmc(query)
            # Already in Europe PMC or neutral
            return query

        elif target_syntax == "pubmed":
            if current_syntax == "europepmc":
                return QueryTranslator.europepmc_to_pubmed(query)
            # Already in PubMed or neutral
            return query

        return query

    @staticmethod
    def is_neutral_query(query: str) -> bool:
        """Check if a query contains no syntax-specific field tags.

        Neutral queries can be used with either provider without translation.

        Args:
            query: Search query string

        Returns:
            True if query has no syntax-specific elements
        """
        return not (
            QueryTranslator.is_pubmed_syntax(query)
            or QueryTranslator.is_europepmc_syntax(query)
        )
