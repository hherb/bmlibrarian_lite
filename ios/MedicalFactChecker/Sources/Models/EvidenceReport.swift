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
import SwiftData
import BioMedLit

/// The final evidence report for a fact-check session.
///
/// Contains the verdict, summary, and full markdown report
/// synthesizing evidence from all relevant documents.
@Model
final class EvidenceReport {
    // MARK: - Identification

    /// Unique identifier for this report.
    /// Note: @Attribute(.unique) removed for CloudKit compatibility.
    var id: UUID = UUID()

    // MARK: - Content

    /// The evidence verdict (supported, refuted, etc.).
    /// Stored as raw string for SwiftData compatibility.
    private var verdictRaw: String = "Insufficient Evidence"

    /// The evidence verdict (supported, refuted, etc.).
    var verdict: Verdict {
        get { Verdict(rawValue: verdictRaw) ?? .insufficientEvidence }
        set { verdictRaw = newValue.rawValue }
    }

    /// Brief 2-3 sentence summary of findings.
    var summary: String = ""

    /// Full markdown report with citations.
    var fullReport: String = ""

    /// When the report was generated.
    var generatedAt: Date = Date()

    // MARK: - Statistics

    /// Number of citations included in the report.
    var citationCount: Int = 0

    /// Number of unique sources (documents) cited.
    var uniqueSourceCount: Int = 0

    /// Number of documents reviewed total.
    var documentsReviewed: Int = 0

    // MARK: - Search Shortfalls

    /// What the search behind this report failed to retrieve, in the contract's JSON.
    ///
    /// `"[]"` for a complete search, so a report that recorded nothing can be
    /// told from one that recorded a complete search. `nil` is therefore only a
    /// report saved before this shipped, whose own text is asked instead.
    ///
    /// Private because it is only ever read through ``completeness``, which
    /// refuses to let a damaged record read as a complete search (#284).
    private var searchShortfallsJSON: String?

    // MARK: - Relationships

    var session: FactCheckSession?

    // MARK: - Initialization

    /// Creates a new evidence report.
    ///
    /// - Parameters:
    ///   - verdict: The evidence verdict (supported, refuted, etc.).
    ///   - summary: Brief 2-3 sentence summary of findings.
    ///   - fullReport: Full markdown report with citations.
    ///   - citationCount: Number of citations included.
    ///   - uniqueSourceCount: Number of unique sources cited.
    ///   - documentsReviewed: Total documents reviewed.
    ///   - searchShortfallsRecord: What the search behind the report failed to
    ///     retrieve, from ``BioMedLit/SearchFailureReporting/reportRecord(for:)``.
    ///     It has no default: a report that does not say what its search lost is
    ///     the defect this parameter exists to prevent (#284). Pass `nil` only
    ///     to stand in for a report saved before the record existed.
    init(
        verdict: Verdict,
        summary: String,
        fullReport: String,
        citationCount: Int,
        uniqueSourceCount: Int,
        documentsReviewed: Int,
        searchShortfallsRecord: String?
    ) {
        self.verdict = verdict
        self.summary = summary
        self.fullReport = fullReport
        self.citationCount = citationCount
        self.uniqueSourceCount = uniqueSourceCount
        self.documentsReviewed = documentsReviewed
        self.searchShortfallsJSON = searchShortfallsRecord
    }

    // MARK: - Computed Properties

    /// What this report says about the search behind it.
    ///
    /// Read from the record it stored, not from its own text: a report used to
    /// answer by matching the notice's opening words in `fullReport`, so
    /// anything that rewrote the text answered for the search (#284).
    var completeness: ReportSearchCompleteness {
        ReportSearchCompleteness(record: searchShortfallsJSON, reportText: fullReport)
    }

    /// The incomplete-search notice this report opens with, as plain text.
    ///
    /// `nil` when the search behind the report was complete. All three surfaces
    /// that show a report — the screen, the exported PDF and the shared text —
    /// show the verdict and the summary ahead of the report's own text, so the
    /// notice is drawn before the verdict and removed from the body it opened
    /// (#256). It is moved, never dropped.
    var incompleteSearchNotice: String? {
        completeness.notice
    }

    /// The report's text with the incomplete-search notice taken off the front.
    ///
    /// Unchanged for a report whose search was complete.
    var reportBodyAfterNotice: String {
        completeness.bodyAfterNotice
    }

    /// Whether the search behind this report was incomplete.
    ///
    /// For a surface that shows the verdict without the report's text, such as
    /// the history list, which must still say the evidence base was partial.
    /// `true` as well for a record that could not be read: a report that cannot
    /// say what it is missing must not pass as one missing nothing.
    var searchWasIncomplete: Bool {
        completeness.wasIncomplete
    }

    /// A footnote describing how this report was generated.
    var generationFootnote: String {
        var parts: [String] = []

        // Model and provider info
        if let model = session?.modelName, let provider = session?.providerName {
            let providerDisplay = provider == "ollama" ? "\(provider.capitalized) (Local)" : provider.capitalized
            parts.append("Generated using \(model) by \(providerDisplay)")
        } else if let model = session?.modelName {
            parts.append("Generated using \(model)")
        }

        // Search statistics - use actual values from session if available
        if let session = session {
            parts.append("\(session.documentsFound) documents found")
            parts.append("\(session.relevantDocumentsFound) scored as relevant")
        } else {
            parts.append("\(documentsReviewed) documents reviewed")
            parts.append("\(uniqueSourceCount) cited")
        }

        return parts.joined(separator: ", ") + "."
    }

    /// Plain text version of the report for sharing.
    ///
    /// The body is flattened first. ``fullReport`` is markdown carrying its
    /// references as `[Smith et al., 2016](doc:<identity>)`, and this string
    /// goes to the clipboard, the share sheet and *Export as Text* — none of
    /// which can follow a link. Interpolated raw, it put the link syntax and a
    /// document's identity into prose that a reader keeps and forwards.
    ///
    /// The identity must not be shown for the reason ``Document/id`` gives: it
    /// names a row, not an article, and nothing outside the app can resolve it.
    /// A reader who wants to look a study up is served by the reference list,
    /// which carries a namespace-labelled identifier.
    var plainTextReport: String {
        let notice = incompleteSearchNotice.map { "\($0)\n\n" } ?? ""
        // The screen and the printed report discuss every high-risk study;
        // text a reader copies or exports must not drop that discussion.
        let highRisk = HighRiskTransparencySection.plainText(
            for: Document.highRiskTransparencyEntries(in: session?.documents ?? [])
        ).map { "---\n\n\($0)\n\n" } ?? ""
        return """
        MEDICAL FACT CHECK REPORT
        Generated: \(generatedAt.formatted(date: .abbreviated, time: .shortened))

        \(notice)VERDICT: \(verdict.rawValue)

        SUMMARY:
        \(ReportFormatter.plainText(fromReportMarkdown: summary))

        ---

        \(ReportFormatter.plainText(fromReportMarkdown: reportBodyAfterNotice))

        \(highRisk)---
        Based on \(uniqueSourceCount) sources, \(citationCount) citations.
        \(documentsReviewed) documents reviewed.

        \(generationFootnote)

        DISCLAIMER: This report is for informational purposes only and should not be used for self-diagnosis or treatment. Always consult qualified healthcare professionals for medical advice.
        """
    }
}
