# Implementation Plan: Multi-Provider Task-Based Model Configuration

## Overview

This plan implements a comprehensive task-based model configuration system that allows users to:
1. Configure multiple LLM providers (Anthropic, Ollama, potentially more)
2. Assign specific provider/model/parameters to each task type
3. Mix providers (e.g., Ollama for simple tasks, Anthropic for complex ones)
4. Reduce costs during development by using free local models

## Current Architecture

### LLM Task Types Identified

| Task ID | Task Name | Current Model | Temperature | Complexity | Cost Impact |
|---------|-----------|---------------|-------------|------------|-------------|
| `query_conversion` | Query Conversion | Sonnet | 0.1 | Low | Low |
| `document_scoring` | Document Scoring | Sonnet | 0.1 | Medium | High (per doc) |
| `citation_extraction` | Citation Extraction | Sonnet | 0.1 | Medium | High (per doc) |
| `report_generation` | Report Generation | Sonnet | 0.3 | High | Medium |
| `query_expansion` | Query Expansion | Sonnet | 0.3 | Low | Low |
| `document_qa` | Document Q&A | Sonnet | 0.2 | High | Variable |
| `document_summary` | Document Summary | Sonnet | 0.2 | Low-Med | Low |
| `study_classification` | Study Classification | Haiku | 0.1 | Low | Medium (per doc) |
| `quality_assessment` | Quality Assessment | Sonnet | 0.1 | High | High (per doc) |

### Current Limitations
- Settings UI only shows Anthropic models
- No provider selection in UI
- Quality models hardcoded in constants
- No task-specific configuration exposed to users

---

## Proposed Architecture

### 1. Data Models

#### 1.1 Task Model Configuration (`config.py`)

```python
@dataclass
class TaskModelConfig:
    """Configuration for a single LLM task."""

    provider: str = "anthropic"          # Provider name
    model: str = ""                       # Model name (empty = use provider default)
    temperature: float = 0.3             # Sampling temperature
    max_tokens: int = 4096               # Maximum output tokens
    top_p: Optional[float] = None        # Nucleus sampling (None = not set)
    top_k: Optional[int] = None          # Top-k sampling (None = not set)
    context_window: Optional[int] = None # Context limit (None = use model default)

    # If True, inherit unset values from default config
    use_defaults: bool = True


@dataclass
class ProviderConfig:
    """Configuration for an LLM provider."""

    name: str                            # Provider identifier
    enabled: bool = True                 # Whether provider is available
    api_key_env_var: str = ""           # Environment variable for API key
    base_url: str = ""                  # Base URL (for Ollama, custom endpoints)
    default_model: str = ""             # Default model for this provider


@dataclass
class MultiModelConfig:
    """Complete multi-provider, task-based model configuration."""

    # Provider configurations
    providers: dict[str, ProviderConfig] = field(default_factory=dict)

    # Default task configuration (fallback for all tasks)
    default: TaskModelConfig = field(default_factory=TaskModelConfig)

    # Task-specific overrides
    tasks: dict[str, TaskModelConfig] = field(default_factory=dict)

    def get_task_config(self, task_id: str) -> TaskModelConfig:
        """Get effective configuration for a task, with inheritance."""
        if task_id in self.tasks and not self.tasks[task_id].use_defaults:
            return self.tasks[task_id]

        # Merge task config with defaults
        task = self.tasks.get(task_id, TaskModelConfig())
        return TaskModelConfig(
            provider=task.provider or self.default.provider,
            model=task.model or self.default.model,
            temperature=task.temperature if task.temperature != 0.3 else self.default.temperature,
            max_tokens=task.max_tokens if task.max_tokens != 4096 else self.default.max_tokens,
            top_p=task.top_p if task.top_p is not None else self.default.top_p,
            top_k=task.top_k if task.top_k is not None else self.default.top_k,
            context_window=task.context_window or self.default.context_window,
            use_defaults=False,
        )
```

#### 1.2 Task Type Registry (`constants.py`)

