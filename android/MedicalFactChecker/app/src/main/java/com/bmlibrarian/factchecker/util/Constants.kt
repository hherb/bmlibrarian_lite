/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

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

    /** Height of compact context header when scrolled (dp). */
    const val UI_COMPACT_HEADER_HEIGHT = 56

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

    // ==================== JATS Parsing Constants ====================

    /** Maximum heading level in markdown output. */
    const val JATS_MAX_HEADING_LEVEL = 6

    /** Maximum authors before showing "et al." in JATS output. */
    const val JATS_MAX_AUTHORS_BEFORE_ET_AL = 3

    /** Minimum length for PMID detection. */
    const val JATS_MIN_PMID_LENGTH = 7

    /** Europe PMC figure base URL. */
    const val JATS_EUROPE_PMC_FIGURE_BASE_URL = "https://europepmc.org/articles"

    /** Europe PMC full text XML base URL. */
    const val EUROPE_PMC_FULLTEXT_BASE_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/"

    /** Default email for Unpaywall API (should be configured by user). */
    const val UNPAYWALL_DEFAULT_EMAIL = "bmlibrarian@example.com"

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

    // ==================== Report Screen Configuration ====================

    /** Regex pattern to match citation references like [1], [2], etc. */
    const val REFERENCE_PATTERN = "\\[(\\d+)\\]"

    /** Bottom sheet peek height in dp. */
    const val BOTTOM_SHEET_PEEK_HEIGHT = 56

    /** Bottom padding for content above navigation bar. */
    const val UI_NAVIGATION_BAR_PADDING = 32

    // ==================== PDF Export Configuration ====================

    /** PDF export cache subdirectory name. */
    const val PDF_EXPORT_DIRECTORY = "exports"

    /** PDF filename prefix. */
    const val PDF_FILENAME_PREFIX = "factcheck_report_"

    /** Date format pattern for PDF filenames. */
    const val PDF_FILENAME_DATE_PATTERN = "yyyy-MM-dd_HHmmss"

    /** Date format pattern for display in reports. */
    const val REPORT_DATE_DISPLAY_PATTERN = "MMMM d, yyyy"

    /** Date format pattern for display with time. */
    const val REPORT_DATETIME_DISPLAY_PATTERN = "MMM d, yyyy 'at' h:mm a"

    /** PDF page margin in points (72 points = 1 inch). */
    const val PDF_PAGE_MARGIN_POINTS = 72f

    /** PDF title font size in points. */
    const val PDF_TITLE_FONT_SIZE = 18f

    /** PDF heading font size in points. */
    const val PDF_HEADING_FONT_SIZE = 14f

    /** PDF body font size in points. */
    const val PDF_BODY_FONT_SIZE = 11f

    /** PDF small font size in points. */
    const val PDF_SMALL_FONT_SIZE = 9f

    /** PDF line spacing multiplier. */
    const val PDF_LINE_SPACING = 1.2f

    // ==================== Markdown Rendering ====================

    /** Text size in SP for markdown content. */
    const val MARKDOWN_TEXT_SIZE_SP = 16f

    // ==================== Progress Indicator ====================

    /** Stroke width for small circular progress indicators in dp. */
    const val PROGRESS_STROKE_WIDTH_SMALL = 2

    // ==================== Color/Alpha Constants ====================

    /** Alpha for verdict header background tint. */
    const val VERDICT_BACKGROUND_ALPHA = 0.1f

    /** Alpha for divider lines. */
    const val DIVIDER_ALPHA = 0.5f

    // ==================== History Screen Configuration ====================

    /** Date format pattern for session list display. */
    const val SESSION_DATE_DISPLAY_PATTERN = "MMM d, yyyy"

    /** Maximum lines for claim text in session card. */
    const val MAX_CLAIM_LINES = 2

    /** Maximum lines for summary preview in session card. */
    const val MAX_SUMMARY_PREVIEW_LINES = 2

    /** Spacing between session cards in the history list (dp). */
    const val HISTORY_CARD_SPACING = 12

    /** Cost display decimal places. */
    const val COST_DISPLAY_DECIMAL_PLACES = 4

    // ==================== Luminance Calculation (ITU-R BT.601) ====================

    /** Red coefficient for relative luminance (ITU-R BT.601 Y'). */
    const val LUMINANCE_RED_COEFFICIENT = 0.299f

    /** Green coefficient for relative luminance (ITU-R BT.601 Y'). */
    const val LUMINANCE_GREEN_COEFFICIENT = 0.587f

    /** Blue coefficient for relative luminance (ITU-R BT.601 Y'). */
    const val LUMINANCE_BLUE_COEFFICIENT = 0.114f

    /** Threshold for determining light vs dark background (0.5 = midpoint). */
    const val LUMINANCE_THRESHOLD = 0.5f

    // ==================== PDF Verdict Colors (RGB) ====================

    /** Green RGB for SUPPORTED verdict in PDF (matches VerdictSupported). */
    const val PDF_VERDICT_GREEN_R = 76
    const val PDF_VERDICT_GREEN_G = 175
    const val PDF_VERDICT_GREEN_B = 80

    /** Light green RGB for LIKELY_SUPPORTED verdict in PDF. */
    const val PDF_VERDICT_LIGHT_GREEN_R = 139
    const val PDF_VERDICT_LIGHT_GREEN_G = 195
    const val PDF_VERDICT_LIGHT_GREEN_B = 74

    /** Orange RGB for UNCLEAR/LIKELY_REFUTED verdict in PDF. */
    const val PDF_VERDICT_ORANGE_R = 255
    const val PDF_VERDICT_ORANGE_G = 152
    const val PDF_VERDICT_ORANGE_B = 0

    /** Red RGB for REFUTED verdict in PDF. */
    const val PDF_VERDICT_RED_R = 244
    const val PDF_VERDICT_RED_G = 67
    const val PDF_VERDICT_RED_B = 54

    /** Gray RGB for unknown verdict in PDF. */
    const val PDF_VERDICT_GRAY_R = 158
    const val PDF_VERDICT_GRAY_G = 158
    const val PDF_VERDICT_GRAY_B = 158

    // ==================== Settings Screen Configuration ====================

    /** Minimum value for per-run budget slider in USD. */
    const val SETTINGS_MIN_RUN_BUDGET_USD = 0.10f

    /** Maximum value for per-run budget slider in USD. */
    const val SETTINGS_MAX_RUN_BUDGET_USD = 5.0f

    /** Number of steps for per-run budget slider. */
    const val SETTINGS_RUN_BUDGET_STEPS = 49

    /** Minimum value for monthly budget slider in USD. */
    const val SETTINGS_MIN_MONTHLY_BUDGET_USD = 1.0f

    /** Maximum value for monthly budget slider in USD. */
    const val SETTINGS_MAX_MONTHLY_BUDGET_USD = 100.0f

    /** Number of steps for monthly budget slider. */
    const val SETTINGS_MONTHLY_BUDGET_STEPS = 99

    /** Minimum value for batch size slider. */
    const val SETTINGS_MIN_BATCH_SIZE = 5f

    /** Maximum value for batch size slider. */
    const val SETTINGS_MAX_BATCH_SIZE = 100f

    /** Number of steps for batch size slider. */
    const val SETTINGS_BATCH_SIZE_STEPS = 18

    /** Minimum value for target documents slider. */
    const val SETTINGS_MIN_TARGET_DOCS = 3f

    /** Maximum value for target documents slider. */
    const val SETTINGS_MAX_TARGET_DOCS = 50f

    /** Number of steps for target documents slider. */
    const val SETTINGS_TARGET_DOCS_STEPS = 46

    /** Column weight for model name in pricing table. */
    const val SETTINGS_PRICING_MODEL_WEIGHT = 2f

    /** Column weight for price columns in pricing table. */
    const val SETTINGS_PRICING_VALUE_WEIGHT = 1f

    /** Number of decimal places for budget display. */
    const val SETTINGS_BUDGET_DECIMAL_PLACES = 2
}
