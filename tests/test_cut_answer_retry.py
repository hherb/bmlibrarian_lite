"""An answer cut at its token limit is asked once more with twice the limit (#825).

Only an answer that generated its whole limit: one that stopped short ran out
of context window, which a larger limit does not change. Every cut is recorded
with its task, model, tokens and limits, so real use re-measures the limits.
The benchmarks keep fixed limits: they call the client directly.
"""

import sqlite3
from typing import Any
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite import cut_answers
from bmlibrarian_lite.agents.base import CUT_OFF_PROSE_NOTE, LiteBaseAgent
from bmlibrarian_lite.agents.search_agent import LiteSearchAgent
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import CUT_ANSWER_RETRY_MAX_TOKENS, SHORT_ANSWER_MAX_TOKENS
from bmlibrarian_lite.cut_answers import CutAnswer, raised_limit
from bmlibrarian_lite.data_models import EvaluationErrorCode
from bmlibrarian_lite.exceptions import TruncatedResponseError
from bmlibrarian_lite.llm import LLMMessage, LLMResponse
from bmlibrarian_lite.llm.data_types import STOP_REASON_MAX_TOKENS, STOP_REASON_REFUSAL
from bmlibrarian_lite.storage import LiteStorage
from tests.test_benchmark_failures import ScriptedClient, score_once

MESSAGES = [LLMMessage(role="user", content="q")]
LIMIT = 2048


def cut(content: str, output_tokens: int, max_tokens: int, input_tokens: int = 100) -> LLMResponse:
    """An answer stopped at its token limit, or at the context window when short of it."""
    return LLMResponse(
        content=content, model="m", input_tokens=input_tokens, output_tokens=output_tokens,
        stop_reason=STOP_REASON_MAX_TOKENS, max_tokens=max_tokens,
    )


def finished(content: str, max_tokens: int, output_tokens: int = 3000) -> LLMResponse:
    """An answer the model ended itself."""
    return LLMResponse(
        content=content, model="m", output_tokens=output_tokens, stop_reason="end_turn", max_tokens=max_tokens,
    )


class Client:
    """An LLM client answering each call with the next response, keeping each call's arguments."""

    def __init__(self, *responses: LLMResponse | Exception) -> None:
        """Answer the calls in order."""
        self._responses = list(responses)
        self.limits: list[int] = []
        self.calls: list[dict[str, Any]] = []

    def chat(self, messages: Any, model: str, max_tokens: int, **kwargs: Any) -> LLMResponse:
        """Answer one call."""
        self.limits.append(max_tokens)
        self.calls.append({"messages": messages, "model": model, **kwargs})
        assert len(self.limits) <= len(self._responses), "More calls than scripted"
        answer = self._responses[len(self.limits) - 1]
        if isinstance(answer, Exception):
            raise answer
        return answer


def agent_on(client: Client, provider: str = "anthropic", context_window: int | None = None) -> LiteBaseAgent:
    """A base agent whose default task runs on *provider*, calling *client*."""
    task: dict[str, Any] = {"provider": provider, "model": "test-model", "max_tokens": LIMIT}
    if context_window is not None:
        task["context_window"] = context_window
    config = LiteConfig._from_dict({"models": {"tasks": {"default": task}}})
    return LiteBaseAgent(config=config, llm_client=client)  # type: ignore[arg-type]


@pytest.fixture
def recorded() -> list[CutAnswer]:
    """The cut answers recorded during the test."""
    rows: list[CutAnswer] = []
    cut_answers.set_recorder(rows.append)
    return rows


class TestTheRaisedLimit:
    """Twice the limit, never past the cap or the context window's room."""

    def test_a_cut_answer_is_asked_again_with_twice_its_limit(self) -> None:
        """The whole limit generated: twice it."""
        assert raised_limit(2048, 2048, None) == 4096

    def test_the_raised_limit_stops_at_the_cap(self) -> None:
        """Never past the SDK's non-streaming bound."""
        assert raised_limit(12000, 12000, None) == CUT_ANSWER_RETRY_MAX_TOKENS

    def test_an_answer_at_the_cap_is_not_asked_again(self) -> None:
        """No larger limit is allowed, so no retry."""
        assert raised_limit(CUT_ANSWER_RETRY_MAX_TOKENS, CUT_ANSWER_RETRY_MAX_TOKENS, None) is None

    def test_an_answer_short_of_its_limit_ran_out_of_context(self) -> None:
        """Anthropic's context-exceeded stop and Ollama's ``length`` read as the limit too."""
        assert raised_limit(2047, 2048, None) is None

    def test_the_raised_limit_stops_at_the_windows_room(self) -> None:
        """The prompt keeps its place in the window."""
        assert raised_limit(2048, 2048, 3000) == 3000

    def test_no_room_past_the_limit_is_no_retry(self) -> None:
        """A retry no larger than the cut answer's limit gains nothing."""
        assert raised_limit(2048, 2048, 2048) is None
        assert raised_limit(2048, 2048, 0) is None


