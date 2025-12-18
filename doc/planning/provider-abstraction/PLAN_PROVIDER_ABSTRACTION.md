# Provider Base Class Abstraction - Design Plan

## Design Decisions
- **Sync only** - No async/streaming for now (can be added later)
- **API-first model discovery** - Query provider APIs for available models, cache results
- **Migrate pricing fully** - Remove `MODEL_COSTS` from `data_types.py`, pricing lives in providers

---

## Quick Summary

### New Files to Create
1. `src/bmlibrarian_lite/llm/providers/base.py` - Abstract `BaseProvider` class with:
   - Attributes: `PROVIDER_NAME`, `DISPLAY_NAME`, `is_local`, `is_free`, `requires_api_key`, `api_key_env_var`, `default_base_url`, `default_model`
   - Methods: `chat()`, `list_models()`, `test_connection()`, `count_tokens()`, `get_model_pricing()`, `calculate_cost()`
   - Dataclasses: `ModelPricing`, `ModelMetadata`, `ProviderCapabilities`

2. `src/bmlibrarian_lite/llm/providers/anthropic.py` - `AnthropicProvider` implementation

3. `src/bmlibrarian_lite/llm/providers/ollama.py` - `OllamaProvider` implementation

4. `src/bmlibrarian_lite/llm/providers/__init__.py` - Registry with `get_provider()`, `list_providers()`, `register_provider()`

### Files to Modify
- `llm/client.py` - Delegate to providers instead of inline methods
- `llm/data_types.py` - Remove `MODEL_COSTS` dict
- `llm/token_tracker.py` - Get pricing from providers
- `constants.py` - Remove `LLM_PROVIDERS` dict
- `gui/settings_dialog.py` - Use provider introspection

### Backward Compatibility
- `LLMClient` API unchanged
- `provider:model` string format unchanged
- Global singleton via `get_llm_client()` unchanged

---

## Overview

Design a flexible provider abstraction layer that decouples provider-specific logic from the LLMClient, enabling easy addition of new providers (OpenAI, Cohere, Google, etc.) with minimal code changes.

## Current State Analysis

### What Exists Today
- **LLMClient** (`llm/client.py`) - Monolithic client with provider-specific methods:
  - `_chat_anthropic()` and `_chat_ollama()` hardcoded in the same class
  - `_parse_model_string()` extracts provider:model format
  - `list_models()` has provider-specific branches
  - `test_connection()` has provider-specific logic

- **Configuration** (`config.py`):
  - `ProviderConfig` - per-provider settings (enabled, base_url, default_model)
  - `TaskModelConfig` - per-task model selection
  - `ModelsConfig` - orchestrates task→provider→model routing

- **Constants** (`constants.py`):
  - `LLM_PROVIDERS` dict with provider metadata
  - `LLM_TASK_TYPES` with task defaults

- **Token Tracking** (`llm/token_tracker.py`, `llm/data_types.py`):
  - `MODEL_COSTS` dict with per-model pricing
  - `TokenTracker` records usage per call

### Pain Points
1. Adding a new provider requires modifying LLMClient in multiple places
2. Provider-specific logic scattered (client, settings dialog, constants)
3. No capability introspection (context window, features, etc.)
4. Hardcoded model lists for Anthropic
5. Token counting is provider-specific but not abstracted

---

## Proposed Architecture

### Core Design Principles
1. **Single Responsibility**: Each provider class handles only its own API
2. **Open/Closed**: Add providers by creating new classes, not modifying existing code
3. **Dependency Inversion**: LLMClient depends on abstract provider interface
4. **Configuration-driven**: Provider metadata in one place, not scattered

### File Structure
```
src/bmlibrarian_lite/llm/
├── __init__.py
├── client.py              # LLMClient (orchestrator, delegates to providers)
├── data_types.py          # LLMMessage, LLMResponse, ModelInfo (existing)
├── token_tracker.py       # TokenTracker (existing)
└── providers/
    ├── __init__.py        # Provider registry, get_provider()
    ├── base.py            # BaseProvider abstract class
    ├── anthropic.py       # AnthropicProvider
    └── ollama.py          # OllamaProvider
```

---

## BaseProvider Abstract Class Design

### Core Attributes

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional

@dataclass
class ProviderCapabilities:
    """Describes what a provider can do."""
    supports_streaming: bool = False
    supports_function_calling: bool = False
    supports_vision: bool = False
    supports_system_messages: bool = True
    max_context_window: int = 128000  # Default, overridden per model

@dataclass
class ModelPricing:
    """Cost per million tokens."""
    input_cost: float = 0.0   # USD per million input tokens
    output_cost: float = 0.0  # USD per million output tokens

@dataclass
class ModelMetadata:
    """Information about a specific model."""
    model_id: str
    display_name: str
    context_window: int
    pricing: ModelPricing
    capabilities: ProviderCapabilities = field(default_factory=ProviderCapabilities)
    is_deprecated: bool = False
```

### Base Provider Interface

```python
class BaseProvider(ABC):
    """Abstract base class for LLM providers."""

    # === Class-level metadata ===
    PROVIDER_NAME: str           # e.g., "anthropic", "ollama"
    DISPLAY_NAME: str            # e.g., "Anthropic", "Ollama"
    DESCRIPTION: str             # Human-readable description
    WEBSITE_URL: str             # Provider website
    SETUP_INSTRUCTIONS: str      # How to set up

    # === Provider characteristics ===
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
        """Environment variable name for API key, if any."""
        return ""

    # === Configuration ===
    def __init__(
        self,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        **kwargs
    ):
        self._api_key = api_key
        self._base_url = base_url or self.default_base_url
        self._client = None  # Lazy initialization
        self._extra_config = kwargs

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

    # === Core Operations ===
    @abstractmethod
    def chat(
        self,
        messages: list[LLMMessage],
        model: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
        **kwargs
    ) -> LLMResponse:
        """Send a chat completion request."""
        pass

    @abstractmethod
    def list_models(self) -> list[ModelMetadata]:
        """Return list of available models with metadata."""
        pass

    @abstractmethod
    def test_connection(self) -> tuple[bool, str]:
        """
        Test provider connectivity.

        Returns:
            (success, message) tuple
        """
        pass

    # === Token Handling ===
    @abstractmethod
    def count_tokens(self, text: str, model: Optional[str] = None) -> int:
        """Count tokens in text for the given model."""
        pass

    def get_model_pricing(self, model: str) -> ModelPricing:
        """
        Get pricing for a specific model.

        Default implementation returns zero cost.
        Override for paid providers.
        """
        return ModelPricing(input_cost=0.0, output_cost=0.0)

    def calculate_cost(
        self,
        model: str,
        input_tokens: int,
        output_tokens: int
    ) -> float:
        """Calculate cost in USD for token usage."""
        pricing = self.get_model_pricing(model)
        return (
            (input_tokens / 1_000_000) * pricing.input_cost +
            (output_tokens / 1_000_000) * pricing.output_cost
        )

    # === Utility Methods ===
    def get_model_metadata(self, model: str) -> Optional[ModelMetadata]:
        """Get metadata for a specific model."""
        for m in self.list_models():
            if m.model_id == model:
                return m
        return None

    def validate_model(self, model: str) -> bool:
        """Check if model ID is valid for this provider."""
        return any(m.model_id == model for m in self.list_models())

    def format_model_string(self, model: str) -> str:
        """Return full provider:model string."""
        return f"{self.PROVIDER_NAME}:{model}"
