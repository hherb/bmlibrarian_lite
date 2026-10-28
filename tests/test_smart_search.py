# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Smart search: alternative queries, as on the apps.

The rules are ``doc/cross_platform/search_failure_reporting.md``'s
*Alternative queries* and iOS/macOS's ``executeSmartSearch``.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest
from bmlib.publications.retraction_status import RetractionStatus, RetractionVerdict

from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.agents.search_agent import LiteSearchAgent
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    DocumentSource,
    LiteDocument,
    ReportMetadata,
    RequestFailure,
    RequestFailureKind,
    RetrievalShortfall,
    SearchProvider,
    SearchSession,
    ShortfallQuery,
)
from bmlibrarian_lite.exceptions import (
    RefusedResponseError,
    SearchFailedError,
    TruncatedResponseError,
)
from bmlibrarian_lite.llm import LLMResponse
from bmlibrarian_lite.llm.data_types import STOP_REASON_MAX_TOKENS
from bmlibrarian_lite.retraction_screen import (
    RetractionSnapshot,
    merged_screen,
    screen_documents,
    unchecked_check,
)
from bmlibrarian_lite.retraction_store import PaperCheck
from bmlibrarian_lite.retraction_text import (
    checked_on_line,
    retraction_methods_line,
    run_summary_clause,
)
from bmlibrarian_lite.search_failures import (
    combined_shortfalls,
    retrieval_shortfalls_to_metadata,
)
from bmlibrarian_lite.smart_search import (
    ANSWER_CUT_OFF_TEXT,
    ANSWER_REFUSED_TEXT,
    CUT_OFF_ADVICE_TEXT,
    EARLIER_REPEATS_TEXT,
    NO_USABLE_QUERY_TEXT,
    ONLY_REPEATS_TEXT,
    QUERY_GENERATION_FAILED_TEXT,
    SmartSearchContext,
    SmartSearchError,
    alternative_queries_prompt,
    cut_off_queries_notice,
    generate_alternative_queries,
    parse_alternative_queries,
    run_smart_search,
)
from bmlibrarian_lite.smart_search_store import RunQuery
from bmlibrarian_lite.storage import LiteStorage

QUESTION = "Is drug A better than drug B for migraine?"
RUN = "checkpoint-1"
CONTEXT = SmartSearchContext(
    question=QUESTION, initial_query="(migraine[tiab])", total_results=12, relevant_count=1,
    checkpoint_id=RUN,
)
TIMEOUT = RequestFailure(RequestFailureKind.TIMEOUT)


def answer(*queries: list[tuple[str, list[str]]]) -> str:
    """A model answer: each query a list of (name, keywords) concepts."""
    return json.dumps([
        {"concepts": [{"name": n, "mesh_terms": [], "keywords": k} for n, k in q]}
        for q in queries
    ])


def document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"pmid-{pmid}", title=f"Trial {pmid}", abstract="Abstract.",
        pmid=pmid, source=DocumentSource.PUBMED,
    )


def session(shortfalls: list[RetrievalShortfall] | None = None) -> SearchSession:
    """A search session, its metadata holding what it lost."""
    metadata: dict[str, Any] = {"provider": "pubmed"}
    if shortfalls:
        metadata.update(retrieval_shortfalls_to_metadata(shortfalls))
    return SearchSession(
        id="s", query="q", natural_language_query=QUESTION,
        created_at=datetime.now(UTC), document_count=0, metadata=metadata,
    )


class Searcher:
    """A search agent whose answers and searches are scripted."""

    def __init__(self, answers: list[Any], results: dict[str, Any] | None = None) -> None:
        """Answers in order (a string, or an exception to raise); results by query string."""
        self.answers = list(answers)
        self.results = results or {}
        self.prompts: list[str] = []
        self.searched: list[str] = []

    def ask(self, prompt: str) -> str:
        """Answer one request."""
        self.prompts.append(prompt)
        reply = self.answers.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply

    def search_with_query(self, query_string: str, natural_language_query: str | None = None,
                          max_results: int | None = None) -> tuple[SearchSession, list[LiteDocument]]:
        """Search one query: documents, a shortfall list, or an exception."""
        self.searched.append(query_string)
        result = self.results.get(query_string, [])
        if isinstance(result, Exception):
            raise result
        if result and isinstance(result[0], RetrievalShortfall):
            return session(result), []
        return session(), list(result)


