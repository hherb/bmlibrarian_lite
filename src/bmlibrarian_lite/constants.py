"""
Constants for BMLibrarian Lite.

All magic numbers and default values are defined here to ensure
consistency and easy configuration. No hardcoded values should
appear elsewhere in the lite module.
"""

from pathlib import Path

# =============================================================================
# Data Directory
# =============================================================================

# Default data directory - can be overridden by config
DEFAULT_DATA_DIR = Path.home() / ".bmlibrarian_lite"

# =============================================================================
# Embedding Model Settings
# =============================================================================

# Default FastEmbed model
# BAAI/bge-small-en-v1.5: Good balance of speed and quality
# Alternatives:
#   - BAAI/bge-base-en-v1.5: Better quality, slower
#   - intfloat/multilingual-e5-small: Multi-language support
DEFAULT_EMBEDDING_MODEL = "BAAI/bge-small-en-v1.5"
DEFAULT_EMBEDDING_DIMENSIONS = 384

# Supported embedding models with their specifications
EMBEDDING_MODEL_SPECS = {
    "BAAI/bge-small-en-v1.5": {
        "dimensions": 384,
        "size_mb": 50,
        "description": "Fast, good quality (default)",
    },
    "BAAI/bge-base-en-v1.5": {
        "dimensions": 768,
        "size_mb": 130,
        "description": "Better quality, slower",
    },
    "intfloat/multilingual-e5-small": {
        "dimensions": 384,
        "size_mb": 50,
        "description": "Multi-language support",
    },
}

# =============================================================================
# SQLite Database Settings
# =============================================================================

# SQLite database filename
SQLITE_DATABASE_NAME = "metadata.db"

# =============================================================================
# PubMed API Settings
# =============================================================================

# Cache TTL for PubMed API responses (24 hours)
PUBMED_CACHE_TTL_SECONDS = 86400

# Default maximum results for PubMed searches
PUBMED_DEFAULT_MAX_RESULTS = 200

# Batch size for fetching PubMed article details
PUBMED_BATCH_SIZE = 200

# =============================================================================
# Document Chunking Settings
# =============================================================================

# Default chunk size in characters
DEFAULT_CHUNK_SIZE = 8000

# Default overlap between chunks in characters
DEFAULT_CHUNK_OVERLAP = 200

# Minimum chunk size (smaller chunks are merged with previous)
MIN_CHUNK_SIZE = 100

# =============================================================================
# Search Settings
# =============================================================================

# Default similarity threshold for vector search (0.0 - 1.0)
DEFAULT_SIMILARITY_THRESHOLD = 0.5

# Default maximum results for vector search
DEFAULT_MAX_RESULTS = 20

# =============================================================================
# LLM Settings
# =============================================================================

# Default LLM provider
DEFAULT_LLM_PROVIDER = "anthropic"

# Default LLM model
DEFAULT_LLM_MODEL = "claude-sonnet-4-20250514"

# Default temperature for LLM requests
DEFAULT_LLM_TEMPERATURE = 0.3

# Default max tokens for LLM responses
DEFAULT_LLM_MAX_TOKENS = 4096

# Default Ollama host URL
DEFAULT_OLLAMA_HOST = "http://localhost:11434"

# =============================================================================
# LLM Task Types
# =============================================================================

