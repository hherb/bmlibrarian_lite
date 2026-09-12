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

import BioMedLit
import SwiftUI

// MARK: - Rendering

/// Report markdown turned into the rich text an on-screen report shows.
///
/// Shared by the iOS and macOS report views, which each carried a private
/// parser of their own. Those parsers decided what a reference was
/// independently of the export path, and when #230 widened the export path
/// the screen was left printing `(doc:pmid-889149)` — a row's identity, and on
/// PubMed a 1977 paper on mouse courtship (#233). Recognition now happens once,
/// in ``ReportInlineText``; this only decides how each segment looks.
enum ReportRichText {
    /// Rich text for one parsed run of report markdown.
    ///
    /// - A reference to a document is shown with its brackets, tinted and
    ///   underlined, and opens that document.
    /// - A citation with no target looks the same and opens the document its
    ///   author and year name.
    /// - An ordinary link keeps a destination the reader can follow.
    /// - Prose has its inline markdown — emphasis, chiefly — rendered rather
    ///   than printed.
    ///
    /// No document identity is ever part of the text. It travels only inside a
    /// reference's link, which the app intercepts before the system sees it.
    ///
    /// Emphasis that spans a reference or link is printed as literal markers,
    /// because each piece of prose is rendered on its own: in
    /// `**as [Smith, 2016](doc:…) showed**`, neither half holds a closed `**`.
    /// The screen always split prose at `Author, Year` references; it now also
    /// splits at ordinary links and at references worded otherwise.
    ///
    /// - Parameter parsed: The parsed markdown.
    /// - Returns: The text to hand to a SwiftUI `Text`.
    static func attributedString(from parsed: ReportInlineText) -> AttributedString {
        var result = AttributedString()
        for segment in parsed.segments {
            switch segment {
            case .prose(let text):
                result.append(inlineMarkdown(text))
            case .documentReference(let displayText, let identity):
                result.append(reference(displayText, opening: .documentIdentity(identity)))
            case .untargetedCitation(let displayText):
                result.append(reference(displayText, opening: .citationText(displayText)))
            case .link(let displayText, let target):
                var linked = inlineMarkdown(displayText)
                // A target Foundation will not accept as a URL leaves the text
                // readable and unlinked, which is what a reader could use of it.
                linked.link = URL(string: target.trimmingCharacters(in: .whitespaces))
                result.append(linked)
            }
        }
        return result
    }

    /// A reference's text, styled as a link and carrying where it leads.
    ///
    /// - Parameters:
    ///   - displayText: What the report wrote between the brackets.
    ///   - link: The document the reference opens.
    private static func reference(
        _ displayText: String,
        opening link: ReportReferenceLink
    ) -> AttributedString {
        var attributed = AttributedString("[\(displayText)]")
        // Styled as a link only when it is one: a tinted, underlined citation
        // that does nothing when tapped reads as broken.
        guard let url = link.url else { return attributed }
        attributed.swiftUI.foregroundColor = .accentColor
        attributed.swiftUI.underlineStyle = .single
        attributed.link = url
        return attributed
    }

    /// Inline markdown rendered, or the text as written if it will not parse.
    ///
    /// Whitespace is preserved because prose arrives in pieces cut around
    /// references, and the space before a reference belongs to the sentence.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Telling the Reader

/// What the reader is told when citation links were removed on the way to the
/// screen.
///
/// A malformed reference's target is removed rather than shown (#230). What
/// that costs the reader depends on the shape: a reference with nothing but a
/// target disappears from the sentence, while one that keeps its
/// `[Author, Year]` text is still offered, now found by author and year, which
/// can open a different paper or none. The sentence says both, because the note
/// cannot tell which happened. Golden rule 8 asks that the reader be told as
/// well as the log. A pure value rather than logic inside a view, so it can be
/// tested without rendering.
///
/// Shown above the text it describes, which is what "the text below" refers
/// to: each renderer that removes something shows its own note.
struct RemovedCitationNotice: Equatable {
    /// How many citation links were removed. Links, not citations: one
    /// reference can lose two, and a citation can outlive its link.
    let count: Int

    /// A notice for these removals, or `nil` when nothing was removed — a note
    /// over a report that is fine teaches the reader to ignore the one over a
    /// report that is not.
    ///
    /// - Parameter removedReferences: Every reference removed from what the
    ///   reader is shown.
    init?(removedReferences: [String]) {
        guard !removedReferences.isEmpty else { return nil }
        count = removedReferences.count
    }

    /// The sentence the reader sees.
    var sentence: String {
        count == 1
            ? """
                1 malformed citation link was removed from the text below, so a \
                citation may be missing or may not open the right source.
                """
            : """
                \(count) malformed citation links were removed from the text below, \
                so citations may be missing or may not open the right sources.
                """
    }
}

/// Layout values for ``RemovedCitationNote``.
private enum ReportRichTextConstants {
    /// Gap between the note and the text beneath it.
    static let noteSpacing: CGFloat = 6

    /// The SF Symbol beside the note.
    static let noteIconName = "exclamationmark.triangle"
}

/// A quiet line, placed above the text it describes, telling the reader
/// citation links were removed from it.
///
/// Carries its own gap to the text below, so a caller places it without a
/// spacing value of its own.
struct RemovedCitationNote: View {
    /// What to say.
    let notice: RemovedCitationNotice

    var body: some View {
        Label(notice.sentence, systemImage: ReportRichTextConstants.noteIconName)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, ReportRichTextConstants.noteSpacing)
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Summary

/// A report's summary, rendered like its body.
///
/// Every summary site was `Text(report.summary)` over a runtime `String`, which
/// SwiftUI prints verbatim. The report prompt asks for
/// `[Author, Year](doc:<identity>)` on *every* citation, so a summary that cited
/// anything showed the link syntax and a UUID on well-formed input.
///
/// Font and line spacing come from the caller's environment, as they did for
/// the `Text` this replaces.
struct ReportSummaryText: View {
    /// The summary's markdown.
    let markdown: String

    /// A summary view for this markdown.
    ///
    /// - Parameter markdown: The report's summary, as the model wrote it.
    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        let parsed = ReportInlineText(parsing: markdown)
        VStack(alignment: .leading, spacing: 0) {
            // Above the text, as in the report body, so it is read first and
            // "the text below" is true wherever it appears.
            if let notice = RemovedCitationNotice(removedReferences: parsed.removedReferences) {
                RemovedCitationNote(notice: notice)
            }
            Text(ReportRichText.attributedString(from: parsed))
        }
        // Logged when the summary appears or changes, not from `body`, which
        // SwiftUI runs on every layout pass.
        .task(id: markdown) {
            ReportFormatter.reportUnparseableReferences(in: [ReportInlineText(parsing: markdown)])
        }
    }
}