@pytest.fixture
def storage(tmp_path: Path) -> LiteStorage:
    """A database this test owns."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def query_of(*concepts: tuple[str, list[str]]) -> str:
    """The query string a parsed answer gives."""
    return parse_alternative_queries(answer(list(concepts)))[0].query


class TestThePrompt:
    """The apps' prompt, word for word."""

    def test_the_first_round_names_no_earlier_query(self) -> None:
        """No "already run" section, and the search so far."""
        prompt = alternative_queries_prompt(CONTEXT, [])

        assert "already run" not in prompt
        assert f"Question: {QUESTION}\nInitial query: (migraine[tiab])\n" in prompt
        assert "Results found: 12\nRelevant documents: 1\n\nGenerate 2-3" in prompt

    def test_a_later_round_names_every_query_run(self) -> None:
        """Each as its concept names joined by AND."""
        prompt = alternative_queries_prompt(CONTEXT, ["drug A AND migraine", "drug B"])

        assert (
            "Relevant documents: 1\n\nThese alternative queries were already run. Do not "
            "repeat them; take different approaches (broader terms, related conditions, "
            "mechanisms or outcomes):\n- drug A AND migraine\n- drug B\n\nGenerate 2-3"
        ) in prompt

    def test_no_initial_query_reads_n_a(self) -> None:
        """As on the apps."""
        context = SmartSearchContext(QUESTION, "", 0, 0, RUN)
        assert "Initial query: N/A\n" in alternative_queries_prompt(context, [])


class TestTheAnswer:
    """What of the model's answer is a query."""

    def test_an_array_gives_a_query_each(self) -> None:
        """Labelled by the concept names, built as the converter builds."""
        queries = parse_alternative_queries(
            answer([("drug A", ["drug A"]), ("migraine", ["migraine"])], [("drug B", ["drug B"])])
        )

        assert [q.label for q in queries] == ["drug A AND migraine", "drug B"]
        assert queries[0].query == (
            '(("drug A"[tiab]) AND (migraine[tiab])) AND humans[mh] AND hasabstract'
        )

    @pytest.mark.parametrize("wrap", [
        lambda a: f"Here you are:\n```json\n{a}\n```",
        lambda a: json.dumps({"queries": json.loads(a)}),
        lambda a: json.dumps(json.loads(a)[0]),
    ], ids=["fenced", "wrapped", "single"])
    def test_a_wrapped_answer_is_read(self, wrap: Any) -> None:
        """A code fence, an object holding the list, or one query alone."""
        queries = parse_alternative_queries(wrap(answer([("drug A", ["drug A"])])))
        assert [q.label for q in queries] == ["drug A"]

    @pytest.mark.parametrize("reply", [
        "", "no idea", "[]", "{}", '[{"concepts": []}]',
        '[{"concepts": [{"name": "x", "mesh_terms": [], "keywords": []}]}]',
        '[{"concepts": [{"name": "x", "keywords": [3, ""]}]}]', '["drug A"]',
    ])
    def test_an_answer_without_a_term_holds_no_query(self, reply: str) -> None:
        """Nothing to search by is no query."""
        assert parse_alternative_queries(reply) == []

    def test_a_query_given_twice_is_kept_once(self) -> None:
        """The same query string."""
        queries = parse_alternative_queries(
            answer([("drug A", ["drug A"])], [("A again", ["drug A"])])
        )
        assert len(queries) == 1

    def test_a_query_too_long_for_pubmed_is_dropped(self) -> None:
        """As the converter refuses one."""
        long = [(f"c{i}", [f"keyword{i}x" * 10]) for i in range(30)]
        assert parse_alternative_queries(answer(long, [("drug A", ["drug A"])])) == [
            RunQuery("drug A", query_of(("drug A", ["drug A"])))
        ]


class TestTheAgentsAnswer:
    """``LiteSearchAgent.ask`` refuses an answer cut off at its token limit."""

    @pytest.mark.parametrize(("stop_reason", "cut_off"), [
        (STOP_REASON_MAX_TOKENS, True), ("end_turn", False), (None, False),
    ])
    def test_a_cut_off_answer_is_refused(self, stop_reason: str | None, cut_off: bool) -> None:
        """Its half a JSON array is never parsed as "no usable query"."""
        agent = LiteSearchAgent.__new__(LiteSearchAgent)
        agent._chat_response = lambda *_a, **_k: LLMResponse(  # type: ignore[method-assign]
            content="[{", stop_reason=stop_reason)

        if cut_off:
            with pytest.raises(TruncatedResponseError):
                agent.ask("p")
        else:
            assert agent.ask("p") == "[{"


