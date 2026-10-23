/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
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

import java.util.regex.Pattern

/**
 * The windows a model reads of a text: every LLM analysis maps over them, one
 * call each, and reduces the answers. A publication is never cut before a prompt;
 * only its reference list is left out, since a reference is another paper's claim.
 *
 * A port of Python's `chunking.py` (`without_references`, `analysis_windows`,
 * `chunk_text`, `_find_boundary`), which is canonical; the shared rows are
 * `doc/cross_platform/llm_parity/text_windows.json`. Lengths and positions are
 * Unicode code points, as Python's `str` counts them, not UTF-16 units.
 */
object TextWindows {

    /** How far back from a window's end a natural boundary is looked for (the contract's `boundary_search_chars`). */
    internal const val BOUNDARY_SEARCH_CHARS = 200

    /** Boundaries in order of preference, each with how far past it the window ends (the contract's `boundary_markers`). */
    internal val BOUNDARY_MARKERS = listOf(
        "\n\n" to 2, ".\n" to 2, ". " to 2, "! " to 2, "? " to 2, ";\n" to 2,
        "; " to 2, ",\n" to 2, "\n" to 1, ", " to 2, " " to 1
    )

    /**
     * A line that is only a reference-list heading. UNIX_LINES keeps `^`/`$` at
     * `\n` alone, as Python's are (`\r?` handles CRLF); UNICODE_CASE and `\p{Nd}`
     * match Python's Unicode IGNORECASE and `\d`.
     */
    private val REFERENCES_HEADING: Pattern = Pattern.compile(
        "^[ \\t]*(?:#{1,6}[ \\t]*)?(?:\\p{Nd}+\\.?[ \\t]*)?" +
            "(?:references|bibliography|literature cited|works cited|references and notes)" +
            "[ \\t]*:?[ \\t]*\\r?$",
        Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE or Pattern.MULTILINE or Pattern.UNIX_LINES
    )

    /**
     * The text up to its reference list, which no analysis reads.
     *
     * @param text Any text a model analyses
     * @return Everything before the last reference-list heading (so a "References"
     *   line in the body cannot take the rest with it), right-stripped; the whole
     *   text, stripped, when it has none
     */
    fun withoutReferences(text: String): String {
        val matcher = REFERENCES_HEADING.matcher(text)
        var last = -1
        while (matcher.find()) last = matcher.start()
        return if (last >= 0) text.substring(0, last).trimEnd(::isPySpace) else text.trim(::isPySpace)
    }

    /**
     * The windows a model reads of a text, one call each.
     *
     * @param text The text
     * @param windowChars The most code points in one window
     * @param overlapChars Code points consecutive windows share
     * @return The text before its reference list in overlapping windows broken at
     *   natural boundaries; none when nothing is left to read
     * @throws IllegalArgumentException If the window is not longer than the overlap
     */
    fun analysisWindows(
        text: String,
        windowChars: Int = Constants.TEXT_WINDOW_CHARS,
        overlapChars: Int = Constants.TEXT_WINDOW_OVERLAP_CHARS
    ): List<String> = chunks(withoutReferences(text), windowChars, overlapChars)

    /**
     * Reduce the items of a text's windows to each passage once.
     *
     * Consecutive windows share their overlap, so two can quote one sentence, or
     * one can quote part of what the other quotes whole. Kept in order; an item is
     * dropped when an earlier one says the same, or a different, longer one
     * contains it, compared lowercased with whitespace runs collapsed. Python's
     * `merged_window_citations`.
     *
     * @param items Every window's items, in window order
     * @param text An item's passage
     * @return The items, each passage once
     */
    fun <T> mergedWindowItems(items: List<T>, text: (T) -> String): List<T> {
        val normalised = items.map { normalise(text(it)) }
        return items.filterIndexed { i, _ ->
            val own = normalised[i]
            own !in normalised.subList(0, i) && normalised.none { it != own && own in it }
        }
    }

    /** Python's `chunk_text` over code points, returning the chunks' text. */
    private fun chunks(text: String, size: Int, overlap: Int): List<String> {
        if (text.isEmpty()) return emptyList()
        require(size > 0) { "chunk_size must be positive, got $size" }
        require(overlap >= 0) { "chunk_overlap must be non-negative, got $overlap" }
        require(overlap < size) { "chunk_overlap ($overlap) must be less than chunk_size ($size)" }

        val stripped = text.trim(::isPySpace)
        if (stripped.codePointCount(0, stripped.length) <= size) {
            return if (stripped.isEmpty()) emptyList() else listOf(stripped)
        }

        val points = text.codePoints().toArray()
        val length = points.size
        val windows = mutableListOf<String>()
        var start = 0
        while (start < length) {
            var end = minOf(start + size, length)
            if (end < length) {
                val boundary = findBoundary(points, start, end)
                if (boundary > start) end = boundary
            }
            val window = String(points, start, end - start).trim(::isPySpace)
            if (window.isNotEmpty()) windows += window
            // The end is read; stepping back by the overlap would add a window the last one holds
            if (end >= length) break
            var newStart = end - overlap
            if (newStart <= start) newStart = end
            start = newStart
        }
        return windows
    }

    /** Python's `_find_boundary`: the best natural break before [end], or [end]. */
    private fun findBoundary(points: IntArray, start: Int, end: Int): Int {
        val searchStart = maxOf(start, end - BOUNDARY_SEARCH_CHARS)
        for ((marker, offset) in BOUNDARY_MARKERS) {
            val pos = lastIndexOf(points, marker, searchStart, end)
            if (pos > start) return pos + offset
        }
        return end
    }

    /** Python's `str.rfind(marker, from, to)` on code points: the marker wholly inside [from, to), or -1. */
    private fun lastIndexOf(points: IntArray, marker: String, from: Int, to: Int): Int {
        // Markers are ASCII, so their chars are their code points
        var pos = to - marker.length
        while (pos >= from) {
            if (marker.indices.all { points[pos + it] == marker[it].code }) return pos
            pos--
        }
        return -1
    }

    /** Python's `" ".join(text.lower().split())`. */
    private fun normalise(text: String): String =
        text.lowercase().map { if (isPySpace(it)) ' ' else it }.joinToString("")
            .split(' ').filter { it.isNotEmpty() }.joinToString(" ")

    /**
     * Python's `str.isspace` for one char: Kotlin's `isWhitespace` (Java's
     * whitespace plus every Unicode space separator) misses only U+0085.
     */
    private fun isPySpace(c: Char): Boolean = c.isWhitespace() || c == '\u0085'
}
