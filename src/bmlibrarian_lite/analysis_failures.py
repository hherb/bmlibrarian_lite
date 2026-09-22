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
- :func:`unreachable_source_caveat` says a source could not be read, so what
  it would have told us is not assessed rather than absent (#346).
  :func:`unreachable_lookups_clause` names the sources a full-text discovery
  could not ask, each once; :func:`no_pdf_sources_message`,
  :func:`paywall_message` and :func:`with_unestablished_access` are the three
  sentences that carry it to the reader, and none of them claims a licence
  that the lookup we could not make was the one to establish (#347).
- :func:`unassessed_caveat` is the one sentence shape all of these share --
  why something could not be checked, and that the result is therefore not a
  finding against the study. :func:`coi_not_assessed_caveat` builds the two
  conflict of interest reasons on it: no source that carries a disclosure was
  read, or the article's full text was not (#352).

None of these put the provider's own words on the screen: those can print the
request, credentials and all, and stay in the log (#330).

The wording follows the search contract in
``doc/cross_platform/search_failure_reporting.md``; this family's own contract
is ``doc/cross_platform/analysis_failure_reporting.md``.
"""

from collections import Counter
from collections.abc import Iterable, Sequence

from .data_models import (
    AnalysisShortfall,
    EvaluationErrorCode,
    PassFailure,
    RequestFailure,
    SourceLookupFailure,
)


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


def unreachable_source_caveat(
    service: str, failure: RequestFailure, sought: str
) -> str:
    """Say that a source could not be read, so what it holds is not assessed.

    A source that answered "nothing" and one we could not reach are opposite
    answers, and only the first is the article's fault (#186, #187, #346).
    Where the second cannot be told from the first, the reader is shown a
    property of the study that nobody ever established.

    The failure is rendered through :meth:`RequestFailure.describe`, which
    keeps only the kind and the HTTP status. The provider's own error text
    is never interpolated: since #196 it can carry the NCBI API key, and an
    Unpaywall URL carries the user's email address (#330).

    Args:
        service: The source that could not be read, named as the reader
            knows it, for example ``"Europe PMC"``.
        failure: Why it could not be read.
        sought: What was being looked for, substituted into "so ... could
            not be checked", for example ``"its data availability
            statement"``.

    Returns:
        Two sentences, ending in a full stop: what could not be read, and
        that the result is therefore not a finding against the study. The
        second says what *was* recorded rather than warning about an
        absence reported elsewhere -- a caller that raises this caveat
        records "not assessed", so there is no absence to discount.
    """
    return unassessed_caveat(
        f"{service} could not be read ({failure.describe()})", sought
    )


def unassessed_caveat(because: str, sought: str) -> str:
    """Say that something about a study was not established, and why.

    One sentence shape for every "not assessed" caveat, so that the reason a
    source went unread -- throttled, unparseable, or never consulted at all --
    cannot drift into reading like a finding in one place and a non-finding in
    another.

    Args:
        because: Why it could not be checked, as a capitalised clause that
            opens the sentence, for example ``"Europe PMC could not be read
            (HTTP 429)"``.
        sought: What was being looked for, substituted into "so ... could not
            be checked", for example ``"its data availability statement"``.

    Returns:
        Two sentences, ending in a full stop: why it could not be checked,
        and that the result is therefore not a finding against the study.
        The second says what *was* recorded rather than warning about an
        absence reported elsewhere -- a caller that raises this caveat
        records "not assessed", so there is no absence to discount.
    """
    return (
        f"{because}, so {sought} could not be checked. It is recorded as "
        f"not assessed, which is not a finding against the study."
    )


#: What the COI caveats say was not established, as the reader is told it.
#: One place, because every COI reason is completed by it -- the two below
#: and the unparsed-end-matter one in the analyzer -- and they must not drift.
COI_DISCLOSURE_SOUGHT = "this study's conflict of interest disclosure"


def coi_not_assessed_caveat(pubmed_record_read: bool) -> str:
    """Say that nothing carrying a COI statement was read for this study.

    A conflict of interest statement reaches the analysis from the article's
    own full text, or from the ``CoiStatement`` of a PubMed record. Neither
    having been read is not the study declaring no conflicts -- but that is
    what it was reported as, for every study, until #352.

    The two reasons are kept apart because they tell the reader different
    things about what to do next: a study whose full text we never obtained
    may still carry a disclosure in its PDF, and so may one whose publisher
    simply never deposited the statement with PubMed. Measured over samples
    of 2018 and 2024 records, PubMed carries a ``CoiStatement`` for 36.5%
    and 79.7% of articles respectively, so its silence is not the article's.

    Args:
        pubmed_record_read: Whether a PubMed record for this study was read.
            When it was, it held no conflict of interest statement.

    Returns:
        Two sentences, ending in a full stop.
    """
    if pubmed_record_read:
        because = (
            "The article's full text was not read, and the PubMed record "
            "carries no conflict of interest statement"
        )
    else:
        because = "Neither the article's full text nor a PubMed record was read"
    return unassessed_caveat(because, COI_DISCLOSURE_SOUGHT)


#: What a lookup we could not make leaves open, as the reader is told it.
#: One place, because three sentences end with it and they must not drift.
_ACCESS_NOT_ESTABLISHED = (
    "so a freely available copy may exist. Whether this document is open "
    "access was not established."
)


def unreachable_lookups_clause(failures: Sequence[SourceLookupFailure]) -> str:
    """Name the sources that could not be asked, each once.

    Two lookups against one throttled host are one thing to tell the reader.
    No caller records more than one failure per service today, so the
    reduction is defensive rather than load-bearing; it is done here so that
    a caller which starts recording per-attempt failures cannot make the
    sentence repeat itself.

    Where one service failed twice differently, the first failure is the one
    described: they are equally true, and naming both would spend the
    reader's attention on our retry policy rather than on the article.

    Args:
        failures: The lookups that could not be made; may be empty.

    Returns:
        For example ``"Unpaywall (HTTP 429 Too Many Requests)"``; several
        are joined by commas with a final "and". Empty when nothing failed.
    """
    seen: dict[str, str] = {}
    for failure in failures:
        seen.setdefault(failure.service, failure.failure.describe())
    clauses = [f"{service} ({reason})" for service, reason in seen.items()]
    if not clauses:
        return ""
    if len(clauses) == 1:
        return clauses[0]
    return f"{', '.join(clauses[:-1])} and {clauses[-1]}"


def unestablished_access_clause(failures: Sequence[SourceLookupFailure]) -> str:
    """Say which sources were never asked, and what that leaves open.

    Args:
        failures: The lookups that could not be made; may be empty.

    Returns:
        Two sentences ending in a full stop, or empty when every lookup was
        made. Never the bare denial "this is not evidence the document
        requires access": read on its own, that repeats the claim it means
        to withdraw.
    """
    if not failures:
        return ""
    return f"{unreachable_lookups_clause(failures)} could not be asked, {_ACCESS_NOT_ESTABLISHED}"


def with_unestablished_access(
    claim: str, failures: Sequence[SourceLookupFailure]
) -> str:
    """Add what was never asked to a claim that does not depend on it.

    For a claim about *our* attempts -- that no source we reached served a
    PDF -- which stays true whatever the unasked sources would have said.
    A claim about the document's access is not of that kind; see
    :func:`paywall_message`.

    Args:
        claim: The sentence to qualify, ending in a full stop.
        failures: The lookups that could not be made; may be empty.

    Returns:
        ``claim`` when every lookup was made, else ``claim`` followed by
        :func:`unestablished_access_clause`.
    """
    clause = unestablished_access_clause(failures)
    return f"{claim} {clause}" if clause else claim


def paywall_message(claim: str, failures: Sequence[SourceLookupFailure]) -> str:
    """Say a source refused access, without claiming the document is paywalled.

    A source that answers 401 or 403 establishes that *that* source wants
    payment, not that the document has no free copy elsewhere -- and the
    lookup we could not make is exactly the one that would have found it.
    So where a lookup failed the claim is withheld rather than stated and
    then retracted (#347).

    Args:
        claim: What to say when nothing failed: the wording of the source
            that refused, ending in a full stop. It is deliberately unused
            otherwise, because a claim about this document's access is
            precisely what cannot be stood behind then.
        failures: The lookups that could not be made; may be empty.

    Returns:
        One or two sentences for the reader, ending in a full stop.
    """
    if not failures:
        return claim
    return (
        f"A source refused access, but "
        f"{unreachable_lookups_clause(failures)} could not be asked, "
        f"{_ACCESS_NOT_ESTABLISHED}"
    )


def no_pdf_sources_message(failures: Sequence[SourceLookupFailure]) -> str:
    """Say why no full-text source was found, without overstating it.

    A lookup we could not make and an article with no open-access copy are
    opposite answers, and only the second is a fact about the article. Where
    a lookup failed, the sentence says so and stops short of the paywall
    claim, because a throttled Unpaywall knows nothing about the licence.

    Args:
        failures: The lookups that could not be made; may be empty.

    Returns:
        Two sentences for the reader, ending in a full stop.
    """
    if not failures:
        return (
            "No PDF sources found. The document may require institutional "
            "access."
        )
    return (
        f"No PDF sources found, but "
        f"{unreachable_lookups_clause(failures)} could not be asked, "
        f"{_ACCESS_NOT_ESTABLISHED}"
    )
