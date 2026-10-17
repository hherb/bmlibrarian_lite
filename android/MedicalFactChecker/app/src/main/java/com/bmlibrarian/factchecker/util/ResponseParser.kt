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

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Utility for parsing LLM responses.
 *
 * Handles common LLM response patterns including:
 * - JSON wrapped in markdown code blocks
 * - Escaped characters in strings
 * - Various JSON formatting issues
 *
 * Following the golden rule: All errors must be handled, logged, and reported.
 */
object ResponseParser {

    /**
     * Lenient JSON parser that ignores unknown keys and allows trailing commas.
     */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    /**
     * Result of parsing a score response.
     *
     * @property score Relevance score (1-5), or null when the reply holds no score on the scale.
     *   A failed parse is never a score: not clamped, not defaulted.
     * @property rationale Explanation for the score, or the reason the parse failed
     * @property parseFailed Whether the reply held no score on the scale (the caller retries it)
     */
    data class ScoreResult(
        val score: Int?,
        val rationale: String,
        val parseFailed: Boolean
    )

    /**
     * Result of parsing a citation extraction response.
     *
     * @property passage The extracted citation passage
     * @property relevance Explanation of why this passage is relevant
     */
    data class CitationResult(
        val passage: String,
        val relevance: String
    )

    /**
     * Result of parsing a report generation response.
     *
     * @property verdict The evidence verdict (SUPPORTED, LIKELY_SUPPORTED, etc.)
     * @property summary Brief summary of findings
     * @property report Full markdown report
     */
    data class ReportResult(
        val verdict: String,
        val summary: String,
        val report: String
    )

    /**
     * Parse a score response from LLM.
     *
     * Expected format:
     * ```json
     * {"score": 4, "rationale": "Directly relevant to the claim"}
     * ```
     *
     * @param response Raw LLM response text
     * A reply that is a JSON object is read as that object alone: a `score` that
     * is missing, null, not a number or off the scale makes it unreadable. The
     * contract is `doc/cross_platform/llm_parity/score_values.json`.
     *
     * @param response Raw LLM response text
     * @return The score, or a result with `parseFailed` set and no score
     */
    fun parseScoreResponse(response: String): ScoreResult {
        val cleanJson = cleanJsonResponse(response)

        val jsonObject = try {
            json.parseToJsonElement(cleanJson).jsonObject
        } catch (e: Exception) {
            // Not a JSON object: only an exact `"score": N` is read from the text
            return parseScoreWithRegex(cleanJson)
        }

        val score = scoreOnScale(jsonObject["score"])
            ?: return ScoreResult(null, UNREADABLE_SCORE_REASON, parseFailed = true)
        val rationale = (jsonObject["explanation"] ?: jsonObject["rationale"] ?: jsonObject["reason"])
            ?.let { it as? JsonPrimitive }
            ?.content
            ?: DEFAULT_RATIONALE
        return ScoreResult(score, rationale, parseFailed = false)
    }

    /**
     * A JSON `score` value as a score on the scale, if it is one.
     *
     * Mirrors the desktop's `_score_on_scale`: a whole number from 1 to 5 as an
     * integer, an integral finite float or a string of digits. A boolean, a
     * fraction, a word, null, a number too large for an Int and anything off the
     * scale is null, never clamped.
     *
     * @param element The value the model gave, or null when the key was missing
     * @return The score, or null
     */
    internal fun scoreOnScale(element: JsonElement?): Int? {
        val primitive = element as? JsonPrimitive ?: return null
        if (primitive is JsonNull) return null
        val value: Int = if (primitive.isString) {
            val text = primitive.content.trim()
            if (text.isEmpty() || !text.all { it in '0'..'9' }) return null
            text.toIntOrNull() ?: return null
        } else {
            if (primitive.booleanOrNull != null) return null
            primitive.intOrNull
                ?: primitive.doubleOrNull
                    ?.takeIf { it.isFinite() && it == Math.rint(it) && it in Int.MIN_VALUE.toDouble()..Int.MAX_VALUE.toDouble() }
                    ?.toInt()
                ?: return null
        }
        return value.takeIf { it in Constants.SCORING_MIN_SCORE..Constants.SCORING_MAX_SCORE }
    }