class TestTheAgentAsksOnceMore:
    """``_chat`` and ``_chat_prose`` ask a cut answer again with the raised limit."""

    @pytest.mark.parametrize("method", ["_chat", "_chat_prose"])
    def test_cut_then_retried_and_finished(self, method: str, recorded: list[CutAnswer]) -> None:
        """The retry's whole answer is the answer; the cut is recorded with the retry's tokens."""
        client = Client(cut('{"score": ', LIMIT, LIMIT), finished('{"score": 4}', 2 * LIMIT))

        assert getattr(agent_on(client), method)(MESSAGES) == '{"score": 4}'
        assert client.limits == [LIMIT, 2 * LIMIT]
        assert [(r.task_id, r.model, r.max_tokens, r.output_tokens) for r in recorded] == [
            ("default", "anthropic:test-model", LIMIT, LIMIT)
        ]
        assert (recorded[0].retry_max_tokens, recorded[0].retry_output_tokens, recorded[0].retry_cut) == (
            2 * LIMIT, 3000, False
        )

    def test_cut_and_cut_again_is_truncated(self, recorded: list[CutAnswer]) -> None:
        """Asked only once more: the retry's cut answer is refused as before, with its text."""
        client = Client(cut('{"a', LIMIT, LIMIT), cut('{"ab', 2 * LIMIT, 2 * LIMIT))

        with pytest.raises(TruncatedResponseError) as raised:
            agent_on(client)._chat(MESSAGES)
        assert raised.value.content == '{"ab'
        assert client.limits == [LIMIT, 2 * LIMIT]
        assert (recorded[0].retry_output_tokens, recorded[0].retry_cut) == (2 * LIMIT, True)

    def test_prose_cut_again_keeps_the_retrys_text_with_the_note(self, recorded: list[CutAnswer]) -> None:
        """The retry's longer text is shown, marked as cut."""
        client = Client(cut("Short", LIMIT, LIMIT), cut("Longer", 2 * LIMIT, 2 * LIMIT))

        assert agent_on(client)._chat_prose(MESSAGES) == f"Longer\n\n{CUT_OFF_PROSE_NOTE}"
        assert recorded[0].retry_cut is True

    @pytest.mark.parametrize("method", ["_chat", "_chat_prose"])
    def test_context_exceeded_is_not_asked_again(self, method: str, recorded: list[CutAnswer]) -> None:
        """Short of its limit, the window ran out: a larger limit gains nothing. Still recorded."""
        client = Client(cut("Some text", 900, LIMIT))

        if method == "_chat":
            with pytest.raises(TruncatedResponseError):
                agent_on(client)._chat(MESSAGES)
        else:
            assert agent_on(client)._chat_prose(MESSAGES).endswith(CUT_OFF_PROSE_NOTE)
        assert client.limits == [LIMIT]
        assert [(r.output_tokens, r.retry_max_tokens) for r in recorded] == [(900, None)]

    def test_a_finished_answer_records_nothing(self, recorded: list[CutAnswer]) -> None:
        """Generating the whole limit is no cut when the model ended itself."""
        client = Client(finished("text", LIMIT, output_tokens=LIMIT))

        assert agent_on(client)._chat(MESSAGES) == "text"
        assert client.limits == [LIMIT]
        assert recorded == []

    def test_an_answer_with_no_known_limit_is_not_asked_again(self, recorded: list[CutAnswer]) -> None:
        """A response that does not say what limit it was asked with is never judged against one."""
        client = Client(LLMResponse(content="x", output_tokens=LIMIT, stop_reason=STOP_REASON_MAX_TOKENS))

        with pytest.raises(TruncatedResponseError):
            agent_on(client)._chat(MESSAGES)
        assert client.limits == [LIMIT]
        assert recorded == []

    def test_a_failed_retry_keeps_the_cut_answer(
        self, recorded: list[CutAnswer], caplog: pytest.LogCaptureFixture
    ) -> None:
        """As before #825: ``_chat`` refuses it with its text, the cut recorded with no retry tokens."""
        client = Client(cut("x", LIMIT, LIMIT), ConnectionError("down"))

        with pytest.raises(TruncatedResponseError) as raised:
            agent_on(client)._chat(MESSAGES)
        assert raised.value.content == "x"
        assert "keeping the cut answer" in caplog.text
        assert (recorded[0].retry_max_tokens, recorded[0].retry_output_tokens, recorded[0].retry_cut) == (
            2 * LIMIT, None, None
        )

    def test_a_failed_retry_keeps_the_cut_prose_with_its_note(self) -> None:
        """A cut report is still the reader's, marked as cut (the SDK refusing 16384 on Opus 4.1)."""
        client = Client(cut("Short report", LIMIT, LIMIT), ValueError("Streaming is required"))

        assert agent_on(client)._chat_prose(MESSAGES) == f"Short report\n\n{CUT_OFF_PROSE_NOTE}"

    def test_the_retry_asks_as_the_answer_was_asked(self, recorded: list[CutAnswer]) -> None:
        """Same task, model, messages, temperature and JSON mode; only the limit differs."""
        client = Client(cut('{"a', LIMIT, LIMIT), finished('{"a": 1}', 2 * LIMIT))
        config = LiteConfig._from_dict({"models": {"tasks": {
            "default": {"provider": "anthropic", "model": "default-model"},
            "scoring": {"provider": "anthropic", "model": "scoring-model", "max_tokens": LIMIT},
        }}})
        agent = LiteBaseAgent(config=config, llm_client=client)  # type: ignore[arg-type]

        agent._chat(MESSAGES, task_id="scoring", temperature=0.1, json_mode=True)

        first, retry = client.calls
        assert first == retry
        assert (first["model"], first["temperature"], first["json_mode"]) == (
            "anthropic:scoring-model", 0.1, True
        )
        assert client.limits == [LIMIT, 2 * LIMIT]
        assert (recorded[0].task_id, recorded[0].model) == ("scoring", "anthropic:scoring-model")

    def test_the_query_expansion_asks_once_more(self) -> None:
        """The interrogation agent's own call reads the retry's lines."""
        from bmlibrarian_lite.agents.interrogation_agent import LiteInterrogationAgent

        agent = LiteInterrogationAgent.__new__(LiteInterrogationAgent)
        client = Client(cut("one\ntw", 2048, 2048), finished("one\ntwo\nthree", 4096))
        agent.config = LiteConfig()
        agent._llm_client = client  # type: ignore[assignment]

        assert agent._expand_query("Q?") == ["Q?", "one", "two", "three"]
        assert client.limits == [2048, 4096]


