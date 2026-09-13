// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// One block of a report as a renderer lays it out: a heading, a paragraph or
/// a list item, its text already parsed for references.
///
/// The iOS screen, the macOS screen and the PDF exporter each carried a private
/// copy of this splitter. The copies agreed until #233 taught the two screens to
/// parse a paragraph before joining its wrapped lines; the PDF went on joining
/// first, and so deleted words the screen showed. One splitter is what keeps
/// the document a reader keeps in step with the one they saw.
///
/// The report's text is parsed once, when a block is built, so what a block
/// shows and what a renderer counts as removed come from the same parse.
public enum ReportMarkdownBlock: Equatable, Sendable {
    /// A `#`, `##` or `###` heading, with its level.
    case heading(level: Int, text: ReportInlineText)

    /// Consecutive non-blank lines, parsed with their line breaks and then
    /// joined into one flowing line.
    case paragraph(ReportInlineText)

    /// A list item: `ordinal` is its position in an ordered list, counted from
    /// one, or `nil` for a bulleted item.
    ///
    /// Counted rather than copied from the text, as each private splitter did:
    /// the model's own numbering is not reliable.
    case listItem(text: ReportInlineText, ordinal: Int?)

    /// The block's text.
    public var inlineText: ReportInlineText {
        switch self {
        case .heading(_, let text), .paragraph(let text), .listItem(let text, _):
            return text
        }
    }

    /// Splits report markdown into blocks.
    ///
    /// A blank line ends a paragraph. A heading or list item ends one too, and
    /// takes its whole line. The count of an ordered list restarts after a blank
    /// line, a heading or a bulleted item.
    ///
    /// A reference soft-wrapped onto the line after a heading or list item is
    /// split from it, since that line starts a paragraph (#241). The text export,
    /// which parses the whole report at once, reads it whole.
    ///
    /// - Parameter markdown: A report's markdown, as the model wrote it.
    /// - Returns: The blocks, in order.
    public static func blocks(fromReportMarkdown markdown: String) -> [ReportMarkdownBlock] {
        var blocks: [ReportMarkdownBlock] = []
        var paragraphLines: [String] = []
        var ordinal = 0

        /// Ends the paragraph being collected, if there is one.
        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(paragraph(fromLines: paragraphLines))
            paragraphLines = []
        }

        for line in normalizedLineBreaks(markdown).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                ordinal = 0
            } else if let heading = heading(in: trimmed) {
                flushParagraph()
                ordinal = 0
                blocks.append(.heading(level: heading.level, text: ReportInlineText(parsing: heading.text)))
            } else if let text = bulletedItem(in: trimmed) {
                flushParagraph()
                ordinal = 0
                blocks.append(.listItem(text: ReportInlineText(parsing: text), ordinal: nil))
            } else if let text = orderedItem(in: trimmed) {
                flushParagraph()
                ordinal += 1
                blocks.append(.listItem(text: ReportInlineText(parsing: text), ordinal: ordinal))
            } else {
                paragraphLines.append(trimmed)
            }
        }
        flushParagraph()

        return blocks
    }

    // MARK: - Lines

    /// A paragraph from its lines, parsed with the breaks in place and joined
    /// afterwards.
    ///
    /// Joined with a space first, an ordinary link's unclosed target crossed the
    /// break and reached a `)` on the next line: the words between became the
    /// target and were never shown, and nothing said so (#233).
    ///
    /// - Parameter lines: The paragraph's trimmed lines, in order.
    private static func paragraph(fromLines lines: [String]) -> ReportMarkdownBlock {
        .paragraph(ReportInlineText(parsing: lines.joined(separator: "\n")).joiningWrappedLines())
    }

    /// The report's line breaks made uniform.
    ///
    /// A model returning JSON sometimes leaves a line break escaped as the two
    /// characters `\n`. Runs of blank lines collapse to one, and the ends are
    /// trimmed.
    private static func normalizedLineBreaks(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\n", with: "\n")
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heading markers, longest first so `## ` is not read as `# `.
    private static let headingMarkers: [(marker: String, level: Int)] = [
        ("### ", 3), ("## ", 2), ("# ", 1),
    ]

    /// Markers that open a bulleted list item.
    private static let bulletMarkers = ["- ", "* "]

    /// ``BioMedLitConstants/orderedListItemPattern``, compiled once.
    private static let orderedItemRegex: NSRegularExpression? = ReportInlineText.compiled(
        BioMedLitConstants.orderedListItemPattern,
        consequence: "an ordered list item will be shown as a paragraph, with its number"
    )

    /// The level and text of a heading line, or `nil` for any other line.
    private static func heading(in line: String) -> (level: Int, text: String)? {
        headingMarkers
            .first { line.hasPrefix($0.marker) }
            .map { ($0.level, String(line.dropFirst($0.marker.count))) }
    }

    /// The text of a bulleted item line, or `nil` for any other line.
    private static func bulletedItem(in line: String) -> String? {
        bulletMarkers
            .first { line.hasPrefix($0) }
            .map { String(line.dropFirst($0.count)) }
    }

    /// The text of an ordered item line, or `nil` for any other line.
    private static func orderedItem(in line: String) -> String? {
        guard let regex = orderedItemRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let textRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[textRange])
    }
}
