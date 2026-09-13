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

// MARK: - Segments

/// One run of report markdown, classified by what a renderer may do with it.
///
/// A renderer switches over these and decides for itself: a screen makes a
/// ``documentReference(displayText:documentIdentity:)`` tappable, an exported
/// page shows its display text. What it may not do is look at the source text
/// again and draw its own conclusions — that is how two renderers came to
/// disagree about what a reference is (#233).
public enum ReportInlineSegment: Equatable, Sendable {
    /// Text carrying no reference.
    ///
    /// It may still carry inline markdown, chiefly emphasis, for a renderer to
    /// interpret or strip. It carries no parenthesised document reference:
    /// those are removed before a segment is built.
    case prose(String)

    /// A citation that names the document it was drawn from:
    /// `[Smith et al., 2016](doc:<identity>)`.
    ///
    /// `documentIdentity` names a row in this app's store. It resolves nowhere
    /// else and must never be shown: a legacy `pmid-889149` identity reads as a
    /// PubMed ID, and on PubMed `889149` is a real 1977 paper on mouse courtship
    /// rather than the article cited (#212). As ``ReportInlineText`` builds it,
    /// it is one non-empty run of identity characters: surrounding space and
    /// line breaks are removed, since a lookup by ` pmid-889149` matches nothing.
    case documentReference(displayText: String, documentIdentity: String)

    /// A citation in `Author, Year` form with no target: `[Smith, 2016]`.
    ///
    /// Either written before references carried an identity, or left behind
    /// when an unparseable target was removed. Resolvable only by its text. See
    /// ``BioMedLitConstants/untargetedCitationPattern``.
    case untargetedCitation(displayText: String)

    /// A link whose target is not a document: `[the guideline](https://…)`.
    case link(displayText: String, target: String)

    /// What a renderer that follows no links shows for this segment.
    ///
    /// A link of either kind becomes its display text. A citation with no
    /// target keeps its brackets, because it reached the parser with them —
    /// even where a malformed target was removed from after them.
    public var flattened: String {
        switch self {
        case .prose(let text):
            return text
        case .documentReference(let displayText, _), .link(let displayText, _):
            return displayText
        case .untargetedCitation(let displayText):
            return "[\(displayText)]"
        }
    }
}

// MARK: - Parsed Text

/// Report markdown split into the segments a renderer draws, and what could not
/// be drawn.
///
/// The one place a report's references are recognised. The text export
/// flattens these segments (``ReportFormatter/flattenedReferenceLinks(in:)``),
/// the PDF flattens them block by block, and the screen renders them as links,
/// so all three apply the same rules to a given run of text.
///
/// That is not the same as agreeing on every report. The text export parses the
/// whole report at once, while the PDF and the screen split it into blocks first
/// (``ReportMarkdownBlock``), and a reference wrapped onto the line after a list
/// item or heading lands in a different block (#241).
///
/// Parsing logs nothing about its input. A renderer parsing block by block from
/// a SwiftUI `body`, which is evaluated again whenever its inputs change, would
/// otherwise repeat one malformed reference per block per evaluation, so the
/// caller collects the parses and hands them to
/// ``ReportFormatter/logUnparseableReferences(in:)`` once.
///
/// ## What is removed
///
/// Widening a pattern narrows the gap; it does not close it. Any parenthesised
/// document reference ``BioMedLitConstants/markdownLinkPattern`` could not
/// match — a target with no closing parenthesis, one with no preceding link, a
/// closed target that is not one identity — is removed from the text and named
/// in ``removedReferences`` rather than shown. A target is a row's identity and
/// means nothing to a reader, so removing one discards nothing a reader wanted,
/// while showing one is #212 through a different door. See
/// ``BioMedLitConstants/residualDocumentReferencePattern`` for how the removed
/// run is bounded so that the report's own words stay.
///
/// Only a *parenthesised* target is removed. A scheme that lost its opening
/// parenthesis stays in the text (#236), and ``retainsDocumentReferenceScheme``
/// says so rather than letting a clean-looking parse vouch for it.
public struct ReportInlineText: Equatable, Sendable {
    /// The text's segments, in order. Adjacent prose is merged, and a segment
    /// is never empty prose.
    public let segments: [ReportInlineSegment]

    /// Each document reference removed because nothing could parse it, with
    /// surrounding space trimmed, in the order removed.
    ///
    /// That is source order, except where one removal assembled another from
    /// the text around it: `((doc:x)doc:a)` names `(doc:x)`, then
    /// `(doc:a)` as assembled. For diagnostics only — each carries an identity,
    /// which a reader must not be shown.
    public let removedReferences: [String]