```

---

## Provider Implementations

### AnthropicProvider

```python
class AnthropicProvider(BaseProvider):
    """Anthropic Claude API provider."""

    PROVIDER_NAME = "anthropic"
    DISPLAY_NAME = "Anthropic"
    DESCRIPTION = "Claude models via Anthropic API"
    WEBSITE_URL = "https://console.anthropic.com"
    SETUP_INSTRUCTIONS = "Get API key from console.anthropic.com/account/keys"

    # Known model pricing (costs per million tokens) - used for cost calculation
    # Models are discovered via API, this provides pricing metadata
    MODEL_PRICING = {
        "claude-opus-4-20250514": ModelPricing(input_cost=15.0, output_cost=75.0),
        "claude-sonnet-4-20250514": ModelPricing(input_cost=3.0, output_cost=15.0),
        "claude-3-5-sonnet-20241022": ModelPricing(input_cost=3.0, output_cost=15.0),
        "claude-3-5-haiku-20241022": ModelPricing(input_cost=1.0, output_cost=5.0),
        "claude-3-opus-20240229": ModelPricing(input_cost=15.0, output_cost=75.0),
        "claude-3-sonnet-20240229": ModelPricing(input_cost=3.0, output_cost=15.0),
        "claude-3-haiku-20240307": ModelPricing(input_cost=0.25, output_cost=1.25),
    }

    # Cache for API-fetched models
    _models_cache: list[ModelMetadata] | None = None
    _cache_timestamp: float = 0
    CACHE_TTL = 3600  # 1 hour

    @property
    def is_local(self) -> bool:
        return False

    @property
    def is_free(self) -> bool:
        return False

    @property
    def requires_api_key(self) -> bool:
        return True

    @property
    def api_key_env_var(self) -> str:
        return "ANTHROPIC_API_KEY"

    @property
    def default_base_url(self) -> str:
        return "https://api.anthropic.com"

    @property
    def default_model(self) -> str:
        return "claude-sonnet-4-20250514"

    def _get_client(self):
        """Lazy initialization of Anthropic client."""
        if self._client is None:
            import anthropic
            self._client = anthropic.Anthropic(
                api_key=self._api_key,
                base_url=self._base_url if self._base_url != self.default_base_url else None,
            )
        return self._client

    def chat(self, messages, model=None, temperature=0.7, max_tokens=4096, **kwargs):
        """Send chat request to Anthropic API."""
        model = model or self.default_model
        client = self._get_client()

        # Separate system message (Anthropic API requirement)
        system_content = ""
        chat_messages = []
        for msg in messages:
            if msg.role == "system":
                system_content = msg.content
            else:
                chat_messages.append({"role": msg.role, "content": msg.content})

        response = client.messages.create(
            model=model,
            max_tokens=max_tokens,
            temperature=temperature,
            system=system_content or None,
            messages=chat_messages,
        )

        return LLMResponse(
            content=response.content[0].text,
            model=model,
            input_tokens=response.usage.input_tokens,
            output_tokens=response.usage.output_tokens,
            stop_reason=response.stop_reason,
        )

    def list_models(self, force_refresh: bool = False) -> list[ModelMetadata]:
        """Fetch available models from Anthropic API with caching."""
        import time

        # Return cached if valid
        if (not force_refresh and
            self._models_cache is not None and
            time.time() - self._cache_timestamp < self.CACHE_TTL):
            return self._models_cache

        try:
            client = self._get_client()
            api_models = client.models.list()
            models = []
            for model in api_models:
                model_id = model.id
                pricing = self.MODEL_PRICING.get(
                    model_id,
                    ModelPricing(input_cost=3.0, output_cost=15.0)  # Default to Sonnet pricing
                )
                models.append(ModelMetadata(
                    model_id=model_id,
                    display_name=getattr(model, 'display_name', model_id),
                    context_window=getattr(model, 'context_window', 200000),
                    pricing=pricing,
                ))
            self._models_cache = models
            self._cache_timestamp = time.time()
            return models
        except Exception:
            # Fallback: return models we know about from pricing dict
            return [
                ModelMetadata(model_id=mid, display_name=mid, context_window=200000, pricing=p)
                for mid, p in self.MODEL_PRICING.items()
            ]

    def test_connection(self) -> tuple[bool, str]:
        """Test API connectivity."""
        try:
            client = self._get_client()
            models = client.models.list()
            return True, f"Connected. {len(list(models))} models available."
        except anthropic.AuthenticationError:
            return False, "Invalid API key"
        except Exception as e:
            return False, str(e)

    def count_tokens(self, text: str, model: Optional[str] = None) -> int:
        """Count tokens using Anthropic's tokenizer."""
        try:
            client = self._get_client()
            return client.count_tokens(text)
        except Exception:
            # Fallback: rough estimate
            return len(text) // 4

    def get_model_pricing(self, model: str) -> ModelPricing:
        """Get pricing for Anthropic model."""
        if model in self.MODEL_PRICING:
            return self.MODEL_PRICING[model]
        return ModelPricing(input_cost=3.0, output_cost=15.0)  # Default to Sonnet
