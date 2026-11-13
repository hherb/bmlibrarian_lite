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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
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
     * The object read is the first balanced `{...}` in the reply, so prose or a
     * markdown fence around it does not hide it, as on the desktop and iOS. A
     * `score` that is missing, null, not a number or off the scale makes the
     * reply unreadable, and so does a value JSON does not define anywhere in it
     * ([holdsRefusedValue]), with no regex read around it. The contract is
     * `doc/cross_platform/llm_parity/score_values.json`.
     *
     * @param response Raw LLM response text
     * @return The score, or a result with `parseFailed` set and no score
     */
    fun parseScoreResponse(response: String): ScoreResult {
        val cleanJson = cleanJsonResponse(response)
        val candidate = firstJsonObject(cleanJson) ?: cleanJson

        val jsonObject = try {
            json.parseToJsonElement(candidate).jsonObject
        } catch (e: Exception) {
            // Not a JSON object (a trailing comma, a reply cut short): only an
            // exact `"score": N` is read from the text, and none beside a
            // value JSON does not define (#761)
            if (holdsRefusedToken(cleanJson)) {
                return ScoreResult(null, REFUSED_VALUE_REASON, parseFailed = true)
            }
            return parseScoreWithRegex(cleanJson)
        }
        if (holdsRefusedValue(jsonObject)) {
            return ScoreResult(null, REFUSED_VALUE_REASON, parseFailed = true)
        }

        val score = scoreOnScale(jsonObject["score"])
            ?: return ScoreResult(null, UNREADABLE_SCORE_REASON, parseFailed = true)
        val rationale = listOf("explanation", "rationale", "reason")
            .firstNotNullOfOrNull { key -> textOf(jsonObject[key]) }
            ?: NO_RATIONALE
        return ScoreResult(score, rationale, parseFailed = false)
    }

    /**
     * Whether a parsed reply holds a value JSON does not define (#761).
     *
     * The lenient parser keeps `NaN`, `Infinity`, `-Infinity`, a number that
     * overflows binary64 (`1e999`) and an integer past it as bare tokens, and
     * decodes a lone surrogate escape (`"\ud800"`) into a string. bmlib, the
     * desktop and iOS refuse the whole reply over one (bmlib#572), never
     * reading the fields beside it. Any other bare word stays the lenient
     * parse's business.
     *
     * @param element The parsed reply
     * @return True when some number in it is not a finite JSON number, or some
     *   key or string holds a lone surrogate
     */
    internal fun holdsRefusedValue(element: JsonElement): Boolean = when (element) {
        is JsonObject -> element.keys.any(::holdsLoneSurrogate) || element.values.any(::holdsRefusedValue)
        is JsonArray -> element.any(::holdsRefusedValue)
        is JsonPrimitive ->
            if (element.isString) holdsLoneSurrogate(element.content) else isRefusedToken(element.content)
    }

    /**
     * Whether reply text the lenient parse could not read holds a value JSON
     * does not define (#761), so no regex reads a field beside it.
     *
     * String literals, a string cut off at the end of the reply included, are
     * set aside before bare tokens are read: a quoted `"NaN"` is text. A lone
     * surrogate, raw or as a `\u` escape, is refused wherever it stands.
     *
     * @param text The reply, markdown fences removed
     * @return True when a bare token outside every string is refused, or the
     *   text holds a lone surrogate
     */
    internal fun holdsRefusedToken(text: String): Boolean =
        holdsLoneSurrogate(text) || LONE_SURROGATE_ESCAPE.containsMatchIn(text) ||
            BARE_TOKEN.findAll(STRING_LITERAL.replace(text, "\"\"")).any { isRefusedToken(it.value) }

    /** `NaN`, `Infinity`, `-Infinity`, or a JSON number that is not finite in binary64. */
    private fun isRefusedToken(token: String): Boolean =
        token in NON_FINITE_TOKENS || (JSON_NUMBER.matches(token) && !token.toDouble().isFinite())

    /** Whether [text] holds a surrogate not paired as a UTF-16 high-low pair. */
    private fun holdsLoneSurrogate(text: String): Boolean {
        var index = 0
        while (index < text.length) {
            val char = text[index]
            if (char.isHighSurrogate() && index + 1 < text.length && text[index + 1].isLowSurrogate()) {
                index += 2
                continue
            }
            if (char.isSurrogate()) return true
            index++
        }
        return false
    }

    /**
     * A JSON value as text, when it is a string.
     *
     * A null, a number or an object is no rationale: `JsonNull` is a
     * `JsonPrimitive` whose content is the word "null".
     *
     * @param element The value, or null when the key was missing
     * @return The string, or null
     */
    private fun textOf(element: JsonElement?): String? {
        val primitive = element as? JsonPrimitive ?: return null
        return if (primitive.isString) primitive.content else null
    }

    /**
     * The first balanced `{...}` in a text, nested objects included.
     *
     * A brace inside a JSON string is text, not structure, and an escaped quote
     * does not end the string: the same scan as iOS's `extractBalancedJSON` and
     * the desktop's `_first_json_object`.
     *
     * @param text The reply text
     * @return The object's text, or null when the text holds no balanced one
     */
    internal fun firstJsonObject(text: String): String? {
        val start = text.indexOf('{')
        if (start == -1) return null
        var depth = 0
        var inString = false
        var escaped = false
        for (index in start until text.length) {
            val char = text[index]
            when {
                escaped -> escaped = false
                inString && char == '\\' -> escaped = true
                char == '"' -> inString = !inString
                inString -> Unit
                char == '{' -> depth++
                char == '}' -> {
                    depth--
                    if (depth == 0) return text.substring(start, index + 1)
                }
            }
        }
        return null
    }

    /**
     * A JSON `score` value as a score on the scale, if it is one.
     *
     * Mirrors the desktop's `_score_on_scale`: a whole number from 1 to 5 as an
     * integer, an integral float or a string of the ASCII digits 0-9. A boolean,
     * a fraction, a word, null, a non-ASCII digit and anything off the scale is
     * null, never clamped.
     *
     * @param element The value the model gave, or null when the key was missing
     * @return The score, or null
     */
    internal fun scoreOnScale(element: JsonElement?): Int? {
        val primitive = element as? JsonPrimitive ?: return null
        if (primitive is JsonNull) return null
        val content = primitive.content.let { if (primitive.isString) it.trim() else it }
        // A string holds digits only; a bare value is a JSON number, which the
        // lenient parser does not check ("4f" and "0x4p0" are Java doubles)
        val pattern = if (primitive.isString) ASCII_DIGITS else JSON_NUMBER
        if (!pattern.matches(content)) return null
        val value = content.toDoubleOrNull() ?: return null
        val low = Constants.SCORING_MIN_SCORE.toDouble()
        val high = Constants.SCORING_MAX_SCORE.toDouble()
        return if (value in low..high && value == Math.rint(value)) value.toInt() else null
    }

    /**
     * Parse a citation extraction response from LLM.
     *
     * Expected format:
     * ```json
     * {"citations": [{"passage": "...", "relevance": "..."}]}
     * ```
     *
     * A reply holding a value JSON does not define ([holdsRefusedValue],
     * [holdsRefusedToken]) is unreadable, not a reply with no passages: no
     * passage beside it is read (#761).
     *
     * @param response Raw LLM response text
     * @return List of parsed citations, or empty list if none is found; null
     *   when the reply holds a value JSON does not define
     */
    fun parseCitationResponse(response: String): List<CitationResult>? {
        val cleanJson = cleanJsonResponse(response)

        return try {
            val jsonObject = json.parseToJsonElement(cleanJson).jsonObject
            // No passage is read around a value JSON does not define (#761)
            if (holdsRefusedValue(jsonObject)) return null
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
            // Fall back to regex parsing, never beside a refused value (#761)
            if (holdsRefusedToken(cleanJson)) null else parseCitationsWithRegex(cleanJson)
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
     *
     * Reached only when no JSON object in the reply parses: a trailing comma
     * (`{"score": 3,}`, which iOS also reads) or a reply cut short. The score
     * must be a whole number followed by `,` or `}`, so `4.5` is no score.
     *
     * @param text The reply, markdown fences removed
     * @return The score, or a result with `parseFailed` set and no score
     */
    private fun parseScoreWithRegex(text: String): ScoreResult {
        // A whole number and nothing else: `4.5` or `4abc` is no score
        val scoreRegex = Regex(""""score"\s*:\s*(\d+)\s*[,}]""")
        val rationaleRegex = Regex(""""(?:rationale|explanation)"\s*:\s*"([^"]+)"""")

        val score = scoreRegex.find(text)?.groupValues?.get(1)?.toIntOrNull()
            ?.takeIf { it in Constants.SCORING_MIN_SCORE..Constants.SCORING_MAX_SCORE }
            ?: return ScoreResult(null, UNREADABLE_SCORE_REASON, parseFailed = true)
        val rationale = rationaleRegex.find(text)?.groupValues?.get(1)
            ?: NO_RATIONALE

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

    /** A scored reply that gave no explanation: the same words as iOS. */
    internal const val NO_RATIONALE = "No explanation provided"

    /** A string score: one or more of the ASCII digits 0-9, as on every platform. */
    private val ASCII_DIGITS = Regex("[0-9]+")

    /** The bare tokens the lenient parser keeps that JSON does not define (#761). */
    private val NON_FINITE_TOKENS = setOf("NaN", "Infinity", "-Infinity")
    private const val REFUSED_VALUE_REASON =
        "parse: the reply holds NaN, Infinity, a number past binary64 or a lone surrogate"

    /** A JSON string literal, or one cut off at the end of the reply. */
    private val STRING_LITERAL = Regex(""""(?:[^"\\]|\\[\s\S])*(?:"|$)""")

    /** A run of the characters a bare JSON number or word is written in. */
    private val BARE_TOKEN = Regex("""[-+.0-9A-Za-z_]+""")

    /**
     * A high-surrogate escape with no low one after it, or a low one with no
     * high one before it. shortcut: an escaped backslash before `u` (`\\ud800`,
     * text) is read as an escape too; parse the string literals if a model
     * ever writes one.
     */
    private val LONE_SURROGATE_ESCAPE = Regex(
        """\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})""" +
            """|(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}"""
    )

    /** A JSON number as RFC 8259 writes it. */
    private val JSON_NUMBER = Regex("""-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?""")
    private const val DEFAULT_VERDICT = "UNCLEAR"
    private const val DEFAULT_SUMMARY = "Unable to generate summary"
}
