"""
Configuration management for BMLibrarian Lite.

Provides dataclass-based configuration with sensible defaults and
JSON file persistence. Configuration is loaded from:
    ~/.bmlibrarian_lite/config.json

All paths are resolved relative to the data directory.
"""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Any
import hashlib
import json
import logging
import os
import stat

from .constants import (
    CONFIG_DIR_PERMISSIONS,
    CONFIG_FILE_PERMISSIONS,
    DEFAULT_DATA_DIR,
    DEFAULT_EMBEDDING_MODEL,
    DEFAULT_CHUNK_SIZE,
    DEFAULT_CHUNK_OVERLAP,
    DEFAULT_SIMILARITY_THRESHOLD,
    DEFAULT_MAX_RESULTS,
    DEFAULT_LLM_PROVIDER,
    DEFAULT_LLM_MODEL,
    DEFAULT_LLM_TEMPERATURE,
    DEFAULT_LLM_MAX_TOKENS,
    DEFAULT_OLLAMA_HOST,
    SQLITE_DATABASE_NAME,
    MIN_CHUNK_SIZE,
    EMBEDDING_MODEL_SPECS,
    LLM_TASK_TYPES,
    LLM_PROVIDERS,
)

logger = logging.getLogger(__name__)


@dataclass
class TaskModelConfig:
    """
    Configuration for a single LLM task.

    Each task (scoring, citation extraction, etc.) can have its own
    provider, model, and parameters.

    Attributes:
        provider: LLM provider name (anthropic, ollama)
        model: Model name (empty string means use provider default)
        temperature: Sampling temperature (0.0-2.0)
        max_tokens: Maximum output tokens
        top_p: Nucleus sampling parameter (None = not set)
        top_k: Top-k sampling parameter (None = not set)
        context_window: Context window limit (None = use model default)
    """

    provider: str = ""
    model: str = ""
    temperature: float = DEFAULT_LLM_TEMPERATURE
    max_tokens: int = DEFAULT_LLM_MAX_TOKENS
    top_p: Optional[float] = None
    top_k: Optional[int] = None
    context_window: Optional[int] = None

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "provider": self.provider,
            "model": self.model,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
            "top_p": self.top_p,
            "top_k": self.top_k,
            "context_window": self.context_window,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "TaskModelConfig":
        """Create from dictionary."""
        return cls(
            provider=data.get("provider", ""),
            model=data.get("model", ""),
            temperature=float(data.get("temperature", DEFAULT_LLM_TEMPERATURE)),
            max_tokens=int(data.get("max_tokens", DEFAULT_LLM_MAX_TOKENS)),
            top_p=data.get("top_p"),
            top_k=data.get("top_k"),
            context_window=data.get("context_window"),
        )

    def is_configured(self) -> bool:
        """Return True if this task has custom configuration."""
        return bool(self.provider)


@dataclass
class ProviderConfig:
    """
    Configuration for an LLM provider.

    Attributes:
        enabled: Whether this provider is available for use
        base_url: Base URL for the provider API
        default_model: Default model to use for this provider
    """

    enabled: bool = True
    base_url: str = ""
    default_model: str = ""

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "enabled": self.enabled,
            "base_url": self.base_url,
            "default_model": self.default_model,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ProviderConfig":
        """Create from dictionary."""
        return cls(
            enabled=data.get("enabled", True),
            base_url=data.get("base_url", ""),
            default_model=data.get("default_model", ""),
        )


