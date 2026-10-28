# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Smart search: alternative queries for a question its own query answers too little.

The rules are the apps' (iOS/macOS's ``executeSmartSearch``) and the
*Alternative queries* section of ``doc/cross_platform/search_failure_reporting.md``:

- The model is asked for two or three alternative queries, told of every one
  already run for the run (``smart_search_store``; the apps keep them on the
  session), each named by its concept names joined by AND. An answer holding
  no usable query, or only queries already run (or the question's own), is
  asked for again up to ``SMART_SEARCH_MAX_QUERY_RETRIES`` more times, each a
  paid call; the apps search a repeat again, the desktop never does. A
  request that failed, an answer the model declined, or an answer cut off at
  its token limit (asked again, it is likely cut off again, each time paid),
  stops the round; the complete queries a cut-off answer held before the
  limit (those not already run) are still searched. None of these is a source's failure, so none
  records a shortfall.
- Each query is searched with the configured provider. Once the round ends,
  a query is kept as run unless a source could not answer it and it found
  nothing new: a later round may ask it again. Kept at the end, so a round
  that breaks off keeps none, and the next may ask them again.
- What the queries lose is marked as an alternative search's. When the reader
  asked for more evidence and failures left the round with nothing new, the
  search failed: nothing it lost is kept, and :class:`SearchFailedError` is
  raised. When smart search is the review's own idea, the losses are kept.

Nothing here imports Qt.
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Callable, Collection, Sequence
from dataclasses import dataclass, replace
from typing import TYPE_CHECKING, Any, Protocol

from .analysis_failures import failure_cause_text
from .constants import SMART_SEARCH_MAX_QUERY_RETRIES
from .data_models import ShortfallQuery
from .exceptions import RefusedResponseError, SearchFailedError, TruncatedResponseError
from .llm.data_types import strip_unclosed_thinking
from .query_converter import MAX_TOTAL_QUERY_LENGTH, build_query_string
from .search_failures import combined_shortfalls, retrieval_shortfalls_from_metadata
from .smart_search_store import RunQuery
from .utils import classify_analysis_exception

if TYPE_CHECKING:
    from .data_models import LiteDocument, RetrievalShortfall, SearchSession
    from .storage import LiteStorage

logger = logging.getLogger(__name__)

# The apps' sentences (SmartSearchError, noNewEvidenceNotice)
NO_USABLE_QUERY_TEXT = (
    "The model's answers held no usable alternative search query, "
    "so no alternative search was run."
)
#: Followed by the cause and what to do about it
QUERY_GENERATION_FAILED_TEXT = (
    "Alternative searches could not be run: the model could not be asked for them."
)
#: The desktop's own: the apps search a repeated query again
ONLY_REPEATS_TEXT = (
    "The model proposed only alternative search queries already run, "
    "so no alternative search was run."
)
#: What to do about an answer cut off at its length limit
CUT_OFF_ADVICE_TEXT = (
    "A model that writes out its reasoning first can use up that limit; "
    "another Query Conversion model in Settings may help."
)
#: The desktop's own: a cut-off answer is likely cut off again, so it is not asked for again
ANSWER_CUT_OFF_TEXT = (
    "The model's answer was cut off at its length limit before it held a "
    "complete alternative search query not already run, so no alternative "
    f"search was run. {CUT_OFF_ADVICE_TEXT}"
)
#: Put before ANSWER_CUT_OFF_TEXT when an earlier answer held only repeats
EARLIER_REPEATS_TEXT = "Earlier, the model proposed only alternative search queries already run."
#: The desktop's own: asked again, the model likely declines again
ANSWER_REFUSED_TEXT = (
    "The model declined to propose alternative search queries, so no "
    "alternative search was run. Another Query Conversion model in Settings may answer."
)
NO_NEW_EVIDENCE_TEXT = (
    "The alternative searches found no documents beyond those already found. "
    "The report is unchanged."
)

# PromptTemplates.alternativeQueries, word for word
ALTERNATIVE_QUERIES_PROMPT = """The following medical question did not return enough relevant results with the initial search.

Question: {question}
Initial query: {initial_query}
Results found: {total_results}
Relevant documents: {relevant_count}
{tried_section}
Generate 2-3 alternative search strategies as structured queries. Consider:
1. If comparing two treatments/medications, search for each one separately
2. Use different synonyms or related terms
3. Break compound questions into simpler components
4. Try broader or narrower search terms
5. Focus on key outcomes or mechanisms

Return a JSON array of structured query objects. Each object should have:
- "concepts": an array of concepts, each with "name", "mesh_terms", and "keywords"

Example response:
[
  {{
    "concepts": [
      {{"name": "treatment A", "mesh_terms": ["MeSH Term A"], "keywords": ["keyword A"]}},
      {{"name": "condition", "mesh_terms": ["Condition MeSH"], "keywords": ["condition"]}}
    ]
  }},
  {{
    "concepts": [
      {{"name": "treatment B", "mesh_terms": ["MeSH Term B"], "keywords": ["keyword B"]}},
      {{"name": "condition", "mesh_terms": ["Condition MeSH"], "keywords": ["condition"]}}
    ]
  }}
]

Generate alternative structured queries for the medical question:"""


class SmartSearchError(Exception):
    """No alternative search ran; the message is the reader's."""


@dataclass(frozen=True)
class SmartSearchContext:
    """The run a round searches for, and what the prompt tells the model of its search so far.

    Attributes:
        question: The research question.
        initial_query: The question's own query.
        total_results: How many results it had.
        relevant_count: How many documents were found relevant.
        checkpoint_id: The run's checkpoint, which keeps the queries run.
    """

    question: str
    initial_query: str
    total_results: int
    relevant_count: int
    checkpoint_id: str


@dataclass(frozen=True)
class SmartSearchRound:
    """What one round of alternative queries found.

    Attributes:
        documents: The documents new to the question, stored and linked to it.
        queries: The query strings the round searched, in order, whether or
            not a source answered (a report lists every one it tried).
        shortfalls: What its queries lost, each marked as an alternative
            search's; empty when the reader asked and nothing new was found.
        stopped: Whether a stop ended it before every query ran.
        notice: The reader's sentence when the model's answer was cut off
            after the queries searched, so it may have proposed more; else None.
    """

    documents: tuple[LiteDocument, ...] = ()
    queries: tuple[str, ...] = ()
    shortfalls: tuple[RetrievalShortfall, ...] = ()
    stopped: bool = False
    notice: str | None = None


class SmartSearcher(Protocol):
    """What a round needs of the search agent."""

    def ask(self, prompt: str) -> str:
        """One answer from the query model.

        Raises:
            TruncatedResponseError: The answer reached its token limit;
                ``content`` carries what it wrote.
            RefusedResponseError: The model declined to answer.
        """
        ...

    def search_with_query(
        self,
        query_string: str,
        natural_language_query: str | None = None,
        max_results: int | None = None,
    ) -> tuple[SearchSession, list[LiteDocument]]:
        """Search, store the documents and link them to the question."""
        ...


def alternative_queries_prompt(context: SmartSearchContext, tried: Sequence[str]) -> str:
    """The request for alternative queries.

    Args:
        context: The question's search so far.
        tried: The labels of the queries already run, earlier rounds first.

    Returns:
        The prompt.
    """
    tried_section = ""
    if tried:
        lines = "\n".join(f"- {label}" for label in tried)
        tried_section = (
            "\nThese alternative queries were already run. Do not repeat them; "
            "take different approaches (broader terms, related conditions, "
            f"mechanisms or outcomes):\n{lines}\n"
        )
    return ALTERNATIVE_QUERIES_PROMPT.format(
        question=context.question,
        initial_query=context.initial_query or "N/A",
        total_results=context.total_results,
        relevant_count=context.relevant_count,
        tried_section=tried_section,
    )


def parse_alternative_queries(answer: str) -> list[RunQuery]:
    """The usable queries in the model's answer.

    Reads a JSON array of query objects, also inside a code fence, or an
    object holding one under any key, or a single query object. A query is
    usable when one of its concepts has a MeSH term or keyword and its query
    string is not too long; each query string is kept once.

    Args:
        answer: The model's answer, untrusted.

    Returns:
        The queries, each labelled by its concept names joined by AND; empty
        when none is usable.
    """
    return _queries_from(_loads(answer))


def cut_off_alternative_queries(answer: str) -> list[RunQuery]:
    """The usable queries an answer cut off at its token limit completed.

    The whole answer is read first, as :func:`parse_alternative_queries`
    reads it; otherwise each complete value after the answer's first
    ``[``, in order, up to the one the limit broke off or the array's end.

    Args:
        answer: What the model wrote before the limit, untrusted.

    Returns:
        The queries; empty when none was complete and usable.
    """
    answer = strip_unclosed_thinking(answer)
    return parse_alternative_queries(answer) or _queries_from(_complete_items(answer))


def _queries_from(data: Any) -> list[RunQuery]:
    """The usable queries in a parsed answer (see :func:`parse_alternative_queries`)."""
    if isinstance(data, dict):
        lists = [v for v in data.values() if isinstance(v, list)]
        items: list[Any] = lists[0] if "concepts" not in data and lists else [data]
    elif isinstance(data, list):
        items = data
    else:
        return []
    queries: list[RunQuery] = []
    for item in items:
        concepts = item.get("concepts") if isinstance(item, dict) else None
        if not isinstance(concepts, list):
            continue
        usable = [
            c for c in concepts
            if isinstance(c, dict)
            and _strings(c.get("mesh_terms")) + _strings(c.get("keywords"))
        ]
        if not usable:
            continue
        cleaned: list[dict[str, Any]] = [
            {
                "name": str(c.get("name") or "").strip(),
                "mesh_terms": _strings(c.get("mesh_terms")),
                "keywords": _strings(c.get("keywords")),
            }
            for c in usable
        ]
        query = build_query_string({"concepts": cleaned})
        if not query or len(query) > MAX_TOTAL_QUERY_LENGTH:
            continue
        if any(q.query == query for q in queries):
            continue
        label = " AND ".join(c["name"] for c in cleaned if c["name"]) or query
        queries.append(RunQuery(label=label, query=query))
    return queries


def generate_alternative_queries(
    searcher: SmartSearcher,
    prompt: str,
    should_stop: Callable[[], bool],
    run_before: Collection[str] = (),
) -> tuple[list[RunQuery], str | None]:
    """Ask the model for alternative queries, asking again for an answer with none new.

    Args:
        searcher: Asks the model.
        prompt: The request.
        should_stop: Asked before each request.
        run_before: Query strings already run; never searched again.

    Returns:
        The new queries, empty only when a stop came first; and the reader's
        sentence when they are the complete ones of an answer cut off at its
        token limit (#637), else None.

    Raises:
        SmartSearchError: The request to the model failed, the model
            declined, an answer was cut off at its token limit before a
            usable query not already run, or no answer held one.
    """
    only_repeats = False
    for _attempt in range(SMART_SEARCH_MAX_QUERY_RETRIES + 1):
        if should_stop():
            return [], None
        try:
            answer = searcher.ask(prompt)
        except TruncatedResponseError as e:
            logger.warning("%s", e)  # our own text, never the provider's
            queries = [q for q in cut_off_alternative_queries(e.content) if q.query not in run_before]
            if queries:
                return queries, cut_off_queries_notice(len(queries))
            text = f"{EARLIER_REPEATS_TEXT} {ANSWER_CUT_OFF_TEXT}" if only_repeats else ANSWER_CUT_OFF_TEXT
            raise SmartSearchError(text) from e
        except RefusedResponseError as e:
            logger.warning("%s", e)
            raise SmartSearchError(ANSWER_REFUSED_TEXT) from e
        except Exception as e:
            # the type only: provider text can carry a credential (#330)
            logger.warning("Alternative queries could not be asked for (%s)", type(e).__name__)
            cause = failure_cause_text(classify_analysis_exception(e))
            raise SmartSearchError(f"{QUERY_GENERATION_FAILED_TEXT} {cause}") from e
        usable = parse_alternative_queries(answer)
        queries = [q for q in usable if q.query not in run_before]
        if queries:
            return queries, None
        only_repeats = only_repeats or bool(usable)
        logger.warning("The model's answer held no usable alternative query not already run")
    raise SmartSearchError(ONLY_REPEATS_TEXT if only_repeats else NO_USABLE_QUERY_TEXT)


def cut_off_queries_notice(count: int) -> str:
    """The reader's sentence for a cut-off answer whose complete queries were searched.

    Args:
        count: How many complete queries not already run it held.

    Returns:
        That the model may have proposed more, and what to do about it.
    """
    held = "1 complete alternative search query" if count == 1 else (
        f"{count} complete alternative search queries")
    return (
        f"The model's answer was cut off at its length limit after {held} "
        f"not already run; only those were searched. {CUT_OFF_ADVICE_TEXT}"
    )


def run_smart_search(
    searcher: SmartSearcher,
    storage: LiteStorage,
    context: SmartSearchContext,
    known_ids: Collection[str],
    *,
    asked: bool,
    max_results: int,
    should_stop: Callable[[], bool],
    progress: Callable[[str], None] | None = None,
) -> SmartSearchRound:
    """Run one round of alternative queries for a question.

    Args:
        searcher: Asks the model and searches.
        storage: Keeps the queries run.
        context: The question's search so far.
        known_ids: The documents already found; only others count as new.
        asked: Whether the reader asked for more evidence, rather than the
            review running smart search on its own.
        max_results: How many results each query fetches.
        should_stop: Asked before each request; true stops the round.
        progress: Told what the round is doing.

    Returns:
        What the round found.

    Raises:
        SmartSearchError: No usable query not already run, an answer cut off
            at its token limit, or the model could not be asked.
        SearchFailedError: The reader asked, and failures left the round with
            nothing new, a stop or not (a cancel does not excuse reporting them).
    """
    tell = progress or (lambda _message: None)
    tried = storage.get_smart_search_queries(context.checkpoint_id)
    tell("Generating alternative search strategies...")
    alternatives, notice = generate_alternative_queries(
        searcher,
        alternative_queries_prompt(context, [t.label for t in tried]),
        should_stop,
        {t.query for t in tried} | {context.initial_query},
    )
    if should_stop() or not alternatives:
        return SmartSearchRound(stopped=True)

    seen = set(known_ids)
    found: list[LiteDocument] = []
    lost: list[RetrievalShortfall] = []
    ran: list[str] = []
    completed: list[RunQuery] = []
    stopped = False
    for index, alternative in enumerate(alternatives, start=1):
        if should_stop():
            stopped = True
            break
        tell(f"Smart search {index}/{len(alternatives)}: {alternative.label}...")
        try:
            session, documents = searcher.search_with_query(
                alternative.query,
                natural_language_query=context.question,
                max_results=max_results,
            )
            losses = retrieval_shortfalls_from_metadata(session.metadata)
        except SearchFailedError as e:
            # One query failing does not end the round
            documents, losses = [], list(e.shortfalls)
        new = [d for d in documents if d.id not in seen]
        seen.update(d.id for d in new)
        found.extend(new)
        lost.extend(replace(s, query=ShortfallQuery.ALTERNATIVE) for s in losses)
        ran.append(alternative.query)
        # A query a source could not answer has not run: a later round may ask it again
        if new or not losses:
            completed.append(alternative)

    for alternative in completed:
        storage.record_smart_search_query(context.checkpoint_id, alternative)
    shortfalls = combined_shortfalls(lost)
    if asked and not found:
        if shortfalls:
            raise SearchFailedError(shortfalls)
        # A request for more evidence that found nothing keeps nothing
        shortfalls = []
    return SmartSearchRound(tuple(found), tuple(ran), tuple(shortfalls), stopped, notice)


def _strings(value: object) -> list[str]:
    """The non-empty strings of a list, stripped; nothing for anything else."""
    if not isinstance(value, list):
        return []
    return [s.strip() for s in value if isinstance(s, str) and s.strip()]


def _complete_items(answer: str) -> list[Any]:
    """Each complete value in the first JSON array of an answer cut off part-way."""
    start = answer.find("[")
    if start < 0:
        return []
    decoder = json.JSONDecoder()
    items: list[Any] = []
    pos = start + 1
    while True:
        while pos < len(answer) and answer[pos] in " \t\r\n,":
            pos += 1
        try:
            item, pos = decoder.raw_decode(answer, pos)
        except json.JSONDecodeError:
            return items
        items.append(item)


def _loads(answer: str) -> Any:
    """The JSON in an answer: whole, in a code fence, or the outermost brackets."""
    if not answer or not answer.strip():
        return None
    candidates = [answer]
    fence = re.search(r"```(?:json)?\s*\n?(.*?)\n?```", answer, re.DOTALL)
    if fence:
        candidates.append(fence.group(1))
    for pattern in (r"\[.*\]", r"\{.*\}"):
        match = re.search(pattern, answer, re.DOTALL)
        if match:
            candidates.append(match.group(0))
    for candidate in candidates:
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue
    return None
