"""What the Anthropic provider sends, through the installed anthropic SDK (#758, #759).

A mocked SDK accepts any keyword, so it could not see that anthropic 2.x has no
``temperature`` on ``Messages.create`` (a ``TypeError`` before any request).
These tests drive the real SDK over a mock transport and read the
request body it would have sent.
"""

from __future__ import annotations

import json

import anthropic
import anthropic._base_client as _sdk_base
import pytest

from bmlibrarian_lite.constants import (
    ANTHROPIC_NONSTREAMING_MAX_TOKENS,
    ANTHROPIC_RETIRED_MODEL_SUCCESSORS,
    DEFAULT_LLM_MODEL,
    LLM_PROVIDERS,
    LLM_TASK_TYPES,
    QUALITY_ASSESSOR_MODEL,
    QUALITY_CLASSIFIER_MODEL,
)
from bmlibrarian_lite.exceptions import OutputLimitExceededError
from bmlibrarian_lite.gui.settings_dialog import FALLBACK_CLAUDE_MODELS
from bmlibrarian_lite.llm.data_types import LLMMessage
from bmlibrarian_lite.llm.providers.anthropic import AnthropicProvider

# anthropic 2.x moved to the httpx2 package and takes only its Client.
_httpx = getattr(_sdk_base, "httpx2", None) or _sdk_base.httpx

_REPLY = {
    "id": "msg_test", "type": "message", "role": "assistant", "model": "m",
    "content": [{"type": "text", "text": "answer"}],
    "stop_reason": "end_turn", "stop_sequence": None,
    "usage": {"input_tokens": 3, "output_tokens": 1},
}


def _provider_sending_to(sent: list[dict[str, object]]) -> AnthropicProvider:
    """An AnthropicProvider whose real SDK client posts into ``sent``."""

    def handle(request: _httpx.Request) -> _httpx.Response:
        sent.append(json.loads(request.content))
        return _httpx.Response(200, json=_REPLY)

    provider = AnthropicProvider(api_key="synthetic-test-key")
    provider._client = anthropic.Anthropic(
        api_key="synthetic-test-key", max_retries=0,
        http_client=_httpx.Client(transport=_httpx.MockTransport(handle)),
    )
    return provider


def test_claude_is_sent_no_temperature_or_top_p() -> None:
    """A temperature and top_p the caller sets never reach the request body."""
    sent: list[dict[str, object]] = []
    response = _provider_sending_to(sent).chat(
        [LLMMessage(role="system", content="s"), LLMMessage(role="user", content="q")],
        model="claude-sonnet-5-5", temperature=0.1, top_p=0.9,
    )

    assert response.content == "answer"
    assert len(sent) == 1
    assert "temperature" not in sent[0] and "top_p" not in sent[0]
    assert sent[0]["model"] == "claude-sonnet-5-5"
    assert sent[0]["system"] == "s"


@pytest.mark.parametrize(("retired", "successor"), sorted(ANTHROPIC_RETIRED_MODEL_SUCCESSORS.items()))
def test_a_retired_model_is_requested_as_its_successor(retired: str, successor: str) -> None:
    """A retired ID this app shipped is requested, and reported, as its successor."""
    sent: list[dict[str, object]] = []
    response = _provider_sending_to(sent).chat([LLMMessage(role="user", content="q")], model=retired)

    assert sent[0]["model"] == successor
    assert response.model == successor


def test_a_live_model_is_requested_as_named() -> None:
    """A model the table does not name is requested unchanged (the control)."""
    sent: list[dict[str, object]] = []
    _provider_sending_to(sent).chat([LLMMessage(role="user", content="q")], model="claude-opus-4-8")

    assert sent[0]["model"] == "claude-opus-4-8"