class TestAskingForThem:
    """An unusable answer is asked for again; a failed request ends the round."""

    def test_an_unusable_answer_is_asked_for_twice_more(self) -> None:
        """Three paid calls in all, then none, and says why."""
        searcher = Searcher(["no", "[]", "{}", answer([("x", ["x"])])])

        with pytest.raises(SmartSearchError) as raised:
            generate_alternative_queries(searcher, "p", lambda: False)
        assert str(raised.value) == NO_USABLE_QUERY_TEXT
        assert len(searcher.prompts) == 3

    def test_an_answer_of_queries_already_run_is_asked_for_again(self) -> None:
        """A repeat is no query: asked again, and a new one is taken."""
        searcher = Searcher([answer([("x", ["x"])]), answer([("x", ["x"])], [("y", ["y"])])])

        queries, notice = generate_alternative_queries(
            searcher, "p", lambda: False, {query_of(("x", ["x"]))})

        assert [q.label for q in queries] == ["y"]
        assert notice is None
        assert len(searcher.prompts) == 2

    def test_only_repeats_are_said_to_be_repeats(self) -> None:
        """Not "no usable query": the answers were usable."""
        searcher = Searcher([answer([("x", ["x"])])] * 2 + ["[]"])

        with pytest.raises(SmartSearchError) as raised:
            generate_alternative_queries(searcher, "p", lambda: False, {query_of(("x", ["x"]))})
        assert str(raised.value) == ONLY_REPEATS_TEXT

    def test_a_usable_answer_ends_the_asking(self) -> None:
        """The first one usable."""
        searcher = Searcher(["no", answer([("x", ["x"])])])

        assert [q.label for q in generate_alternative_queries(searcher, "p", lambda: False)[0]] == ["x"]
        assert len(searcher.prompts) == 2

    def test_a_failed_request_says_why_and_what_to_do(self) -> None:
        """Its classified cause, never the provider's own words (#330)."""
        searcher = Searcher([ConnectionError("key sk-secret refused")])

        with pytest.raises(SmartSearchError) as raised:
            generate_alternative_queries(searcher, "p", lambda: False)
        text = str(raised.value)
        assert text.startswith(QUERY_GENERATION_FAILED_TEXT + " ")
        assert len(text) > len(QUERY_GENERATION_FAILED_TEXT) + 1
        assert "sk-secret" not in text

    def test_a_cut_off_answer_is_not_asked_for_again(self) -> None:
        """Asked again with the same limit it is cut off again: one paid call, and says so."""
        searcher = Searcher([TruncatedResponseError("limit"), answer([("x", ["x"])])])

        with pytest.raises(SmartSearchError) as raised:
            generate_alternative_queries(searcher, "p", lambda: False)
        assert str(raised.value) == ANSWER_CUT_OFF_TEXT
        assert len(searcher.prompts) == 1

    def test_a_cut_off_answers_complete_queries_are_searched(self) -> None:
        """#631 item 2: the queries finished before the limit are used, the broken one never."""
        whole = answer([("x", ["x"])], [("y", ["y"])])
        searcher = Searcher([TruncatedResponseError("limit", content=whole[:-1] + ', {"concepts": [{"na')])

        queries, notice = generate_alternative_queries(searcher, "p", lambda: False, {query_of(("x", ["x"]))})
        assert [q.label for q in queries] == ["y"]
        assert notice == cut_off_queries_notice(1)
        assert len(searcher.prompts) == 1

    @pytest.mark.parametrize("content", [
        json.dumps(json.loads(answer([("x", ["x"])]))[0]),
        f"```json\n{answer([('x', ['x'])])}\n```",
        '{"queries": ' + answer([("x", ["x"])])[:-1] + ', {"conc',
    ], ids=["single-object", "fenced", "cut-off-wrapper"])
    def test_a_cut_off_answer_read_whole_or_wrapped_is_searched(self, content: str) -> None:
        """An answer that completed at the limit is read as a whole one; a wrapper's array as its own."""
        searcher = Searcher([TruncatedResponseError("limit", content=content)])

        assert [q.label for q in generate_alternative_queries(searcher, "p", lambda: False)[0]] == ["x"]

    @pytest.mark.parametrize("content", [
        "", '[{"concepts": [{"name": "x", "keywords": ["x','{"concepts": [{"name": "x", "keywords": ["x"]}, {"na',
        '<think>[{"concepts": [{"name": "x", "keywords": ["x"]}]}, ',
    ])
    def test_a_cut_off_answer_with_no_complete_query_is_not_searched(self, content: str) -> None:
        """Half a query, a concept outside its query, or reasoning never closed is no query."""
        searcher = Searcher([TruncatedResponseError("limit", content=content)])

        with pytest.raises(SmartSearchError) as raised:
            generate_alternative_queries(searcher, "p", lambda: False)
        assert str(raised.value) == ANSWER_CUT_OFF_TEXT

    def test_a_cut_off_answer_of_repeats_says_it_held_none_not_run(self) -> None:
        """Its complete queries were all run already: cut off before one that was not."""
        searcher = Searcher([TruncatedResponseError("limit", content=answer([("x", ["x"])])[:-1] + ", {")])

        with pytest.raises(SmartSearchError) as raised:
            generate_alternative_queries(searcher, "p", lambda: False, {query_of(("x", ["x"]))})
        assert str(raised.value) == ANSWER_CUT_OFF_TEXT

    def test_a_cut_off_answer_after_repeats_is_still_searched(self) -> None:
        """An earlier answer of repeats does not lose the next one's complete queries."""
        searcher = Searcher([
            answer([("x", ["x"])]),
            TruncatedResponseError("limit", content=answer([("y", ["y"])])[:-1] + ", {"),
        ])

        queries, notice = generate_alternative_queries(searcher, "p", lambda: False, {query_of(("x", ["x"]))})
        assert [q.label for q in queries] == ["y"]
        assert notice == cut_off_queries_notice(1)

    def test_a_cut_off_answer_after_repeats_says_both(self) -> None:
        """#631 item 5: the earlier answer's repeats are not left out."""
        searcher = Searcher([answer([("x", ["x"])]), TruncatedResponseError("limit")])

        with pytest.raises(SmartSearchError) as raised:
            generate_alternative_queries(searcher, "p", lambda: False, {query_of(("x", ["x"]))})
        assert str(raised.value) == f"{EARLIER_REPEATS_TEXT} {ANSWER_CUT_OFF_TEXT}"

    def test_a_declined_answer_is_not_asked_for_again(self) -> None:
        """#631 item 3: asked again, the model likely declines again."""
        searcher = Searcher([RefusedResponseError("declined"), answer([("x", ["x"])])])

        with pytest.raises(SmartSearchError) as raised:
            generate_alternative_queries(searcher, "p", lambda: False)
        assert str(raised.value) == ANSWER_REFUSED_TEXT
        assert len(searcher.prompts) == 1

    def test_a_stop_asks_nothing(self) -> None:
        """Not even once."""
        searcher = Searcher([])
        assert generate_alternative_queries(searcher, "p", lambda: True) == ([], None)

    @pytest.mark.parametrize(("count", "held"), [
        (1, "after 1 complete alternative search query not"),
        (2, "after 2 complete alternative search queries not"),
    ])
    def test_a_cut_off_answers_notice_counts_its_queries(self, count: int, held: str) -> None:
        """#637 item 2: the reader is told the model may have proposed more, and what to do."""
        notice = cut_off_queries_notice(count)

        assert held in notice
        assert notice.endswith(CUT_OFF_ADVICE_TEXT)


