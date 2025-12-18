"""Base provider abstract class for LLM providers.

This module defines the abstract base class that all LLM providers must implement,
along with supporting dataclasses for model metadata, pricing, and capabilities.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Optional

if TYPE_CHECKING:
    from ..data_types import LLMMessage, LLMResponse


@dataclass
class ProviderCapabilities:
    """Describes what a provider can do.

    Attributes:
        supports_streaming: Whether the provider supports streaming responses.
        supports_function_calling: Whether the provider supports function/tool calling.
        supports_vision: Whether the provider supports image inputs.
        supports_system_messages: Whether the provider supports system messages.
        max_context_window: Maximum context window size in tokens.
    """

    supports_streaming: bool = False
    supports_function_calling: bool = False
    supports_vision: bool = False
    supports_system_messages: bool = True
    max_context_window: int = 128000


@dataclass
class ModelPricing:
    """Cost per million tokens.

    Attributes:
        input_cost: USD per million input tokens.
        output_cost: USD per million output tokens.
    """

    input_cost: float = 0.0
    output_cost: float = 0.0


@dataclass
class ModelMetadata:
    """Information about a specific model.

    Attributes:
        model_id: Unique identifier for the model.
        display_name: Human-readable name for display.
        context_window: Maximum context window size in tokens.
        pricing: Pricing information for the model.
        capabilities: Model capabilities.
        is_deprecated: Whether the model is deprecated.
    """

    model_id: str
    display_name: str
    context_window: int
    pricing: ModelPricing
    capabilities: ProviderCapabilities = field(default_factory=ProviderCapabilities)
    is_deprecated: bool = False


class BaseProvider(ABC):
    """Abstract base class for LLM providers.

    All LLM providers must inherit from this class and implement the abstract
    methods. This ensures a consistent interface across different providers
    (Anthropic, Ollama, OpenAI, etc.).

    Class Attributes:
        PROVIDER_NAME: Short identifier for the provider (e.g., "anthropic").
        DISPLAY_NAME: Human-readable name (e.g., "Anthropic").
        DESCRIPTION: Brief description of the provider.
        WEBSITE_URL: Provider's website URL.
        SETUP_INSTRUCTIONS: Instructions for setting up the provider.

    Instance Attributes:
        _api_key: API key for authentication (if required).
        _base_url: Base URL for API requests.
        _client: Lazy-initialized provider client.
        _extra_config: Additional provider-specific configuration.
    """

    # === Class-level metadata (must be set by subclasses) ===
    PROVIDER_NAME: str
    DISPLAY_NAME: str
    DESCRIPTION: str
    WEBSITE_URL: str
    SETUP_INSTRUCTIONS: str

    def __init__(
        self,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        **kwargs: object,
    ) -> None:
        """Initialize the provider.

        Args:
            api_key: Optional API key for authentication.
            base_url: Optional custom base URL for API requests.
            **kwargs: Additional provider-specific configuration.
        """
        self._api_key = api_key
        self._base_url = base_url or self.default_base_url
        self._client: object = None
        self._extra_config = kwargs

    # === Provider characteristics (abstract properties) ===

    @property
    @abstractmethod
    def is_local(self) -> bool:
        """True if provider runs locally (no cloud API calls)."""
        pass

    @property
    @abstractmethod
    def is_free(self) -> bool:
        """True if provider has no usage costs."""
        pass

    @property
    @abstractmethod
    def requires_api_key(self) -> bool:
        """True if an API key is required."""
        pass

    @property
    def api_key_env_var(self) -> str:
        """Environment variable name for API key, if any.

        Returns:
            Empty string by default. Override in subclasses that require API keys.
        """
        return ""

    @property
    @abstractmethod
    def default_base_url(self) -> str:
        """Default API endpoint URL."""
        pass

    @property
    @abstractmethod
    def default_model(self) -> str:
        """Default model ID for this provider."""
        pass

    # === Core Operations (abstract methods) ===

    @abstractmethod
    def chat(
        self,
        messages: list["LLMMessage"],
        model: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
        **kwargs: object,
    ) -> "LLMResponse":
        """Send a chat completion request.

        Args:
            messages: List of messages in the conversation.
            model: Model ID to use. Defaults to provider's default model.
            temperature: Sampling temperature (0.0 to 1.0).
            max_tokens: Maximum tokens in the response.
            **kwargs: Additional provider-specific parameters.

        Returns:
            LLMResponse with the model's response.
        """
        pass

    @abstractmethod
    def list_models(self) -> list[ModelMetadata]:
        """Return list of available models with metadata.

        Returns:
            List of ModelMetadata objects for available models.
        """
        pass

    @abstractmethod
    def test_connection(self) -> tuple[bool, str]:
        """Test provider connectivity.

        Returns:
            Tuple of (success, message) where success is True if connected
            and message provides details or error information.
        """
        pass

    # === Token Handling ===

    @abstractmethod
    def count_tokens(self, text: str, model: Optional[str] = None) -> int:
        """Count tokens in text for the given model.

        Args:
            text: Text to count tokens for.
            model: Model to use for tokenization. Defaults to provider's default.

        Returns:
            Number of tokens in the text.
        """
        pass

    def get_model_pricing(self, model: str) -> ModelPricing:
        """Get pricing for a specific model.

        Default implementation returns zero cost. Override for paid providers.

        Args:
            model: Model ID to get pricing for.

        Returns:
            ModelPricing with input and output costs.
        """
        return ModelPricing(input_cost=0.0, output_cost=0.0)

    def calculate_cost(
        self,
        model: str,
        input_tokens: int,
        output_tokens: int,
    ) -> float:
        """Calculate cost in USD for token usage.

        Args:
            model: Model ID used.
            input_tokens: Number of input tokens.
            output_tokens: Number of output tokens.

        Returns:
            Total cost in USD.
        """
        pricing = self.get_model_pricing(model)
        return (input_tokens / 1_000_000) * pricing.input_cost + (
            output_tokens / 1_000_000
        ) * pricing.output_cost

    # === Utility Methods ===

    def get_model_metadata(self, model: str) -> Optional[ModelMetadata]:
        """Get metadata for a specific model.

        Args:
            model: Model ID to get metadata for.

        Returns:
            ModelMetadata if found, None otherwise.
        """
        for m in self.list_models():
            if m.model_id == model:
                return m
        return None

    def validate_model(self, model: str) -> bool:
        """Check if model ID is valid for this provider.

        Args:
            model: Model ID to validate.

        Returns:
            True if the model is available, False otherwise.
        """
        return any(m.model_id == model for m in self.list_models())

    def format_model_string(self, model: str) -> str:
        """Return full provider:model string.

        Args:
            model: Model ID.

        Returns:
            String in format "provider:model".
        """
        return f"{self.PROVIDER_NAME}:{model}"