class TestOllama:
    """A larger ``num_predict`` must fit the context window beside the prompt."""

    def test_no_configured_window_is_no_retry(self, recorded: list[CutAnswer]) -> None:
        """The server's own window is unknown, so the prompt could be pushed out of it."""
        client = Client(cut("x", LIMIT, LIMIT))

        with pytest.raises(TruncatedResponseError):
            agent_on(client, provider="ollama")._chat(MESSAGES)
        assert client.limits == [LIMIT]
        assert recorded[0].retry_max_tokens is None

    def test_the_retry_fits_the_configured_window(self, recorded: list[CutAnswer]) -> None:
        """Twice the limit would overrun 8192 beside a 5000-token prompt."""
        client = Client(cut("x", LIMIT, LIMIT, input_tokens=5000), finished("done", 3192))

        assert agent_on(client, provider="ollama", context_window=8192)._chat(MESSAGES) == "done"
        assert client.limits == [LIMIT, 8192 - 5000]


class TestTheRecord:
    """Cut answers are kept in SQLite; a failed write never fails the answer."""

    def test_a_cut_answer_round_trips_through_storage(self, tmp_path: Any) -> None:
        """Every field comes back as written, oldest first."""
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        storage = LiteStorage(config)
        rows = [
            CutAnswer("scoring", "anthropic:m", 2048, 2048, 4096, 2500, False, "2026-11-25T00:00:00+00:00"),
            CutAnswer("citation_extraction", "ollama:m", 4096, 1000, cut_at="2026-11-25T00:00:01+00:00"),
        ]
        for row in rows:
            storage.record_cut_answer(row)

        assert storage.cut_answers() == rows
        assert storage.cut_answers()[0].retry_cut is False

    def test_the_app_records_through_its_storage(self, tmp_path: Any) -> None:
        """The recorder the app sets writes the agent's cut to SQLite."""
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        storage = LiteStorage(config)
        cut_answers.set_recorder(storage.record_cut_answer)
        client = Client(cut("x", LIMIT, LIMIT), finished("done", 2 * LIMIT))

        agent_on(client)._chat(MESSAGES)

        assert [(r.max_tokens, r.retry_max_tokens) for r in storage.cut_answers()] == [(LIMIT, 2 * LIMIT)]

    def test_a_failed_write_is_logged_not_raised(self, caplog: pytest.LogCaptureFixture) -> None:
        """A locked database never costs the answer."""
        def broken(_cut: CutAnswer) -> None:
            raise sqlite3.OperationalError("database is locked")

        cut_answers.set_recorder(broken)
        client = Client(cut("x", LIMIT, LIMIT), finished("done", 2 * LIMIT))

        assert agent_on(client)._chat(MESSAGES) == "done"
        assert "Could not record a cut answer" in caplog.text

    def test_any_failed_record_keeps_the_answer(self, caplog: pytest.LogCaptureFixture) -> None:
        """A record is diagnostics: not only a database error, nothing it raises costs the answer."""
        def broken(_cut: CutAnswer) -> None:
            raise PermissionError("data dir")

        cut_answers.set_recorder(broken)
        client = Client(cut("x", LIMIT, LIMIT), finished("done", 2 * LIMIT))

        assert agent_on(client)._chat(MESSAGES) == "done"
        assert "Could not record a cut answer" in caplog.text

    def test_the_mcp_server_records_through_its_storage(self, tmp_path: Any) -> None:
        """Building the server sets the recorder to its own storage."""
        from bmlibrarian_lite.mcp_server import _make_server

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        _, context = _make_server(config)
        row = CutAnswer("scoring", "anthropic:m", LIMIT, LIMIT)

        cut_answers.record(row)

        assert context.storage.cut_answers() == [row]


