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

// MARK: - Report Formatter

/// Pure functions for formatting evidence reports.
///
/// All functions are stateless and easily testable. They handle:
/// - Formatting citations for LLM prompts
/// - Generating reference lists
/// - Creating no-evidence report content
///
/// ## Example
///
/// ```swift
/// let citationsText = ReportFormatter.formatCitationsForPrompt(citations)
/// let references = ReportFormatter.formatReferences(documents)
/// ```
public enum ReportFormatter {
    // MARK: - Citation Formatting

    /// Input data for formatting a citation.
    public struct CitationData: Sendable {
        /// The document's identity, opaque and copied verbatim.
        ///
        /// It reaches the model in the `ID:` line and comes back in the report
        /// as `[Author, Year](doc:<id>)`, which is how a reference resolves to
        /// the row it was drawn from. Nothing here reads it, and nothing
        /// downstream may: it once looked like `pmid-889149`, and an exported
        /// report printed that as `PMID: 889149` — a real, unrelated article
        /// (#212). An identifier meant for a reader is ``ReferenceData/identifier``.
        public let documentId: String

        /// Formatted author string (e.g., "Smith et al.").
        public let authors: String

        /// Publication year.
        public let year: Int

        /// Document title.
        public let title: String

        /// Citation passage text.
        public let passage: String

        /// Initialize with citation data.
        ///
        /// - Parameters:
        ///   - documentId: The document's identity. See ``documentId``.
        ///   - authors: Formatted author string (e.g., "Smith et al.").
        ///   - year: Publication year.
        ///   - title: Document title.
        ///   - passage: Citation passage text.
        public init(documentId: String, authors: String, year: Int, title: String, passage: String) {
            self.documentId = documentId
            self.authors = authors
            self.year = year
            self.title = title
            self.passage = passage
        }
    }

    /// Format citations for inclusion in an LLM prompt.
    ///
    /// Produces numbered citations with author, year, title, and passage
    /// in a format optimized for LLM consumption.
    ///
    /// - Parameter citations: Array of citation data to format.
    /// - Returns: Formatted string suitable for LLM prompt.
    public static func formatCitationsForPrompt(_ citations: [CitationData]) -> String {
        var result = ""

        for (index, citation) in citations.enumerated() {
            result += """
            [\(index + 1)] ID: \(citation.documentId)
            Authors: \(citation.authors) (\(citation.year))
            Title: \(citation.title)
            Passage: "\(citation.passage)"

            """
        }

        return result
    }

    // MARK: - Reference Formatting

    /// Input data for formatting a reference.
    public struct ReferenceData: Sendable {
        /// Formatted author string.
        public let authors: String

        /// Publication year (optional).
        public let year: Int?

        /// Document title.
        public let title: String

        /// Journal name (optional).
        public let journal: String?

        /// The article's identifier, already carrying the namespace that
        /// resolves it — `PMID: 12662058`, `Europe PMC: 889149` — or `nil`.
        ///
        /// Deliberately not a bare `pmid: String`. It was one, printed as
        /// `PMID: \(pmid)` with no test applied, and the slot it was filled
        /// from also holds preprint, PMC and Europe PMC thesis accessions; a
        /// thesis accession is a bare decimal that resolves, on PubMed, to a
        /// real but unrelated article (#212). This formatter cannot tell the
        /// difference, so it is not asked to: the caller establishes the
        /// namespace and passes the labelled form, or passes `nil`.
        ///
        /// `nil` where nothing can name the identifier. A reference with no
        /// locator is honest; one with a locator that resolves to the wrong
        /// paper is not, and the reference list outlives the app.
        public let identifier: String?

        /// Initialize with reference data.
        ///
        /// - Parameters:
        ///   - authors: Formatted author string.
        ///   - year: Publication year (optional).
        ///   - title: Document title.
        ///   - journal: Journal name (optional).
        ///   - identifier: The namespace-labelled identifier, or `nil` when
        ///     nothing establishes one. See ``identifier``.
        public init(authors: String, year: Int?, title: String, journal: String?, identifier: String?) {
            self.authors = authors
            self.year = year
            self.title = title
            self.journal = journal
            self.identifier = identifier
        }
    }

    /// Format a list of documents as numbered references.
    ///
    /// Produces markdown-formatted references suitable for inclusion in
    /// evidence reports.
    ///
    /// - Parameter documents: Array of reference data to format.
    /// - Returns: Markdown-formatted reference list.
    public static func formatReferences(_ documents: [ReferenceData]) -> String {
        documents.enumerated().map { index, doc in
            var ref = "**\(index + 1).** "
            ref += "**\(doc.authors)"
            if let year = doc.year { ref += " (\(year))" }
            ref += ".** "
            ref += doc.title
            if let journal = doc.journal { ref += ". *\(journal)*" }
            if let identifier = doc.identifier { ref += ". \(identifier)" }
            return ref
        }.joined(separator: "\n\n")
    }