@dataclass
class ModelsConfig:
    """
    Multi-provider, task-based model configuration.

    Allows different tasks to use different providers and models.
    Simple tasks like query conversion can use a fast local Ollama model,
    while complex tasks like report generation can use Anthropic.

    Attributes:
        providers: Configuration for each provider
        default_provider: Default provider for tasks without custom config
        default_model: Default model for tasks without custom config
        default_temperature: Default temperature
        default_max_tokens: Default max tokens
        tasks: Task-specific configuration overrides

    Example:
        config.models.default_provider = "anthropic"
        config.models.default_model = "claude-sonnet-4-20250514"

        # Use Ollama for simple tasks
        config.models.tasks["query_conversion"] = TaskModelConfig(
            provider="ollama",
            model="llama3.2",
        )
    """

    providers: dict[str, ProviderConfig] = field(default_factory=dict)
    default_provider: str = DEFAULT_LLM_PROVIDER
    default_model: str = DEFAULT_LLM_MODEL
    default_temperature: float = DEFAULT_LLM_TEMPERATURE
    default_max_tokens: int = DEFAULT_LLM_MAX_TOKENS
    tasks: dict[str, TaskModelConfig] = field(default_factory=dict)

    def __post_init__(self) -> None:
        """Initialize default provider configurations."""
        if not self.providers:
            self.providers = {
                "anthropic": ProviderConfig(
                    enabled=True,
                    base_url=LLM_PROVIDERS["anthropic"]["default_base_url"],
                    default_model=LLM_PROVIDERS["anthropic"]["default_model"],
                ),
                "ollama": ProviderConfig(
                    enabled=True,
                    base_url=DEFAULT_OLLAMA_HOST,
                    default_model=LLM_PROVIDERS["ollama"]["default_model"],
                ),
            }

    def get_task_config(self, task_id: str) -> TaskModelConfig:
        """
        Get effective configuration for a task.

        If the task has custom settings, returns those.
        Otherwise, returns default configuration merged with
        task type defaults from constants.

        Args:
            task_id: Task identifier (e.g., "document_scoring")

        Returns:
            TaskModelConfig with effective settings for the task
        """
        # Check for task-specific config
        if task_id in self.tasks and self.tasks[task_id].is_configured():
            task = self.tasks[task_id]
            # Fill in model from provider default if not specified
            model = task.model
            if not model and task.provider in self.providers:
                model = self.providers[task.provider].default_model
            return TaskModelConfig(
                provider=task.provider,
                model=model,
                temperature=task.temperature,
                max_tokens=task.max_tokens,
                top_p=task.top_p,
                top_k=task.top_k,
                context_window=task.context_window,
            )

        # Get task type defaults from constants
        task_type_info = LLM_TASK_TYPES.get(task_id, {})
        default_temp = task_type_info.get("default_temperature", self.default_temperature)
        default_tokens = task_type_info.get("default_max_tokens", self.default_max_tokens)

        # Return default config with task-type-specific defaults
        return TaskModelConfig(
            provider=self.default_provider,
            model=self.default_model,
            temperature=default_temp,
            max_tokens=default_tokens,
        )

    def get_model_string(self, task_id: str) -> str:
        """
        Get the provider:model string for a task.

        Args:
            task_id: Task identifier

        Returns:
            Model string in format "provider:model"
        """
        config = self.get_task_config(task_id)
        return f"{config.provider}:{config.model}"

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "providers": {
                name: cfg.to_dict() for name, cfg in self.providers.items()
            },
            "default_provider": self.default_provider,
            "default_model": self.default_model,
            "default_temperature": self.default_temperature,
            "default_max_tokens": self.default_max_tokens,
            "tasks": {
                task_id: cfg.to_dict()
                for task_id, cfg in self.tasks.items()
                if cfg.is_configured()
            },
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ModelsConfig":
        """Create from dictionary."""
        providers = {}
        if "providers" in data:
            providers = {
                name: ProviderConfig.from_dict(cfg_data)
                for name, cfg_data in data["providers"].items()
            }

        tasks = {}
        if "tasks" in data:
            tasks = {
                task_id: TaskModelConfig.from_dict(cfg_data)
                for task_id, cfg_data in data["tasks"].items()
            }

        config = cls(
            providers=providers,
            default_provider=data.get("default_provider", DEFAULT_LLM_PROVIDER),
            default_model=data.get("default_model", DEFAULT_LLM_MODEL),
            default_temperature=float(data.get("default_temperature", DEFAULT_LLM_TEMPERATURE)),
            default_max_tokens=int(data.get("default_max_tokens", DEFAULT_LLM_MAX_TOKENS)),
            tasks=tasks,
        )
        return config


@dataclass
class EmbeddingConfig:
    """Embedding model configuration."""

    model: str = DEFAULT_EMBEDDING_MODEL
    cache_dir: Optional[Path] = None


@dataclass
class PubMedConfig:
    """PubMed API configuration."""

    email: str = ""  # Required by NCBI for polite access
    api_key: Optional[str] = None  # Optional, increases rate limit to 10 req/sec


@dataclass
class OpenAthensConfig:
    """OpenAthens institutional access configuration."""

    enabled: bool = False  # Whether OpenAthens is configured
    institution_url: str = ""  # Institution's OpenAthens login URL (HTTPS required)
    session_max_age_hours: int = 24  # Maximum session age before re-authentication


