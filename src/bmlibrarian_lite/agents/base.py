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

"""
Base class for BMLibrarian Lite agents.

Provides common functionality for LLM communication and configuration.
All Lite agents inherit from this base class to share the unified LLM client
interface and configuration management.
"""

import dataclasses
import json
import logging
from typing import Optional

from bmlib.agents import JSON_CORRECTION_NOTE
from bmlib.llm.utils import strict_json_loads

from bmlibrarian_lite.llm import LLMClient, LLMMessage, LLMResponse
from bmlibrarian_lite.llm.client import PROVIDER_OLLAMA
from .. import cut_answers
from ..config import LiteConfig, TaskModelConfig
from ..exceptions import OutputLimitExceededError, RefusedResponseError, TruncatedResponseError
from ..utils import json_correction_due
from ..llm.data_types import STOP_REASON_MAX_TOKENS, STOP_REASON_REFUSAL

logger = logging.getLogger(__name__)


def refuses_json_value(text: str) -> bool:
    """Whether *text* is JSON only to a reader that takes what JSON does not define.

    ``json.loads`` reads ``NaN``, ``Infinity``, ``1e999`` and an integer past
    binary64; bmlib's ``strict_json_loads`` refuses them, and with them the
    whole reply (#761, bmlib#572). An integer longer than
    ``sys.get_int_max_str_digits()`` is refused by both, and is a refusal too;
    so are a lone surrogate escape and nesting past bmlib's depth limit, which
    only ``strict_json_loads`` refuses. A reader that falls back to another
    span or to prose after a failed decode asks this first, so nothing is read
    around a refused value. A syntax error is not a refusal.

    Args:
        text: The span about to be decoded.

    Returns:
        True when ``strict_json_loads`` refuses the text for anything but its
        syntax.
    """
    try:
        strict_json_loads(text)
    except ValueError:
        try:
            json.loads(text)
        except json.JSONDecodeError:
            return False
        except ValueError:
            # An integer longer than sys.get_int_max_str_digits(): a number
            # JSON's grammar reads, refused for its size, not a syntax error
            return True
        return True
    return False


def with_json_correction(messages: list[LLMMessage]) -> list[LLMMessage]:
    """*messages* with bmlib's ``JSON_CORRECTION_NOTE`` on the last user turn.

    Appended after a blank line, or sent as a user turn of its own when the
    last turn is not the user's, as bmlib's ``with_json_correction`` does
    (#761). The unreadable reply is not sent back. *messages* is not changed.

    Args:
        messages: The request's turns.

    Returns:
        The turns to send instead.
    """
    if messages and messages[-1].role == "user":
        last = messages[-1]
        note = f"{last.content}\n\n{JSON_CORRECTION_NOTE}"
        return [*messages[:-1], dataclasses.replace(last, content=note)]
    return [*messages, LLMMessage(role="user", content=JSON_CORRECTION_NOTE)]


def _answer_text(response: LLMResponse) -> str:
    """The answer's text, unless the model declined or was cut off.

    Args:
        response: The answer, after any retries with larger limits.

    Returns:
        What the model wrote.

    Raises:
        RefusedResponseError: The model declined to answer.
        TruncatedResponseError: The answer reached its token limit. No part
            of it is read as the answer (#831); the message names the limit
            and quotes the answer, which points at why it ran so long.
    """
    if response.stop_reason == STOP_REASON_REFUSAL:
        raise RefusedResponseError(f"The model {response.model} declined to answer")
    if response.stop_reason == STOP_REASON_MAX_TOKENS:
        limit = (
            f"{response.max_tokens} tokens" if response.max_tokens
            else f"{response.output_tokens} tokens generated"
        )
        raise TruncatedResponseError(
            f"The answer from {response.model} reached its token limit ({limit}) and is "
            f"incomplete. The answer as cut:\n\n{response.content}",
            content=response.content,
        )
    return response.content


