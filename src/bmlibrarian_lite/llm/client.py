"""
Unified LLM client supporting Anthropic and Ollama providers.

This module provides a single interface for communicating with different
LLM providers, abstracting away the differences in their APIs.

The client delegates to provider implementations in the providers/ subpackage,
which can be extended to support additional providers.

Usage:
    from bmlibrarian_lite.llm import LLMClient, LLMMessage

    # Using Anthropic (default)
    client = LLMClient()
    response = client.chat(
        messages=[LLMMessage(role="user", content="Hello")],
        model="anthropic:claude-sonnet-4-20250514",
    )

    # Using Ollama
    response = client.chat(
        messages=[LLMMessage(role="user", content="Hello")],
        model="ollama:medgemma4B_it_q8",
    )
"""

import logging
import os
from typing import Optional, Union

from .data_types import LLMMessage, LLMResponse
from .token_tracker import get_token_tracker
from .providers import (
    BaseProvider,
    ModelMetadata,
    get_provider,
    list_providers,
)

logger = logging.getLogger(__name__)

# Default provider
DEFAULT_PROVIDER = "anthropic"

# Provider prefixes (kept for backward compatibility)
PROVIDER_ANTHROPIC = "anthropic"
PROVIDER_OLLAMA = "ollama"


class LLMClient:
    """Unified LLM client that delegates to provider implementations.

    Automatically routes requests to the appropriate provider based on
    the model string format: "provider:model_name".

    Supported providers:
    - anthropic: Claude models via Anthropic API
    - ollama: Local models via Ollama server

    New providers can be added by implementing BaseProvider and registering
    them with register_provider().

    Attributes:
        default_provider: Default provider if not specified in model string.
    """

    def __init__(
        self,
        default_provider: str = DEFAULT_PROVIDER,
        ollama_host: Optional[str] = None,
        anthropic_api_key: Optional[str] = None,
    ) -> None:
        """Initialize the LLM client.

        Args:
            default_provider: Default provider (anthropic or ollama).
            ollama_host: Ollama server URL (uses OLLAMA_HOST env var or default).
            anthropic_api_key: Anthropic API key (uses env var if not provided).
        """
        self.default_provider = default_provider

        # Store config for lazy provider initialization
        self._provider_config: dict[str, dict[str, object]] = {
            "anthropic": {"api_key": anthropic_api_key},
            "ollama": {"base_url": ollama_host},
        }

        # Lazy-loaded provider instances
        self._providers: dict[str, BaseProvider] = {}

        logger.debug(
            f"LLMClient initialized: default_provider={default_provider}"
        )

    def _get_provider(self, name: str) -> BaseProvider:
        """Get or create provider instance (lazy initialization).

        Args:
            name: Provider name (e.g., "anthropic", "ollama").

        Returns:
            Provider instance.

        Raises:
            ValueError: If provider name is unknown.
        """
        if name not in self._providers:
            config = self._provider_config.get(name, {})
            self._providers[name] = get_provider(name, **config)
        return self._providers[name]

    def _parse_model_string(self, model: Optional[str]) -> tuple[str, str]:
        """Parse a model string into provider and model name.

        Args:
            model: Model string, optionally with provider prefix.

        Returns:
            Tuple of (provider, model_name).
        """
        if model and ":" in model:
            provider, model_name = model.split(":", 1)
            return provider.lower(), model_name

        # Use default provider and its default model
        provider = self.default_provider
        provider_instance = self._get_provider(provider)
        model_name = model or provider_instance.default_model
        return provider, model_name

    def chat(
        self,
        messages: list[LLMMessage],
        model: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
        top_p: Optional[float] = None,
        json_mode: bool = False,
    ) -> LLMResponse:
        """Send a chat request to the LLM.

        Args:
            messages: List of conversation messages.
            model: Model string with optional provider prefix.
            temperature: Sampling temperature (0.0-1.0).
            max_tokens: Maximum tokens to generate.
            top_p: Nucleus sampling parameter (optional).
            json_mode: Request JSON-formatted output.

        Returns:
            LLMResponse with the model's reply.

        Raises:
            ValueError: If provider is not supported.
            Exception: If API call fails.
        """
        # Parse model string
        provider_name, model_name = self._parse_model_string(model)

        logger.debug(f"Chat request: provider={provider_name}, model={model_name}")

        # Get provider and make request
        provider = self._get_provider(provider_name)
        response = provider.chat(
            messages=messages,
            model=model_name,
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p,
            json_mode=json_mode,
        )

        # Track token usage with cost from provider
        tracker = get_token_tracker()
        cost = provider.calculate_cost(
            model_name, response.input_tokens, response.output_tokens
        )
        tracker.record_usage(
            model=f"{provider_name}:{model_name}",
            input_tokens=response.input_tokens,
            output_tokens=response.output_tokens,
            cost=cost,
        )

        return response

    def test_connection(
        self, provider: Optional[str] = None
    ) -> Union[bool, dict[str, tuple[bool, str]]]:
        """Test connection to LLM provider(s).

        Args:
            provider: Provider to test. If None, tests all providers.

        Returns:
            If provider specified: bool indicating success.
            If no provider: dict mapping provider names to (success, message) tuples.
        """
        if provider:
            # Test single provider, return bool for backward compatibility
            try:
                p = self._get_provider(provider)
                success, _ = p.test_connection()
                return success
            except Exception as e:
                logger.warning(f"Connection test failed for {provider}: {e}")
                return False

        # Test all providers
        results = {}
        for name in list_providers():
            try:
                p = self._get_provider(name)
                results[name] = p.test_connection()
            except Exception as e:
                results[name] = (False, str(e))
        return results

    def list_models(
        self, provider: Optional[str] = None
    ) -> Union[list[str], list[ModelMetadata]]:
        """List available models for a provider.

        Args:
            provider: Provider to query. If None, lists from all providers.

        Returns:
            If provider specified: List of model name strings (backward compat).
            If no provider: List of ModelMetadata from all providers.
        """
        if provider:
            # Return list of strings for backward compatibility
            try:
                p = self._get_provider(provider)
                return [m.model_id for m in p.list_models()]
            except Exception as e:
                logger.warning(f"Failed to list models for {provider}: {e}")
                return []

        # Return ModelMetadata from all providers
        all_models = []
        for name in list_providers():
            try:
                p = self._get_provider(name)
                all_models.extend(p.list_models())
            except Exception:
                pass
        return all_models

    def get_model_metadata(
        self, model: str, provider: Optional[str] = None
    ) -> Optional[ModelMetadata]:
        """Get metadata for a specific model.

        Args:
            model: Model ID to get metadata for.
            provider: Provider name. If not specified, parses from model string.

        Returns:
            ModelMetadata if found, None otherwise.
        """
        if provider is None and ":" in model:
            provider, model = model.split(":", 1)

        provider = provider or self.default_provider
        try:
            p = self._get_provider(provider)
            return p.get_model_metadata(model)
        except Exception:
            return None

    def get_provider_info(self, provider: str) -> dict[str, object]:
        """Get information about a provider.

        Args:
            provider: Provider name.

        Returns:
            Dict with provider metadata.
        """
        p = self._get_provider(provider)
        return {
            "name": p.PROVIDER_NAME,
            "display_name": p.DISPLAY_NAME,
            "description": p.DESCRIPTION,
            "website_url": p.WEBSITE_URL,
            "setup_instructions": p.SETUP_INSTRUCTIONS,
            "is_local": p.is_local,
            "is_free": p.is_free,
            "requires_api_key": p.requires_api_key,
            "api_key_env_var": p.api_key_env_var,
            "default_base_url": p.default_base_url,
            "default_model": p.default_model,
        }


# Global client instance
_global_client: Optional[LLMClient] = None


def get_llm_client() -> LLMClient:
    """Get the global LLM client instance.

    Creates a new instance if one doesn't exist.

    Returns:
        Global LLMClient instance.
    """
    global _global_client
    if _global_client is None:
        _global_client = LLMClient()
    return _global_client


def reset_llm_client() -> None:
    """Reset the global LLM client instance.

    Useful for testing or reconfiguration.
    """
    global _global_client
    _global_client = None