A = [("drug A", ["drug A"])]
B = [("drug B", ["drug B"])]


def run(searcher: Searcher, storage: LiteStorage, *, asked: bool = True,
        known: frozenset[str] = frozenset()) -> Any:
    """One round with the scripted searcher."""
    return run_smart_search(searcher, storage, CONTEXT, known, asked=asked, max_results=10,
                            should_stop=lambda: False)


class TestARound:
    """Each query searched; what is new kept; what ran remembered."""

    def test_new_documents_are_kept_and_the_queries_remembered(
        self, storage: LiteStorage
    ) -> None:
        """A document already found, or found twice, counts once or not at all."""
        qa, qb = query_of(*A), query_of(*B)
        searcher = Searcher([answer(A, B)], {
            qa: [document("1"), document("2")], qb: [document("2"), document("3")]})

        round_ = run(searcher, storage, known=frozenset({"pmid-1"}))

        assert [d.id for d in round_.documents] == ["pmid-2", "pmid-3"]
        assert round_.queries == (qa, qb)
        assert round_.shortfalls == ()
        assert storage.get_smart_search_queries(RUN) == [
            RunQuery("drug A", qa), RunQuery("drug B", qb)]

    def test_a_cut_off_answers_queries_carry_its_notice(self, storage: LiteStorage) -> None:
        """#637 item 2: the round's queries ran, and the reader learns more may have been proposed."""
        qa = query_of(*A)
        searcher = Searcher([TruncatedResponseError("limit", content=answer(A)[:-1] + ", {")],
                            {qa: [document("1")]})

        round_ = run(searcher, storage)

        assert round_.queries == (qa,)
        assert round_.notice == cut_off_queries_notice(1)
        assert run(Searcher([answer(B)]), storage).notice is None

    def test_the_next_round_is_told_of_them_and_never_repeats_one(
        self, storage: LiteStorage
    ) -> None:
        """Named in the prompt; one the model repeats anyway is not searched again."""
        qa, qb = query_of(*A), query_of(*B)
        run(Searcher([answer(A)], {qa: [document("1")]}), storage)
        searcher = Searcher([answer(A, B)], {qb: [document("2")]})

        round_ = run(searcher, storage)

        assert "- drug A\n" in searcher.prompts[0]
        assert searcher.searched == [qb]
        assert round_.queries == (qb,)

    def test_the_questions_own_query_is_not_searched_again(self, storage: LiteStorage) -> None:
        """It is the initial query: asked for again, and said to be a repeat."""
        context = SmartSearchContext(QUESTION, query_of(*A), 1, 0, RUN)
        searcher = Searcher([answer(A)] * 3)

        with pytest.raises(SmartSearchError) as raised:
            run_smart_search(searcher, storage, context, (), asked=True, max_results=10,
                             should_stop=lambda: False)
        assert str(raised.value) == ONLY_REPEATS_TEXT
        assert searcher.searched == []

    def test_another_runs_queries_are_not_this_runs(self, storage: LiteStorage) -> None:
        """Kept per run, as the apps keep them on the session: a new review starts afresh."""
        qa = query_of(*A)
        run(Searcher([answer(A)], {qa: [document("1")]}), storage)
        other = SmartSearchContext(QUESTION, "(migraine[tiab])", 12, 1, "checkpoint-2")
        searcher = Searcher([answer(A)], {qa: [document("1")]})

        round_ = run_smart_search(searcher, storage, other, (), asked=True, max_results=10,
                                  should_stop=lambda: False)

        assert "already run" not in searcher.prompts[0]
        assert searcher.searched == [qa] and round_.queries == (qa,)

    def test_no_usable_query_runs_no_search(self, storage: LiteStorage) -> None:
        """And says why."""
        with pytest.raises(SmartSearchError) as raised:
            run(Searcher(["[]", "[]", "[]"]), storage)
        assert str(raised.value) == NO_USABLE_QUERY_TEXT

    def test_a_query_a_source_could_not_answer_has_not_run(self, storage: LiteStorage) -> None:
        """A later round may ask it again; one that found something has run."""
        qa, qb = query_of(*A), query_of(*B)
        lost = RetrievalShortfall(SearchProvider.PUBMED, TIMEOUT)
        searcher = Searcher([answer(A, B)], {qa: SearchFailedError([lost]), qb: [document("2")]})

        round_ = run(searcher, storage)

        assert round_.queries == (qa, qb)  # the report lists every query searched
        assert [r.query for r in storage.get_smart_search_queries(RUN)] == [qb]
        assert round_.shortfalls == (
            RetrievalShortfall(SearchProvider.PUBMED, TIMEOUT, query=ShortfallQuery.ALTERNATIVE),)

    def test_asked_for_and_left_with_nothing_by_failures_is_a_failed_search(
        self, storage: LiteStorage
    ) -> None:
        """Nobody knows what the failed searches held."""
        qa = query_of(*A)
        lost = RetrievalShortfall(SearchProvider.EUROPEPMC, TIMEOUT, records_missing=4)
        searcher = Searcher([answer(A)], {qa: [lost]})

        with pytest.raises(SearchFailedError) as raised:
            run(searcher, storage)
        assert raised.value.shortfalls[0].query is ShortfallQuery.ALTERNATIVE
        assert raised.value.notice is None

    def test_a_cut_off_answers_failed_queries_keep_its_notice(self, storage: LiteStorage) -> None:
        """#639: the failure is told, and so is the cut-off answer behind it."""
        qa = query_of(*A)
        lost = RetrievalShortfall(SearchProvider.EUROPEPMC, TIMEOUT, records_missing=4)
        searcher = Searcher([TruncatedResponseError("limit", content=answer(A)[:-1] + ", {")],
                            {qa: SearchFailedError([lost])})

        with pytest.raises(SearchFailedError) as raised:
            run(searcher, storage)
        assert raised.value.notice == cut_off_queries_notice(1)

    def test_on_its_own_the_review_keeps_what_the_queries_lost(
        self, storage: LiteStorage
    ) -> None:
        """Recorded like any shortfall, and the review goes on."""
        qa = query_of(*A)
        lost = RetrievalShortfall(SearchProvider.EUROPEPMC, TIMEOUT, records_missing=4)

        round_ = run(Searcher([answer(A)], {qa: [lost]}), storage, asked=False)

        assert round_.documents == ()
        assert [s.records_missing for s in round_.shortfalls] == [4]

    def test_asked_for_and_finding_nothing_keeps_nothing(self, storage: LiteStorage) -> None:
        """No failure, no document: an empty round."""
        round_ = run(Searcher([answer(A)]), storage)
        assert (round_.documents, round_.shortfalls) == ((), ())
        assert round_.queries == (query_of(*A),)

    def test_a_stop_between_queries_ends_the_round(self, storage: LiteStorage) -> None:
        """What ran is kept."""
        qa = query_of(*A)
        searcher = Searcher([answer(A, B)], {qa: [document("1")]})

        round_ = run_smart_search(searcher, storage, CONTEXT, (), asked=True, max_results=10,
                                  should_stop=lambda: len(searcher.searched) >= 1)

        assert round_.stopped
        assert round_.queries == (qa,)
        assert [r.query for r in storage.get_smart_search_queries(RUN)] == [qa]

    def test_a_stop_while_asking_is_a_stop_not_a_failure(self, storage: LiteStorage) -> None:
        """No query, but nothing went wrong."""
        searcher = Searcher([answer(A)])

        round_ = run_smart_search(searcher, storage, CONTEXT, (), asked=True, max_results=10,
                                  should_stop=lambda: len(searcher.prompts) >= 1)

        assert round_.stopped and searcher.searched == []

    def test_a_stop_does_not_excuse_reporting_a_failure(self, storage: LiteStorage) -> None:
        """Asked for, left with nothing by a failure, then stopped: still a failed search (rule 8)."""
        qa = query_of(*A)
        lost = RetrievalShortfall(SearchProvider.PUBMED, TIMEOUT)
        searcher = Searcher([answer(A, B)], {qa: [lost]})

        with pytest.raises(SearchFailedError):
            run_smart_search(searcher, storage, CONTEXT, (), asked=True, max_results=10,
                             should_stop=lambda: len(searcher.searched) >= 1)

    def test_a_round_that_breaks_off_keeps_no_query_as_run(self, storage: LiteStorage) -> None:
        """Its documents are not held yet: the next round may ask the queries again."""
        qa, qb = query_of(*A), query_of(*B)
        searcher = Searcher([answer(A, B)], {qa: [document("1")], qb: RuntimeError("disk full")})

        with pytest.raises(RuntimeError):
            run(searcher, storage)
        assert storage.get_smart_search_queries(RUN) == []

    def test_the_queries_go_with_the_run(self, storage: LiteStorage) -> None:
        """Deleting the run, or its question, forgets them."""
        for delete in (storage.delete_checkpoint,
                       lambda _id: storage.delete_research_question(QUESTION)):
            checkpoint = storage.create_checkpoint(research_question=QUESTION)
            storage.record_smart_search_query(checkpoint.id, RunQuery("a", "q"))
            delete(checkpoint.id)
            assert storage.get_smart_search_queries(checkpoint.id) == []