# Task type definitions with metadata for UI and configuration
LLM_TASK_TYPES = {
    "query_conversion": {
        "name": "Query Conversion",
        "description": "Convert natural language to PubMed queries",
        "category": "search",
        "default_temperature": 0.1,
        "default_max_tokens": 512,
        "complexity": "low",
        "recommended_models": ["claude-3-5-haiku-20241022", "llama3.2", "mistral"],
    },
    "document_scoring": {
        "name": "Document Scoring",
        "description": "Score document relevance (1-5 scale)",
        "category": "analysis",
        "default_temperature": 0.1,
        "default_max_tokens": 256,
        "complexity": "medium",
        "recommended_models": ["claude-3-5-haiku-20241022", "claude-sonnet-4-20250514"],
    },
    "citation_extraction": {
        "name": "Citation Extraction",
        "description": "Extract relevant passages from documents",
        "category": "analysis",
        "default_temperature": 0.1,
        "default_max_tokens": 512,
        "complexity": "medium",
        "recommended_models": ["claude-3-5-haiku-20241022", "claude-sonnet-4-20250514"],
    },
    "report_generation": {
        "name": "Report Generation",
        "description": "Generate synthesis reports from citations",
        "category": "generation",
        "default_temperature": 0.3,
        "default_max_tokens": 4096,
        "complexity": "high",
        "recommended_models": ["claude-sonnet-4-20250514", "claude-opus-4-20250514"],
    },
    "query_expansion": {
        "name": "Query Expansion",
        "description": "Generate alternative query phrasings",
        "category": "search",
        "default_temperature": 0.3,
        "default_max_tokens": 200,
        "complexity": "low",
        "recommended_models": ["claude-3-5-haiku-20241022", "llama3.2", "mistral"],
    },
    "document_qa": {
        "name": "Document Q&A",
        "description": "Answer questions about documents",
        "category": "interrogation",
        "default_temperature": 0.2,
        "default_max_tokens": 2048,
        "complexity": "high",
        "recommended_models": ["claude-sonnet-4-20250514", "llama3.2:70b"],
    },
    "document_summary": {
        "name": "Document Summary",
        "description": "Generate document summaries",
        "category": "interrogation",
        "default_temperature": 0.2,
        "default_max_tokens": 500,
        "complexity": "medium",
        "recommended_models": ["claude-3-5-haiku-20241022", "claude-sonnet-4-20250514"],
    },
    "study_classification": {
        "name": "Study Classification",
        "description": "Classify study design type",
        "category": "quality",
        "default_temperature": 0.1,
        "default_max_tokens": 256,
        "complexity": "low",
        "recommended_models": ["claude-3-5-haiku-20241022", "llama3.2"],
    },
    "quality_assessment": {
        "name": "Quality Assessment",
        "description": "Detailed evidence quality assessment",
        "category": "quality",
        "default_temperature": 0.1,
        "default_max_tokens": 1024,
        "complexity": "high",
        "recommended_models": ["claude-sonnet-4-20250514"],
    },
}

# Task categories for UI grouping
LLM_TASK_CATEGORIES = {
    "search": {
        "name": "Search & Queries",
        "description": "Tasks related to search query generation",
        "tasks": ["query_conversion", "query_expansion"],
    },
    "analysis": {
        "name": "Document Analysis",
        "description": "Tasks for analyzing document content",
        "tasks": ["document_scoring", "citation_extraction"],
    },
    "generation": {
        "name": "Report Generation",
        "description": "Tasks for generating reports and summaries",
        "tasks": ["report_generation"],
    },
    "interrogation": {
        "name": "Document Q&A",
        "description": "Interactive document questioning",
        "tasks": ["document_qa", "document_summary"],
    },
    "quality": {
        "name": "Quality Assessment",
        "description": "Evidence quality evaluation tasks",
        "tasks": ["study_classification", "quality_assessment"],
    },
}

# =============================================================================
# LLM Provider Definitions
# =============================================================================
#
# Provider metadata is now managed by provider classes in llm/providers/.
# This dict is maintained for backward compatibility but should be considered
# deprecated. Use llm.providers.get_all_provider_info() instead.