@dataclass
class DiscoveryConfig:
    """PDF discovery and download configuration."""

    unpaywall_email: str = ""  # Email for Unpaywall API (enables additional PDF sources)


@dataclass
class StorageConfig:
    """Storage configuration with derived paths."""

    data_dir: Path = field(default_factory=lambda: DEFAULT_DATA_DIR)

    @property
    def sqlite_path(self) -> Path:
        """Path to SQLite database file."""
        return self.data_dir / SQLITE_DATABASE_NAME

    @property
    def reviews_dir(self) -> Path:
        """Directory for review checkpoints."""
        return self.data_dir / "reviews"

    @property
    def exports_dir(self) -> Path:
        """Directory for exported reports."""
        return self.data_dir / "exports"

    @property
    def cache_dir(self) -> Path:
        """Directory for temporary cache."""
        return self.data_dir / "cache"

    @property
    def env_file(self) -> Path:
        """Path to .env file for API keys."""
        return self.data_dir / ".env"


@dataclass
class SearchConfig:
    """Search configuration."""

    chunk_size: int = DEFAULT_CHUNK_SIZE
    chunk_overlap: int = DEFAULT_CHUNK_OVERLAP
    similarity_threshold: float = DEFAULT_SIMILARITY_THRESHOLD
    max_results: int = DEFAULT_MAX_RESULTS


@dataclass
class BenchmarkModelConfig:
    """
    Configuration for a single model in benchmarking.

    Attributes:
        provider: LLM provider name (anthropic, ollama)
        model: Model name
        temperature: Sampling temperature
        max_tokens: Maximum output tokens
        enabled: Whether this model is included in benchmarks
        is_baseline: Whether this model serves as the baseline for comparison
    """

    provider: str = ""
    model: str = ""
    temperature: float = 0.1
    max_tokens: int = 256
    enabled: bool = True
    is_baseline: bool = False

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "provider": self.provider,
            "model": self.model,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
            "enabled": self.enabled,
            "is_baseline": self.is_baseline,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "BenchmarkModelConfig":
        """Create from dictionary."""
        return cls(
            provider=data.get("provider", ""),
            model=data.get("model", ""),
            temperature=float(data.get("temperature", 0.1)),
            max_tokens=int(data.get("max_tokens", 256)),
            enabled=bool(data.get("enabled", True)),
            is_baseline=bool(data.get("is_baseline", False)),
        )

    def get_model_string(self) -> str:
        """Get the provider:model string."""
        return f"{self.provider}:{self.model}"

    def is_configured(self) -> bool:
        """Return True if this model has valid configuration."""
        return bool(self.provider and self.model)


@dataclass
class BenchmarkConfig:
    """
    Configuration for model benchmarking.

    Allows comparing multiple LLM models on evaluation tasks.

    Attributes:
        enabled: Whether benchmarking feature is enabled
        models: List of models to include in benchmarks
        default_sample_mode: How to sample documents ("all" or "random")
        default_sample_size: Number of documents when using random sampling
        tasks: List of task IDs to benchmark (e.g., ["document_scoring"])
    """

    enabled: bool = False
    models: list[BenchmarkModelConfig] = field(default_factory=list)
    default_sample_mode: str = "all"
    default_sample_size: int = 10
    tasks: list[str] = field(default_factory=lambda: ["document_scoring"])
    # Quality benchmark settings
    quality_enabled: bool = False
    quality_task_type: str = "study_classification"  # or "quality_assessment"

    def __post_init__(self) -> None:
        """Initialize with default models if empty."""
        if not self.models:
            # Add some sensible defaults
            self.models = [
                BenchmarkModelConfig(
                    provider="anthropic",
                    model="claude-sonnet-4-20250514",
                    is_baseline=True,
                ),
                BenchmarkModelConfig(
                    provider="anthropic",
                    model="claude-3-5-haiku-20241022",
                ),
            ]

    def get_enabled_models(self) -> list[BenchmarkModelConfig]:
        """Get list of enabled and configured models."""
        return [m for m in self.models if m.enabled and m.is_configured()]

    def get_baseline_model(self) -> Optional[BenchmarkModelConfig]:
        """Get the baseline model if one is set."""
        for model in self.models:
            if model.is_baseline and model.enabled and model.is_configured():
                return model
        return None

    def get_model_strings(self) -> list[str]:
        """Get provider:model strings for all enabled models."""
        return [m.get_model_string() for m in self.get_enabled_models()]

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "enabled": self.enabled,
            "models": [m.to_dict() for m in self.models],
            "default_sample_mode": self.default_sample_mode,
            "default_sample_size": self.default_sample_size,
            "tasks": self.tasks,
            "quality_enabled": self.quality_enabled,
            "quality_task_type": self.quality_task_type,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "BenchmarkConfig":
        """Create from dictionary."""
        models = []
        if "models" in data:
            models = [
                BenchmarkModelConfig.from_dict(m) for m in data["models"]
            ]

        config = cls(
            enabled=bool(data.get("enabled", False)),
            models=models if models else [],
            default_sample_mode=data.get("default_sample_mode", "all"),
            default_sample_size=int(data.get("default_sample_size", 10)),
            tasks=data.get("tasks", ["document_scoring"]),
            quality_enabled=bool(data.get("quality_enabled", False)),
            quality_task_type=data.get("quality_task_type", "study_classification"),
        )
        return config