    /// Parses one run of report markdown.
    ///
    /// Links are found first, across the whole text, because a well-formed
    /// reference may be soft-wrapped between its display text and its target.
    /// Unparseable targets are then removed from the prose between links and
    /// from each link's display text — both reach a reader. Citations with no
    /// target are recognised last, in what remains, which is what lets a
    /// reference that lost its unterminated target still be resolved by its
    /// author and year.
    ///
    /// - Parameter markdown: Report markdown: a block, or a whole report.
    public init(parsing markdown: String) {
        var builder = SegmentBuilder()
        var cursor = markdown.startIndex
        let whole = NSRange(markdown.startIndex..., in: markdown)
        let links = Self.markdownLinkRegex?.matches(in: markdown, range: whole) ?? []

        for link in links {
            guard let linkRange = Range(link.range, in: markdown),
                  let displayRange = Range(link.range(at: 1), in: markdown) else {
                // Unreachable for a range the regex took from this same string.
                // Leaving the run to the prose still sweeps any target out of it.
                assertionFailure("A link match's range did not convert back to its string")
                continue
            }
            let identityRange = Range(link.range(at: 2), in: markdown)
            let targetRange = Range(link.range(at: 3), in: markdown)
            guard identityRange != nil || targetRange != nil else {
                // Unreachable while exactly one target group participates in a
                // match. Were the groups renumbered, dropping the link would
                // delete its text unseen; left to the prose, it is still swept.
                assertionFailure("A link matched with neither target group: the pattern's groups changed")
                continue
            }
            builder.appendProse(markdown[cursor..<linkRange.lowerBound])

            let displayText = builder.sweptOfDocumentReferences(String(markdown[displayRange]))
            if let identityRange {
                builder.append(.documentReference(
                    displayText: displayText,
                    documentIdentity: markdown[identityRange].trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            } else if let targetRange {
                builder.append(.link(
                    displayText: displayText,
                    target: String(markdown[targetRange])
                ))
            }
            cursor = linkRange.upperBound
        }
        builder.appendProse(markdown[cursor...])

        segments = builder.segments
        removedReferences = builder.removedReferences
    }

    /// Builds a parse from segments already established.
    private init(segments: [ReportInlineSegment], removedReferences: [String]) {
        self.segments = segments
        self.removedReferences = removedReferences
    }

    /// The same parse with every line break a reader would see replaced by a
    /// space.
    ///
    /// For a renderer that shows a wrapped paragraph as one flowing line. It
    /// must parse the lines *with* their breaks and join them afterwards:
    /// joining first erases the break that stops an ordinary link's unclosed
    /// target in ``BioMedLitConstants/markdownLinkPattern``, and the words up to
    /// a `)` on the next line vanish unreported (#233). ``ReportMarkdownBlock``
    /// builds paragraphs this way. What was removed is unchanged.
    ///
    /// - Returns: The parse with each `\n` in prose and display text a space.
    public func joiningWrappedLines() -> ReportInlineText {
        func joined(_ text: String) -> String {
            text.replacingOccurrences(of: "\n", with: " ")
        }

        return ReportInlineText(
            segments: segments.map { segment in
                switch segment {
                case .prose(let text):
                    return .prose(joined(text))
                case .documentReference(let displayText, let identity):
                    return .documentReference(displayText: joined(displayText), documentIdentity: identity)
                case .untargetedCitation(let displayText):
                    return .untargetedCitation(displayText: joined(displayText))
                case .link(let displayText, let target):
                    return .link(displayText: joined(displayText), target: target)
                }
            },
            removedReferences: removedReferences
        )
    }

    /// The text as a renderer that follows no links shows it.
    ///
    /// Emphasis markers are left standing, because one such renderer consumes
    /// them itself; see ``ReportFormatter/plainText(fromReportMarkdown:)``.
    public var flattened: String {
        segments.map(\.flattened).joined()
    }

    /// Whether what a reader is shown still carries the document reference
    /// scheme after removal.
    ///
    /// Checked against the flattened text rather than inferred from what was
    /// removed, so it catches the shape removal deliberately does not match: a
    /// scheme that lost its parenthesis (#236).
    ///
    /// It looks for the scheme, not for identities, so it cannot see an
    /// identity whose scheme was removed without it. Removal is written so that
    /// cannot happen — a target broken across a line after `doc:` is taken
    /// whole — and the tests pin those shapes, because a diagnostic saying the
    /// target was removed over a page printing `pmid-889149` costs more than no
    /// diagnostic at all.
    public var retainsDocumentReferenceScheme: Bool {
        flattened.contains(BioMedLitConstants.documentReferenceScheme)
    }

    // MARK: - Patterns

    /// Compiles one of the report formatter's literal patterns, reporting a
    /// failure.
    ///
    /// Each pattern is a literal, so a failure here means the build is broken
    /// rather than the input is odd: debug builds stop, and a test asserts that
    /// every pattern compiles. A release build logs rather than crashing,
    /// because the consequence is otherwise silent and permanent.
    ///
    /// - Parameters:
    ///   - pattern: The regular expression source.
    ///   - consequence: What a reader sees if this pattern is unavailable,
    ///     phrased to complete "so …".
    /// - Returns: The compiled expression, or `nil` if it would not compile.
    static func compiled(
        _ pattern: String,
        consequence: String
    ) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            BioMedLitLib.logger?.error(
                """
                Report formatting pattern failed to compile, so \(consequence): \
                \(error.localizedDescription)
                """,
                category: .parsing
            )
            assertionFailure("Report formatting pattern failed to compile: \(error)")
            return nil
        }
    }

