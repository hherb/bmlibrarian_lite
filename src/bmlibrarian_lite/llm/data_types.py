"""Data types for LLM communication.

Provides type-safe dataclasses for messages and responses.

Note: Model pricing has moved to the provider classes in providers/.
Use provider.get_model_pricing(model) instead of MODEL_COSTS.
"""

from dataclasses import dataclass
from typing import Literal, Optional
import warnings


@dataclass
class LLMMessage:
    """A message in an LLM conversation.

    Attributes:
        role: The role of the message sender (system, user, or assistant).
        content: The text content of the message.
    """

    role: Literal["system", "user", "assistant"]
    content: str


@dataclass
class LLMResponse:
    """Response from an LLM request.

    Attributes:
        content: The text response from the model.
        model: The model that generated the response.
        input_tokens: Number of input tokens used.
        output_tokens: Number of output tokens generated.
        total_tokens: Total tokens used (input + output).
        stop_reason: Why the model stopped generating.
    """

    content: str
    model: str = ""
    input_tokens: int = 0
    output_tokens: int = 0
    total_tokens: int = 0
    stop_reason: Optional[str] = None

    def __post_init__(self) -> None:
        """Calculate total tokens if not provided."""
        if self.total_tokens == 0:
            self.total_tokens = self.input_tokens + self.output_tokens


@dataclass
class ModelInfo:
    """Information about an LLM model.

    .. deprecated::
        Use ModelMetadata from providers.base instead for new code.
        This class is kept for backward compatibility.

    Attributes:
        provider: The provider name (anthropic, ollama).
        model: The model name/ID.
        display_name: Human-readable name.
        input_cost_per_million: Cost per million input tokens (USD).
        output_cost_per_million: Cost per million output tokens (USD).
    """

    provider: str
    model: str
    display_name: str = ""
    input_cost_per_million: float = 0.0
    output_cost_per_million: float = 0.0

    def __post_init__(self) -> None:
        """Set display name if not provided."""
        if not self.display_name:
            self.display_name = f"{self.provider}:{self.model}"


def get_model_info(model: str) -> ModelInfo:
    """Get model information for cost calculation.

    .. deprecated::
        Use provider.get_model_pricing(model) instead.
        Pricing is now managed by individual provider classes.

    Args:
        model: Model name (with or without provider prefix).

    Returns:
        ModelInfo for the model, or default info for unknown models.
    """
    warnings.warn(
        "get_model_info() is deprecated. Use provider.get_model_pricing() instead.",
        DeprecationWarning,
        stacklevel=2,
    )

    # Strip provider prefix if present
    if ":" in model:
        provider, model_name = model.split(":", 1)
    else:
        provider = "unknown"
        model_name = model

    # Try to get pricing from provider
    try:
        from .providers import get_provider

        p = get_provider(provider)
        pricing = p.get_model_pricing(model_name)
        return ModelInfo(
            provider=provider,
            model=model_name,
            display_name=model_name,
            input_cost_per_million=pricing.input_cost,
            output_cost_per_million=pricing.output_cost,
        )
    except (ImportError, ValueError):
        pass

    # Default for unknown models
    return ModelInfo(
        provider=provider,
        model=model_name,
        display_name=model_name,
        input_cost_per_million=0.0,
        output_cost_per_million=0.0,
    )
