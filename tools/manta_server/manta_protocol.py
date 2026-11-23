#!/usr/bin/env python3
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
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

"""MANTA-4B protocol shared by the benchmark and the local server.

Request builders, the label vocabularies and the screening rules. Pure
standard library: this module must not import torch, bmlibrarian_lite or
anything outside the standard library.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from typing import Any

# Shadow screener: a paper whose expected app-scale score is below this is "out".
SHADOW_CUTOFF: float = 1.95
# The lowest app score that counts as relevant.
RELEVANT_MIN_SCORE: int = 3

# The app's five relevance levels (agents/scoring_agent.py), lowest first.
RELEVANCE_LEVELS = (
    "Not relevant to the research question",
    "Marginally relevant, tangentially related",
    "Moderately relevant, contains useful related information",
    "Highly relevant, provides substantial supporting information",
    "Directly answers the question with strong evidence",
)
RELEVANCE_INSTRUCTIONS = "How relevant is this article to answering the research question?"
SCORE_MIN = 1

# The LiteStudyClassifier's options (quality/study_classifier.py), with
# descriptions for MANTA's choice question.
DESIGN_OPTIONS: dict[str, str] = {
    "systematic_review": "Systematic review without a meta-analysis",
    "meta_analysis": "Meta-analysis (with or without a systematic review)",
    "rct": "Randomised controlled trial",
    "cohort_prospective": "Prospective cohort study",
    "cohort_retrospective": "Retrospective cohort study",
    "case_control": "Case-control study",
    "cross_sectional": "Cross-sectional study",
    "case_series": "Case series",
    "case_report": "Case report",
    "editorial": "Editorial",
    "letter": "Letter",
    "guideline": "Clinical practice guideline",
    "other": "Another design (narrative review, laboratory, animal or qualitative study, ...)",
}
DESIGN_INSTRUCTIONS = (
    "What is the study design of this paper? Classify what this paper itself reports, "
    "not the studies it cites."
)

_PT_META = "Meta-Analysis"
_PT_SR = "Systematic Review"
_PT_RCT = "Randomized Controlled Trial"
_PT_CASE_REPORT = "Case Reports"
_PT_GUIDELINES = frozenset({"Practice Guideline", "Guideline"})
_PT_TRIALS = frozenset(
    {
        "Randomized Controlled Trial",
        "Clinical Trial",
        "Controlled Clinical Trial",
        "Pragmatic Clinical Trial",
        "Equivalence Trial",
        "Clinical Trial, Phase I",
        "Clinical Trial, Phase II",
        "Clinical Trial, Phase III",
        "Clinical Trial, Phase IV",
    }
)
_PT_NOT_PRIMARY = frozenset(
    {
        "Review",
        "Systematic Review",
        "Meta-Analysis",
        "Comment",
        "Editorial",
        "Letter",
        "Practice Guideline",
        "Guideline",
    }
)
_MH_PROSPECTIVE = "Prospective Studies"
_MH_RETROSPECTIVE = "Retrospective Studies"
_MH_COHORT = "Cohort Studies"
_MH_CASE_CONTROL = "Case-Control Studies"
_MH_CROSS_SECTIONAL = "Cross-Sectional Studies"
_HUMAN_INDEXING = frozenset({None, "Manual"})
_MEDLINE = "MEDLINE"

# Coarse groups: designs a reader would not tell apart from an abstract
# without the indexer's convention (SR vs MA, which kind of cohort).
DESIGN_GROUPS: dict[str, str] = {
    "systematic_review": "evidence_synthesis",
    "meta_analysis": "evidence_synthesis",
    "rct": "rct",
    "cohort_prospective": "cohort",
    "cohort_retrospective": "cohort",
    "case_control": "case_control",
    "cross_sectional": "cross_sectional",
    "case_series": "case",
    "case_report": "case",
    "editorial": "opinion",
    "letter": "opinion",
    "guideline": "guideline",
    "other": "other",
}


def design_label(
    publication_types: Iterable[str],
    mesh_headings: Iterable[str],
) -> str | None:
    """The study design that a record's human indexing states, if one.

    The rules are written against NLM's indexing conventions, not against
    any classifier: a publication type for syntheses, trials, case reports
    and guidelines, and the MeSH design headings for observational studies.
    A record whose headings name two designs is refused.

    Args:
        publication_types: The record's publication type names.
        mesh_headings: The record's MeSH descriptor names (not qualifiers).

    Returns:
        A ``DESIGN_OPTIONS`` key, or None when the indexing states no single
        design.
    """
    pt = set(publication_types)
    mh = set(mesh_headings)
    if _PT_META in pt:
        return "meta_analysis"
    if _PT_SR in pt:
        return "systematic_review"
    if pt & _PT_GUIDELINES:
        return None if (pt & _PT_TRIALS) else "guideline"
    if _PT_RCT in pt:
        return None if "Review" in pt else "rct"
    if pt & _PT_NOT_PRIMARY or pt & _PT_TRIALS:
        return None
    if _PT_CASE_REPORT in pt:
        observational = {_MH_COHORT, _MH_CASE_CONTROL, _MH_CROSS_SECTIONAL}
        return None if mh & observational else "case_report"
    cohort = _MH_COHORT in mh
    case_control = _MH_CASE_CONTROL in mh
    cross_sectional = _MH_CROSS_SECTIONAL in mh
    if cohort + case_control + cross_sectional != 1:
        return None
    prospective = _MH_PROSPECTIVE in mh
    retrospective = _MH_RETROSPECTIVE in mh
    if cohort:
        if prospective and not retrospective:
            return "cohort_prospective"
        if retrospective and not prospective:
            return "cohort_retrospective"
        return None
    if case_control:
        return None if prospective else "case_control"
    return None if prospective else "cross_sectional"


def relevance_request(item_id: str, question: str, title: str, abstract: str) -> dict[str, Any]:
    """The MANTA request for one question-abstract pair.

    Args:
        item_id: The item's id (it also seeds MANTA's option order).
        question: The research question.
        title: The article's title.
        abstract: The article's abstract.

    Returns:
        A request in MANTA's format, one ``score`` question.
    """
    return {
        "id": item_id,
        "state": {"research_question": question, "article": {"title": title, "abstract": abstract}},
        "questions": {
            "relevance": {
                "type": "score",
                "instructions": RELEVANCE_INSTRUCTIONS,
                "criteria": list(RELEVANCE_LEVELS),
            }
        },
    }


def design_request(item_id: str, title: str, abstract: str) -> dict[str, Any]:
    """The MANTA request for one abstract's study design.

    Args:
        item_id: The item's id (it also seeds MANTA's option order).
        title: The article's title.
        abstract: The article's abstract.

    Returns:
        A request in MANTA's format, one ``choice`` question.
    """
    return {
        "id": item_id,
        "state": {"article": {"title": title, "abstract": abstract}},
        "questions": {
            "study_design": {
                "type": "choice",
                "instructions": DESIGN_INSTRUCTIONS,
                "criteria": dict(DESIGN_OPTIONS),
            }
        },
    }


def expected_score(level_probabilities: Mapping[str, float]) -> float:
    """MANTA's relevance as the expected level on the app's 1-5 scale.

    Args:
        level_probabilities: Option id ("0", "1", ...) to probability.

    Returns:
        The expected score, ``SCORE_MIN`` for the lowest level.
    """
    total = 0.0
    for option, p in sorted(level_probabilities.items(), key=lambda kv: int(kv[0])):
        total += (int(option) + SCORE_MIN) * p
    return total


def verdict(expected: float, cutoff: float = SHADOW_CUTOFF) -> str:
    """The shadow screener's call on one paper.

    Args:
        expected: The expected relevance on the app's 1-5 scale.
        cutoff: The lowest expected score that is kept.

    Returns:
        ``"in"`` at or above the cutoff, else ``"out"``.
    """
    return "in" if expected >= cutoff else "out"


def app_scale(level_probabilities: Mapping[str, float]) -> dict[str, float]:
    """MANTA option ids "0".."4" as app levels "1".."5".

    Args:
        level_probabilities: Option id to probability.

    Returns:
        App level (as text) to probability.
    """
    return {str(int(option) + SCORE_MIN): p for option, p in level_probabilities.items()}


def human_indexed(medline_status: str | None, indexing_method: str | None) -> bool | None:
    """Whether a PubMed record's indexing was done by a person.

    Args:
        medline_status: The record's status (``"MEDLINE"`` when indexed).
        indexing_method: The record's indexing method, None when absent.

    Returns:
        For a MEDLINE record, True when indexed manually (or with no method
        stated) and False otherwise; None for any other record (no status,
        ``"PubMed-not-MEDLINE"``, ``"In-Process"``, ...), whose indexing is
        not known to be either.
    """
    if medline_status != _MEDLINE:
        return None
    return indexing_method in _HUMAN_INDEXING


def indexing_design(indexing: Mapping[str, Any] | None) -> tuple[str | None, bool | None]:
    """The design a record's indexing states, and whether a person indexed it.

    Args:
        indexing: A record's ``publication_types``, ``mesh_terms``,
            ``medline_status`` and ``indexing_method``, or None.

    Returns:
        ``(design_label(...), human_indexed(...))``, or ``(None, None)``.
    """
    if indexing is None:
        return None, None
    return (
        design_label(indexing.get("publication_types") or [], indexing.get("mesh_terms") or []),
        human_indexed(indexing.get("medline_status"), indexing.get("indexing_method")),
    )
