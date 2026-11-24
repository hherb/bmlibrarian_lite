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

"""Answers cut at their token limit, and the one retry with a larger limit (#825).

How long a thinking model thinks varies from run to run, so an answer can
reach a limit set at twice the longest one measured. Such an answer is asked
once more with twice the limit, up to :data:`CUT_ANSWER_RETRY_MAX_TOKENS`.
Each cut is recorded, so real use re-measures the limits. The record goes to
the recorder the app sets (its ``LiteStorage``); with none set, nothing is
kept.
"""

from __future__ import annotations

import logging
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime

from .constants import CUT_ANSWER_RETRY_FACTOR, CUT_ANSWER_RETRY_MAX_TOKENS

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class CutAnswer:
    """An answer that stopped at its token limit, and what its retry did.

    Attributes:
        task_id: The task asked (``scoring``, ``citation_extraction``, ...).
        model: ``provider:model``.
        max_tokens: The limit the answer reached.
        output_tokens: The tokens it generated, thinking included.
        retry_max_tokens: The limit it was asked again with; None when it was
            not asked again (the context window ran out, or no larger limit
            was allowed).
        retry_output_tokens: The tokens the retry generated; None when there
            was no retry or it raised.
        retry_cut: Whether the retry reached its limit too; None as above.
        cut_at: When, ISO, UTC.
    """

    task_id: str
    model: str
    max_tokens: int
    output_tokens: int
    retry_max_tokens: int | None = None
    retry_output_tokens: int | None = None
    retry_cut: bool | None = None
    cut_at: str = field(default_factory=lambda: datetime.now(UTC).isoformat())


def raised_limit(output_tokens: int, max_tokens: int, room: int | None) -> int | None:
    """The limit to ask a cut answer again with, or None not to ask again.

    Args:
        output_tokens: The tokens the cut answer generated.
        max_tokens: The limit it was asked with.
        room: The tokens the context window leaves after the prompt, when the
            window bounds the answer (Ollama's ``num_ctx``); None when not.

    Returns:
        Twice the limit, capped by :data:`CUT_ANSWER_RETRY_MAX_TOKENS` and the
        room; None when the answer stopped short of its limit (the context
        window ran out, which a larger limit does not change) or no larger
        limit is allowed.
    """
    if max_tokens <= 0 or output_tokens < max_tokens:
        return None
    raised = min(max_tokens * CUT_ANSWER_RETRY_FACTOR, CUT_ANSWER_RETRY_MAX_TOKENS)
    if room is not None:
        raised = min(raised, room)
    return raised if raised > max_tokens else None


_recorder: Callable[[CutAnswer], None] | None = None


def set_recorder(recorder: Callable[[CutAnswer], None] | None) -> None:
    """Set where cut answers are recorded, process-wide; None records nothing.

    Args:
        recorder: Called with each cut answer (``LiteStorage.record_cut_answer``).
    """
    global _recorder
    _recorder = recorder


def record(cut: CutAnswer) -> None:
    """Record a cut answer. A failed write is logged, never raised: the answer matters more.

    Args:
        cut: The cut answer.
    """
    recorder = _recorder
    if recorder is None:
        return
    try:
        recorder(cut)
    except sqlite3.Error as e:
        logger.warning("Could not record a cut answer (%s, %s): %s", cut.task_id, cut.model, e)