    /// Markdown link syntax, compiled once.
    static let markdownLinkRegex: NSRegularExpression? = compiled(
        BioMedLitConstants.markdownLinkPattern,
        consequence: """
            every reference will be reported as malformed and found by author \
            and year, and ordinary links will lose their destination
            """
    )

    /// Document references no link pattern could account for, compiled once.
    static let residualDocumentReferenceRegex: NSRegularExpression? = compiled(
        BioMedLitConstants.residualDocumentReferencePattern,
        consequence: "a malformed reference will print its document identity"
    )

    /// Citations in `Author, Year` form with no target, compiled once.
    static let untargetedCitationRegex: NSRegularExpression? = compiled(
        BioMedLitConstants.untargetedCitationPattern,
        consequence: "a citation with no target will not be offered as a link"
    )
}

// MARK: - Builder

/// Accumulates segments and removals while ``ReportInlineText`` walks its text.
private struct SegmentBuilder {
    /// Segments built so far, in source order.
    private(set) var segments: [ReportInlineSegment] = []

    /// Document references removed so far, in the order removed.
    private(set) var removedReferences: [String] = []

    /// Appends a segment, merging prose into prose and dropping empty prose.
    mutating func append(_ segment: ReportInlineSegment) {
        guard case .prose(let text) = segment else {
            segments.append(segment)
            return
        }
        guard !text.isEmpty else { return }
        if case .prose(let previous)? = segments.last {
            segments[segments.count - 1] = .prose(previous + text)
        } else {
            segments.append(segment)
        }
    }

    /// Appends text lying between links: swept of unparseable document
    /// references, then split around citations that carry no target.
    mutating func appendProse(_ text: Substring) {
        let swept = sweptOfDocumentReferences(String(text))
        guard let regex = ReportInlineText.untargetedCitationRegex else {
            append(.prose(swept))
            return
        }

        var cursor = swept.startIndex
        let whole = NSRange(swept.startIndex..., in: swept)
        for citation in regex.matches(in: swept, range: whole) {
            guard let citationRange = Range(citation.range, in: swept),
                  let displayRange = Range(citation.range(at: 1), in: swept) else {
                // Unreachable for a range the regex took from this same string.
                // The citation's text stays in the prose that follows.
                assertionFailure("A citation match's range did not convert back to its string")
                continue
            }
            append(.prose(String(swept[cursor..<citationRange.lowerBound])))
            append(.untargetedCitation(displayText: String(swept[displayRange])))
            cursor = citationRange.upperBound
        }
        append(.prose(String(swept[cursor...])))
    }

    /// The text with every parenthesised document reference removed, each
    /// removal recorded.
    ///
    /// Repeated until nothing matches, because a removal can assemble another
    /// reference from what surrounded it: `((doc:x)doc:pmid-889149)` gives up
    /// `(doc:x)` and leaves `(doc:pmid-889149)`. Each pass removes at least the
    /// scheme it matched, so the text shrinks every time and the loop ends.
    ///
    /// - Parameter text: Text a reader will be shown.
    /// - Returns: The same text carrying no parenthesised document reference.
    mutating func sweptOfDocumentReferences(_ text: String) -> String {
        guard let regex = ReportInlineText.residualDocumentReferenceRegex else { return text }
        var swept = text
        while true {
            let whole = NSRange(swept.startIndex..., in: swept)
            let matches = regex.matches(in: swept, range: whole)
            guard !matches.isEmpty else { return swept }

            // Named from the matches themselves, so the count a diagnostic
            // states and the list it shows cannot disagree.
            removedReferences += matches
                .compactMap { Range($0.range, in: swept) }
                .map { swept[$0].trimmingCharacters(in: .whitespaces) }
            swept = regex.stringByReplacingMatches(in: swept, range: whole, withTemplate: "")
        }
    }
}
