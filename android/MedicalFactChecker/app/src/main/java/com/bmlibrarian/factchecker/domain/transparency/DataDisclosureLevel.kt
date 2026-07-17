package com.bmlibrarian.factchecker.domain.transparency

/**
 * Classification of how openly a study's underlying data is shared.
 *
 * Raw values and semantics mirror the canonical Python `DataDisclosureLevel`
 * (`study_transparency_analyzer.py`) and the Swift `DataDisclosureLevel`
 * (BioMedLit), so a statement classifies identically on all three platforms.
 */
enum class DataDisclosureLevel(val rawValue: String, val displayName: String) {
    /** Data deposited in a public repository or explicitly openly available. */
    FULL_OPEN("full_open", "Fully Open"),

    /**
     * Available upon reasonable request. Never emitted by
     * [DataAvailabilityAnalyzer.analyze] (on-request phrasing maps to
     * [RESTRICTED]); retained for later scoring and externally-constructed
     * results, matching Python/Swift.
     */
    AVAILABLE_ON_REQUEST("on_request", "Available on Request"),

    /** Significant access restrictions (IRB, ethics, privacy/legal, on request). */
    RESTRICTED("restricted", "Restricted"),

    /** Effectively unavailable — a sharing statement that amounts to a refusal. */
    NOT_AVAILABLE("not_available", "Not Available"),

    /** No data-availability statement present. */
    NOT_STATED("not_stated", "Not Stated"),

    /** A statement exists but no pattern matched. */
    UNKNOWN("unknown", "Unknown"),
}