    /**
     * Parse a citation extraction response from LLM.
     *
     * Expected format:
     * ```json
     * {"citations": [{"passage": "...", "relevance": "..."}]}
     * ```
     *
     * @param response Raw LLM response text
     * @return List of parsed citations, or empty list if parsing fails
     */
    fun parseCitationResponse(response: String): List<CitationResult> {
        val cleanJson = cleanJsonResponse(response)

        return try {
            val jsonObject = json.parseToJsonElement(cleanJson).jsonObject
            val citations = jsonObject["citations"]?.jsonArray ?: return emptyList()

            citations.mapNotNull { element ->
                try {
                    val obj = element.jsonObject
                    val passage = obj["passage"]?.jsonPrimitive?.content ?: return@mapNotNull null
                    val relevance = obj["relevance"]?.jsonPrimitive?.content ?: ""
                    CitationResult(passage, relevance)
                } catch (e: Exception) {
                    null
                }
            }
        } catch (e: Exception) {
            // Fall back to regex parsing
            parseCitationsWithRegex(cleanJson)
        }
    }

    /**
     * Parse a report generation response from LLM.
     *
     * Expected format:
     * ```json
     * {
     *     "verdict": "SUPPORTED",
     *     "summary": "Brief summary",
     *     "report": "Full markdown report"
     * }
     * ```
     *
     * @param response Raw LLM response text
     * @return Parsed report result, or default if parsing fails
     */
    fun parseReportResponse(response: String): ReportResult {
        val cleanJson = cleanJsonResponse(response)

        return try {
            val jsonObject = json.parseToJsonElement(cleanJson).jsonObject
            val verdict = jsonObject["verdict"]?.jsonPrimitive?.content ?: DEFAULT_VERDICT
            val summary = jsonObject["summary"]?.jsonPrimitive?.content ?: DEFAULT_SUMMARY
            val report = jsonObject["report"]?.jsonPrimitive?.content
                ?.unescapeJsonString()
                ?: summary

            ReportResult(verdict.uppercase(), summary, report)
        } catch (e: Exception) {
            // Fall back to regex parsing
            parseReportWithRegex(cleanJson)
        }
    }

    /**
     * Parse a structured query response from LLM and convert to PubMed query string.
     *
     * Uses the structured JSON approach for better cross-platform consistency.
     * Falls back to claim-based search if parsing fails.
     *
     * @param response Raw LLM response text
     * @param claim Original claim for fallback
     * @return The PubMed query string
     */
    fun parseStructuredQueryResponse(response: String, claim: String): String {
        // Try to parse as structured query first
        val structuredQuery = com.bmlibrarian.factchecker.domain.model.StructuredQuery.parse(response)

        if (structuredQuery != null && !structuredQuery.isEmpty) {
            // Build PubMed query from structured query
            return com.bmlibrarian.factchecker.domain.model.PubMedQueryBuilder.build(structuredQuery)
        }

        // Fallback: try legacy parsing
        return parsePubMedQueryResponseLegacy(response, claim)
    }

    /**
     * Legacy PubMed query parsing (fallback).
     *
     * @param response Raw LLM response text
     * @param claim Original claim for fallback
     * @return The extracted PubMed query string
     */
    private fun parsePubMedQueryResponseLegacy(response: String, claim: String): String {
        val trimmed = response.trim()

        // If response is JSON, extract the query field
        if (trimmed.startsWith("{")) {
            try {
                val cleanJson = cleanJsonResponse(trimmed)
                val jsonObject = json.parseToJsonElement(cleanJson).jsonObject
                val query = jsonObject["query"]?.jsonPrimitive?.content
                if (query != null) return query.trim()
            } catch (e: Exception) {
                // Continue with raw extraction
            }
        }

        // Remove markdown code blocks if present
        val withoutCodeBlocks = trimmed
            .removePrefix("```")
            .removeSuffix("```")
            .trim()

        // If it starts with a quote, extract the quoted content
        if (withoutCodeBlocks.startsWith("\"") || withoutCodeBlocks.startsWith("'")) {
            val quote = withoutCodeBlocks.first()
            val endIndex = withoutCodeBlocks.indexOf(quote, 1)
            if (endIndex > 0) {
                return withoutCodeBlocks.substring(1, endIndex)
            }
        }

        // If we got something useful, use the first line
        val firstLine = withoutCodeBlocks.lines().first().trim()
        if (firstLine.isNotEmpty() && firstLine.length > 10) {
            return firstLine
        }

        // Final fallback: use claim with basic filters
        return "$claim AND hasabstract AND (Clinical Trial[pt] OR Randomized Controlled Trial[pt] OR Meta-Analysis[pt] OR Systematic Review[pt] OR Review[pt])"
    }

