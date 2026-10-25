# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""``build_query_string``: the PubMed query a structured answer names (#629).

Smart search's alternative queries and the question's own are both built here.
"""

from __future__ import annotations

from typing import Any

import pytest

from bmlibrarian_lite.query_converter import (
    MAX_KEYWORDS_PER_CONCEPT,
    MAX_MESH_TERMS_PER_CONCEPT,
    build_query_string,
)


def concept(mesh: list[str] | None = None, keywords: list[str] | None = None) -> dict[str, Any]:
    """One concept of a structured answer."""
    return {"name": "c", "mesh_terms": mesh or [], "keywords": keywords or []}


class TestBuildQueryString:
    """OR within a concept, AND between concepts, then the filters."""

    def test_terms_are_ored_and_concepts_anded(self) -> None:
        """MeSH terms first; a phrase is quoted, a single word is not."""
        query = build_query_string({"concepts": [
            concept(["Aspirin"], ["acetylsalicylic acid", "ASA"]),
            concept(keywords=["stroke"]),
        ]})

        assert query == (
            '(("Aspirin"[mh] OR "acetylsalicylic acid"[tiab] OR ASA[tiab]) AND (stroke[tiab]))'
            " AND humans[mh] AND hasabstract"
        )

    def test_the_filters_can_be_turned_off(self) -> None:
        """Humans only and abstracts only are defaults, not fixed."""
        query = build_query_string({
            "concepts": [concept(keywords=["stroke"])],
            "filters": {"humans_only": False, "has_abstract": False},
        })

        assert query == "((stroke[tiab]))"

    @pytest.mark.parametrize("data", [
        {}, {"concepts": []}, {"concepts": [concept()]},
    ], ids=["no concepts key", "no concepts", "no terms"])
    def test_nothing_to_search_is_an_empty_query(self, data: dict[str, Any]) -> None:
        """Never a query of filters alone, which would match all of PubMed."""
        assert build_query_string(data) == ""

    def test_a_concept_without_terms_is_left_out(self) -> None:
        """The others still make the query."""
        query = build_query_string({"concepts": [concept(), concept(keywords=["stroke"])]})

        assert query.startswith("((stroke[tiab]))")

    def test_each_concept_keeps_its_first_terms(self) -> None:
        """At most the configured number of MeSH terms and keywords per concept."""
        mesh = [f"M{i}" for i in range(MAX_MESH_TERMS_PER_CONCEPT + 2)]
        keywords = [f"k{i}" for i in range(MAX_KEYWORDS_PER_CONCEPT + 2)]

        query = build_query_string({"concepts": [concept(mesh, keywords)]})

        assert query.count("[mh]") - query.count("humans[mh]") == MAX_MESH_TERMS_PER_CONCEPT
        assert query.count("[tiab]") == MAX_KEYWORDS_PER_CONCEPT
        assert f'"M{MAX_MESH_TERMS_PER_CONCEPT}"' not in query