def _get_llm_providers() -> dict[str, dict]:
    """Get LLM provider info, preferring provider classes when available.

    Returns:
        Dict mapping provider names to their metadata.
    """
    try:
        from bmlibrarian_lite.llm.providers import get_all_provider_info

        provider_info = get_all_provider_info()
        # Convert to expected format for backward compatibility
        result = {}
        for name, info in provider_info.items():
            result[name] = {
                "name": info["display_name"],
                "description": info["description"],
                "api_key_env_var": info["api_key_env_var"],
                "default_base_url": info["default_base_url"],
                "default_model": info["default_model"],
                "requires_api_key": info["requires_api_key"],
                "website_url": info["website_url"],
                "setup_instructions": info["setup_instructions"],
            }
        return result
    except ImportError:
        # Fallback if providers not yet loaded
        pass

    # Fallback static definitions
    return {
        "anthropic": {
            "name": "Anthropic",
            "description": "Claude models via Anthropic API",
            "api_key_env_var": "ANTHROPIC_API_KEY",
            "default_base_url": "https://api.anthropic.com",
            "default_model": "claude-sonnet-4-20250514",
            "requires_api_key": True,
            "website_url": "https://console.anthropic.com",
            "setup_instructions": """1. Create an account at https://console.anthropic.com
2. Generate an API key in Settings > API Keys
3. Enter the key in the API Keys tab""",
        },
        "ollama": {
            "name": "Ollama",
            "description": "Local models via Ollama server (free)",
            "api_key_env_var": "",
            "default_base_url": "http://localhost:11434",
            "default_model": "medgemma4B_it_q8",
            "requires_api_key": False,
            "website_url": "https://ollama.ai",
            "setup_instructions": """1. Install Ollama from https://ollama.ai
2. Start the Ollama service: ollama serve
3. Pull a model: ollama pull medgemma4B_it_q8

Popular models for biomedical research:
- medgemma4B_it_q8 - Medical domain fine-tuned (default)
- llama3.2 (3B) - Fast, good for simple tasks
- llama3.1 (8B) - Good balance of speed and quality
- mistral (7B) - Fast, good for simple tasks
- mixtral (8x7B) - High quality, slower
- meditron (7B) - Medical domain fine-tuned

Verify installation: ollama list""",
        },
    }


# Lazy-loaded provider info for backward compatibility
LLM_PROVIDERS = _get_llm_providers()

# =============================================================================
# Timeout Settings (milliseconds)
# =============================================================================

# Timeout for embedding generation
EMBEDDING_TIMEOUT_MS = 30000

# Timeout for LLM requests
LLM_TIMEOUT_MS = 120000

# Timeout for PubMed API requests
PUBMED_TIMEOUT_MS = 30000

# =============================================================================
# Scoring Settings
# =============================================================================

# Default minimum score for including documents in results
DEFAULT_MIN_SCORE = 3

# Score range
SCORE_MIN = 1
SCORE_MAX = 5

# =============================================================================
# Network Retry Settings
# =============================================================================

# Maximum number of retry attempts for network operations
DEFAULT_MAX_RETRIES = 3

# Initial delay between retries in seconds
DEFAULT_RETRY_BASE_DELAY = 1.0

# Maximum delay between retries in seconds
DEFAULT_RETRY_MAX_DELAY = 10.0

# Exponential backoff multiplier
DEFAULT_RETRY_EXPONENTIAL_BASE = 2.0

# Jitter factor for retry delays (0.0 to 1.0)
# Adds randomness to prevent thundering herd effects
DEFAULT_RETRY_JITTER_FACTOR = 0.2

# =============================================================================
# Security Settings
# =============================================================================

# File permissions for configuration files (owner read/write only)
# 0o600 = -rw------- (only owner can read/write)
CONFIG_FILE_PERMISSIONS = 0o600

# Directory permissions for configuration directories
# 0o700 = drwx------ (only owner can access)
CONFIG_DIR_PERMISSIONS = 0o700

# =============================================================================
# Quality Filtering Settings
# =============================================================================

# Default quality tier threshold for filtering (3 = controlled observational and above)
# Quality tiers: 5=systematic, 4=experimental, 3=controlled, 2=observational, 1=anecdotal
DEFAULT_QUALITY_TIER_THRESHOLD = 3

# Default minimum quality score (0.0 - 1.0)
DEFAULT_QUALITY_SCORE_THRESHOLD = 0.5

# Default confidence threshold for accepting LLM classifications (0.0 - 1.0)
DEFAULT_QUALITY_CONFIDENCE_THRESHOLD = 0.7

# =============================================================================
# Quality Assessment LLM Settings
# =============================================================================

# Model for quick study design classification (Tier 2)
# Claude Haiku: Fast, cheap (~$0.00025/doc)
QUALITY_CLASSIFIER_MODEL = "claude-3-5-haiku-20241022"

# Model for detailed quality assessment (Tier 3)
# Claude Sonnet: More thorough, higher cost (~$0.003/doc)
QUALITY_ASSESSOR_MODEL = "claude-sonnet-4-20250514"

