"""Configured task context limits reach Ollama without altering prompt data (#620)."""

from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.agents.base import LiteBaseAgent
from bmlibrarian_lite.config import LiteConfig, TaskModelConfig
from bmlibrarian_lite.llm import LLMClient, LLMMessage
from bmlibrarian_lite.llm.providers.anthropic import AnthropicProvider
from bmlibrarian_lite.llm.providers.ollama import OllamaProvider

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
