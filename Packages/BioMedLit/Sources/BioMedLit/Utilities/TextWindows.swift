// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// How a model reads a publication: never cut, always in windows.
///
/// A publication is never truncated before a prompt. Every text a model
/// analyses is read without its reference list, in sliding windows of
/// ``BioMedLitConstants/textWindowChars`` overlapping by
/// ``BioMedLitConstants/textWindowOverlapChars``, one call per window, and the
/// answers are reduced. Python's `chunking.py` (`without_references`,
/// `analysis_windows`, `chunk_text`) is canonical; the shared contract is
/// `doc/cross_platform/llm_parity/text_windows.json`.
///
/// Every length and position is a Unicode code point, as in Python's `str`,
/// so the windows are cut on `unicodeScalars`, never on `Character`s.
public enum TextWindows {
    /// How far back from a window's end a natural break is looked for.
    static let boundarySearchChars = 200

    /// The breaks a window prefers, best first, each with how much of the
    /// marker the window keeps. Python's `_find_boundary` order.
    static let boundaryMarkers: [(marker: [Unicode.Scalar], keep: Int)] = {
        let markers: [(String, Int)] = [
            ("\n\n", 2), (".\n", 2), (". ", 2), ("! ", 2), ("? ", 2), (";\n", 2),
            ("; ", 2), (",\n", 2), ("\n", 1), (", ", 2), (" ", 1),
        ]
        return markers.map { (Array($0.0.unicodeScalars), $0.1) }
    }()

    /// A line that is only a reference-list heading: `## References` as the
    /// JATS converter writes it, or `References` / `4. Bibliography` as a PDF
    /// carries it. Matched one `\n`-separated line at a time, so a lone `\r`
    /// or U+2028 is not a line end here either, as in Python.
    private static let referencesHeading = try! NSRegularExpression(
        pattern: #"\A[ \t]*(?:#{1,6}[ \t]*)?(?:\d+\.?[ \t]*)?"#
            + #"(?:references|bibliography|literature cited|works cited|references and notes)"#
            + #"[ \t]*:?[ \t]*\r?\z"#,
        options: [.caseInsensitive]
    )

    /// The text up to its reference list, which no analysis reads.
    ///
    /// A reference is another paper's claim, never this one's evidence.
    ///
    /// - Parameter text: Any text a model analyses: converted JATS markdown,
    ///   PDF text, CORE's text, an abstract.
    /// - Returns: Everything before the last reference-list heading, trailing
    ///   whitespace stripped; the whole text, stripped, when it has none. The
    ///   last, so a "References" line in the body cannot take the rest of the
    ///   article with it.
    public static func withoutReferences(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var lineStart = 0
        var lastHeading: Int?
        while lineStart <= scalars.count {
            let lineEnd = scalars[lineStart...].firstIndex(of: "\n") ?? scalars.count
            let line = string(scalars[lineStart..<lineEnd])
            let range = NSRange(line.startIndex..., in: line)
            if referencesHeading.firstMatch(in: line, range: range) != nil {
                lastHeading = lineStart
            }
            lineStart = lineEnd + 1
        }
        guard let lastHeading else { return string(stripped(scalars[...])) }
        return string(stripped(scalars[..<lastHeading], leading: false))
    }

    /// The windows a model reads of a text, one call each.
    ///
    /// Every analysis of a text maps over these and reduces the answers: a
    /// sliding window that fits any provider's context, never a cut.
    ///
    /// - Parameters:
    ///   - text: The text.
    ///   - windowChars: The most code points in one window.
    ///   - overlapChars: Code points consecutive windows share.
    /// - Returns: The text before its reference list, in overlapping windows
    ///   broken at natural boundaries; none when nothing is left to read.
    /// - Precondition: `overlapChars` is not negative and less than `windowChars`.
    public static func analysisWindows(
        _ text: String,
        windowChars: Int = BioMedLitConstants.textWindowChars,
        overlapChars: Int = BioMedLitConstants.textWindowOverlapChars
    ) -> [String] {
        let scalars = Array(withoutReferences(text).unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        precondition(windowChars > 0 && overlapChars >= 0 && overlapChars < windowChars,
                     "a window must be longer than its overlap")

        let whole = stripped(scalars[...])
        if whole.count <= windowChars {
            return whole.isEmpty ? [] : [string(whole)]
        }

        var windows: [String] = []
        var start = 0
        while start < scalars.count {
            var end = min(start + windowChars, scalars.count)
            if end < scalars.count {
                let boundary = boundary(in: scalars, start: start, end: end)
                if boundary > start { end = boundary }
            }
            let window = stripped(scalars[start..<end])
            if !window.isEmpty { windows.append(string(window)) }
            // The end is read; stepping back by the overlap would add a window
            // the last one already holds
            if end >= scalars.count { break }
            var next = end - overlapChars
            if next <= start { next = end }
            start = next
        }
        return windows
    }

    /// Reduce the items a text's windows yielded to each item once.
    ///
    /// Consecutive windows share their overlap, so two can quote one
    /// sentence, or one can quote part of what the other quotes whole. Kept
    /// in order; an item is dropped when an earlier one says the same, or a
    /// different, longer one contains it — compared lowercased, whitespace
    /// runs read as one space. Python's `merged_window_citations`.
    ///
    /// - Parameters:
    ///   - items: Every window's items, in window order.
    ///   - text: The text an item is compared by.
    /// - Returns: The items, each once.
    public static func mergedWindowItems<T>(_ items: [T], text: (T) -> String) -> [T] {
        let normalised = items.map { normalise(text($0)) }
        return items.indices.filter { i in
            let mine = normalised[i]
            return !normalised[..<i].contains(mine)
                && !normalised.contains { $0 != mine && $0.contains(mine) }
        }.map { items[$0] }
    }

    // MARK: - Private

    /// Python's `" ".join(text.lower().split())`, as code points.
    private static func normalise(_ text: String) -> [Unicode.Scalar] {
        let lower = Array(text.lowercased().unicodeScalars)
        return Array(lower.split(whereSeparator: isSpace).joined(separator: [" "]))
    }

    /// Python's `_find_boundary`: the best natural break near `end`, else `end`.
    private static func boundary(in scalars: [Unicode.Scalar], start: Int, end: Int) -> Int {
        let searchStart = max(start, end - boundarySearchChars)
        for (marker, keep) in boundaryMarkers {
            // Python's `rfind(marker, searchStart, end)`: the marker lies wholly inside
            var position = end - marker.count
            while position >= searchStart {
                if scalars[position..<(position + marker.count)].elementsEqual(marker) { break }
                position -= 1
            }
            if position >= searchStart && position > start { return position + keep }
        }
        return end
    }

    /// Python's `str.isspace()`: Unicode White_Space plus U+001C–U+001F,
    /// which Python also strips. Not Foundation's set, which trims U+200B.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    /// Python's `strip()` (or `rstrip()` when `leading` is false).
    private static func stripped(_ scalars: ArraySlice<Unicode.Scalar>, leading: Bool = true) -> ArraySlice<Unicode.Scalar> {
        var slice = scalars
        while let last = slice.last, isSpace(last) { slice.removeLast() }
        while leading, let first = slice.first, isSpace(first) { slice.removeFirst() }
        return slice
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
