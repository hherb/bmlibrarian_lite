package com.bmlibrarian.factchecker.util

/**
 * Application-wide constants.
 *
 * Centralizes all magic numbers and configuration values to ensure
 * they can be easily found and modified. Following the golden rule:
 * "No magic numbers - use proper settings/configurations module(s)"
 */
object Constants {

    // ==================== Network Configuration ====================

    /** Connection timeout for HTTP requests in seconds. */
    const val NETWORK_CONNECT_TIMEOUT_SECONDS = 30L

    /** Read timeout for HTTP responses in seconds. Longer for LLM responses. */
    const val NETWORK_READ_TIMEOUT_SECONDS = 60L

    /** Write timeout for HTTP requests in seconds. */
    const val NETWORK_WRITE_TIMEOUT_SECONDS = 60L

    /** Maximum number of retry attempts for failed network requests. */
    const val NETWORK_MAX_RETRIES = 4

    /** Initial delay for exponential backoff in milliseconds. */
    const val NETWORK_INITIAL_BACKOFF_MS = 2000L

    /** Maximum delay for exponential backoff in milliseconds. */
    const val NETWORK_MAX_BACKOFF_MS = 16000L

    // ==================== API Base URLs ====================

    /** PubMed E-utilities API base URL. */
    const val PUBMED_BASE_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"

    /** Europe PMC REST API base URL. */
    const val EUROPE_PMC_BASE_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/"

    /** Unpaywall API base URL for open access PDF lookup. */
    const val UNPAYWALL_BASE_URL = "https://api.unpaywall.org/v2/"

    /** Default OpenAI API base URL. */
    const val DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1/"

    /** Default Ollama local API base URL. */
    const val DEFAULT_OLLAMA_BASE_URL = "http://localhost:11434/v1/"

    // ==================== PubMed Search Configuration ====================

    /** Default number of results to fetch per PubMed search. */
    const val PUBMED_DEFAULT_RESULT_COUNT = 50

    /** Maximum number of results to fetch from PubMed. */
    const val PUBMED_MAX_RESULT_COUNT = 200

    /** Default sort order for PubMed results. */
    const val PUBMED_DEFAULT_SORT = "relevance"

    // ==================== Scoring Configuration ====================

    /** Minimum relevance score to be considered relevant (inclusive). */
    const val SCORING_MIN_RELEVANT_SCORE = 3

    /** Maximum relevance score. */
    const val SCORING_MAX_SCORE = 5

    /** Minimum relevance score. */
    const val SCORING_MIN_SCORE = 1

    // ==================== Budget Defaults ====================

    /** Default maximum budget per run in USD. */
    const val DEFAULT_MAX_RUN_BUDGET_USD = 0.50f

    /** Default monthly budget limit in USD. */
    const val DEFAULT_MONTHLY_BUDGET_USD = 10.00f

    // ==================== UI Configuration ====================

    /** Maximum number of authors to display before showing "et al." */
    const val MAX_AUTHORS_BEFORE_ET_AL = 3

    /** Maximum lines of abstract to show before truncation. */
    const val MAX_ABSTRACT_LINES = 8

    /** Animation duration for card expansion in milliseconds. */
    const val CARD_ANIMATION_DURATION_MS = 300

    // ==================== LLM Configuration ====================

    /** Default temperature for LLM requests (0.0 = deterministic). */
    const val LLM_DEFAULT_TEMPERATURE = 0.0f

    /** Maximum tokens for scoring responses. */
    const val LLM_SCORING_MAX_TOKENS = 500

    /** Maximum tokens for citation extraction responses. */
    const val LLM_CITATION_MAX_TOKENS = 1000

    /** Maximum tokens for report generation responses. */
    const val LLM_REPORT_MAX_TOKENS = 2000

    /** Maximum tokens for query conversion responses. */
    const val LLM_QUERY_MAX_TOKENS = 200
}
