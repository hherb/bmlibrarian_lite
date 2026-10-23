# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Reducing one paper's per-window quality answers to one.

The reduce step of the map-reduce every quality analysis runs over a text's
windows (:func:`bmlibrarian_lite.chunking.analysis_windows`). Pure.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import replace

from .data_models import QualityAssessment, StudyClassification


def reduce_by_design_vote[Answer: (StudyClassification, QualityAssessment)](
    answers: Sequence[Answer],
) -> Answer:
    """One answer from every window's, by a confidence-weighted design vote.

    The design with the most confidence summed over the windows wins; the
    rest is the most confident answer naming it. Its confidence becomes the
    winning design's support averaged over every window, so windows that
    disagree lower it and windows that agree keep it; the sample size is the
    largest any window stated.

    Args:
        answers: Every window's answer, at least one.

    Returns:
        The reduced answer; a single window's answer unchanged.

    Raises:
        ValueError: If there are no answers.
    """
    if not answers:
        raise ValueError("A vote needs at least one window's answer")
    if len(answers) == 1:
        return answers[0]
    support: dict[object, float] = {}
    for answer in answers:
        support[answer.study_design] = support.get(answer.study_design, 0.0) + answer.confidence
    design = max(support, key=lambda d: support[d])
    best = max((a for a in answers if a.study_design == design), key=lambda a: a.confidence)
    sizes = [a.sample_size for a in answers if a.sample_size is not None]
    return replace(
        best,
        confidence=support[design] / len(answers),
        sample_size=max(sizes) if sizes else None,
    )