    // MARK: - Reference Link Flattening

    /// Compiles one of this type's literal patterns, reporting a failure.
    ///
    /// Each pattern is a literal, so a failure here means the build is broken
    /// rather than the input is odd. It is still logged rather than dropped,
    /// because the consequence is otherwise silent and permanent: every caller
    /// would render raw `[text](doc:…)` onto a page a reader keeps.
    ///
    /// - Parameters:
    ///   - pattern: The regular expression source.
    ///   - consequence: What a reader sees if this pattern is unavailable,
    ///     phrased to complete "so …".
    /// - Returns: The compiled expression, or `nil` if it would not compile.
    private static func compiled(
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
            return nil
        }
    }

    /// Markdown link syntax, compiled once.
    private static let markdownLinkRegex: NSRegularExpression? = compiled(
        BioMedLitConstants.markdownLinkPattern,
        consequence: "report links will render as raw markdown"
    )

    /// Document references no link pattern could account for, compiled once.
    private static let residualDocumentReferenceRegex: NSRegularExpression? = compiled(
        BioMedLitConstants.residualDocumentReferencePattern,
        consequence: "a malformed reference will print its document identity"
    )

    /// Every markdown link in a report reduced to its display text.
    ///
    /// The report body carries references as `[Smith et al., 2016](doc:<id>)`,
    /// where the link target is a document's identity and the display text is
    /// what a reader is meant to see. A renderer that cannot follow a link needs
    /// the display text alone. Ordinary links are flattened on the same ground:
    /// such a renderer has no way to offer their destination either.
    ///
    /// Emphasis markers are deliberately left standing, because the caller that
    /// wants them gone is not the caller that wants them kept — `PDFExporter`
    /// consumes `**` itself to set a bold font. A renderer that shows text
    /// verbatim wants ``plainText(fromReportMarkdown:)`` instead.
    ///
    /// ## The link target is not an identifier
    ///
    /// Each of the three private copies this replaces had a branch matching
    /// `doc:pmid-<digits>` and rendering it as `(PMID: <digits>)`. Documents
    /// were identified as `pmid-<primary slot>`, and that slot also holds
    /// Europe PMC thesis, case-report and `HIR` accessions: bare decimals
    /// indistinguishable from a PubMed ID, which Europe PMC serves in bulk.
    /// See ``ArticleIdentifierKind/pubmed`` for the measurement and its date.
    /// An exported report therefore printed a locator that resolves, on PubMed,
    /// to a real but unrelated article (#212).
    ///
    /// The argument is a report's markdown and nothing else: this function never
    /// sees the documents, so it cannot establish what a target names and must
    /// not guess. The numbered reference list carries the namespace-labelled
    /// identifier instead. See ``ReferenceData/identifier``, filled by a caller
    /// that has the document.
    ///
    /// Saved reports still carry `doc:pmid-…` targets, so this is not only about
    /// text written from here on.
    ///
    /// ## A target the pattern cannot parse is still removed
    ///
    /// A reference this function does not recognise used to pass through with
    /// its target intact, which is the same reader-facing outcome by a different
    /// route. Anything left carrying
    /// ``BioMedLitConstants/documentReferenceScheme`` is therefore swept away
    /// and reported — see ``withoutUnparseableDocumentReferences(in:)`` for what
    /// survives that sweep and why.
    ///
    /// - Parameter text: Report markdown.
    /// - Returns: The same markdown with every link reduced to its display text
    ///   and no document reference left standing.
    public static func flattenedReferenceLinks(in text: String) -> String {
        guard let regex = markdownLinkRegex else { return text }
        let flattened = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1"
        )
        return withoutUnparseableDocumentReferences(in: flattened)
    }

    /// Removes any document reference the link pattern could not account for,
    /// and reports what it removed.
    ///
    /// Widening a pattern narrows the gap; it does not close it. Whatever the
    /// link pattern misses used to reach the page with its target intact, and a
    /// legacy `doc:pmid-889149` target printed there is #212 arriving through a
    /// different door — `889149` is a real 1977 paper on mouse courtship, not
    /// the article being cited. A target is a row's identity, which resolves
    /// nowhere outside this app and means nothing to a reader, so removing one
    /// discards nothing a reader wanted.
    ///
    /// Display text keeps its brackets where it has them. Nothing here can tell
    /// where an unterminated target was meant to end, so guessing at the
    /// author's intent would risk eating prose to tidy punctuation.
    ///
    /// Golden rule 8: the removal is an error, not a silent repair. Without the
    /// report, the only symptom is wrong text in a document that outlives the
    /// app.
    ///
    /// - Parameter text: Report markdown with every parseable link flattened.
    /// - Returns: The same text with no document reference left standing.
    private static func withoutUnparseableDocumentReferences(in text: String) -> String {
        guard let regex = residualDocumentReferenceRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        let removed = matches
            .compactMap { Range($0.range, in: text) }
            .map { text[$0].trimmingCharacters(in: .whitespaces) }

        BioMedLitLib.logger?.error(
            """
            Report markdown carried \(matches.count) document \
            reference(s) this formatter could not parse. Each target was removed \
            rather than printed, because it names a row rather than an article \
            and a bare number reads as a PubMed ID: \
            \(removed.joined(separator: ", ")). A reference is written as \
            [display text](\(BioMedLitConstants.documentReferenceScheme)<identity>).
            """,
            category: .parsing
        )

        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// A report's markdown reduced to what a verbatim renderer should show.
    ///
    /// Links become their display text and emphasis markers are removed. That is
    /// what a renderer which follows no links and parses no markdown needs:
    /// SwiftUI's `Text(_:)` over a runtime `String` prints `**` as two literal
    /// asterisks, and ``formatReferences(_:)`` opens every entry with `**1.**`.
    ///
    /// Kept separate from ``flattenedReferenceLinks(in:)`` because the two
    /// renderers genuinely differ, and conflating them has already cost once:
    /// three private copies were consolidated on the assumption they were
    /// identical, when two stripped emphasis and the third relied on it
    /// surviving to set a bold font (#226).
    ///
    /// - Parameter text: Report markdown.
    /// - Returns: Plain text carrying no link syntax and no emphasis markers.
    public static func plainText(fromReportMarkdown text: String) -> String {
        var result = flattenedReferenceLinks(in: text)
        for marker in BioMedLitConstants.markdownEmphasisMarkers {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result
    }

    // MARK: - No Evidence Content

    /// Result of generating no-evidence content.
    public struct NoEvidenceContent: Sendable {
        /// Brief summary for the report.
        public let summary: String

        /// Full markdown report content.
        public let fullReport: String

        /// Initialize with content.
        ///
        /// - Parameters:
        ///   - summary: Brief summary for the report.
        ///   - fullReport: Full markdown report content.
        public init(summary: String, fullReport: String) {
            self.summary = summary
            self.fullReport = fullReport
        }
    }

    /// Generate content for a report when no evidence was found.
    ///
    /// Distinguishes between two scenarios:
    /// 1. No relevant documents found during search
    /// 2. Relevant documents found but citation extraction failed
    ///
    /// - Parameters:
    ///   - claim: The medical claim being evaluated.
    ///   - hadRelevantDocuments: Whether relevant documents were found.
    ///   - relevantDocCount: Number of documents meeting relevance threshold.
    /// - Returns: Generated summary and full report content.
    public static func generateNoEvidenceContent(
        claim: String,
        hadRelevantDocuments: Bool,
        relevantDocCount: Int
    ) -> NoEvidenceContent {
        if hadRelevantDocuments {
            return generateCitationExtractionFailedContent(
                claim: claim,
                relevantDocCount: relevantDocCount
            )
        } else {
            return generateNoRelevantDocumentsContent(claim: claim)
        }
    }

    /// Generate content when citation extraction failed.
    private static func generateCitationExtractionFailedContent(
        claim: String,
        relevantDocCount: Int
    ) -> NoEvidenceContent {
        let summary = "Citation extraction failed for \(relevantDocCount) relevant document(s). Please review the scored documents manually or try again."

        let fullReport = """
        ## Evidence Report

        **Claim:** \(claim)

        **Verdict:** Insufficient Evidence

        \(relevantDocCount) relevant document(s) were found during the search, but citation extraction was unable to identify specific passages from them. This may be due to:

        1. API or network errors during citation extraction
        2. Documents having abstracts that are difficult to parse
        3. Temporary service issues
        4. The LLM returning responses in an unexpected format

        ### Recommendations

        - Review the scored documents shown above - they contain relevant information
        - Try running the search again
        - If the problem persists, check for network connectivity issues

        ---
        *No citations extracted*
        """

        return NoEvidenceContent(summary: summary, fullReport: fullReport)
    }

    /// Generate content when no relevant documents were found.
    private static func generateNoRelevantDocumentsContent(claim: String) -> NoEvidenceContent {
        let summary = "No relevant evidence was found in the medical literature for this claim."

        let fullReport = """
        ## Evidence Report

        **Claim:** \(claim)

        **Verdict:** Insufficient Evidence

        No relevant evidence was found in the searched medical literature for this claim.

        ### Possible Reasons

        1. The topic may have limited published research
        2. The search terms may need refinement
        3. The claim may be too specific or novel

        ### Recommendations

        - Try rephrasing the claim with different medical terms
        - Consider searching for related topics
        - Consult specialized medical databases

        ---
        *No citations available*
        """

        return NoEvidenceContent(summary: summary, fullReport: fullReport)
    }
}