class LiteBaseAgent:
    """
    Base class for all Lite agents.

    Provides common functionality for LLM communication and configuration.
    Agents inheriting from this class gain access to:
    - Configured LLM client with provider selection
    - Task-based model configuration
    - Helper methods for creating chat messages
    - Configuration management

    Subclasses should set TASK_ID to their task identifier for automatic
    model configuration lookup.

    Attributes:
        config: Lite configuration instance
        TASK_ID: Task identifier for model configuration (override in subclass)
    """

    # Override in subclasses to set the task type for model configuration
    TASK_ID: str = "default"

    def __init__(
        self,
        config: Optional[LiteConfig] = None,
        llm_client: Optional[LLMClient] = None,
    ) -> None:
        """
        Initialize the base agent.

        Args:
            config: Lite configuration (uses defaults if not provided)
            llm_client: Optional pre-configured LLM client
        """
        self.config = config or LiteConfig()
        self._llm_client = llm_client

    @property
    def llm_client(self) -> LLMClient:
        """
        Get or create LLM client.

        The client is lazily created on first access.

        Returns:
            Configured LLMClient instance
        """
        if self._llm_client is None:
            self._llm_client = LLMClient()
        return self._llm_client

    def _get_task_config(self, task_id: Optional[str] = None) -> TaskModelConfig:
        """
        Get model configuration for a task.

        Args:
            task_id: Task identifier (uses class TASK_ID if not specified)

        Returns:
            TaskModelConfig with effective settings for the task
        """
        task_id = task_id or self.TASK_ID
        return self.config.models.get_task_config(task_id)

    def _get_model(self, task_id: Optional[str] = None) -> str:
        """
        Get the configured model string for a task.

        Combines provider and model name into the format expected
        by LLMClient (e.g., "anthropic:claude-haiku-5-5").

        Args:
            task_id: Task identifier (uses class TASK_ID if not specified)

        Returns:
            Model string with provider prefix
        """
        task_id = task_id or self.TASK_ID
        return self.config.models.get_model_string(task_id)

    def _chat(
        self,
        messages: list[LLMMessage],
        task_id: Optional[str] = None,
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
        json_mode: bool = False,
    ) -> str:
        """
        Send a chat request to the LLM.

        Uses task-specific configuration if available, otherwise falls back
        to defaults. Temperature and max_tokens can be overridden per-call.
        Inside an ``llm_retry`` attempt after an unreadable reply, the last
        user turn carries ``JSON_CORRECTION_NOTE`` (#761).

        Args:
            messages: List of conversation messages
            task_id: Task identifier for config lookup (uses class TASK_ID if None)
            temperature: Optional temperature override
            max_tokens: Optional max tokens override
            json_mode: Request JSON-formatted output

        Returns:
            Response text from the LLM

        Raises:
            TruncatedResponseError: The answer reached its token limit, after
                the retries with larger limits that were allowed (#825, #831).
                Asked again with the same limit it is likely cut off again, so
                a caller that retries an unreadable answer must not retry
                this. It carries what the model wrote.
            RefusedResponseError: The model declined to answer; never retried
                either.
        """
        if json_correction_due():
            messages = with_json_correction(messages)
        return _answer_text(
            self._chat_response_retrying_cut(messages, task_id, temperature, max_tokens, json_mode)
        )

    def _chat_prose(
        self,
        messages: list[LLMMessage],
        task_id: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> str:
        """Send a chat request for text the reader reads as written.

        As :meth:`_chat`, without JSON mode or the JSON correction note: a
        prose answer still cut after its retries fails too (#831), never shown
        as a part.

        Args:
            messages: List of conversation messages
            task_id: Task identifier for config lookup (uses class TASK_ID if None)
            temperature: Optional temperature override
            max_tokens: Optional max tokens override

        Returns:
            The answer's text

        Raises:
            TruncatedResponseError: The answer reached its token limit, after
                the retries with larger limits that were allowed.
            RefusedResponseError: The model declined to answer: what it wrote
                before declining is not the answer.
        """
        return _answer_text(self._chat_response_retrying_cut(messages, task_id, temperature, max_tokens))

    def _chat_response_retrying_cut(
        self,
        messages: list[LLMMessage],
        task_id: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
        json_mode: bool = False,
    ) -> LLMResponse:
        """:meth:`_chat_response`, asked again with larger limits when cut (#825, #831).

        An answer that generated its whole limit is asked again with the
        limit :func:`cut_answers.raised_limit` allows, twice the last, up to
        :data:`CUT_ANSWER_MAX_RETRIES` times; the last answer is returned, cut
        or not. Each retry is one request, never backed off. A provider
        refusing a limit past the model's maximum is asked once with that
        maximum, the last retry. A retry that raises (a timeout, an outage) is
        logged and the cut answer before it returned. One that stopped short
        of its limit is not asked again: the context window ran out, and a
        larger limit does not change that. On Ollama a retry must fit the
        configured ``context_window`` beside the prompt (as the reported
        prompt tokens measure it); with none configured the window is unknown,
        so it is not asked again. Every cut answer with a known limit is
        logged with its text and recorded (:func:`cut_answers.record`).

        Args:
            messages: List of conversation messages
            task_id: Task identifier for config lookup (uses class TASK_ID if None)
            temperature: Optional temperature override
            max_tokens: Optional max tokens override
            json_mode: Request JSON-formatted output

        Returns:
            The last answer: the first, or the last retry that answered
        """
        response = self._chat_response(messages, task_id, temperature, max_tokens, json_mode)
        if response.stop_reason != STOP_REASON_MAX_TOKENS or response.max_tokens is None:
            return response
        task_config = self._get_task_config(task_id)
        room: int | None = None
        if task_config.provider == PROVIDER_OLLAMA:
            window = task_config.context_window
            room = window - response.input_tokens if window else 0
        task, model = task_id or self.TASK_ID, self._get_model(task_id)
        attempt = 0
        while True:
            assert response.max_tokens is not None  # every answer here was asked with one
            cut = cut_answers.CutAnswer(
                task_id=task, model=model, max_tokens=response.max_tokens,
                output_tokens=response.output_tokens, attempt=attempt,
                retry_max_tokens=cut_answers.raised_limit(
                    response.output_tokens, response.max_tokens, room, attempt
                ),
            )
            logger.warning(
                f"The answer from {model} reached its token limit ({cut.max_tokens}; "
                f"{cut.output_tokens} tokens generated, attempt {attempt}); "
                f"{f'asking again with {cut.retry_max_tokens}' if cut.retry_max_tokens else 'not asked again'}. "
                f"The answer as cut:\n{response.content}"
            )
            if cut.retry_max_tokens is None:
                cut_answers.record(cut)
                return response
            try:
                retry = self._chat_response(
                    messages, task_id, temperature, cut.retry_max_tokens, json_mode
                )
            except Exception as e:
                if isinstance(e, OutputLimitExceededError) and e.maximum < cut.retry_max_tokens:
                    logger.warning(f"{e}; asking within it")
                    room = e.maximum  # caps this retry and every later one
                    continue
                # the cut answer is still an answer: its caller decides
                logger.warning(
                    f"Asking {model} again with {cut.retry_max_tokens} failed "
                    f"({type(e).__name__}: {e}); keeping the cut answer"
                )
                cut_answers.record(cut)
                return response
            retry_cut = retry.stop_reason == STOP_REASON_MAX_TOKENS
            cut_answers.record(
                dataclasses.replace(cut, retry_output_tokens=retry.output_tokens, retry_cut=retry_cut)
            )
            if not retry_cut or retry.max_tokens is None:
                return retry
            response, attempt = retry, attempt + 1

    def _chat_response(
        self,
        messages: list[LLMMessage],
        task_id: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
        json_mode: bool = False,
    ) -> LLMResponse:
        """Send a chat request and return the whole response, unchecked.

        :meth:`_chat` and :meth:`_chat_prose` check why the model stopped;
        a caller of this one reads ``stop_reason`` itself. A cut answer is
        not asked again: :meth:`_chat_response_retrying_cut` does that.

        Args:
            messages: List of conversation messages
            task_id: Task identifier for config lookup (uses class TASK_ID if None)
            temperature: Optional temperature override
            max_tokens: Optional max tokens override
            json_mode: Request JSON-formatted output

        Returns:
            The response, with why the model stopped
        """
        task_config = self._get_task_config(task_id)
        return self.llm_client.chat(
            messages=messages,
            model=f"{task_config.provider}:{task_config.model}",
            temperature=temperature if temperature is not None else task_config.temperature,
            max_tokens=max_tokens if max_tokens is not None else task_config.max_tokens,
            top_p=task_config.top_p,
            json_mode=json_mode,
            context_window=task_config.context_window,
        )

    def _create_system_message(self, content: str) -> LLMMessage:
        """
        Create a system message for the LLM.

        Args:
            content: System prompt content

        Returns:
            LLMMessage with role="system"
        """
        return LLMMessage(role="system", content=content)

    def _create_user_message(self, content: str) -> LLMMessage:
        """
        Create a user message for the LLM.

        Args:
            content: User message content

        Returns:
            LLMMessage with role="user"
        """
        return LLMMessage(role="user", content=content)

    def _create_assistant_message(self, content: str) -> LLMMessage:
        """
        Create an assistant message for conversation history.

        Args:
            content: Assistant message content

        Returns:
            LLMMessage with role="assistant"
        """
        return LLMMessage(role="assistant", content=content)

    def test_connection(self) -> bool:
        """
        Test if the LLM provider is available.

        Returns:
            True if connection is successful
        """
        try:
            # Simple test message
            messages = [self._create_user_message("Hello")]
            # Not _chat: an answer cut off at ten tokens still proves a connection
            self._chat_response(messages, max_tokens=10)
            return True
        except Exception as e:
            logger.warning(f"LLM connection test failed: {e}")
            return False