def test_no_default_or_offered_model_is_retired() -> None:
    """No default, preset or fallback model is one the table retires."""
    offered = {
        DEFAULT_LLM_MODEL, QUALITY_ASSESSOR_MODEL, QUALITY_CLASSIFIER_MODEL,
        AnthropicProvider(api_key="k").default_model, *FALLBACK_CLAUDE_MODELS,
    }
    for preset in [*LLM_PROVIDERS.values(), *LLM_TASK_TYPES.values()]:
        offered.add(str(preset.get("default_model", "")))
        offered.update(str(m) for m in preset.get("recommended_models", []))

    assert not offered & set(ANTHROPIC_RETIRED_MODEL_SUCCESSORS)
    assert not set(ANTHROPIC_RETIRED_MODEL_SUCCESSORS.values()) & set(ANTHROPIC_RETIRED_MODEL_SUCCESSORS)


def _stream_body(text: str, stop_reason: str, output_tokens: int) -> str:
    """A Messages answer as the server streams it."""
    events = [
        ("message_start", {"type": "message_start", "message": {**_REPLY, "content": [], "stop_reason": None}}),
        ("content_block_start", {"type": "content_block_start", "index": 0,
                                 "content_block": {"type": "text", "text": ""}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                 "delta": {"type": "text_delta", "text": text}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                           "usage": {"output_tokens": output_tokens}}),
        ("message_stop", {"type": "message_stop"}),
    ]
    return "".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events)


def _provider_answering(handle: object) -> AnthropicProvider:
    """An AnthropicProvider whose real SDK client is answered by ``handle``."""
    provider = AnthropicProvider(api_key="synthetic-test-key")
    provider._client = anthropic.Anthropic(
        api_key="synthetic-test-key", max_retries=0,
        http_client=_httpx.Client(transport=_httpx.MockTransport(handle)),  # type: ignore[arg-type]
    )
    return provider


def test_a_limit_past_the_non_streaming_bound_streams() -> None:
    """The SDK refuses 65,536 without streaming (#831); streamed, the answer reads as one."""
    sent: list[dict[str, object]] = []

    def handle(request: _httpx.Request) -> _httpx.Response:
        sent.append(json.loads(request.content))
        return _httpx.Response(200, text=_stream_body("long answer", "max_tokens", 65536),
                               headers={"content-type": "text/event-stream"})

    response = _provider_answering(handle).chat(
        [LLMMessage(role="user", content="q")], model="claude-sonnet-5-5", max_tokens=65536)

    assert sent[0]["stream"] is True and sent[0]["max_tokens"] == 65536
    assert (response.content, response.stop_reason, response.output_tokens, response.max_tokens) == (
        "long answer", "max_tokens", 65536, 65536)


def test_a_limit_at_the_bound_does_not_stream() -> None:
    """The control: every first request is asked as before."""
    sent: list[dict[str, object]] = []
    _provider_sending_to(sent).chat([LLMMessage(role="user", content="q")], max_tokens=ANTHROPIC_NONSTREAMING_MAX_TOKENS)

    assert "stream" not in sent[0]


def _refusing(message: str) -> AnthropicProvider:
    """A provider whose server answers every request with a 400 saying *message*."""
    return _provider_answering(lambda _request: _httpx.Response(400, json={
        "type": "error", "error": {"type": "invalid_request_error", "message": message}}))


def test_a_limit_past_the_models_maximum_raises_the_stated_maximum() -> None:
    """The API's own wording (2026-11-26), streamed or not."""
    message = ("max_tokens: 10000000 > 128000, which is the maximum allowed number of output tokens "
               "for claude-haiku-5-5")
    for limit in (4096, 10_000_000):
        with pytest.raises(OutputLimitExceededError) as raised:
            _refusing(message).chat([LLMMessage(role="user", content="q")], model="claude-haiku-5-5",
                                    max_tokens=limit)
        assert raised.value.maximum == 128000


def test_any_other_refusal_is_raised_as_it_came() -> None:
    """The control: a 400 that states no maximum is not read as one."""
    with pytest.raises(anthropic.BadRequestError):
        _refusing("messages: at least one message is required").chat([LLMMessage(role="user", content="q")])