    /**
     * Parse a PubMed query conversion response from LLM.
     *
     * @deprecated Use parseStructuredQueryResponse instead
     * @param response Raw LLM response text
     * @return The extracted PubMed query string
     */
    @Deprecated("Use parseStructuredQueryResponse instead", ReplaceWith("parseStructuredQueryResponse(response, claim)"))
    fun parsePubMedQueryResponse(response: String): String {
        return parseStructuredQueryResponse(response, "")
    }

    /**
     * Clean a JSON response by removing markdown code blocks and fixing common issues.
     *
     * @param response Raw response text
     * @return Cleaned JSON string
     */
    private fun cleanJsonResponse(response: String): String {
        var cleaned = response.trim()

        // Remove markdown code block markers
        if (cleaned.startsWith("```json")) {
            cleaned = cleaned.removePrefix("```json")
        } else if (cleaned.startsWith("```")) {
            cleaned = cleaned.removePrefix("```")
        }

        if (cleaned.endsWith("```")) {
            cleaned = cleaned.removeSuffix("```")
        }

        return cleaned.trim()
    }

    /**
     * Fallback regex parsing for score responses.
     */
    private fun parseScoreWithRegex(text: String): ScoreResult {
        // A whole number and nothing else: `4.5` or `4abc` is no score
        val scoreRegex = Regex(""""score"\s*:\s*(\d+)\s*[,}]""")
        val rationaleRegex = Regex(""""(?:rationale|explanation)"\s*:\s*"([^"]+)"""")

        val score = scoreRegex.find(text)?.groupValues?.get(1)?.toIntOrNull()
            ?.takeIf { it in Constants.SCORING_MIN_SCORE..Constants.SCORING_MAX_SCORE }
            ?: return ScoreResult(null, UNREADABLE_SCORE_REASON, parseFailed = true)
        val rationale = rationaleRegex.find(text)?.groupValues?.get(1)
            ?: DEFAULT_RATIONALE

        return ScoreResult(score, rationale, parseFailed = false)
    }

    /**
     * Fallback regex parsing for citation responses.
     */
    private fun parseCitationsWithRegex(text: String): List<CitationResult> {
        val results = mutableListOf<CitationResult>()
        val regex = Regex(
            """"passage"\s*:\s*"([^"]+)"[^}]*"relevance"\s*:\s*"([^"]+)"""",
            RegexOption.DOT_MATCHES_ALL
        )

        regex.findAll(text).forEach { match ->
            results.add(
                CitationResult(
                    passage = match.groupValues[1].unescapeJsonString(),
                    relevance = match.groupValues[2].unescapeJsonString()
                )
            )
        }

        return results
    }

    /**
     * Fallback regex parsing for report responses.
     */
    private fun parseReportWithRegex(text: String): ReportResult {
        val verdictRegex = Regex(""""verdict"\s*:\s*"([^"]+)"""")
        val summaryRegex = Regex(""""summary"\s*:\s*"([^"]+)"""")
        // Report can contain newlines and special characters
        val reportRegex = Regex(""""report"\s*:\s*"([\s\S]*?)(?:"\s*[,}])""")

        val verdict = verdictRegex.find(text)?.groupValues?.get(1)?.uppercase() ?: DEFAULT_VERDICT
        val summary = summaryRegex.find(text)?.groupValues?.get(1)?.unescapeJsonString()
            ?: DEFAULT_SUMMARY
        val report = reportRegex.find(text)?.groupValues?.get(1)?.unescapeJsonString() ?: summary

        return ReportResult(verdict, summary, report)
    }

    /**
     * Unescape JSON string escape sequences.
     */
    private fun String.unescapeJsonString(): String {
        return this
            .replace("\\n", "\n")
            .replace("\\r", "\r")
            .replace("\\t", "\t")
            .replace("\\\"", "\"")
            .replace("\\\\", "\\")
    }

    // Default values for failed parsing
    private const val UNREADABLE_SCORE_REASON = "parse: no relevance score on the scale in the reply"
    private const val DEFAULT_RATIONALE = "Unable to parse response"
    private const val DEFAULT_VERDICT = "UNCLEAR"
    private const val DEFAULT_SUMMARY = "Unable to generate summary"
}