```

### OllamaProvider

```python
class OllamaProvider(BaseProvider):
    """Ollama local model provider."""

    PROVIDER_NAME = "ollama"
    DISPLAY_NAME = "Ollama"
    DESCRIPTION = "Local models via Ollama server (free)"
    WEBSITE_URL = "https://ollama.ai"
    SETUP_INSTRUCTIONS = "Install from ollama.ai, then run 'ollama pull medgemma4B_it_q8'"

    # Cache for model metadata from ollama.show()
    _model_info_cache: dict[str, ModelMetadata] = {}

    @property
    def is_local(self) -> bool:
        return True

    @property
    def is_free(self) -> bool:
        return True

    @property
    def requires_api_key(self) -> bool:
        return False

    @property
    def default_base_url(self) -> str:
        return "http://localhost:11434"

    @property
    def default_model(self) -> str:
        return "medgemma4B_it_q8"

    def _get_client(self):
        """Lazy initialization of Ollama client."""
        if self._client is None:
            import ollama
            self._client = ollama.Client(host=self._base_url)
        return self._client

    def chat(self, messages, model=None, temperature=0.7, max_tokens=4096, **kwargs):
        """Send chat request to Ollama."""
        model = model or self.default_model
        client = self._get_client()

        ollama_messages = [
            {"role": msg.role, "content": msg.content}
            for msg in messages
        ]

        response = client.chat(
            model=model,
            messages=ollama_messages,
            options={
                "temperature": temperature,
                "num_predict": max_tokens,
            },
        )

        # Ollama returns token counts in response
        content = response.get("message", {}).get("content", "")
        input_tokens = response.get("prompt_eval_count", self._estimate_tokens(messages))
        output_tokens = response.get("eval_count", len(content) // 4)

        return LLMResponse(
            content=content,
            model=model,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            stop_reason="stop",
        )

    def _estimate_tokens(self, messages: list[LLMMessage]) -> int:
        """Estimate input token count (fallback only)."""
        total_chars = sum(len(m.content) for m in messages)
        return total_chars // 4

    def _get_model_info(self, model_name: str) -> ModelMetadata:
        """
        Fetch model metadata using ollama.show().

        Caches results to avoid repeated API calls.
        """
        if model_name in self._model_info_cache:
            return self._model_info_cache[model_name]

        try:
            client = self._get_client()
            info = client.show(model_name)

            # Extract context window from modelfile parameters
            # ollama.show() returns details including 'parameters' or 'modelfile'
            modelfile = info.get("modelfile", "")
            parameters = info.get("parameters", {})

            # Context length can be in parameters dict or parsed from modelfile
            context_window = 8192  # Default fallback
            if isinstance(parameters, dict):
                context_window = parameters.get("num_ctx", 8192)
            elif "num_ctx" in modelfile:
                # Parse from modelfile string if needed
                import re
                match = re.search(r"num_ctx\s+(\d+)", modelfile)
                if match:
                    context_window = int(match.group(1))

            # Get model details
            details = info.get("details", {})
            family = details.get("family", "")
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

        except Exception:
            # Fallback if show() fails
            return ModelMetadata(
                model_id=model_name,
                display_name=model_name,
                context_window=8192,
                pricing=ModelPricing(0.0, 0.0),
            )

    def list_models(self) -> list[ModelMetadata]:
        """Query Ollama for available models with full metadata."""
        try:
            client = self._get_client()
            response = client.list()
            models = []
            for model_info in response.get("models", []):
                name = model_info.get("name", "")
                # Get full metadata via show()
                metadata = self._get_model_info(name)
                models.append(metadata)
            return models
        except Exception:
            return []

    def test_connection(self) -> tuple[bool, str]:
        """Test Ollama server connectivity."""
        try:
            models = self.list_models()
            if models:
                return True, f"Connected. {len(models)} models available."
            return True, "Connected. No models installed."
        except Exception as e:
            return False, f"Connection failed: {e}"

    def count_tokens(self, text: str, model: Optional[str] = None) -> int:
        """Estimate tokens (Ollama doesn't expose tokenizer directly)."""
        # Could potentially use ollama's tokenize endpoint if available
        return len(text) // 4

    def get_model_pricing(self, model: str) -> ModelPricing:
        """Ollama is always free."""
        return ModelPricing(0.0, 0.0)

    def get_model_metadata(self, model: str) -> Optional[ModelMetadata]:
        """Get metadata for a specific model using ollama.show()."""
        return self._get_model_info(model)
```

---

## Provider Registry

```python
# providers/__init__.py

from typing import Optional, Type
from .base import BaseProvider
from .anthropic import AnthropicProvider
from .ollama import OllamaProvider

# Registry mapping provider names to classes
_PROVIDER_REGISTRY: dict[str, Type[BaseProvider]] = {
    "anthropic": AnthropicProvider,
    "ollama": OllamaProvider,
}

def register_provider(name: str, provider_class: Type[BaseProvider]) -> None:
    """Register a new provider."""
    _PROVIDER_REGISTRY[name] = provider_class

def get_provider_class(name: str) -> Optional[Type[BaseProvider]]:
    """Get provider class by name."""
    return _PROVIDER_REGISTRY.get(name)

def list_providers() -> list[str]:
    """List all registered provider names."""
    return list(_PROVIDER_REGISTRY.keys())

def get_provider(
    name: str,
    api_key: Optional[str] = None,
    base_url: Optional[str] = None,
    **kwargs
) -> BaseProvider:
    """
    Factory function to create provider instance.

    Args:
        name: Provider name (e.g., "anthropic", "ollama")
        api_key: Optional API key (or read from environment)
        base_url: Optional custom base URL
        **kwargs: Additional provider-specific config

    Returns:
        Configured provider instance

    Raises:
        ValueError: If provider name is unknown
    """
    provider_class = _PROVIDER_REGISTRY.get(name)
    if provider_class is None:
        available = ", ".join(_PROVIDER_REGISTRY.keys())
        raise ValueError(f"Unknown provider '{name}'. Available: {available}")

    return provider_class(api_key=api_key, base_url=base_url, **kwargs)
```

---

## Updated LLMClient Integration

The refactored `LLMClient` becomes a thin orchestrator:

```python
class LLMClient:
    """Unified LLM client that delegates to provider implementations."""

    def __init__(
        self,
        anthropic_api_key: Optional[str] = None,
        ollama_host: Optional[str] = None,
        default_provider: str = "anthropic",
    ):
        self.default_provider = default_provider
        self._providers: dict[str, BaseProvider] = {}

        # Store config for lazy initialization
        self._provider_config = {
            "anthropic": {"api_key": anthropic_api_key},
            "ollama": {"base_url": ollama_host},
        }

    def _get_provider(self, name: str) -> BaseProvider:
        """Get or create provider instance (lazy initialization)."""
        if name not in self._providers:
            config = self._provider_config.get(name, {})
            self._providers[name] = get_provider(name, **config)
        return self._providers[name]

    def chat(
        self,
        messages: list[LLMMessage],
        model: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
        **kwargs,
    ) -> LLMResponse:
        """Send chat request to appropriate provider."""
        provider_name, model_name = self._parse_model_string(model)
        provider = self._get_provider(provider_name)

        response = provider.chat(
            messages=messages,
            model=model_name,
            temperature=temperature,
            max_tokens=max_tokens,
            **kwargs,
        )

        # Track token usage
        tracker = get_token_tracker()
        cost = provider.calculate_cost(model_name, response.input_tokens, response.output_tokens)
        tracker.record_usage(
            model=f"{provider_name}:{model_name}",
            input_tokens=response.input_tokens,
            output_tokens=response.output_tokens,
            cost=cost,
        )

        return response

    def _parse_model_string(self, model: Optional[str]) -> tuple[str, str]:
        """Parse 'provider:model' string into components."""
        if model and ":" in model:
            parts = model.split(":", 1)
            return parts[0], parts[1]

        provider = self.default_provider
        provider_instance = self._get_provider(provider)
        model_name = model or provider_instance.default_model
        return provider, model_name

    def list_models(self, provider: Optional[str] = None) -> list[ModelMetadata]:
        """List available models."""
        if provider:
            return self._get_provider(provider).list_models()

        # All providers
        all_models = []
        for name in list_providers():
            try:
                all_models.extend(self._get_provider(name).list_models())
            except Exception:
                pass
        return all_models

    def test_connection(self, provider: Optional[str] = None) -> dict[str, tuple[bool, str]]:
        """Test provider connections."""
        providers_to_test = [provider] if provider else list_providers()
        results = {}
        for name in providers_to_test:
            try:
                p = self._get_provider(name)
                results[name] = p.test_connection()
            except Exception as e:
                results[name] = (False, str(e))
        return results
```

---

## Migration Strategy

### Phase 1: Create Provider Infrastructure
1. Create `src/bmlibrarian_lite/llm/providers/` directory
2. Implement `base.py` with `BaseProvider` abstract class
3. Implement `AnthropicProvider` extracting logic from current `_chat_anthropic()`
4. Implement `OllamaProvider` extracting logic from current `_chat_ollama()`
5. Create `providers/__init__.py` with registry

### Phase 2: Refactor LLMClient
1. Modify `client.py` to use provider registry
2. Replace inline `_chat_anthropic()` and `_chat_ollama()` with provider delegation
3. Update `list_models()` and `test_connection()` to use providers
4. Maintain backward compatibility with existing API

### Phase 3: Update Dependent Code
1. Update `constants.py` - move `LLM_PROVIDERS` metadata into provider classes
2. Update `config.py` - simplify `ProviderConfig` if needed
3. Update `gui/settings_dialog.py` - use provider introspection for UI
4. Update `data_types.py` - remove `MODEL_COSTS` (now in providers)

### Phase 4: Testing & Documentation
1. Add unit tests for each provider
2. Add integration tests for provider switching
3. Update docstrings and type hints

---

## Future Extensibility

### Adding a New Provider (e.g., OpenAI)

```python
# providers/openai.py
class OpenAIProvider(BaseProvider):
    PROVIDER_NAME = "openai"
    DISPLAY_NAME = "OpenAI"
    # ... implement abstract methods
```

```python
# providers/__init__.py - just add import
from .openai import OpenAIProvider
_PROVIDER_REGISTRY["openai"] = OpenAIProvider
```

### Potential Future Providers
- **OpenAI** - GPT-4, GPT-4o
- **Google** - Gemini
- **Cohere** - Command R+
- **Together AI** - Various open models
- **Groq** - Fast inference
- **Azure OpenAI** - Enterprise deployment
- **AWS Bedrock** - Multiple models

### Plugin Architecture (Future)
Could support dynamic loading:
```python
def load_provider_plugin(module_path: str) -> None:
    """Load provider from external module."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("provider", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    register_provider(module.Provider.PROVIDER_NAME, module.Provider)
```

---

## Files to Modify

| File | Changes |
|------|---------|
| `llm/providers/__init__.py` | **NEW** - Registry and factory functions |
| `llm/providers/base.py` | **NEW** - BaseProvider abstract class + dataclasses |
| `llm/providers/anthropic.py` | **NEW** - AnthropicProvider with API-based model discovery |
| `llm/providers/ollama.py` | **NEW** - OllamaProvider |
| `llm/client.py` | Refactor to use provider delegation |
| `llm/data_types.py` | Add ModelMetadata, ProviderCapabilities, ModelPricing; **remove MODEL_COSTS** |
| `llm/token_tracker.py` | Update to get pricing from providers instead of MODEL_COSTS |
| `constants.py` | Remove `LLM_PROVIDERS` dict (move to provider classes) |
| `gui/settings_dialog.py` | Use provider introspection for model fetching |

## Backward Compatibility

- Keep `LLMClient` API unchanged (same `chat()`, `list_models()`, `test_connection()` signatures)
- Keep `provider:model` string format
- Keep global singleton pattern via `get_llm_client()`
- Existing agent code requires no changes

---

## Summary

This design:
1. **Separates concerns** - Each provider manages its own API details
2. **Enables easy extension** - Add providers by creating new classes
3. **Centralizes metadata** - Pricing, capabilities, model info in provider classes
4. **Maintains compatibility** - Existing code continues to work unchanged
5. **Supports introspection** - `is_local`, `is_free`, capabilities, pricing all queryable
6. **Provides flexibility** - Custom base URLs, lazy initialization, per-provider config
