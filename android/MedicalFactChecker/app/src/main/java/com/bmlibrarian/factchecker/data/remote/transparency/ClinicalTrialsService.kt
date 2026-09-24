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

package com.bmlibrarian.factchecker.data.remote.transparency

import android.util.Log
import com.bmlibrarian.factchecker.domain.transparency.JsonCasts
import com.bmlibrarian.factchecker.domain.transparency.TransparencyConstants
import com.bmlibrarian.factchecker.domain.transparency.TrialRegistration
import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.time.Year
import java.time.YearMonth
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.format.ResolverStyle
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Why a ClinicalTrials.gov request failed. Messages are those of the Swift `ClinicalTrialsError`.
 *
 * @property isRetryable Whether another attempt could succeed (network and server failures).
 */
sealed class ClinicalTrialsException(message: String) : Exception(message) {
    abstract val isRetryable: Boolean

    /** The NCT ID cannot be turned into a request URL. */
    class InvalidNctId(val nctId: String) : ClinicalTrialsException("Invalid NCT ID: $nctId") {
        override val isRetryable: Boolean = false
    }

    /** The exchange failed in transport (no connection, timeout, ...). */
    class NetworkError(val detail: String) : ClinicalTrialsException("Network error: $detail") {
        override val isRetryable: Boolean = true
    }

    /** A non-retryable HTTP status other than 404. */
    class HttpError(val statusCode: Int) : ClinicalTrialsException("HTTP error: $statusCode") {
        override val isRetryable: Boolean = false
    }

    /** A retryable status (429 or 5xx). */
    class ServerError(val statusCode: Int) :
        ClinicalTrialsException("ClinicalTrials.gov server error (HTTP $statusCode). Try again later.") {
        override val isRetryable: Boolean = true
    }

    /** The answer was not a JSON object. */
    class ParseError(val detail: String) : ClinicalTrialsException("Failed to parse response: $detail") {
        override val isRetryable: Boolean = false
    }
}

/**
 * Client for the ClinicalTrials.gov API v2: sponsor class, registered outcomes
 * and results-posting status of a registered trial.
 *
 * Ported from the Swift `ClinicalTrialsService` (BioMedLit). A 404 answers
 * null — the trial is absent; every other failure throws a
 * [ClinicalTrialsException].
 *
 * @param httpClient HTTP client; defaults to one with Swift's 45 s timeout.
 * @param baseUrl API base URL (overridable for tests).
 * @param retryPolicy How transient failures are retried.
 * @param minimumRequestIntervalMs Minimum gap between two requests.
 */