@dataclass
class LiteConfig:
    """
    Main configuration for BMLibrarian Lite.

    Combines all sub-configurations and provides load/save functionality.

    Usage:
        # Load from default location
        config = LiteConfig.load()

        # Load from specific path
        config = LiteConfig.load(Path("/path/to/config.json"))

        # Use defaults
        config = LiteConfig()

        # Modify and save
        config.models.default_model = "claude-3-haiku-20240307"
        config.save()

    Validation Caching:
        Validation results are cached based on a hash of configuration values.
        The cache is automatically invalidated when configuration changes.
        Use invalidate_validation_cache() to force re-validation.
    """

    models: ModelsConfig = field(default_factory=ModelsConfig)
    embeddings: EmbeddingConfig = field(default_factory=EmbeddingConfig)
    pubmed: PubMedConfig = field(default_factory=PubMedConfig)
    discovery: DiscoveryConfig = field(default_factory=DiscoveryConfig)
    openathens: OpenAthensConfig = field(default_factory=OpenAthensConfig)
    storage: StorageConfig = field(default_factory=StorageConfig)
    search: SearchConfig = field(default_factory=SearchConfig)
    benchmark: BenchmarkConfig = field(default_factory=BenchmarkConfig)

    # Validation cache (not serialized)
    _validation_cache: dict[str, list[str]] = field(
        default_factory=dict, repr=False, compare=False
    )

    @classmethod
    def load(cls, config_path: Optional[Path] = None) -> "LiteConfig":
        """
        Load configuration from file or use defaults.

        Args:
            config_path: Optional path to config file.
                        If None, uses ~/.bmlibrarian_lite/config.json

        Returns:
            Loaded configuration
        """
        if config_path is None:
            config_path = DEFAULT_DATA_DIR / "config.json"

        if config_path.exists():
            try:
                with open(config_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                config = cls._from_dict(data)
                logger.debug(f"Loaded config from {config_path}")
                return config
            except (json.JSONDecodeError, KeyError, TypeError) as e:
                logger.warning(f"Failed to load config from {config_path}: {e}")
                logger.info("Using default configuration")

        return cls()

    @classmethod
    def _from_dict(cls, data: dict[str, Any]) -> "LiteConfig":
        """
        Create config from dictionary.

        Args:
            data: Configuration dictionary

        Returns:
            LiteConfig instance
        """
        config = cls()

        if "models" in data:
            config.models = ModelsConfig.from_dict(data["models"])

        if "embeddings" in data:
            embed_data = data["embeddings"]
            cache_dir = embed_data.get("cache_dir")
            config.embeddings = EmbeddingConfig(
                model=embed_data.get("model", DEFAULT_EMBEDDING_MODEL),
                cache_dir=Path(cache_dir).expanduser() if cache_dir else None,
            )

        if "pubmed" in data:
            pubmed_data = data["pubmed"]
            config.pubmed = PubMedConfig(
                email=pubmed_data.get("email", ""),
                api_key=pubmed_data.get("api_key"),
            )

        if "discovery" in data:
            discovery_data = data["discovery"]
            config.discovery = DiscoveryConfig(
                unpaywall_email=discovery_data.get("unpaywall_email", ""),
            )

        if "openathens" in data:
            openathens_data = data["openathens"]
            config.openathens = OpenAthensConfig(
                enabled=bool(openathens_data.get("enabled", False)),
                institution_url=openathens_data.get("institution_url", ""),
                session_max_age_hours=int(openathens_data.get("session_max_age_hours", 24)),
            )

        if "storage" in data:
            storage_data = data["storage"]
            data_dir = storage_data.get("data_dir", str(DEFAULT_DATA_DIR))
            config.storage = StorageConfig(
                data_dir=Path(data_dir).expanduser(),
            )

        if "search" in data:
            search_data = data["search"]
            config.search = SearchConfig(
                chunk_size=int(search_data.get("chunk_size", DEFAULT_CHUNK_SIZE)),
                chunk_overlap=int(search_data.get("chunk_overlap", DEFAULT_CHUNK_OVERLAP)),
                similarity_threshold=float(
                    search_data.get("similarity_threshold", DEFAULT_SIMILARITY_THRESHOLD)
                ),
                max_results=int(search_data.get("max_results", DEFAULT_MAX_RESULTS)),
            )

        if "benchmark" in data:
            config.benchmark = BenchmarkConfig.from_dict(data["benchmark"])

        return config

    def to_dict(self) -> dict[str, Any]:
        """
        Convert configuration to dictionary for serialization.

        Returns:
            Configuration dictionary
        """
        return {
            "models": self.models.to_dict(),
            "embeddings": {
                "model": self.embeddings.model,
                "cache_dir": str(self.embeddings.cache_dir) if self.embeddings.cache_dir else None,
            },
            "pubmed": {
                "email": self.pubmed.email,
                "api_key": self.pubmed.api_key,
            },
            "discovery": {
                "unpaywall_email": self.discovery.unpaywall_email,
            },
            "openathens": {
                "enabled": self.openathens.enabled,
                "institution_url": self.openathens.institution_url,
                "session_max_age_hours": self.openathens.session_max_age_hours,
            },
            "storage": {
                "data_dir": str(self.storage.data_dir),
            },
            "search": {
                "chunk_size": self.search.chunk_size,
                "chunk_overlap": self.search.chunk_overlap,
                "similarity_threshold": self.search.similarity_threshold,
                "max_results": self.search.max_results,
            },
            "benchmark": self.benchmark.to_dict(),
        }

    def save(self, config_path: Optional[Path] = None) -> None:
        """
        Save configuration to file.

        The configuration file is saved with restricted permissions (600)
        to protect sensitive data like API keys.

        Args:
            config_path: Optional path to save to.
                        If None, saves to data_dir/config.json
        """
        if config_path is None:
            config_path = self.storage.data_dir / "config.json"

        # Ensure directory exists with secure permissions
        config_path.parent.mkdir(parents=True, exist_ok=True)

        # Write config
        with open(config_path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2)

        # Set secure file permissions (owner read/write only)
        # This protects API keys and other sensitive configuration
        try:
            os.chmod(config_path, CONFIG_FILE_PERMISSIONS)
            logger.debug(f"Set file permissions to {oct(CONFIG_FILE_PERMISSIONS)} for {config_path}")
        except OSError as e:
            # Log but don't fail - permissions may not be settable on all filesystems
            logger.warning(f"Could not set file permissions for {config_path}: {e}")

        # Invalidate validation cache after save
        self._validation_cache.clear()

        logger.info(f"Configuration saved to {config_path}")

    def ensure_directories(self) -> None:
        """Create all required directories if they don't exist."""
        directories = [
            self.storage.data_dir,
            self.storage.reviews_dir,
            self.storage.exports_dir,
            self.storage.cache_dir,
        ]
        for directory in directories:
            directory.mkdir(parents=True, exist_ok=True)

    def load_env(self) -> None:
        """
        Load environment variables from .env file.

        This loads API keys and other sensitive configuration that
        should not be stored in the main config file.
        """
        env_file = self.storage.env_file
        if not env_file.exists():
            return

        try:
            with open(env_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        key, value = line.split("=", 1)
                        os.environ[key.strip()] = value.strip()
            logger.debug(f"Loaded environment from {env_file}")
        except Exception as e:
            logger.warning(f"Failed to load .env file: {e}")

    def _compute_config_hash(self) -> str:
        """
        Compute a hash of the current configuration values.

        Used for validation caching - the cache is invalidated when
        the configuration changes.

        Returns:
            MD5 hash of the configuration dictionary
        """
        config_str = json.dumps(self.to_dict(), sort_keys=True)
        return hashlib.md5(config_str.encode()).hexdigest()

    def invalidate_validation_cache(self) -> None:
        """
        Manually invalidate the validation cache.

        Call this method to force re-validation on the next validate() call.
        The cache is also automatically invalidated when save() is called.
        """
        self._validation_cache.clear()
        logger.debug("Validation cache invalidated")

    def validate(self) -> list[str]:
        """
        Validate configuration values.

        Checks all configuration parameters for valid ranges and formats.
        Returns a list of error messages if any validation fails.

        Validation results are cached based on configuration values.
        The cache is automatically invalidated when configuration changes.

        Returns:
            List of validation error messages (empty if all valid)

        Example:
            config = LiteConfig.load()
            errors = config.validate()
            if errors:
                for error in errors:
                    print(f"Config error: {error}")
                raise ConfigurationError(f"Invalid configuration: {errors}")
        """
        # Check cache first
        config_hash = self._compute_config_hash()
        if config_hash in self._validation_cache:
            logger.debug("Returning cached validation result")
            return self._validation_cache[config_hash]

        errors: list[str] = []

        # Email validation
        if self.pubmed.email and "@" not in self.pubmed.email:
            errors.append("Invalid email format for PubMed configuration")

        # LLM temperature range (0.0 to 2.0 - some providers allow up to 2.0)
        if not 0.0 <= self.models.default_temperature <= 2.0:
            errors.append(
                f"LLM temperature must be between 0.0 and 2.0, got {self.models.default_temperature}"
            )

        # LLM max tokens (must be positive)
        if self.models.default_max_tokens < 1:
            errors.append(
                f"LLM max_tokens must be a positive integer, got {self.models.default_max_tokens}"
            )

        # LLM provider validation
        valid_providers = list(LLM_PROVIDERS.keys())
        if self.models.default_provider not in valid_providers:
            errors.append(
                f"LLM provider must be one of {valid_providers}, got '{self.models.default_provider}'"
            )

        # Validate task-specific configurations
        for task_id, task_config in self.models.tasks.items():
            if task_config.is_configured():
                if task_config.provider not in valid_providers:
                    errors.append(
                        f"Task '{task_id}' has invalid provider: '{task_config.provider}'"
                    )
                if not 0.0 <= task_config.temperature <= 2.0:
                    errors.append(
                        f"Task '{task_id}' temperature must be 0.0-2.0, got {task_config.temperature}"
                    )

        # Embedding model validation
        if self.embeddings.model not in EMBEDDING_MODEL_SPECS:
            valid_models = list(EMBEDDING_MODEL_SPECS.keys())
            errors.append(
                f"Embedding model must be one of {valid_models}, got '{self.embeddings.model}'"
            )

        # Chunk size validation
        if self.search.chunk_size < MIN_CHUNK_SIZE:
            errors.append(
                f"Chunk size must be >= {MIN_CHUNK_SIZE}, got {self.search.chunk_size}"
            )

        # Chunk overlap validation
        if self.search.chunk_overlap < 0:
            errors.append(
                f"Chunk overlap must be >= 0, got {self.search.chunk_overlap}"
            )

        if self.search.chunk_overlap >= self.search.chunk_size:
            errors.append(
                f"Chunk overlap ({self.search.chunk_overlap}) must be less than "
                f"chunk size ({self.search.chunk_size})"
            )

        # Similarity threshold validation (0.0 to 1.0)
        if not 0.0 <= self.search.similarity_threshold <= 1.0:
            errors.append(
                f"Similarity threshold must be between 0.0 and 1.0, "
                f"got {self.search.similarity_threshold}"
            )

        # Max results validation
        if self.search.max_results < 1:
            errors.append(
                f"Max results must be a positive integer, got {self.search.max_results}"
            )

        # Data directory validation
        if not self.storage.data_dir:
            errors.append("Data directory path cannot be empty")

        # Cache the result
        self._validation_cache[config_hash] = errors
        logger.debug(f"Cached validation result for config hash {config_hash[:8]}...")

        return errors

    def is_valid(self) -> bool:
        """
        Check if configuration is valid.

        Convenience method that returns True if no validation errors.

        Returns:
            True if configuration is valid, False otherwise

        Example:
            if not config.is_valid():
                print("Configuration is invalid, using defaults")
                config = LiteConfig()
        """
        return len(self.validate()) == 0