class TestAnAlternativeSearchsLoss:
    """Never read as the source never having been searched (the contract's clauses)."""

    def test_its_clauses(self) -> None:
        """The two alternative-query rows of *Telling the user*."""
        alternative = ShortfallQuery.ALTERNATIVE
        assert RetrievalShortfall(SearchProvider.PUBMED, TIMEOUT, query=alternative).describe() == (
            "an alternative search of PubMed could not be completed (the request timed out)")
        assert RetrievalShortfall(
            SearchProvider.EUROPEPMC, TIMEOUT, records_missing=1200, query=alternative
        ).describe() == (
            "1,200 Europe PMC records from an alternative search could not be retrieved "
            "(the request timed out)")

    def test_only_an_alternative_query_writes_its_marker(self) -> None:
        """And anything but the marker reads as the original query."""
        original = RetrievalShortfall(SearchProvider.PUBMED, TIMEOUT)
        alternative = RetrievalShortfall(SearchProvider.PUBMED, TIMEOUT,
                                         query=ShortfallQuery.ALTERNATIVE)

        assert "query" not in original.to_dict()
        assert alternative.to_dict()["query"] == "alternative"
        assert RetrievalShortfall.from_dict(alternative.to_dict()) == alternative
        assert RetrievalShortfall.from_dict({**alternative.to_dict(), "query": "Alternative"}) == original

    def test_its_counts_are_never_added_to_the_original_querys(self) -> None:
        """Combined only within the same query."""
        original = RetrievalShortfall(SearchProvider.PUBMED, TIMEOUT, records_missing=2)
        alternative = RetrievalShortfall(SearchProvider.PUBMED, TIMEOUT, records_missing=3,
                                         query=ShortfallQuery.ALTERNATIVE)

        assert combined_shortfalls([original, alternative, alternative]) == [
            original,
            RetrievalShortfall(SearchProvider.PUBMED, TIMEOUT, records_missing=6,
                               query=ShortfallQuery.ALTERNATIVE),
        ]