class ClinicalTrialsService(
    private val httpClient: OkHttpClient = defaultTransparencyHttpClient(),
    private val baseUrl: String = TransparencyConstants.CLINICAL_TRIALS_BASE_URL,
    private val retryPolicy: TransparencyRetryPolicy = TransparencyRetryPolicy(),
    minimumRequestIntervalMs: Long = TransparencyConstants.MINIMUM_REQUEST_INTERVAL_MS,
) {
    private val pacer = RequestPacer(minimumRequestIntervalMs)

    /**
     * Fetch a study by NCT ID.
     *
     * @param nctId The NCT identifier; upper-cased, trimmed and given an "NCT" prefix if missing.
     * @return The study JSON, or null if ClinicalTrials.gov answered 404.
     * @throws ClinicalTrialsException on any other failure, after retrying transient ones.
     */
    suspend fun getStudy(nctId: String): JsonObject? {
        val normalizedId = normalizeNctId(nctId)
        if (percentEncodePath(normalizedId) != normalizedId) throw ClinicalTrialsException.InvalidNctId(nctId)
        val url = "$baseUrl/studies/$normalizedId".toHttpUrlOrNull()
            ?: throw ClinicalTrialsException.InvalidNctId(nctId)
        val request = Request.Builder().url(url).build()

        pacer.awaitTurn()
        Log.d(TAG, "Fetching ClinicalTrials.gov study: $normalizedId")

        val body = withTransparencyRetries(retryPolicy, { it is ClinicalTrialsException && it.isRetryable }) {
            val response = try {
                executeTransparencyRequest(httpClient, request)
            } catch (e: IOException) {
                throw ClinicalTrialsException.NetworkError(e.javaClass.simpleName)
            }
            val status = response.statusCode
            when {
                status in TransparencyHttpConstants.RETRYABLE_STATUS_CODES ->
                    throw ClinicalTrialsException.ServerError(status)
                status == TransparencyHttpConstants.HTTP_STATUS_OK -> response.body
                status == TransparencyHttpConstants.HTTP_STATUS_NOT_FOUND -> null
                else -> throw ClinicalTrialsException.HttpError(status)
            }
        }

        if (body == null) {
            Log.d(TAG, "ClinicalTrials.gov returned 404 for: $normalizedId")
            return null
        }

        val study = try {
            JsonCasts.obj(Json.parseToJsonElement(body))
        } catch (e: SerializationException) {
            null
        } ?: throw ClinicalTrialsException.ParseError("Invalid JSON")

        Log.i(TAG, "ClinicalTrials.gov returned study: $normalizedId")
        return study
    }

    /**
     * Fetch several studies, one after another.
     *
     * Mirrors Swift's dictionary semantics exactly, and the difference matters:
     * a study ClinicalTrials.gov answered 404 for is present **with a null
     * value**, while a study whose fetch *failed* is **absent** from the map
     * (logged only). Callers must not read a missing key as "no such trial".
     *
     * @param nctIds NCT identifiers.
     * @return Normalized NCT ID -> study (null for 404), in request order; failed fetches omitted.
     */
    suspend fun getStudies(nctIds: List<String>): Map<String, JsonObject?> {
        val results = LinkedHashMap<String, JsonObject?>()
        for (nctId in nctIds) {
            val normalizedId = normalizeNctId(nctId)
            try {
                results[normalizedId] = getStudy(normalizedId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Failed to fetch study $normalizedId: ${describeFailure(e)}")
                results.remove(normalizedId)
            }
        }
        return results
    }

    /**
     * Parse a study into a [TrialRegistration].
     *
     * Reads `protocolSection` (required): identification (NCT ID, official title
     * falling back to brief title), lead sponsor name and class, primary and
     * secondary outcome measures, completion date; and top-level `hasResults`.
     *
     * @param study The study JSON, or null.
     * @return The registration, or null without a `protocolSection` object.
     */
    fun extractTrialInfo(study: JsonObject?): TrialRegistration? {
        val protocolSection = JsonCasts.obj(study?.get("protocolSection")) ?: return null

        val idModule = JsonCasts.obj(protocolSection["identificationModule"])
        val nctId = JsonCasts.string(idModule?.get("nctId")) ?: ""
        val title = JsonCasts.string(idModule?.get("officialTitle")) ?: JsonCasts.string(idModule?.get("briefTitle"))

        val sponsorModule = JsonCasts.obj(protocolSection["sponsorCollaboratorsModule"])
        val leadSponsor = JsonCasts.obj(sponsorModule?.get("leadSponsor"))
        val sponsorName = JsonCasts.string(leadSponsor?.get("name"))
        val sponsorClass = JsonCasts.string(leadSponsor?.get("class"))

        val outcomesModule = JsonCasts.obj(protocolSection["outcomesModule"])
        val primaryOutcomes = extractOutcomes(outcomesModule?.get("primaryOutcomes"))
        val secondaryOutcomes = extractOutcomes(outcomesModule?.get("secondaryOutcomes"))

        val statusModule = JsonCasts.obj(protocolSection["statusModule"])
        val completionDate = extractDate(statusModule?.get("completionDateStruct"))

        val hasResults = JsonCasts.boolean(study?.get("hasResults")) ?: false

        return TrialRegistration(
            registry = TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME,
            registrationId = nctId,
            title = title,
            sponsorClass = sponsorClass,
            leadSponsor = sponsorName,
            resultsPosted = hasResults,
            completionDate = completionDate,
            primaryOutcomesRegistered = primaryOutcomes,
            secondaryOutcomesRegistered = secondaryOutcomes,
        )
    }

    /**
     * Parse every study that can be parsed.
     *
     * @param studies NCT ID -> study, as [getStudies] returns.
     * @return The registrations, skipping null and unparseable studies.
     */
    fun extractTrialInfos(studies: Map<String, JsonObject?>): List<TrialRegistration> =
        studies.values.mapNotNull { extractTrialInfo(it) }

    /** Upper-case, trim spaces and tabs, and add the "NCT" prefix if missing. */
    private fun normalizeNctId(id: String): String {
        val normalized = id.uppercase().trim { it == ' ' || it == '\t' }
        return if (normalized.startsWith(NCT_PREFIX)) normalized else "$NCT_PREFIX$normalized"
    }

    /** The `measure` of each outcome; empty unless the value is an array of objects. */
    private fun extractOutcomes(outcomes: JsonElement?): List<String> =
        JsonCasts.objectList(outcomes)?.mapNotNull { JsonCasts.string(it["measure"]) } ?: emptyList()

    /**
     * The `date` of a date struct, as "yyyy-MM-dd", "yyyy-MM" or "yyyy" (first
     * of month / year for the shorter forms), at midnight in the device's time
     * zone as Swift's `DateFormatter` reads it.
     */
    private fun extractDate(dateStruct: JsonElement?): Instant? {
        val dateString = JsonCasts.string(JsonCasts.obj(dateStruct)?.get("date")) ?: return null
        val date = parseOrNull { LocalDate.parse(dateString, FULL_DATE) }
            ?: parseOrNull { YearMonth.parse(dateString, MONTH_DATE).atDay(1) }
            ?: parseOrNull { Year.parse(dateString, YEAR_DATE).atDay(1) }
            ?: return null
        return date.atStartOfDay(ZoneId.systemDefault()).toInstant()
    }

    /** [parse]'s value, or null when the text does not have that form. */
    private inline fun parseOrNull(parse: () -> LocalDate): LocalDate? =
        try {
            parse()
        } catch (e: DateTimeParseException) {
            null
        }

    private companion object {
        const val TAG = "ClinicalTrialsService"
        const val NCT_PREFIX = "NCT"
        val FULL_DATE: DateTimeFormatter = DateTimeFormatter.ofPattern("uuuu-M-d").withResolverStyle(ResolverStyle.STRICT)
        val MONTH_DATE: DateTimeFormatter = DateTimeFormatter.ofPattern("uuuu-M").withResolverStyle(ResolverStyle.STRICT)
        val YEAR_DATE: DateTimeFormatter = DateTimeFormatter.ofPattern("uuuu").withResolverStyle(ResolverStyle.STRICT)
    }
}
