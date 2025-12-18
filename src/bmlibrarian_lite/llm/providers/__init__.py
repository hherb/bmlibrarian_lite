"""LLM Provider registry and factory functions.

This module provides a registry for LLM providers and factory functions
for creating provider instances.

Usage:
    from bmlibrarian_lite.llm.providers import get_provider, list_providers

    # Get a provider instance
    provider = get_provider("anthropic", api_key="...")

    # List all registered providers
    providers = list_providers()

    # Get provider class for introspection
    provider_class = get_provider_class("ollama")
"""

from typing import Optional, Type

from .base import (
    BaseProvider,
    ModelMetadata,
    ModelPricing,
    ProviderCapabilities,
)
from .anthropic import AnthropicProvider
from .ollama import OllamaProvider


# Registry mapping provider names to classes
_PROVIDER_REGISTRY: dict[str, Type[BaseProvider]] = {
    "anthropic": AnthropicProvider,
    "ollama": OllamaProvider,
}


def register_provider(name: str, provider_class: Type[BaseProvider]) -> None:
    """Register a new provider.

    Args:
        name: Provider name (e.g., "openai").
        provider_class: Provider class that inherits from BaseProvider.
    """
    _PROVIDER_REGISTRY[name] = provider_class


def get_provider_class(name: str) -> Optional[Type[BaseProvider]]:
    """Get provider class by name.

    Args:
        name: Provider name (e.g., "anthropic").

    Returns:
        Provider class if found, None otherwise.
    """
    return _PROVIDER_REGISTRY.get(name)


def list_providers() -> list[str]:
    """List all registered provider names.

    Returns:
        List of provider name strings.
    """
    return list(_PROVIDER_REGISTRY.keys())


def get_provider(
    name: str,
    api_key: Optional[str] = None,
    base_url: Optional[str] = None,
    **kwargs: object,
) -> BaseProvider:
    """Factory function to create provider instance.

    Args:
        name: Provider name (e.g., "anthropic", "ollama").
        api_key: Optional API key (or read from environment).
        base_url: Optional custom base URL.
        **kwargs: Additional provider-specific config.

    Returns:
        Configured provider instance.

    Raises:
        ValueError: If provider name is unknown.
    """
    provider_class = _PROVIDER_REGISTRY.get(name)
    if provider_class is None:
        available = ", ".join(_PROVIDER_REGISTRY.keys())
        raise ValueError(f"Unknown provider '{name}'. Available: {available}")

    return provider_class(api_key=api_key, base_url=base_url, **kwargs)


def get_provider_info(name: str) -> dict[str, object]:
    """Get metadata about a provider.

    Args:
        name: Provider name.

    Returns:
        Dict with provider metadata (name, display_name, is_local, etc.).

    Raises:
        ValueError: If provider name is unknown.
    """
    provider_class = _PROVIDER_REGISTRY.get(name)
    if provider_class is None:
        available = ", ".join(_PROVIDER_REGISTRY.keys())
        raise ValueError(f"Unknown provider '{name}'. Available: {available}")

    # Create a temporary instance to read properties
    # This is safe because __init__ just sets defaults
    instance = provider_class()

    return {
        "name": provider_class.PROVIDER_NAME,
        "display_name": provider_class.DISPLAY_NAME,
        "description": provider_class.DESCRIPTION,
        "website_url": provider_class.WEBSITE_URL,
        "setup_instructions": provider_class.SETUP_INSTRUCTIONS,
        "is_local": instance.is_local,
        "is_free": instance.is_free,
        "requires_api_key": instance.requires_api_key,
        "api_key_env_var": instance.api_key_env_var,
        "default_base_url": instance.default_base_url,
        "default_model": instance.default_model,
    }


def get_all_provider_info() -> dict[str, dict[str, object]]:
    """Get metadata about all registered providers.

    Returns:
        Dict mapping provider names to their metadata.
    """
    return {name: get_provider_info(name) for name in _PROVIDER_REGISTRY}


# Export public API
__all__ = [
    # Base classes and types
    "BaseProvider",
    "ModelMetadata",
    "ModelPricing",
    "ProviderCapabilities",
    # Provider implementations
    "AnthropicProvider",
    "OllamaProvider",
    # Registry functions
    "register_provider",
    "get_provider_class",
    "list_providers",
    "get_provider",
    "get_provider_info",
    "get_all_provider_info",
]