class TestTheReportSaysWhichQueriesRan:
    """Reproducible: the methodology lists every alternative query."""

    def test_they_survive_the_checkpoint(self) -> None:
        """And a report saved before smart search has none."""
        metadata = ReportMetadata(alternative_queries=["q1", "q2"])

        assert ReportMetadata.from_dict(metadata.to_dict()).alternative_queries == ["q1", "q2"]
        stored = metadata.to_dict()
        del stored["alternative_queries"]
        assert ReportMetadata.from_dict(stored).alternative_queries == []

    def test_a_round_that_could_not_run_is_said(self) -> None:
        """Kept with the report, so a reopened one says more searching was tried."""
        metadata = ReportMetadata(pubmed_query="p", smart_search_notice=NO_USABLE_QUERY_TEXT)
        agent = LiteReportingAgent.__new__(LiteReportingAgent)

        restored = ReportMetadata.from_dict(metadata.to_dict())
        assert restored.smart_search_notice == NO_USABLE_QUERY_TEXT
        assert (f"- **Alternative Queries (smart search):** {NO_USABLE_QUERY_TEXT}"
                in agent.format_methodology_section(restored))
        stored = metadata.to_dict()
        del stored["smart_search_notice"]
        assert ReportMetadata.from_dict(stored).smart_search_notice is None
        with pytest.raises(ValueError):
            ReportMetadata.from_dict({**stored, "smart_search_notice": 3})

    def test_a_damaged_list_is_refused(self) -> None:
        """Not read as no queries."""
        with pytest.raises(ValueError):
            ReportMetadata.from_dict({**ReportMetadata().to_dict(), "alternative_queries": "q"})

    def test_the_methodology_lists_them(self) -> None:
        """Under the search strategy."""
        agent = LiteReportingAgent.__new__(LiteReportingAgent)
        section = agent.format_methodology_section(
            ReportMetadata(pubmed_query="p", alternative_queries=["(a[tiab])"]))

        assert "- **Alternative Queries (smart search):**\n  - `(a[tiab])`" in section
        assert "Alternative Queries" not in agent.format_methodology_section(ReportMetadata())

    def test_a_cut_off_answers_notice_heads_its_queries(self) -> None:
        """#637: one heading, the notice on it and the queries run under it."""
        agent = LiteReportingAgent.__new__(LiteReportingAgent)
        notice = cut_off_queries_notice(1)
        section = agent.format_methodology_section(ReportMetadata(
            pubmed_query="p", alternative_queries=["(a[tiab])"], smart_search_notice=notice))

        assert f"- **Alternative Queries (smart search):** {notice}\n  - `(a[tiab])`" in section
        assert section.count("Alternative Queries (smart search)") == 1


