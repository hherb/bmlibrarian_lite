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
    ///   underlined, and opens that document. Its display text is shown as
    ///   written, markers included: it is not rendered as markdown.
    /// - A citation with no target looks the same and opens the document its
    ///   author and year name.
    /// - An ordinary link keeps a destination the reader can follow, if it has
    ///   one; see ``followableDestination(of:)``.
    /// - Prose has its inline markdown — emphasis, chiefly — rendered rather
    ///   than printed.
    ///
    /// A reference's identity is never part of its text: it travels only inside
    /// the reference's link, which the app intercepts before the system sees
    /// it. Text the parse could not clean — a scheme that lost its parenthesis
    /// (#236) — is shown as written, logged, and named in
    /// ``RemovedCitationNotice``.
    ///
    /// Emphasis that spans a reference or link is printed as literal markers,
    /// because each piece of prose is rendered on its own: in
    /// `**as [Smith, 2016](doc:…) showed**`, neither half holds a closed `**`
    /// (#240). The screen always split prose at `Author, Year` references; it
    /// now also splits at ordinary links and at references worded otherwise.
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
                // A destination nothing can open leaves the text readable and
                // unlinked, which is what a reader could use of it.
                linked.link = followableDestination(of: target)
                result.append(linked)
            }
        }
        return result
    }

    /// Where an ordinary link's target leads, or `nil` if nothing the reader
    /// could follow.
    ///
    /// A markdown destination may be written `<url>`, or followed by a title,
    /// `url "Title"`; both are reduced to the URL, as SwiftUI's own markdown
    /// parser does. Only ``ReportRichTextConstants/followableLinkSchemes`` are
    /// linked. `URL(string:)` accepts nearly anything — `see appendix` becomes a
    /// URL with no scheme, `PMID: 889149` one with the scheme `PMID` — and each
    /// was drawn as a link that opened nothing. A `docref:` destination the
    /// model wrote itself may not pose as a reference the app built.
    ///
    /// - Parameter target: The link target as the report wrote it.
    /// - Returns: The URL to attach, or `nil` to show the text unlinked.
    static func followableDestination(of target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination: Substring
        if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
            destination = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        } else {
            destination = trimmed.prefix { !$0.isWhitespace }
        }

        guard let url = URL(string: String(destination)),
              let scheme = url.scheme?.lowercased(),
              ReportRichTextConstants.followableLinkSchemes.contains(scheme) else {
            return nil
        }
        return url
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

/// What the reader is told when a report's citations could not all be shown as
/// written.
///
/// Two things can happen to a malformed reference, and the reader is told about
/// each:
///
/// - **Its target was removed** (#230). A reference with nothing but a target
///   disappears from the sentence, while one that keeps its `[Author, Year]`
///   text is still offered, now found by author and year. That opens a paper
///   only when exactly one fits (`ReportCitation`), which can still be the
///   wrong one if the paper cited is not in the session. The sentence says
///   both, because the note cannot tell which happened.
/// - **A reference code is still showing.** A scheme that lost its parenthesis
///   is not removed (#236), so the page shows `doc:pmid-889149`. That is the
///   case where the harm is on the page, and a note built from removals alone
///   said nothing about it.
///
/// Golden rule 8 asks that the reader be told as well as the log, and the note
/// is built from the same parses the log is given
/// (``ReportFormatter/logUnparseableReferences(in:)``), so the two cannot come
/// to disagree about what went wrong. A pure value rather than logic inside a
/// view, so it can be tested without rendering.
///
/// Shown above the text it describes, which is what "the text below" refers
/// to: each on-screen renderer that parses report text shows its own note. The
/// exports show none yet (#237).
struct RemovedCitationNotice: Equatable {
    /// How many citation links were removed. Links, not citations: one
    /// reference can lose two, and a citation can outlive its link.
    let removedCount: Int

    /// Whether the text still shows a document reference's scheme.
    let showsReferenceCode: Bool

    /// A notice for these parses, or `nil` when nothing was removed and no
    /// reference code shows — a note over a report that is fine teaches the
    /// reader to ignore the one over a report that is not.
    ///
    /// - Parameter parses: Every parse behind the text the note sits above.
    init?(parses: [ReportInlineText]) {
        let removedCount = parses.reduce(0) { $0 + $1.removedReferences.count }
        let showsReferenceCode = parses.contains(where: \.retainsDocumentReferenceScheme)
        guard removedCount > 0 || showsReferenceCode else { return nil }
        self.removedCount = removedCount
        self.showsReferenceCode = showsReferenceCode
    }

    /// The sentence the reader sees.
    var sentence: String {
        [removalSentence, referenceCodeSentence]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// What the note says about removed links, if any were removed.
    private var removalSentence: String? {
        switch removedCount {
        case 0:
            return nil
        case 1:
            return """
                1 malformed citation link was removed from the text below, so a \
                citation may be missing or may not open the right source.
                """
        default:
            return """
                \(removedCount) malformed citation links were removed from the text \
                below, so citations may be missing or may not open the right sources.
                """
        }
    }

    /// What the note says about a reference code left showing, if one is.
    ///
    /// Names the one thing a reader might do with the code — search PubMed for
    /// its number — and why they should not: `889149` is a real 1977 paper on
    /// mouse courtship, not the article cited (#212).
    private var referenceCodeSentence: String? {
        guard showsReferenceCode else { return nil }
        return """
            Some citation text below could not be read and shows an internal \
            reference code beginning "\(BioMedLitConstants.documentReferenceScheme)"; \
            it is not a PubMed ID.
            """
    }
}

/// Layout and linking values for ``ReportRichText`` and ``RemovedCitationNote``.
enum ReportRichTextConstants {
    /// Gap between the note and the text beneath it.
    static let noteSpacing: CGFloat = 6

    /// The SF Symbol beside the note.
    static let noteIconName = "exclamationmark.triangle"

    /// URL schemes an ordinary link in a report may lead to.
    ///
    /// A report links to articles and guidelines on the web; anything else it
    /// writes as a destination is shown as text.
    static let followableLinkSchemes: Set<String> = ["http", "https"]
}

/// A quiet line, placed above the text it describes, telling the reader its
/// citations could not all be shown as written.
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
///
/// Its citations are tappable, but it handles no taps itself: the app's
/// `OpenURLAction` posts every `docref:` tap, and the report body beside it on
/// the same screen opens the document. Placed where no report body listens,
/// its citations would look like links and open nothing (#224).
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
            if let notice = RemovedCitationNotice(parses: [parsed]) {
                RemovedCitationNote(notice: notice)
            }
            Text(ReportRichText.attributedString(from: parsed))
        }
        // Logged when the summary appears or changes, not from `body`, which
        // SwiftUI evaluates again whenever its inputs change. Parsing again
        // here gives the same parse, because parsing is pure.
        .task(id: markdown) {
            ReportFormatter.logUnparseableReferences(in: [ReportInlineText(parsing: markdown)])
        }
    }
}
