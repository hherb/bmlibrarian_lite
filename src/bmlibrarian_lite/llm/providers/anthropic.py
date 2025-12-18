"""Anthropic Claude API provider implementation.

This module provides the AnthropicProvider class for interacting with
Anthropic's Claude models via their API.
"""

import json
import logging
import os
import re
import time
from typing import Optional

from .base import (
    BaseProvider,
    ModelMetadata,
    ModelPricing,
    ProviderCapabilities,
)
from ..data_types import LLMMessage, LLMResponse

logger = logging.getLogger(__name__)


class AnthropicProvider(BaseProvider):
    """Anthropic Claude API provider.

    Provides access to Claude models via the Anthropic API. Requires an API key
    which can be provided directly or via the ANTHROPIC_API_KEY environment variable.

    Class Attributes:
        PROVIDER_NAME: "anthropic"
        DISPLAY_NAME: "Anthropic"
        MODEL_PRICING: Dict mapping model IDs to their pricing.
        CACHE_TTL: Cache time-to-live in seconds for model list.
    """

    PROVIDER_NAME = "anthropic"
    DISPLAY_NAME = "Anthropic"
    DESCRIPTION = "Claude models via Anthropic API"
    WEBSITE_URL = "https://console.anthropic.com"
    SETUP_INSTRUCTIONS = "Get API key from console.anthropic.com/account/keys"

    # Known model pricing (costs per million tokens)
    # Models are discovered via API, this provides pricing metadata
    MODEL_PRICING: dict[str, ModelPricing] = {
        "claude-opus-4-20250514": ModelPricing(input_cost=15.0, output_cost=75.0),
        "claude-sonnet-4-20250514": ModelPricing(input_cost=3.0, output_cost=15.0),
        "claude-3-5-sonnet-20241022": ModelPricing(input_cost=3.0, output_cost=15.0),
        "claude-3-5-haiku-20241022": ModelPricing(input_cost=1.0, output_cost=5.0),
        "claude-3-opus-20240229": ModelPricing(input_cost=15.0, output_cost=75.0),
        "claude-3-sonnet-20240229": ModelPricing(input_cost=3.0, output_cost=15.0),
        "claude-3-haiku-20240307": ModelPricing(input_cost=0.25, output_cost=1.25),
    }

    # Cache settings
    CACHE_TTL = 3600  # 1 hour

    def __init__(
        self,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        **kwargs: object,
    ) -> None:
        """Initialize the Anthropic provider.

        Args:
            api_key: Anthropic API key. If not provided, uses ANTHROPIC_API_KEY env var.
            base_url: Optional custom base URL for API requests.
            **kwargs: Additional configuration options.
        """
        # Get API key from environment if not provided
        resolved_api_key = api_key or os.environ.get("ANTHROPIC_API_KEY")
        super().__init__(api_key=resolved_api_key, base_url=base_url, **kwargs)

        # Cache for API-fetched models
        self._models_cache: list[ModelMetadata] | None = None
        self._cache_timestamp: float = 0

    @property
    def is_local(self) -> bool:
        """Anthropic is a cloud-based API."""
        return False

    @property
    def is_free(self) -> bool:
        """Anthropic API has usage costs."""
        return False

    @property
    def requires_api_key(self) -> bool:
        """Anthropic requires an API key."""
        return True

    @property
    def api_key_env_var(self) -> str:
        """Environment variable for Anthropic API key."""
        return "ANTHROPIC_API_KEY"

    @property
    def default_base_url(self) -> str:
        """Default Anthropic API endpoint."""
        return "https://api.anthropic.com"

    @property
    def default_model(self) -> str:
        """Default Claude model."""
        return "claude-sonnet-4-20250514"

    def _get_client(self) -> object:
        """Get or create Anthropic client (lazy initialization).

        Returns:
            Anthropic client instance.

        Raises:
            ImportError: If anthropic package is not installed.
        """
        if self._client is None:
            try:
                import anthropic

                # Only pass base_url if it's different from default
                kwargs: dict[str, object] = {"api_key": self._api_key}
                if self._base_url and self._base_url != self.default_base_url:
                    kwargs["base_url"] = self._base_url

                self._client = anthropic.Anthropic(**kwargs)
            except ImportError:
                raise ImportError(
                    "Anthropic package not installed. Install with: pip install anthropic"
                )
        return self._client

    def chat(
        self,
        messages: list[LLMMessage],
        model: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
        **kwargs: object,
    ) -> LLMResponse:
        """Send a chat completion request to Anthropic.

        Args:
            messages: List of conversation messages.
            model: Model ID to use. Defaults to claude-sonnet-4.
            temperature: Sampling temperature (0.0 to 1.0).
            max_tokens: Maximum tokens in the response.
            **kwargs: Additional parameters (top_p, json_mode).

        Returns:
            LLMResponse with Claude's response.
        """
        model = model or self.default_model
        client = self._get_client()

        # Extract optional parameters
        top_p: Optional[float] = kwargs.get("top_p")  # type: ignore
        json_mode: bool = kwargs.get("json_mode", False)  # type: ignore

        # Separate system message (Anthropic API requirement)
        system_content = ""
        chat_messages = []
        for msg in messages:
            if msg.role == "system":
                system_content = msg.content
            else:
                chat_messages.append({"role": msg.role, "content": msg.content})

        # Build request kwargs
        request_kwargs: dict[str, object] = {
            "model": model,
            "messages": chat_messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
        }

        if system_content:
            request_kwargs["system"] = system_content

        if top_p is not None:
            request_kwargs["top_p"] = top_p

        # Make API call
        response = client.messages.create(**request_kwargs)

        # Extract content
        content = ""
        if response.content:
            for block in response.content:
                if hasattr(block, "text"):
                    content += block.text

        # Handle JSON mode (parse and re-serialize if needed)
        if json_mode:
            try:
                json.loads(content)
            except json.JSONDecodeError:
                content = self._extract_json(content)

        return LLMResponse(
            content=content,
            model=model,
            input_tokens=response.usage.input_tokens,
            output_tokens=response.usage.output_tokens,
            stop_reason=response.stop_reason,
        )

    def _extract_json(self, text: str) -> str:
        """Extract JSON from text that may contain markdown or other content.

        Args:
            text: Text that may contain JSON.

        Returns:
            Extracted JSON string, or original text if no valid JSON found.
        """
        # Try to find JSON in code blocks
        code_block_match = re.search(
            r"```(?:json)?\s*\n?(.*?)\n?```", text, re.DOTALL
        )
        if code_block_match:
            candidate = code_block_match.group(1).strip()
            try:
                json.loads(candidate)
                return candidate
            except json.JSONDecodeError:
                pass

        # Try to find raw JSON object
        brace_match = re.search(r"\{.*\}", text, re.DOTALL)
        if brace_match:
            candidate = brace_match.group(0)
            try:
                json.loads(candidate)
                return candidate
            except json.JSONDecodeError:
                pass

        return text

    def list_models(self, force_refresh: bool = False) -> list[ModelMetadata]:
        """Fetch available models from Anthropic API with caching.

        Args:
            force_refresh: Force refresh of cached models.

        Returns:
            List of available ModelMetadata.
        """
        # Return cached if valid
        if (
            not force_refresh
            and self._models_cache is not None
            and time.time() - self._cache_timestamp < self.CACHE_TTL
        ):
            return self._models_cache

        try:
            client = self._get_client()
            api_models = client.models.list()
            models = []
            for model in api_models:
                model_id = model.id
                pricing = self.MODEL_PRICING.get(
                    model_id,
                    ModelPricing(input_cost=3.0, output_cost=15.0),
                )
                models.append(
                    ModelMetadata(
                        model_id=model_id,
                        display_name=getattr(model, "display_name", model_id),
                        context_window=getattr(model, "context_window", 200000),
                        pricing=pricing,
                        capabilities=ProviderCapabilities(
                            supports_vision=True,
                            supports_function_calling=True,
                            supports_system_messages=True,
                            max_context_window=getattr(
                                model, "context_window", 200000
                            ),
                        ),
                    )
                )
            self._models_cache = models
            self._cache_timestamp = time.time()
            return models
        except Exception as e:
            logger.warning(f"Failed to fetch models from API: {e}")
            # Fallback: return models we know about from pricing dict
            return [
                ModelMetadata(
                    model_id=mid,
                    display_name=mid,
                    context_window=200000,
                    pricing=p,
                )
                for mid, p in self.MODEL_PRICING.items()
            ]

    def test_connection(self) -> tuple[bool, str]:
        """Test API connectivity.

        Returns:
            Tuple of (success, message).
        """
        try:
            import anthropic

            client = self._get_client()
            models = list(client.models.list())
            return True, f"Connected. {len(models)} models available."
        except anthropic.AuthenticationError:
            return False, "Invalid API key"
        except ImportError:
            return False, "Anthropic package not installed"
        except Exception as e:
            return False, str(e)

    def count_tokens(self, text: str, model: Optional[str] = None) -> int:
        """Count tokens in text.

        Uses Anthropic's tokenizer if available, otherwise estimates.

        Args:
            text: Text to count tokens for.
            model: Model to use for tokenization (unused, Anthropic uses same tokenizer).

        Returns:
            Number of tokens in the text.
        """
        try:
            client = self._get_client()
            return client.count_tokens(text)
        except Exception:
            # Fallback: rough estimate (4 chars per token)
            return len(text) // 4

    def get_model_pricing(self, model: str) -> ModelPricing:
        """Get pricing for an Anthropic model.

        Args:
            model: Model ID to get pricing for.

        Returns:
            ModelPricing with input and output costs.
        """
        if model in self.MODEL_PRICING:
            return self.MODEL_PRICING[model]
        # Default to Sonnet pricing for unknown models
        return ModelPricing(input_cost=3.0, output_cost=15.0)