# Temperature for quality classification (lower = more deterministic)
QUALITY_LLM_TEMPERATURE = 0.1

# Max tokens for classification response
QUALITY_CLASSIFIER_MAX_TOKENS = 256

# Max tokens for detailed assessment response
QUALITY_ASSESSOR_MAX_TOKENS = 1024

# =============================================================================
# Quality Metadata Confidence Levels
# =============================================================================

# Confidence when PubMed publication type matches exactly
METADATA_HIGH_CONFIDENCE = 0.95

# Confidence when PubMed publication type matches partially
METADATA_PARTIAL_MATCH_CONFIDENCE = 0.80

# Confidence when publication types present but unrecognized
METADATA_UNKNOWN_TYPE_CONFIDENCE = 0.30

# Confidence when no publication types available
METADATA_NO_TYPE_CONFIDENCE = 0.0

# =============================================================================
# Quality Classification Confidence Levels
# =============================================================================

# Confidence threshold for accepting Haiku classification
CLASSIFIER_ACCEPTANCE_CONFIDENCE = 0.75

# Confidence boost when multiple indicators agree
CLASSIFIER_MULTI_INDICATOR_BOOST = 0.10

# Maximum confidence from LLM classification
CLASSIFIER_MAX_CONFIDENCE = 0.90

# =============================================================================
# Quality Assessment Batch Settings
# =============================================================================

# Number of documents to classify in parallel
QUALITY_BATCH_SIZE = 10

# Delay between API calls in seconds (rate limiting)
QUALITY_API_DELAY_SECONDS = 0.1

# Maximum documents to assess with detailed Sonnet analysis
QUALITY_MAX_DETAILED_ASSESSMENTS = 20

# =============================================================================
# JSON Parsing Security Settings
# =============================================================================

# Maximum size for JSON responses from LLM (in bytes)
# This prevents DoS attacks via oversized responses
JSON_MAX_RESPONSE_SIZE_BYTES = 65536  # 64 KB

# =============================================================================
# Classification Parsing Constants
# =============================================================================

# Valid values for blinding level (Cochrane terminology)
VALID_BLINDING_VALUES = frozenset({"none", "single", "double", "triple"})

# Valid values for bias risk assessment
VALID_BIAS_RISK_VALUES = frozenset({"low", "unclear", "high"})

# Default confidence value - used when parsing fails
# This is intentionally LOW to signal uncertainty
CONFIDENCE_PARSE_FAILURE_DEFAULT = 0.0

# =============================================================================
# Abstract Processing Settings
# =============================================================================

# Maximum abstract length for single-pass LLM processing
# Abstracts longer than this will be processed in chunks
ABSTRACT_MAX_SINGLE_PASS_LENGTH = 8000

# Chunk size for processing long abstracts
ABSTRACT_CHUNK_SIZE = 4000

# Overlap between chunks for context preservation
ABSTRACT_CHUNK_OVERLAP = 500

# =============================================================================
# Batch Processing Retry Settings
# =============================================================================

# Maximum retry attempts for failed classifications
CLASSIFICATION_MAX_RETRIES = 3

# Base delay between retries in seconds
CLASSIFICATION_RETRY_BASE_DELAY = 1.0

# Exponential backoff multiplier for retries
CLASSIFICATION_RETRY_BACKOFF_MULTIPLIER = 2.0

# Jitter factor for retry delays (0.0 to 1.0)
# Adds randomness to prevent thundering herd effects (per golden rule 22)
CLASSIFICATION_RETRY_JITTER_FACTOR = 0.2

# =============================================================================
# Europe PMC API Settings
# =============================================================================

# Europe PMC REST API base URL
EUROPEPMC_REST_BASE_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest"

# Europe PMC search endpoint
EUROPEPMC_SEARCH_URL = f"{EUROPEPMC_REST_BASE_URL}/search"

# Request timeout for Europe PMC API calls (seconds)
EUROPEPMC_REQUEST_TIMEOUT_SECONDS = 30

# User agent for Europe PMC requests
EUROPEPMC_USER_AGENT = "BMLibrarian/1.0 (https://github.com/hherb/bmlibrarian-lite)"

# =============================================================================
# Full-text Storage Settings
# =============================================================================

