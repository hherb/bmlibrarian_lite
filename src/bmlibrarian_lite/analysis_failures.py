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
lost and why, and :class:`~bmlibrarian_lite.data_models.PassFailure` records
the same for one document of a re-classification or re-scoring; the functions
here turn either record into what a reader sees.

- :func:`describe_analysis_shortfalls`, :func:`format_analysis_shortfall_notice`
  and :func:`with_analysis_shortfall_notice` and
  :func:`without_analysis_shortfall_notice` turn shortfalls into what the
  report, the GUI and MCP callers see.
- :func:`advice_for_causes` says what the user can do about a set of causes,
  and is the one place that decides it. :func:`analysis_failure_advice` is
  its shortfall-shaped caller; a per-document failure reaches it through
  :func:`pass_failure_detail`, so the two cannot advise differently.
- :func:`pass_failure_detail` says what a pass's failures mostly were, with
  one example and the advice; :func:`unclassified_text` says what became of
  the documents the model named no study design for, which is not a failure;
  :func:`failure_cause_text` says what ended a whole pass.
- :func:`also_failed_text` names an error that ended a run alongside
  something else -- a cancel. It takes a bare error rather than a shortfall:
  cancelling is not failing, but a failure is never hidden (golden rule 8).

None of these put the provider's own words on the screen: those can print the
request, credentials and all, and stay in the log (#330).

The wording follows the search contract in
``doc/cross_platform/search_failure_reporting.md``; this family's own contract
is ``doc/cross_platform/analysis_failure_reporting.md``.
"""

from collections import Counter
from collections.abc import Iterable, Sequence

from .data_models import AnalysisShortfall, EvaluationErrorCode, PassFailure


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
    return advice_for_causes(
        cause for shortfall in shortfalls for cause in shortfall.causes
    )


def advice_for_causes(causes: Iterable[EvaluationErrorCode]) -> str:
    """Say what the user can do about a set of failures.

    The advice a reader can act on comes from the causes alone, so a failure
    recorded as a shortfall and one recorded per document (:class:`PassFailure`)
    get the same sentences from the same place.

    Args:
        causes: Why documents failed, in any order, repeats allowed.

    Returns:
        One or more sentences, each at most once, in this order: checking a
        refused API key; waiting out a rate limit; checking the provider is
        reachable; trying another model. Otherwise, trying again later.
    """
    seen = set(causes)
    advice: list[str] = []
    if EvaluationErrorCode.API_AUTH_ERROR in seen:
        advice.append(_AUTH_ADVICE)
    if EvaluationErrorCode.API_RATE_LIMIT in seen:
        advice.append(_RATE_LIMIT_ADVICE)
    if seen.intersection(_UNREACHABLE_CAUSES):
        advice.append(_UNREACHABLE_ADVICE)
    if seen.intersection(_UNREADABLE_CAUSES):
        advice.append(_UNREADABLE_ADVICE)
    return " ".join(advice) if advice else _FALLBACK_ADVICE


def also_failed_text(error: str) -> str:
    """What a cancelled run adds when an error ended it too.

    Args:
        error: The error that ended the run, or an empty string.

    Returns:
        A sentence naming the error, or "" when nothing went wrong. A cancel
        is not a licence to hide a failure (golden rule 8): without this, a
        crash mid-cancel read as an orderly stop (#320).
    """
    return f" It also stopped on an error: {error}" if error else ""


def pass_failure_detail(failures: Sequence[PassFailure]) -> str:
    """Say what a pass's failures mostly were, with one example and what to do.

    A count alone -- "17 documents failed classification" -- lumps together an
    unreachable provider, a refused key, a rate limit, a storage error and an
    abstract the model choked on. The first is one line of fix and the last is
    an afternoon, and the user could not tell which they had (#327).

    The provider's own text is not here. It can carry the request, and with it
    a credential (#330); the classified cause is what the user can act on, and
    the raw text stays in the log.

    Args:
        failures: What the pass could not finish, in the order it happened.

    Returns:
        A sentence naming the cause most of them shared, an example document
        and the advice for every cause among them; or ``""`` when nothing
        failed, so a clean pass never reads as a qualified one.
    """
    if not failures:
        return ""
    counts = Counter(failure.cause for failure in failures)
    # Counter preserves first-seen order among ties, so the same failures in
    # the same order always name the same cause
    cause, count = counts.most_common(1)[0]
    example = next(
        failure.document_id for failure in failures if failure.cause is cause
    )
    total = len(failures)
    if total == 1:
        lead, where = "The failure was:", example
    elif count == total:
        lead, where = f"All {total:,} failures were:", f"first: {example}"
    else:
        lead, where = f"Most failures ({count:,} of {total:,}) were:", f"first: {example}"
    return f"{lead} {cause.description} ({where}). {advice_for_causes(counts)}"


def failure_cause_text(cause: EvaluationErrorCode) -> str:
    """What ended a pass, in the reader's words, with what to do about it.

    :func:`pass_failure_detail` keeps the provider's own text off the screen
    for the documents a pass could not finish. A failure that ends the whole
    pass reached the screen by another door: the worker emitted ``str(e)``
    and the dialog printed it, so an ``httpx`` error that echoes the request
    put the API key in a box the user can screenshot (#330). This is what is
    shown instead; the raw text stays in the log.

    Args:
        cause: What went wrong, classified.

    Returns:
        The cause as the user reads it, followed by what they can do. The
        descriptions are written as sentence fragments, without a full stop,
        because :func:`pass_failure_detail` puts them before a parenthetical;
        standing alone here, one needs its own.
    """
    return f"{cause.description.rstrip('.')}. {advice_for_causes((cause,))}"


def unclassified_text(unclassified: int) -> str:
    """What a re-classification adds for documents the model named no design for.

    Nothing went wrong for these: the model read the document and would not
    say what kind of study it is. Counted among the failures, they turned a
    pass in which nothing broke into "6 documents failed classification"
    (#327).

    Args:
        unclassified: How many documents the model named no design for.

    Returns:
        A sentence, or ``""`` when the model named a design for every document
        it answered about.
    """
    if unclassified <= 0:
        return ""
    if unclassified == 1:
        return (
            " The model named no study design for 1 document; "
            "its stored design is unchanged."
        )
    return (
        f" The model named no study design for {unclassified:,} documents; "
        "their stored designs are unchanged."
    )