class TestTwoBatchesOneScreen:
    """The review screens smart search's documents after the search's."""

    def test_they_are_merged_in_order(self) -> None:
        """A document in both keeps the first check."""
        first = screen_documents([document("1"), document("2")], {"pmid-1": unchecked_check()})
        then = screen_documents([document("2"), document("3")], {"pmid-3": unchecked_check()})

        merged = merged_screen(first, then)

        assert [d.id for d in merged.kept] == ["pmid-1", "pmid-2", "pmid-3"]
        assert set(merged.checks) == {"pmid-1", "pmid-3"}
        assert not merged.failed

    def test_a_failed_batch_is_failed_document_by_document(self) -> None:
        """Its stand-ins never read as checks; the checked batch keeps its times and causes (#629)."""
        failed = screen_documents([document("1")], {"pmid-1": unchecked_check()}, failed=True)
        checked = screen_documents([document("2")], {"pmid-2": unchecked_check()})

        for merged in (merged_screen(checked, failed), merged_screen(failed, checked)):
            assert not merged.failed
            assert merged.failed_ids == {"pmid-1"}
            assert merged.checked_at == checked.checked_at
            rows = {row["document_id"]: row for row in merged.to_snapshot()}
            assert rows["pmid-1"]["checked_at"] is None
            assert rows["pmid-2"]["checked_at"] is not None
            clause = run_summary_clause(merged)
            assert clause is not None
            assert "the check failed" in clause and "Crossref" in clause
        assert merged_screen(failed, failed).failed
        assert not merged_screen(checked, checked).failed

    def test_a_failed_batch_beside_a_decided_one(self) -> None:
        """Only the failed batch's paper is blamed on the failed check; live and reopened agree on the date."""
        clear = PaperCheck(RetractionVerdict(RetractionStatus.CLEAR), datetime.now(UTC), None, None)
        failed = screen_documents([document("1")], {"pmid-1": unchecked_check()}, failed=True)
        checked = screen_documents([document("2")], {"pmid-2": clear})

        for merged in (merged_screen(checked, failed), merged_screen(failed, checked)):
            assert run_summary_clause(merged) == (
                "1 paper's retraction status could not be checked: the check failed")
            reopened = RetractionSnapshot.from_rows(merged.to_snapshot())
            assert retraction_methods_line(merged) == retraction_methods_line(reopened)
            # the methods line alone names the unchecked paper too (#631 item 6)
            assert retraction_methods_line(merged) == (
                f"{checked_on_line(clear.checked_at)}; 1 paper could not be checked")
        assert retraction_methods_line(merged_screen(failed, failed)) == "Retraction status could not be checked"

    def test_the_later_failed_check_of_a_paper_the_first_did_not_reach(self) -> None:
        """Its stand-in is used, so it stays failed: no check time, no source blamed (#629)."""
        first = screen_documents([document("1")], {})  # a cancel stopped before it
        failed = screen_documents([document("1")], {"pmid-1": unchecked_check()}, failed=True)

        merged = merged_screen(first, failed)

        assert merged.failed_ids == {"pmid-1"}
        assert merged.checked_at is None
        assert merged.to_snapshot()[0]["checked_at"] is None
        assert run_summary_clause(merged) == "1 paper's retraction status could not be checked: the check failed"

    def test_a_document_in_both_keeps_the_first_batchs_check(self) -> None:
        """And whether that check failed."""
        failed = screen_documents([document("1")], {"pmid-1": unchecked_check()}, failed=True)
        checked = screen_documents([document("1")], {"pmid-1": unchecked_check()})

        assert merged_screen(checked, failed).failed_ids == frozenset()
        assert merged_screen(failed, checked).failed_ids == {"pmid-1"}