# Default full-text markdown base directory relative to home
# Structure: ~/knowledgebase/fulltext/{year}/{pmcid}.md
DEFAULT_FULLTEXT_BASE_DIR = "knowledgebase/fulltext"

# Default PDF base directory relative to home
# Structure: ~/knowledgebase/pdf/{year}/{doi}.pdf
DEFAULT_PDF_BASE_DIR = "knowledgebase/pdf"

# Environment variable name for overriding PDF base directory
PDF_BASE_DIR_ENV_VAR = "PDF_BASE_DIR"

# =============================================================================
# Full-text Discovery Settings
# =============================================================================

# Priority order for full-text sources (higher = preferred)
FULLTEXT_SOURCE_PRIORITY = {
    "cached_fulltext": 100,  # Cached markdown (fastest)
    "europepmc_xml": 90,     # Europe PMC XML API (best quality)
    "cached_pdf": 80,        # Cached PDF
    "downloaded_pdf": 70,    # Downloaded PDF
    "abstract_only": 10,     # Abstract fallback
}

# Maximum retry attempts for Europe PMC XML retrieval
EUROPEPMC_MAX_RETRIES = 3

# Delay between Europe PMC retry attempts (seconds)
EUROPEPMC_RETRY_DELAY_SECONDS = 1.0

# =============================================================================
# Audit Trail UI Constants
# =============================================================================

# Card layout dimensions (relative, will be scaled by dpi_scale)
AUDIT_CARD_MIN_HEIGHT = 80
AUDIT_CARD_SPACING = 8
AUDIT_CARD_PADDING = 12
AUDIT_CARD_BORDER_RADIUS = 6

# Score color thresholds (1-5 scale)
SCORE_THRESHOLD_EXCELLENT = 4.5
SCORE_THRESHOLD_GOOD = 3.5
SCORE_THRESHOLD_MODERATE = 2.5

# Score badge colors (hex)
SCORE_COLOR_EXCELLENT = "#2E7D32"  # Green - scores >= 4.5
SCORE_COLOR_GOOD = "#1976D2"       # Blue - scores >= 3.5
SCORE_COLOR_MODERATE = "#F57C00"   # Orange - scores >= 2.5
SCORE_COLOR_POOR = "#C62828"       # Red - scores < 2.5

# Citation highlight color (yellow)
CITATION_HIGHLIGHT_COLOR = "#FFEB3B"

# Batched UI update delay (milliseconds)
# Prevents UI lag during rapid document additions
AUDIT_UI_UPDATE_DELAY_MS = 100

# Maximum authors to display before "et al."
MAX_AUTHORS_BEFORE_ET_AL = 3

# Maximum lines of abstract to show before scrolling
AUDIT_ABSTRACT_MAX_LINES = 15

# Card header background color (very pale light blue)
AUDIT_CARD_HEADER_COLOR = "#E3F2FD"

# Rationale text color (muted)
AUDIT_RATIONALE_COLOR = "#555555"

# =============================================================================
# Benchmark Results Colors
# =============================================================================

# Score colors for benchmark visualization (1-5 scale)
BENCHMARK_SCORE_COLORS: dict[int, str] = {
    1: "#FFCDD2",  # Light red - not relevant
    2: "#FFE0B2",  # Light orange - marginally relevant
    3: "#FFF9C4",  # Light yellow - moderately relevant
    4: "#C8E6C9",  # Light green - highly relevant
    5: "#A5D6A7",  # Green - directly answers question
}

# Agreement level colors for matrix visualization
BENCHMARK_AGREEMENT_HIGH = "#A5D6A7"    # >= 90% agreement
BENCHMARK_AGREEMENT_MEDIUM = "#FFF9C4"  # >= 75% agreement
BENCHMARK_AGREEMENT_LOW = "#FFCDD2"     # < 75% agreement

# Inclusion disagreement color (more severe than score disagreement)
# Used when models disagree on the include/exclude decision
BENCHMARK_INCLUSION_DISAGREEMENT = "#EF5350"  # Red - critical disagreement

# Question hash length for benchmark run lookup
# 16 hex chars = 64 bits = sufficient for uniqueness while remaining readable
BENCHMARK_QUESTION_HASH_LENGTH = 16

