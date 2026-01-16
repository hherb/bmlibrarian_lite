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

    // ==================== UI Spacing (in dp) ====================

    /** Standard screen padding. */
    const val UI_SCREEN_PADDING = 16

    /** Standard spacing between major UI sections. */
    const val UI_SECTION_SPACING = 16

    /** Standard padding inside cards. */
    const val UI_CARD_PADDING = 16

    /** Smaller padding inside compact components. */
    const val UI_CARD_PADDING_SMALL = 12

    /** Standard spacing between related elements. */
    const val UI_ELEMENT_SPACING = 8

    /** Small spacing between tightly grouped elements. */
    const val UI_ELEMENT_SPACING_SMALL = 4

    /** Horizontal padding for badges and chips. */
    const val UI_BADGE_PADDING_HORIZONTAL = 8

    /** Vertical padding for badges and chips. */
    const val UI_BADGE_PADDING_VERTICAL = 2

    /** Large padding for placeholder/empty state sections. */
    const val UI_PLACEHOLDER_PADDING = 32

    /** Spacing between icon and text. */
    const val UI_ICON_TEXT_SPACING = 12

    /** Standard icon size. */
    const val UI_ICON_SIZE = 18

    /** Large icon size for placeholder screens. */
    const val UI_ICON_SIZE_LARGE = 64

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

    /** Estimated characters per token for token count estimation. */
    const val TOKEN_ESTIMATE_CHARS_PER_TOKEN = 4

    /** Divisor for estimating output tokens (output typically half of max). */
    const val OUTPUT_TOKEN_ESTIMATE_DIVISOR = 2

    /** Estimated available documents from Europe PMC when cursor exists. */
    const val EUROPE_PMC_AVAILABLE_ESTIMATE = 100

    // ==================== Document Source Constants ====================

    /** Document source: PubMed. */
    const val SOURCE_PUBMED = "pubmed"

    /** Document source: Europe PMC. */
    const val SOURCE_EUROPE_PMC = "europepmc"

    /** Document source: Preprint server. */
    const val SOURCE_PREPRINT = "preprint"

    // ==================== Full-Text Source Constants ====================

    /** Full-text source: Europe PMC XML. */
    const val FULLTEXT_SOURCE_EUROPE_PMC = "europepmc"

    /** Full-text source: Unpaywall PDF. */
    const val FULLTEXT_SOURCE_UNPAYWALL = "unpaywall"

    /** Full-text source: DOI/Publisher. */
    const val FULLTEXT_SOURCE_DOI = "doi"

    /** Full-text source: Cached from previous fetch. */
    const val FULLTEXT_SOURCE_CACHED = "cached"

    // ==================== External URL Prefixes ====================

    /** DOI resolver URL prefix. */
    const val DOI_URL_PREFIX = "https://doi.org/"

    /** PubMed article URL prefix. */
    const val PUBMED_URL_PREFIX = "https://pubmed.ncbi.nlm.nih.gov/"

    /** PubMed Central article URL prefix. */
    const val PMC_URL_PREFIX = "https://www.ncbi.nlm.nih.gov/pmc/articles/"

    // ==================== Preview Length Constants ====================

    /** Default maximum length for abstract preview. */
    const val DEFAULT_ABSTRACT_PREVIEW_LENGTH = 300

    /** Default maximum length for passage preview. */
    const val DEFAULT_PASSAGE_PREVIEW_LENGTH = 150

    /** Default maximum length for summary preview. */
    const val DEFAULT_SUMMARY_PREVIEW_LENGTH = 200

    /** Default maximum length for claim preview. */
    const val DEFAULT_CLAIM_PREVIEW_LENGTH = 100
}