```python
# Task type definitions with metadata
TASK_TYPES = {
    "query_conversion": {
        "name": "Query Conversion",
        "description": "Convert natural language to PubMed queries",
        "category": "search",
        "default_temperature": 0.1,
        "default_max_tokens": 512,
        "complexity": "low",
        "recommended_models": ["haiku", "llama3.2"],
    },
    "document_scoring": {
        "name": "Document Scoring",
        "description": "Score document relevance (1-5 scale)",
        "category": "analysis",
        "default_temperature": 0.1,
        "default_max_tokens": 256,
        "complexity": "medium",
        "recommended_models": ["haiku", "sonnet"],
    },
    "citation_extraction": {
        "name": "Citation Extraction",
        "description": "Extract relevant passages from documents",
        "category": "analysis",
        "default_temperature": 0.1,
        "default_max_tokens": 512,
        "complexity": "medium",
        "recommended_models": ["haiku", "sonnet"],
    },
    "report_generation": {
        "name": "Report Generation",
        "description": "Generate synthesis reports from citations",
        "category": "generation",
        "default_temperature": 0.3,
        "default_max_tokens": 4096,
        "complexity": "high",
        "recommended_models": ["sonnet", "opus"],
    },
    "query_expansion": {
        "name": "Query Expansion",
        "description": "Generate alternative query phrasings",
        "category": "search",
        "default_temperature": 0.3,
        "default_max_tokens": 200,
        "complexity": "low",
        "recommended_models": ["haiku", "llama3.2"],
    },
    "document_qa": {
        "name": "Document Q&A",
        "description": "Answer questions about documents",
        "category": "interrogation",
        "default_temperature": 0.2,
        "default_max_tokens": 2048,
        "complexity": "high",
        "recommended_models": ["sonnet", "llama3.2"],
    },
    "document_summary": {
        "name": "Document Summary",
        "description": "Generate document summaries",
        "category": "interrogation",
        "default_temperature": 0.2,
        "default_max_tokens": 500,
        "complexity": "medium",
        "recommended_models": ["haiku", "sonnet"],
    },
    "study_classification": {
        "name": "Study Classification",
        "description": "Classify study design type",
        "category": "quality",
        "default_temperature": 0.1,
        "default_max_tokens": 256,
        "complexity": "low",
        "recommended_models": ["haiku", "llama3.2"],
    },
    "quality_assessment": {
        "name": "Quality Assessment",
        "description": "Detailed evidence quality assessment",
        "category": "quality",
        "default_temperature": 0.1,
        "default_max_tokens": 1024,
        "complexity": "high",
        "recommended_models": ["sonnet"],
    },
}

# Task categories for UI grouping
TASK_CATEGORIES = {
    "search": "Search & Queries",
    "analysis": "Document Analysis",
    "generation": "Report Generation",
    "interrogation": "Document Q&A",
    "quality": "Quality Assessment",
}
```

---

### 2. Provider Management

#### 2.1 Provider Registry (`llm/providers.py`)

```python
"""LLM provider registry and management."""

from dataclasses import dataclass
from typing import Optional, Protocol, List
import os


class LLMProvider(Protocol):
    """Protocol for LLM provider implementations."""

    name: str

    def test_connection(self) -> bool:
        """Test if provider is reachable."""
        ...

    def list_models(self) -> List[str]:
        """List available models."""
        ...

    def get_default_model(self) -> str:
        """Get recommended default model."""
        ...


@dataclass
class ProviderInfo:
    """Static information about a provider."""

    id: str
    name: str
    description: str
    api_key_env_var: str
    default_base_url: str
    default_model: str
    setup_instructions: str
    website_url: str


# Provider definitions
PROVIDERS = {
    "anthropic": ProviderInfo(
        id="anthropic",
        name="Anthropic",
        description="Claude models via Anthropic API",
        api_key_env_var="ANTHROPIC_API_KEY",
        default_base_url="https://api.anthropic.com",
        default_model="claude-sonnet-4-20250514",
        setup_instructions="""
1. Create an account at https://console.anthropic.com
2. Generate an API key in Settings > API Keys
3. Enter the key in the API Keys tab
        """.strip(),
        website_url="https://console.anthropic.com",
    ),
    "ollama": ProviderInfo(
        id="ollama",
        name="Ollama",
        description="Local models via Ollama server",
        api_key_env_var="",  # No API key needed
        default_base_url="http://localhost:11434",
        default_model="llama3.2",
        setup_instructions="""
1. Install Ollama from https://ollama.ai
2. Start the Ollama service: `ollama serve`
3. Pull a model: `ollama pull llama3.2`

Popular models for biomedical research:
- llama3.2 (8B) - Good balance of speed and quality
- llama3.1 (8B/70B) - Larger context window
- mistral (7B) - Fast, good for simple tasks
- mixtral (8x7B) - High quality, slower

Verify installation: `ollama list`
        """.strip(),
        website_url="https://ollama.ai",
    ),
}


def get_provider_info(provider_id: str) -> Optional[ProviderInfo]:
    """Get provider information by ID."""
    return PROVIDERS.get(provider_id)


def list_providers() -> List[ProviderInfo]:
    """List all available providers."""
    return list(PROVIDERS.values())
```

