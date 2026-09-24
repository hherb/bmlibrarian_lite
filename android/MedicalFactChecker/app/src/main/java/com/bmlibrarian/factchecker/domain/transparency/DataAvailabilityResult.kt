@file:OptIn(ExperimentalSerializationApi::class)

package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Result of analyzing a data-availability statement.
 *
 * Mirrors the canonical Python `DataAvailabilityInfo` and the Swift
 * `DataAvailabilityResult`. [repositoryUrl] is the raw matched [String] (as in
 * Python) rather than a parsed URL type.
 *
 * Serializable in the JSON shape Swift's `Codable` writes, as part of a stored
 * [TransparencyResult]: [repositoryUrl] travels under Swift's key
 * `repositoryURL`, and the non-optional fields are always written because
 * Swift's decoder requires them.
 */
@Serializable
data class DataAvailabilityResult(
    val statement: String? = null,
    @EncodeDefault val disclosureLevel: DataDisclosureLevel = DataDisclosureLevel.UNKNOWN,
    val repositoryName: String? = null,
    @SerialName("repositoryURL") val repositoryUrl: String? = null,
    val accessionNumber: String? = null,
    @EncodeDefault val restrictions: List<String> = emptyList(),
) {
    companion object {
        /** No data-availability statement present. */
        val NOT_STATED = DataAvailabilityResult(
            disclosureLevel = DataDisclosureLevel.NOT_STATED,
        )
    }
}