# Quality benchmark agreement thresholds
# Design agreement requires exact match (stricter)
QUALITY_BENCHMARK_DESIGN_AGREEMENT_HIGH = 0.80   # >= 80% exact design match
QUALITY_BENCHMARK_DESIGN_AGREEMENT_MEDIUM = 0.60  # >= 60% exact design match

# Tier agreement allows ±1 tier difference (more lenient)
QUALITY_BENCHMARK_TIER_AGREEMENT_HIGH = 0.90     # >= 90% within ±1 tier
QUALITY_BENCHMARK_TIER_AGREEMENT_MEDIUM = 0.75   # >= 75% within ±1 tier

# Quality benchmark task type identifiers
QUALITY_BENCHMARK_TASK_CLASSIFICATION = "study_classification"
QUALITY_BENCHMARK_TASK_ASSESSMENT = "quality_assessment"

# =============================================================================
# Incremental Search Settings
# =============================================================================

# Batch size for incremental PubMed searches
# Each batch fetches this many results before checking for new documents
INCREMENTAL_SEARCH_BATCH_SIZE = 100

# Default target for new documents in incremental search
DEFAULT_TARGET_NEW_DOCUMENTS = 50

# Maximum offset for PubMed searches (API limit)
MAX_PUBMED_SEARCH_OFFSET = 9999

# =============================================================================
# Model Pricing (per 1M tokens, USD)
# =============================================================================

# Pricing data for cost estimation in benchmarking
# Updated: December 2024
# Source: https://www.anthropic.com/pricing (Anthropic)
# Note: Ollama models are free (local inference)
MODEL_PRICING: dict[str, dict[str, float]] = {
    # Anthropic Claude models
    "anthropic:claude-opus-4-20250514": {"input": 15.00, "output": 75.00},
    "anthropic:claude-sonnet-4-20250514": {"input": 3.00, "output": 15.00},
    "anthropic:claude-3-5-haiku-20241022": {"input": 0.80, "output": 4.00},
    "anthropic:claude-3-5-sonnet-20241022": {"input": 3.00, "output": 15.00},
    "anthropic:claude-3-opus-20240229": {"input": 15.00, "output": 75.00},
    "anthropic:claude-3-sonnet-20240229": {"input": 3.00, "output": 15.00},
    "anthropic:claude-3-haiku-20240307": {"input": 0.25, "output": 1.25},

    # Ollama models (free - local inference)
    "ollama:llama3.2": {"input": 0.0, "output": 0.0},
    "ollama:llama3.2:3b": {"input": 0.0, "output": 0.0},
    "ollama:llama3.1": {"input": 0.0, "output": 0.0},
    "ollama:llama3.1:8b": {"input": 0.0, "output": 0.0},
    "ollama:llama3.1:70b": {"input": 0.0, "output": 0.0},
    "ollama:mistral": {"input": 0.0, "output": 0.0},
    "ollama:mixtral": {"input": 0.0, "output": 0.0},
    "ollama:medgemma4B_it_q8": {"input": 0.0, "output": 0.0},
    "ollama:meditron": {"input": 0.0, "output": 0.0},
}

# Default pricing for unknown models (conservative estimate)
DEFAULT_MODEL_PRICING: dict[str, float] = {"input": 1.00, "output": 5.00}


def get_model_pricing(model_string: str) -> dict[str, float]:
    """
    Get pricing for a model.

    Args:
        model_string: Model in "provider:model" format

    Returns:
        Dict with "input" and "output" keys (price per 1M tokens)
    """
    return MODEL_PRICING.get(model_string, DEFAULT_MODEL_PRICING)


def calculate_cost(
    model_string: str,
    tokens_input: int,
    tokens_output: int,
) -> float:
    """
    Calculate cost in USD for an LLM call.

    Args:
        model_string: Model in "provider:model" format
        tokens_input: Number of input tokens
        tokens_output: Number of output tokens

    Returns:
        Estimated cost in USD
    """
    pricing = get_model_pricing(model_string)
    input_cost = (tokens_input / 1_000_000) * pricing["input"]
    output_cost = (tokens_output / 1_000_000) * pricing["output"]
    return input_cost + output_cost
