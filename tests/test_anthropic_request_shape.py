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
    ANTHROPIC_RETIRED_MODEL_SUCCESSORS,
    DEFAULT_LLM_MODEL,
    LLM_PROVIDERS,
    LLM_TASK_TYPES,
    QUALITY_ASSESSOR_MODEL,
    QUALITY_CLASSIFIER_MODEL,
)
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
