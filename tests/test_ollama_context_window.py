"""Configured task context limits reach Ollama without altering prompt data (#620)."""

from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.agents.base import LiteBaseAgent
from bmlibrarian_lite.agents.search_agent import LiteSearchAgent
from bmlibrarian_lite.config import LiteConfig, TaskModelConfig
from bmlibrarian_lite.constants import SMART_SEARCH_MAX_TOKENS
from bmlibrarian_lite.exceptions import RefusedResponseError, TruncatedResponseError
from bmlibrarian_lite.llm import LLMClient, LLMMessage
from bmlibrarian_lite.llm.data_types import STOP_REASON_MAX_TOKENS
from bmlibrarian_lite.llm.providers.anthropic import AnthropicProvider, anthropic_stop_reason
from bmlibrarian_lite.llm.providers.ollama import OllamaProvider, ollama_stop_reason

CONTEXT_WINDOW = 32768
REPORT_CONTEXT_WINDOW = 65536
OUTPUT_TOKENS = 321


@pytest.fixture
def sdk() -> MagicMock:
    """An Ollama SDK double that records the complete outgoing request."""
    client = MagicMock()
    client.chat.return_value = {
        "message": {"content": "answer"},
        "prompt_eval_count": 123,
        "eval_count": 7,
    }
    return client


@pytest.fixture
def tracker(monkeypatch: pytest.MonkeyPatch) -> MagicMock:
    """Keep the process-wide usage tracker untouched by these synthetic calls."""
    value = MagicMock()
    monkeypatch.setattr("bmlibrarian_lite.llm.client.get_token_tracker", lambda: value)
    return value


def _client(sdk: MagicMock) -> LLMClient:
    """Use the real provider/client path, replacing only the network SDK."""
    provider = OllamaProvider()
    provider._client = sdk
    client = LLMClient(default_provider="ollama")
    client._providers["ollama"] = provider
    return client


@pytest.mark.parametrize("context_window", [CONTEXT_WINDOW, REPORT_CONTEXT_WINDOW, None])
def test_task_context_reaches_sdk_without_changing_other_options(
    context_window: int | None, sdk: MagicMock, tracker: MagicMock,
) -> None:
    """The serialized per-task setting controls num_ctx, not output or prompt size."""
    config = LiteConfig._from_dict({"models": {"tasks": {"citation_extraction": {
        "provider": "ollama", "model": "test-model", "context_window": context_window,
        "temperature": 0.2, "max_tokens": OUTPUT_TOKENS, "top_p": 0.9,
    }}}})
    agent = LiteBaseAgent(config=config, llm_client=_client(sdk))
    messages = [LLMMessage(role="system", content="Read all evidence."),
                LLMMessage(role="user", content="beginning " + "evidence " * 6000 + " end")]

    assert agent._chat(messages, task_id="citation_extraction", json_mode=True) == "answer"

    request = sdk.chat.call_args.kwargs
    expected_options = {"temperature": 0.2, "num_predict": OUTPUT_TOKENS, "top_p": 0.9}
    if context_window is not None:
        expected_options["num_ctx"] = context_window
    assert request["options"] == expected_options
    assert request["messages"] == [{"role": m.role, "content": m.content} for m in messages]
    assert request["format"] == "json"
    tracker.record_usage.assert_called_once_with(
        model="ollama:test-model", input_tokens=123, output_tokens=7, cost=0.0,
    )


def test_selected_task_uses_its_own_fixed_context(sdk: MagicMock, tracker: MagicMock) -> None:
    """The same client can serve tasks with different explicit context budgets."""
    config = LiteConfig()
    config.models.tasks = {
        "citation_extraction": TaskModelConfig(provider="ollama", model="test-model", context_window=CONTEXT_WINDOW),
        "report_generation": TaskModelConfig(provider="ollama", model="test-model", context_window=REPORT_CONTEXT_WINDOW),
    }
    agent = LiteBaseAgent(config=config, llm_client=_client(sdk))
    agent.TASK_ID = "citation_extraction"
    messages = [LLMMessage(role="user", content="whole prompt")]

    agent._chat(messages)
    agent._chat(messages, task_id="report_generation")

    assert [call.kwargs["options"].get("num_ctx") for call in sdk.chat.call_args_list] == [
        CONTEXT_WINDOW, REPORT_CONTEXT_WINDOW,
    ]


