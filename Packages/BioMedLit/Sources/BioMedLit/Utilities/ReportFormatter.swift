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
        /// Document identifier (e.g., "pmid-12345678").
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
        ///   - documentId: Document identifier (e.g., "pmid-12345678").
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

        /// PubMed identifier.
        public let pmid: String

        /// Initialize with reference data.
        ///
        /// - Parameters:
        ///   - authors: Formatted author string.
        ///   - year: Publication year (optional).
        ///   - title: Document title.
        ///   - journal: Journal name (optional).
        ///   - pmid: PubMed identifier.
        public init(authors: String, year: Int?, title: String, journal: String?, pmid: String) {
            self.authors = authors
            self.year = year
            self.title = title
            self.journal = journal
            self.pmid = pmid
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
            ref += ". PMID: \(doc.pmid)"
            return ref
        }.joined(separator: "\n\n")
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
