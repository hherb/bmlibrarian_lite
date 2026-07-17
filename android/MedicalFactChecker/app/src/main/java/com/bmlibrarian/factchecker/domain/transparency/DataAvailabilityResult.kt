package com.bmlibrarian.factchecker.domain.transparency

/**
 * Result of analyzing a data-availability statement.
 *
 * Mirrors the canonical Python `DataAvailabilityInfo` and the Swift
 * `DataAvailabilityResult`. [repositoryUrl] is the raw matched [String] (as in
 * Python) rather than a parsed URL type.
 */
data class DataAvailabilityResult(
    val statement: String? = null,
    val disclosureLevel: DataDisclosureLevel = DataDisclosureLevel.UNKNOWN,
    val repositoryName: String? = null,
    val repositoryUrl: String? = null,
    val accessionNumber: String? = null,
    val restrictions: List<String> = emptyList(),
) {
    companion object {
        /** No data-availability statement present. */
        val NOT_STATED = DataAvailabilityResult(
            disclosureLevel = DataDisclosureLevel.NOT_STATED,
        )
    }
}
