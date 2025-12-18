"""Ollama local model provider implementation.

This module provides the OllamaProvider class for interacting with
local models via the Ollama server.
"""

import logging
import os
import re
from typing import Optional

from .base import (
    BaseProvider,
    ModelMetadata,
    ModelPricing,
    ProviderCapabilities,
)
from ..data_types import LLMMessage, LLMResponse

logger = logging.getLogger(__name__)


class OllamaProvider(BaseProvider):
    """Ollama local model provider.

    Provides access to locally-running LLM models via the Ollama server.
    No API key required - completely free to use.

    Class Attributes:
        PROVIDER_NAME: "ollama"
        DISPLAY_NAME: "Ollama"
    """

    PROVIDER_NAME = "ollama"
    DISPLAY_NAME = "Ollama"
    DESCRIPTION = "Local models via Ollama server (free)"
    WEBSITE_URL = "https://ollama.ai"
    SETUP_INSTRUCTIONS = "Install from ollama.ai, then run 'ollama pull medgemma4B_it_q8'"

    def __init__(
        self,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        **kwargs: object,
    ) -> None:
        """Initialize the Ollama provider.

        Args:
            api_key: Ignored (Ollama doesn't require API key).
            base_url: Ollama server URL. Defaults to OLLAMA_HOST env var or localhost.
            **kwargs: Additional configuration options.
        """
        # Get base URL from environment if not provided
        resolved_base_url = base_url or os.environ.get(
            "OLLAMA_HOST", "http://localhost:11434"
        )
        super().__init__(api_key=None, base_url=resolved_base_url, **kwargs)

        # Cache for model metadata from ollama.show()
        self._model_info_cache: dict[str, ModelMetadata] = {}

    @property
    def is_local(self) -> bool:
        """Ollama runs locally."""
        return True

    @property
    def is_free(self) -> bool:
        """Ollama is free to use."""
        return True

    @property
    def requires_api_key(self) -> bool:
        """Ollama doesn't require an API key."""
        return False

    @property
    def api_key_env_var(self) -> str:
        """No API key environment variable needed."""
        return ""

    @property
    def default_base_url(self) -> str:
        """Default Ollama server URL."""
        return "http://localhost:11434"

    @property
    def default_model(self) -> str:
        """Default Ollama model."""
        return "medgemma4B_it_q8"

    def _get_client(self) -> object:
        """Get or create Ollama client (lazy initialization).

        Returns:
            Ollama client instance.

        Raises:
            ImportError: If ollama package is not installed.
        """
        if self._client is None:
            try:
                import ollama

                self._client = ollama.Client(host=self._base_url)
            except ImportError:
                raise ImportError(
                    "Ollama package not installed. Install with: pip install ollama"
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
        """Send a chat completion request to Ollama.

        Args:
            messages: List of conversation messages.
            model: Model ID to use. Defaults to medgemma4B_it_q8.
            temperature: Sampling temperature (0.0 to 1.0).
            max_tokens: Maximum tokens in the response.
            **kwargs: Additional parameters (top_p, json_mode).

        Returns:
            LLMResponse with the model's response.
        """
        model = model or self.default_model
        client = self._get_client()

        # Extract optional parameters
        top_p: Optional[float] = kwargs.get("top_p")  # type: ignore
        json_mode: bool = kwargs.get("json_mode", False)  # type: ignore

        # Convert messages to Ollama format
        ollama_messages = [
            {"role": msg.role, "content": msg.content} for msg in messages
        ]

        # Build options
        options: dict[str, object] = {
            "temperature": temperature,
            "num_predict": max_tokens,
        }

        if top_p is not None:
            options["top_p"] = top_p

        # Build request kwargs
        request_kwargs: dict[str, object] = {
            "model": model,
            "messages": ollama_messages,
            "options": options,
        }

        if json_mode:
            request_kwargs["format"] = "json"

        # Make API call
        response = client.chat(**request_kwargs)

        content = response.get("message", {}).get("content", "")

        # Get token counts from response (Ollama provides these)
        input_tokens = response.get(
            "prompt_eval_count", self._estimate_tokens(messages)
        )
        output_tokens = response.get("eval_count", len(content) // 4)

        return LLMResponse(
            content=content,
            model=model,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            stop_reason="stop",
        )

    def _estimate_tokens(self, messages: list[LLMMessage]) -> int:
        """Estimate input token count (fallback only).

        Args:
            messages: Messages to estimate tokens for.

        Returns:
            Estimated token count.
        """
        total_chars = sum(len(m.content) for m in messages)
        return total_chars // 4

    def _get_model_info(self, model_name: str) -> ModelMetadata:
        """Fetch model metadata using ollama.show().

        Caches results to avoid repeated API calls.

        Args:
            model_name: Name of the model to get info for.

        Returns:
            ModelMetadata for the model.
        """
        if model_name in self._model_info_cache:
            return self._model_info_cache[model_name]

        try:
            client = self._get_client()
            info = client.show(model_name)

            # Extract context window from model info
            context_window = self._extract_context_window(info)

            # Get model details
            details = info.get("details", {})
            parameter_size = details.get("parameter_size", "")

            display_name = model_name
            if parameter_size:
                display_name = f"{model_name} ({parameter_size})"

            metadata = ModelMetadata(
                model_id=model_name,
                display_name=display_name,
                context_window=context_window,
                pricing=ModelPricing(0.0, 0.0),  # Always free
                capabilities=ProviderCapabilities(
                    supports_system_messages=True,
                    max_context_window=context_window,
                ),
            )
            self._model_info_cache[model_name] = metadata
            return metadata

        except Exception as e:
            logger.debug(f"Failed to get model info for {model_name}: {e}")
            # Fallback if show() fails
            return ModelMetadata(
                model_id=model_name,
                display_name=model_name,
                context_window=8192,
                pricing=ModelPricing(0.0, 0.0),
            )

    def _extract_context_window(self, info: dict) -> int:
        """Extract context window size from ollama.show() response.

        Args:
            info: Response dict from ollama.show().

        Returns:
            Context window size in tokens.
        """
        # Try to get from model_info first (most reliable)
        model_info = info.get("model_info", {})

        # Look for context_length in model_info keys
        for key, value in model_info.items():
            if "context" in key.lower() and isinstance(value, int):
                return value

        # Try parameters dict
        parameters = info.get("parameters", {})
        if isinstance(parameters, dict):
            if "num_ctx" in parameters:
                return int(parameters["num_ctx"])

        # Try parsing from modelfile
        modelfile = info.get("modelfile", "")
        if modelfile and "num_ctx" in modelfile:
            match = re.search(r"num_ctx\s+(\d+)", modelfile)
            if match:
                return int(match.group(1))

        # Default fallback
        return 8192

    def list_models(self) -> list[ModelMetadata]:
        """Query Ollama for available models with full metadata.

        Returns:
            List of ModelMetadata for all available models.
        """
        try:
            client = self._get_client()
            response = client.list()
            models = []
            # Response is a ListResponse object with .models attribute
            model_list = getattr(response, "models", []) or []
            for model_info in model_list:
                # Each model_info is a Model object with .model attribute
                name = getattr(model_info, "model", "") or ""
                if name:
                    # Get full metadata via show()
                    metadata = self._get_model_info(name)
                    models.append(metadata)
            return models
        except Exception as e:
            logger.warning(f"Failed to list Ollama models: {e}")
            return []

    def test_connection(self) -> tuple[bool, str]:
        """Test Ollama server connectivity.

        Returns:
            Tuple of (success, message).
        """
        try:
            client = self._get_client()
            response = client.list()
            # Response is a ListResponse object with .models attribute
            model_list = getattr(response, "models", []) or []
            if model_list:
                return True, f"Connected. {len(model_list)} models available."
            return True, "Connected. No models installed."
        except ImportError:
            return False, "Ollama package not installed"
        except Exception as e:
            return False, f"Connection failed: {e}"

    def count_tokens(self, text: str, model: Optional[str] = None) -> int:
        """Estimate tokens in text.

        Ollama doesn't expose a tokenizer directly, so we estimate.

        Args:
            text: Text to count tokens for.
            model: Model to use (unused - we always estimate).

        Returns:
            Estimated number of tokens.
        """
        # Rough estimate: ~4 characters per token
        return len(text) // 4

    def get_model_pricing(self, model: str) -> ModelPricing:
        """Get pricing for an Ollama model.

        Ollama is always free.

        Args:
            model: Model ID (ignored).

        Returns:
            ModelPricing with zero costs.
        """
        return ModelPricing(0.0, 0.0)

    def get_model_metadata(self, model: str) -> Optional[ModelMetadata]:
        """Get metadata for a specific model using ollama.show().

        Args:
            model: Model ID to get metadata for.

        Returns:
            ModelMetadata for the model.
        """
        return self._get_model_info(model)