def test_direct_client_accepts_context_and_keeps_response_accounting(
    sdk: MagicMock, tracker: MagicMock,
) -> None:
    """The public client also supports an explicit Ollama context limit."""
    response = _client(sdk).chat(
        [LLMMessage(role="user", content="complete prompt")], context_window=CONTEXT_WINDOW,
    )
    assert sdk.chat.call_args.kwargs["options"]["num_ctx"] == CONTEXT_WINDOW
    assert (response.content, response.input_tokens, response.output_tokens) == ("answer", 123, 7)


@pytest.mark.parametrize("invalid", [0, -1, True, False, 3.5, "32768"])
def test_invalid_context_is_rejected_before_request(invalid: object, sdk: MagicMock) -> None:
    """Bad stored values never become an invalid or misleading Ollama option."""
    provider = OllamaProvider()
    provider._client = sdk
    with pytest.raises(ValueError, match="context_window"):
        provider.chat([LLMMessage(role="user", content="evidence")], context_window=invalid)
    sdk.chat.assert_not_called()


@pytest.mark.parametrize("context_window", [None, CONTEXT_WINDOW])
def test_anthropic_request_does_not_receive_ollama_context_option(
    context_window: int | None, tracker: MagicMock,
) -> None:
    """A task setting must not add Ollama parameters to Anthropic's SDK request."""
    sdk = MagicMock()
    sdk.messages.create.return_value = SimpleNamespace(
        content=[SimpleNamespace(text="answer")],
        usage=SimpleNamespace(input_tokens=123, output_tokens=7), stop_reason="end_turn",
    )
    provider = AnthropicProvider(api_key="synthetic-test-key")
    provider._client = sdk
    client = LLMClient()
    client._providers["anthropic"] = provider
    config = LiteConfig()
    config.models.tasks["default"] = TaskModelConfig(
        provider="anthropic", model="claude-sonnet-4-20250514", context_window=context_window,
    )

    assert LiteBaseAgent(config=config, llm_client=client)._chat(
        [LLMMessage(role="user", content="evidence")],
    ) == "answer"
    assert set(sdk.messages.create.call_args.kwargs) == {"model", "messages", "max_tokens", "temperature"}


@pytest.mark.parametrize(("done_reason", "stop_reason"), [
    ("length", STOP_REASON_MAX_TOKENS), ("stop", "stop"), (None, None), (7, None),
])
def test_an_answer_cut_off_by_num_predict_says_so(
    done_reason: object, stop_reason: str | None, sdk: MagicMock, tracker: MagicMock,
) -> None:
    """Ollama's "length" reads as Anthropic's max_tokens; any other ending as Ollama said it, if text."""
    sdk.chat.return_value = {**sdk.chat.return_value, "done_reason": done_reason}

    agent = LiteBaseAgent(config=LiteConfig._from_dict({"models": {"tasks": {"default": {
        "provider": "ollama", "model": "test-model"}}}}), llm_client=_client(sdk))

    assert agent._chat_response([LLMMessage(role="user", content="q")]).stop_reason == stop_reason


def _search_agent(provider: str, client: LLMClient) -> LiteSearchAgent:
    """The search agent with only what ``ask`` reads: its config and client."""
    agent = LiteSearchAgent.__new__(LiteSearchAgent)
    agent.config = LiteConfig()
    agent.config.models.tasks[LiteSearchAgent.TASK_ID] = TaskModelConfig(provider=provider, model="test-model")
    agent._llm_client = client
    return agent


@pytest.mark.parametrize(("stop_reason", "cut_off"), [
    ("max_tokens", True), ("model_context_window_exceeded", True), ("end_turn", False),
    # unknown, with the whole limit generated (#637)
    ("new_reason", True),
])
def test_anthropics_cut_off_answer_reaches_ask(stop_reason: str, cut_off: bool, tracker: MagicMock) -> None:
    """Anthropic's own stop reason, through the real client, decides whether ``ask`` refuses.

    Running out of context window cuts the answer off as the token limit does (#631 item 3).
    """
    sdk = MagicMock()
    sdk.messages.create.return_value = SimpleNamespace(
        content=[SimpleNamespace(text='[{"concepts": [')],
        usage=SimpleNamespace(input_tokens=12, output_tokens=SMART_SEARCH_MAX_TOKENS), stop_reason=stop_reason,
    )
    provider = AnthropicProvider(api_key="synthetic-test-key")
    provider._client = sdk
    client = LLMClient()
    client._providers["anthropic"] = provider
    agent = _search_agent("anthropic", client)

    if cut_off:
        with pytest.raises(TruncatedResponseError):
            agent.ask("p")
    else:
        assert agent.ask("p") == '[{"concepts": ['
    assert sdk.messages.create.call_args.kwargs["max_tokens"] == SMART_SEARCH_MAX_TOKENS