#### 2.2 Enhanced LLM Client (`llm/client.py`)

Add methods to support the new configuration:

```python
def chat_with_config(
    self,
    messages: List[LLMMessage],
    task_config: TaskModelConfig,
) -> LLMResponse:
    """
    Send chat request using task configuration.

    Args:
        messages: Conversation messages
        task_config: Task-specific model configuration

    Returns:
        LLMResponse with model's reply
    """
    model_string = f"{task_config.provider}:{task_config.model}"

    return self.chat(
        messages=messages,
        model=model_string,
        temperature=task_config.temperature,
        max_tokens=task_config.max_tokens,
        top_p=task_config.top_p,
    )
```

---

### 3. Settings Dialog UI

#### 3.1 New Tab Structure

```
┌─────────────────────────────────────────────────────────────────┐
│ [Providers] [Tasks] [Embeddings] [PubMed] [API Keys] [Quality]  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  (Tab content area)                                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.2 Providers Tab

```
┌─────────────────────────────────────────────────────────────────┐
│ PROVIDERS TAB                                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│ ┌─ Anthropic ──────────────────────────────────────────────┐   │
│ │ ☑ Enabled                              [Test Connection] │   │
│ │                                                    ✓ OK  │   │
│ │ API Key: [sk-ant-•••••••••••••••           ] [Show/Hide] │   │
│ │                                                          │   │
│ │ Available models: 7 models loaded                        │   │
│ └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│ ┌─ Ollama ─────────────────────────────────────────────────┐   │
│ │ ☑ Enabled                              [Test Connection] │   │
│ │                                              ⚠ No models │   │
│ │ Host URL: [http://localhost:11434                      ] │   │
│ │                                                          │   │
│ │ ┌─────────────────────────────────────────────────────┐ │   │
│ │ │ Setup Instructions:                                 │ │   │
│ │ │ 1. Install Ollama from https://ollama.ai            │ │   │
│ │ │ 2. Start the Ollama service: `ollama serve`         │ │   │
│ │ │ 3. Pull a model: `ollama pull llama3.2`             │ │   │
│ │ │                                                     │ │   │
│ │ │ Popular models for biomedical research:             │ │   │
│ │ │ - llama3.2 (8B) - Good balance of speed/quality     │ │   │
│ │ │ - mistral (7B) - Fast, good for simple tasks        │ │   │
│ │ └─────────────────────────────────────────────────────┘ │   │
│ └──────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.3 Tasks Tab (Main Innovation)

```
┌─────────────────────────────────────────────────────────────────┐
│ TASKS TAB                                                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│ Default Configuration ──────────────────────────────────────    │
│ Provider: [Anthropic     ▼]  Model: [claude-sonnet-4-20250514▼] │
│ Temperature: [0.3  ]  Max Tokens: [4096 ]  Context: [Auto    ]  │
│                                                                 │
│ ─────────────────────────────────────────────────────────────   │
│                                                                 │
│ Task-Specific Settings                                          │
│ ┌───────────────────────────────────────────────────────────┐   │
│ │ [Search & Queries] [Document Analysis] [Generation] [Q&A] │   │
│ ├───────────────────────────────────────────────────────────┤   │
│ │                                                           │   │
│ │ Query Conversion                                     [▼]  │   │
│ │ ├─ ☐ Use custom settings (otherwise use defaults)         │   │
│ │ │  Provider: [Ollama ▼]  Model: [llama3.2 ▼]             │   │
│ │ │  Temperature: [0.1]  Max Tokens: [512]                 │   │
│ │ │  💡 Recommended: haiku, llama3.2 (low complexity)      │   │
│ │                                                           │   │
│ │ Query Expansion                                      [▼]  │   │
│ │ ├─ ☐ Use custom settings                                  │   │
│ │ │  (collapsed - using defaults)                          │   │
│ │                                                           │   │
│ └───────────────────────────────────────────────────────────┘   │
│                                                                 │
│ Cost Estimate: ~$0.003/document with current settings           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.4 Provider/Model Selector Widget (`gui/widgets/model_selector.py`)

```python
"""Reusable provider/model selector widget."""

from PySide6.QtWidgets import (
    QWidget, QHBoxLayout, QVBoxLayout, QComboBox,
    QLabel, QPushButton, QFormLayout, QDoubleSpinBox,
    QSpinBox, QCheckBox, QGroupBox,
)
from PySide6.QtCore import Signal, QThread


class ProviderModelSelector(QWidget):
    """
    Two-stage provider/model selector with dynamic model loading.

    Signals:
        selection_changed(provider: str, model: str): Emitted when selection changes
        connection_tested(provider: str, success: bool, message: str): Connection test result
    """

    selection_changed = Signal(str, str)
    connection_tested = Signal(str, bool, str)

    def __init__(
        self,
        parent=None,
        show_test_button: bool = True,
        compact: bool = False,
    ):
        super().__init__(parent)
        self._setup_ui(show_test_button, compact)
        self._connect_signals()

    def _setup_ui(self, show_test_button: bool, compact: bool):
        layout = QHBoxLayout(self) if compact else QFormLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # Provider selector
        self.provider_combo = QComboBox()
        self.provider_combo.addItems(["Anthropic", "Ollama"])

        # Model selector
        self.model_combo = QComboBox()
        self.model_combo.setMinimumWidth(200)

        # Test button
        if show_test_button:
            self.test_button = QPushButton("Test")
            self.test_button.setMaximumWidth(60)

        # Status indicator
        self.status_label = QLabel()

        if compact:
            layout.addWidget(self.provider_combo)
            layout.addWidget(self.model_combo)
            if show_test_button:
                layout.addWidget(self.test_button)
            layout.addWidget(self.status_label)
        else:
            layout.addRow("Provider:", self.provider_combo)
            layout.addRow("Model:", self.model_combo)

    def set_selection(self, provider: str, model: str):
        """Set current provider and model."""
        ...

    def get_selection(self) -> tuple[str, str]:
        """Get current (provider, model) selection."""
        ...

    def refresh_models(self):
        """Refresh model list for current provider."""
        ...


class TaskConfigWidget(QWidget):
    """
    Complete task configuration widget with all parameters.

    Includes: provider, model, temperature, max_tokens, top_p, top_k, context
    """

    config_changed = Signal(str, object)  # (task_id, TaskModelConfig)

    def __init__(self, task_id: str, task_info: dict, parent=None):
        super().__init__(parent)
        self.task_id = task_id
        self.task_info = task_info
        self._setup_ui()

    def _setup_ui(self):
        layout = QVBoxLayout(self)

        # Use custom checkbox
        self.use_custom = QCheckBox("Use custom settings")
        layout.addWidget(self.use_custom)

        # Settings group (collapsible)
        self.settings_group = QGroupBox()
        settings_layout = QFormLayout(self.settings_group)

        # Provider/Model selector
        self.model_selector = ProviderModelSelector(compact=True)
        settings_layout.addRow("Model:", self.model_selector)

        # Temperature
        self.temperature_spin = QDoubleSpinBox()
        self.temperature_spin.setRange(0.0, 2.0)
        self.temperature_spin.setSingleStep(0.1)
        self.temperature_spin.setValue(self.task_info.get("default_temperature", 0.3))
        settings_layout.addRow("Temperature:", self.temperature_spin)

        # Max tokens
        self.max_tokens_spin = QSpinBox()
        self.max_tokens_spin.setRange(100, 32000)
        self.max_tokens_spin.setValue(self.task_info.get("default_max_tokens", 4096))
        settings_layout.addRow("Max Tokens:", self.max_tokens_spin)

        # Top P
        self.top_p_spin = QDoubleSpinBox()
        self.top_p_spin.setRange(0.0, 1.0)
        self.top_p_spin.setSingleStep(0.05)
        self.top_p_spin.setSpecialValueText("Not set")
        settings_layout.addRow("Top P:", self.top_p_spin)

        # Top K
        self.top_k_spin = QSpinBox()
        self.top_k_spin.setRange(0, 100)
        self.top_k_spin.setSpecialValueText("Not set")
        settings_layout.addRow("Top K:", self.top_k_spin)

        # Context window
        self.context_spin = QSpinBox()
        self.context_spin.setRange(0, 200000)
        self.context_spin.setSingleStep(1000)
        self.context_spin.setSpecialValueText("Auto")
        settings_layout.addRow("Context Window:", self.context_spin)

        layout.addWidget(self.settings_group)

        # Recommendation label
        recommended = self.task_info.get("recommended_models", [])
        if recommended:
            rec_label = QLabel(f"💡 Recommended: {', '.join(recommended)}")
            rec_label.setStyleSheet("color: gray; font-size: 11px;")
            layout.addWidget(rec_label)

        # Connect use_custom to enable/disable settings
        self.use_custom.toggled.connect(self.settings_group.setEnabled)
        self.settings_group.setEnabled(False)
```

---

### 4. Agent Integration

#### 4.1 Updated Base Agent (`agents/base.py`)

```python
class LiteBaseAgent:
    """Base class for LLM-powered agents."""

    # Class-level task ID (override in subclasses)
    TASK_ID: str = "default"

    def __init__(self, config: Optional[LiteConfig] = None):
        self.config = config or LiteConfig.load()
        self._llm_client: Optional[LLMClient] = None

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
        """Get model string for a task."""
        config = self._get_task_config(task_id)
        return f"{config.provider}:{config.model}"

    def _chat(
        self,
        messages: List[LLMMessage],
        task_id: Optional[str] = None,
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
        json_mode: bool = False,
    ) -> LLMResponse:
        """
        Send chat request using task configuration.

        Args:
            messages: Conversation messages
            task_id: Task identifier for config lookup
            temperature: Override temperature (uses task config if None)
            max_tokens: Override max tokens (uses task config if None)
            json_mode: Request JSON output

        Returns:
            LLMResponse from the model
        """
        task_config = self._get_task_config(task_id)

        return self.llm_client.chat(
            messages=messages,
            model=f"{task_config.provider}:{task_config.model}",
            temperature=temperature if temperature is not None else task_config.temperature,
            max_tokens=max_tokens if max_tokens is not None else task_config.max_tokens,
            top_p=task_config.top_p,
            json_mode=json_mode,
        )
```

#### 4.2 Update Agent Classes

Each agent gets a `TASK_ID` class attribute:

```python
# scoring_agent.py
class LiteScoringAgent(LiteBaseAgent):
    TASK_ID = "document_scoring"
    ...

# citation_agent.py
class LiteCitationAgent(LiteBaseAgent):
    TASK_ID = "citation_extraction"
    ...

# reporting_agent.py
class LiteReportingAgent(LiteBaseAgent):
    TASK_ID = "report_generation"
    ...

# interrogation_agent.py
class LiteInterrogationAgent(LiteBaseAgent):
    TASK_ID = "document_qa"  # Primary task

    def _expand_query(self, query: str) -> List[str]:
        # Uses different task ID for this sub-task
        response = self._chat(
            messages=[...],
            task_id="query_expansion",  # Override for this method
        )
        ...

# quality/study_classifier.py
class LiteStudyClassifier(LiteBaseAgent):
    TASK_ID = "study_classification"
    ...

# quality/quality_agent.py
class LiteQualityAgent(LiteBaseAgent):
    TASK_ID = "quality_assessment"
    ...
```

---

### 5. Configuration Persistence

#### 5.1 Updated Config Structure (`config.py`)

```python
@dataclass
class LiteConfig:
    """Main configuration for BMLibrarian Lite."""

    # Existing fields...
    llm: LLMConfig = field(default_factory=LLMConfig)  # Keep for backward compat

    # New multi-model configuration
    models: MultiModelConfig = field(default_factory=MultiModelConfig)

    # Provider-specific settings
    providers: dict[str, ProviderConfig] = field(default_factory=dict)
```

#### 5.2 Migration from Old Config

```python
@classmethod
def _from_dict(cls, data: dict) -> "LiteConfig":
    config = cls()

    # Handle legacy llm config
    if "llm" in data and "models" not in data:
        # Migrate old format to new
        llm_data = data["llm"]
        config.models.default = TaskModelConfig(
            provider=llm_data.get("provider", "anthropic"),
            model=llm_data.get("model", "claude-sonnet-4-20250514"),
            temperature=llm_data.get("temperature", 0.3),
            max_tokens=llm_data.get("max_tokens", 4096),
        )
    elif "models" in data:
        # Load new format
        config.models = MultiModelConfig._from_dict(data["models"])

    return config
```

#### 5.3 JSON Structure

```json
{
  "models": {
    "providers": {
      "anthropic": {
        "enabled": true,
        "api_key_env_var": "ANTHROPIC_API_KEY"
      },
      "ollama": {
        "enabled": true,
        "base_url": "http://localhost:11434"
      }
    },
    "default": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-20250514",
      "temperature": 0.3,
      "max_tokens": 4096
    },
    "tasks": {
      "query_conversion": {
        "provider": "ollama",
        "model": "llama3.2",
        "temperature": 0.1,
        "max_tokens": 512,
        "use_defaults": false
      },
      "study_classification": {
        "provider": "anthropic",
        "model": "claude-3-5-haiku-20241022",
        "temperature": 0.1,
        "max_tokens": 256,
        "use_defaults": false
      }
    }
  }
}
```

---

### 6. Implementation Steps

#### Phase 1: Core Infrastructure
1. Create `TaskModelConfig` and `MultiModelConfig` dataclasses in `config.py`
2. Create `llm/providers.py` with provider registry
3. Add task type definitions to `constants.py`
4. Update `LLMClient` with `chat_with_config()` method
5. Update config serialization/deserialization with migration

#### Phase 2: Agent Updates
1. Add `TASK_ID` to `LiteBaseAgent`
2. Update `_get_model()` and `_chat()` to use task config
3. Add `TASK_ID` to all agent subclasses
4. Update agents to pass task_id for sub-tasks

#### Phase 3: Settings UI - Providers Tab
1. Create `ProviderConfigWidget` for each provider
2. Create `ProvidersTab` with collapsible provider sections
3. Add connection testing with status indicators
4. Add Ollama setup instructions display

#### Phase 4: Settings UI - Tasks Tab
1. Create `ProviderModelSelector` widget
2. Create `TaskConfigWidget` widget
3. Create `TasksTab` with category sub-tabs
4. Add default configuration section
5. Add collapsible task-specific sections

#### Phase 5: Model Fetching
1. Create `ModelFetchWorker` supporting both providers
2. Add model caching for Ollama (doesn't change often)
3. Handle connection errors gracefully
4. Show "no models" state with setup instructions

#### Phase 6: Testing & Polish
1. Add unit tests for config migration
2. Test provider switching scenarios
3. Test mixed provider configurations
4. Add cost estimation display
5. Add preset configurations (e.g., "Development mode" = all Ollama)

---

### 7. File Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `config.py` | Major | Add TaskModelConfig, MultiModelConfig, ProviderConfig |
| `constants.py` | Add | Task type definitions, categories |
| `llm/client.py` | Minor | Add chat_with_config method |
| `llm/providers.py` | New | Provider registry and info |
| `agents/base.py` | Major | Add TASK_ID, update _get_model/_chat |
| `agents/search_agent.py` | Minor | Add TASK_ID |
| `agents/scoring_agent.py` | Minor | Add TASK_ID |
| `agents/citation_agent.py` | Minor | Add TASK_ID |
| `agents/reporting_agent.py` | Minor | Add TASK_ID |
| `agents/interrogation_agent.py` | Minor | Add TASK_ID, task_id params |
| `quality/study_classifier.py` | Minor | Add TASK_ID, remove hardcoded model |
| `quality/quality_agent.py` | Minor | Add TASK_ID, remove hardcoded model |
| `gui/settings_dialog.py` | Major | Restructure tabs, add Providers/Tasks |
| `gui/widgets/model_selector.py` | New | Reusable selector widgets |
| `gui/widgets/task_config.py` | New | Task configuration widget |

---

### 8. User Experience

#### 8.1 Simple Use Case (Most Users)
1. Open Settings
2. Go to Providers tab
3. Enter Anthropic API key
4. Done - uses sensible defaults for all tasks

#### 8.2 Cost-Conscious Development
1. Open Settings > Providers
2. Enable Ollama, verify connection
3. Go to Tasks tab
4. Set default provider to Ollama
5. Override specific tasks (report_generation, quality_assessment) to use Anthropic

#### 8.3 Advanced Configuration
1. Open Settings > Tasks
2. Expand individual task sections
3. Configure provider/model/parameters per task
4. Use recommendations as guidance

---

### 9. Future Extensions

1. **Additional Providers**: OpenAI, Google Gemini, local llama.cpp
2. **Cost Tracking**: Per-task cost tracking and budgets
3. **Model Presets**: "Fast & Cheap", "Balanced", "Maximum Quality"
4. **A/B Testing**: Compare model outputs for same task
5. **Fine-tuned Models**: Support for custom/fine-tuned models
