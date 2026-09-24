package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Classification of how openly a study's underlying data is shared.
 *
 * Raw values and semantics mirror the canonical Python `DataDisclosureLevel`
 * (`study_transparency_analyzer.py`) and the Swift `DataDisclosureLevel`
 * (BioMedLit), so a statement classifies identically on all three platforms.
 *
 * Serialized by [rawValue] (each entry's [SerialName]), the same strings Swift's
 * `Codable` writes, so a stored [TransparencyResult] reads on either platform.
 */
@Serializable
enum class DataDisclosureLevel(val rawValue: String, val displayName: String) {
    /** Data deposited in a public repository or explicitly openly available. */
    @SerialName("full_open")
    FULL_OPEN("full_open", "Fully Open"),

    /**
     * Available upon reasonable request. Never emitted by
     * [DataAvailabilityAnalyzer.analyze] (on-request phrasing maps to
     * [RESTRICTED]); retained for later scoring and externally-constructed
     * results, matching Python/Swift.
     */
    @SerialName("on_request")
    AVAILABLE_ON_REQUEST("on_request", "Available on Request"),

    /** Significant access restrictions (IRB, ethics, privacy/legal, on request). */
    @SerialName("restricted")
    RESTRICTED("restricted", "Restricted"),

    /** Effectively unavailable — a sharing statement that amounts to a refusal. */
    @SerialName("not_available")
    NOT_AVAILABLE("not_available", "Not Available"),

    /** No data-availability statement present. */
    @SerialName("not_stated")
    NOT_STATED("not_stated", "Not Stated"),

    /** A statement exists but no pattern matched. */
    @SerialName("unknown")
    UNKNOWN("unknown", "Unknown"),
}