def test_anthropics_refusal_reaches_ask(tracker: MagicMock) -> None:
    """A declined answer is its own error, never parsed as "no usable query" (#631 item 3)."""
    sdk = MagicMock()
    sdk.messages.create.return_value = SimpleNamespace(
        content=[], usage=SimpleNamespace(input_tokens=12, output_tokens=0), stop_reason="refusal",
    )
    provider = AnthropicProvider(api_key="synthetic-test-key")
    provider._client = sdk
    client = LLMClient()
    client._providers["anthropic"] = provider

    with pytest.raises(RefusedResponseError):
        _search_agent("anthropic", client).ask("p")


@pytest.mark.parametrize(("done_reason", "eval_count", "stop_reason"), [
    (None, 1024, STOP_REASON_MAX_TOKENS), (None, 2000, STOP_REASON_MAX_TOKENS),
    (None, 1023, None), (None, None, None), (None, "1024", None),
    ("stop", 1024, "stop"), ("length", 3, STOP_REASON_MAX_TOKENS),
])
def test_a_server_without_done_reason_is_cut_off_at_its_whole_limit(
    done_reason: str | None, eval_count: object, stop_reason: str | None,
) -> None:
    """#631 item 4: generating all of ``num_predict`` is the cut-off an older server does not name."""
    assert ollama_stop_reason(done_reason, eval_count, 1024) == stop_reason


@pytest.mark.parametrize(("reason", "output_tokens", "stop_reason", "warned"), [
    ("end_turn", 1024, "end_turn", False), ("stop_sequence", 7, "stop_sequence", False),
    ("max_tokens", 1024, STOP_REASON_MAX_TOKENS, False), ("refusal", 7, "refusal", False),
    ("model_context_window_exceeded", 7, STOP_REASON_MAX_TOKENS, False), (None, 1024, None, False),
    ("pause_turn", 7, "pause_turn", True), ("new_reason", 7, "new_reason", True),
    # an unknown reason with the whole limit generated may be a cut-off one
    ("new_reason", 1024, STOP_REASON_MAX_TOKENS, True), ("new_reason", None, "new_reason", True),
])
def test_an_unknown_anthropic_stop_reason_is_logged(
    reason: str | None, output_tokens: object, stop_reason: str | None, warned: bool,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """#637 item 1: a reason added later is seen in the log, never fails the call."""
    with caplog.at_level("WARNING", logger="bmlibrarian_lite.llm.providers.anthropic"):
        assert anthropic_stop_reason(reason, output_tokens, 1024) == stop_reason

    assert ("unknown reason" in caplog.text) == warned


@pytest.mark.parametrize(("done_reason", "eval_count", "stop_reason", "warned"), [
    ("stop", 1024, "stop", False), ("length", 7, STOP_REASON_MAX_TOKENS, False), (None, 7, None, False),
    (7, 7, None, False), ("load", 7, "load", True),
    # an unknown reason with the whole limit generated may be a cut-off one
    ("load", 1024, STOP_REASON_MAX_TOKENS, True),
])
def test_an_unknown_ollama_done_reason_is_logged(
    done_reason: object, eval_count: int, stop_reason: str | None, warned: bool,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """#637 item 1: as Anthropic's, the server's own reason passed on and logged."""
    with caplog.at_level("WARNING", logger="bmlibrarian_lite.llm.providers.ollama"):
        assert ollama_stop_reason(done_reason, eval_count, 1024) == stop_reason

    assert ("unknown reason" in caplog.text) == warned


@pytest.mark.parametrize(("done_reason", "eval_count", "cut_off"), [
    ("length", 7, True), ("stop", 7, False), (None, 7, False),
    # an older server names no reason: the whole limit generated is the cut-off (#631 item 4)
    (None, SMART_SEARCH_MAX_TOKENS, True), (None, SMART_SEARCH_MAX_TOKENS - 1, False),
])
def test_ollamas_cut_off_answer_reaches_ask(
    done_reason: str | None, eval_count: int, cut_off: bool, sdk: MagicMock, tracker: MagicMock,
) -> None:
    """Ollama's "length", through the real client, makes ``ask`` refuse; nothing else does."""
    sdk.chat.return_value = {
        **sdk.chat.return_value, "done_reason": done_reason, "eval_count": eval_count,
    }
    agent = _search_agent("ollama", _client(sdk))

    if cut_off:
        with pytest.raises(TruncatedResponseError):
            agent.ask("p")
    else:
        assert agent.ask("p") == "answer"
    assert sdk.chat.call_args.kwargs["options"]["num_predict"] == SMART_SEARCH_MAX_TOKENS