def test_the_benchmark_keeps_its_fixed_limit() -> None:
    """A benchmark run asks once, so its evaluator's limit is the one every answer had."""
    client = ScriptedClient(cut('{"score": 4', LIMIT, LIMIT))

    scored = score_once(client)

    assert len(client.calls) == 1
    assert scored.score == EvaluationErrorCode.RESPONSE_TOO_LARGE.value


QUERY_ANSWER = '{"concepts": [{"name": "c", "mesh_terms": ["Aspirin"], "keywords": []}]}'
# The converter's own limit, which overrides the task's
QUERY_LIMIT = SHORT_ANSWER_MAX_TOKENS


def search_agent_on(client: Client) -> LiteSearchAgent:
    """A search agent whose query conversion runs on Anthropic, calling *client*."""
    config = LiteConfig._from_dict({"models": {"tasks": {"query_conversion": {
        "provider": "anthropic", "model": "test-model", "max_tokens": 4 * QUERY_LIMIT,
    }}}})
    return LiteSearchAgent(storage=MagicMock(), config=config, llm_client=client)  # type: ignore[arg-type]


class TestTheQuestionsOwnQuery:
    """The query converter asks through ``_chat``, so its cut answers are retried too (#827)."""

    def test_a_cut_query_answer_is_asked_again_and_recorded(self, recorded: list[CutAnswer]) -> None:
        """The retry's answer makes the query; the cut is recorded under its task."""
        client = Client(cut("{", QUERY_LIMIT, QUERY_LIMIT), finished(QUERY_ANSWER, 2 * QUERY_LIMIT))

        query = search_agent_on(client).convert_query("Does aspirin prevent stroke?")

        assert client.limits == [QUERY_LIMIT, 2 * QUERY_LIMIT]
        assert query.query_string.startswith('(("Aspirin"[mh]))')
        assert [(row.task_id, row.retry_cut) for row in recorded] == [("query_conversion", False)]

    def test_a_query_answer_still_cut_is_never_parsed(
        self, recorded: list[CutAnswer], caplog: pytest.LogCaptureFixture
    ) -> None:
        """Even one that parses: the fallback query is used, and the log says why."""
        client = Client(
            cut(QUERY_ANSWER, QUERY_LIMIT, QUERY_LIMIT), cut(QUERY_ANSWER, 2 * QUERY_LIMIT, 2 * QUERY_LIMIT)
        )

        query = search_agent_on(client).convert_query("Does aspirin prevent stroke?")

        assert query.generation_model == "fallback"
        assert "reached its token limit" in caplog.text
        assert [row.retry_cut for row in recorded] == [True]

    def test_a_refused_query_answer_is_never_parsed(self, caplog: pytest.LogCaptureFixture) -> None:
        """Even one that parses: the fallback query is used, and the log says why."""
        declined = LLMResponse(content=QUERY_ANSWER, model="m", stop_reason=STOP_REASON_REFUSAL)
        client = Client(declined)

        query = search_agent_on(client).convert_query("Does aspirin prevent stroke?")

        assert query.generation_model == "fallback"
        assert "declined to answer" in caplog.text
        assert len(client.limits) == 1
