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

"""A failed analysis is not an empty one (#261, #262).

The companion of :mod:`~bmlibrarian_lite.search_failures` for the stages after
the search. A document the model could not score is not a document the model
judged irrelevant, and a document no citation could be extracted from is not a
document with nothing to say -- but both used to leave the pipeline as the
same thing: a document that is not in the result.

:class:`~bmlibrarian_lite.data_models.AnalysisShortfall` records what a stage
lost and why; the functions here turn that record into what a reader sees.

- :func:`describe_analysis_shortfalls`, :func:`format_analysis_shortfall_notice`
  and :func:`with_analysis_shortfall_notice` and
  :func:`without_analysis_shortfall_notice` turn shortfalls into what the
  report, the GUI and MCP callers see.
- :func:`analysis_failure_advice` says what the user can do about it.

The wording follows the search contract in
``doc/cross_platform/search_failure_reporting.md``; this family's own contract
is ``doc/cross_platform/analysis_failure_reporting.md``.
"""

from collections.abc import Sequence

from .data_models import AnalysisShortfall, EvaluationErrorCode


def describe_analysis_shortfalls(shortfalls: Sequence[AnalysisShortfall]) -> str:
    """Join every shortfall's clause, in order.

    Args:
        shortfalls: What the analysis lost.

    Returns:
        The clauses separated by semicolons, or ``""`` when there are none.
    """
    return "; ".join(shortfall.describe() for shortfall in shortfalls)


_NOTICE_OPENING = "> **Incomplete analysis:** "
_NOTICE_SEPARATOR = "\n\n"


def format_analysis_shortfall_notice(shortfalls: Sequence[AnalysisShortfall]) -> str:
    """Build the notice that precedes whatever an incomplete analysis produced.

    Args:
        shortfalls: What the analysis lost.

    Returns:
        A Markdown block quote, or ``""`` when nothing was lost, so a complete
        analysis never reads as a qualified one.
    """
    if not shortfalls:
        return ""
    return (
        f"{_NOTICE_OPENING}{describe_analysis_shortfalls(shortfalls)}. "
        "Everything below rests only on the documents that were analysed."
    )


def with_analysis_shortfall_notice(
    text: str, shortfalls: Sequence[AnalysisShortfall]
) -> str:
    """Put the incomplete-analysis notice in front of text a reader will see.

    Args:
        text: A report, or a message standing in for one.
        shortfalls: What the analysis behind it lost.

    Returns:
        The notice, a blank line and the text; or the text unchanged when
        nothing was lost, or when it already opens with a notice -- two
        notices in front of one report read as two separate losses, and the
        stage that wrote the first one knew what it had lost.
    """
    notice = format_analysis_shortfall_notice(shortfalls)
    if not notice or text.startswith(_NOTICE_OPENING):
        return text
    return f"{notice}{_NOTICE_SEPARATOR}{text}"


def without_analysis_shortfall_notice(text: str) -> str:
    """Read what follows the incomplete-analysis notice, for deciding what a text is.

    Not for display: the notice is what tells the reader part of the analysis
    is missing. A check such as "is this a message standing in for a report?"
    reads the text behind it.

    Args:
        text: A report or stand-in message, with or without the notice.

    Returns:
        The text after :func:`with_analysis_shortfall_notice`'s notice, or the
        text unchanged when it does not open with one.
    """
    if not text.startswith(_NOTICE_OPENING):
        return text
    _, separator, rest = text.partition(_NOTICE_SEPARATOR)
    return rest if separator else text


_AUTH_ADVICE = (
    "The model provider refused the credentials: check the API key in Settings."
)
_RATE_LIMIT_ADVICE = (
    "The model provider is limiting how often it can be called: "
    "wait a minute and try again."
)
_UNREACHABLE_ADVICE = (
    "Check that the model provider is reachable -- Ollama running, "
    "or the internet connection -- and try again."
)
_UNREADABLE_ADVICE = (
    "The model's answers could not be read: a different model may do better."
)
_FALLBACK_ADVICE = "Try again later."

_UNREACHABLE_CAUSES = (
    EvaluationErrorCode.API_TIMEOUT,
    EvaluationErrorCode.API_CONNECTION_ERROR,
    EvaluationErrorCode.API_SERVER_ERROR,
)
_UNREADABLE_CAUSES = (
    EvaluationErrorCode.JSON_PARSE_ERROR,
    EvaluationErrorCode.INVALID_RESPONSE_FORMAT,
    EvaluationErrorCode.EMPTY_RESPONSE,
    EvaluationErrorCode.RESPONSE_TOO_LARGE,
)


def analysis_failure_advice(shortfalls: Sequence[AnalysisShortfall]) -> str:
    """Say what the user can do about a failed analysis.

    Args:
        shortfalls: What failed.

    Returns:
        One or more sentences, each at most once, in this order: checking a
        refused API key; waiting out a rate limit; checking the provider is
        reachable; trying another model. Otherwise, trying again later.
    """
    causes = {cause for shortfall in shortfalls for cause in shortfall.causes}
    advice: list[str] = []
    if EvaluationErrorCode.API_AUTH_ERROR in causes:
        advice.append(_AUTH_ADVICE)
    if EvaluationErrorCode.API_RATE_LIMIT in causes:
        advice.append(_RATE_LIMIT_ADVICE)
    if causes.intersection(_UNREACHABLE_CAUSES):
        advice.append(_UNREACHABLE_ADVICE)
    if causes.intersection(_UNREADABLE_CAUSES):
        advice.append(_UNREADABLE_ADVICE)
    return " ".join(advice) if advice else _FALLBACK_ADVICE
