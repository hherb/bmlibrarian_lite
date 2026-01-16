//
//  EvidenceReport.swift
//  MedicalFactChecker
//
//  Final evidence synthesis report.
//

import Foundation
import SwiftData

/// The final evidence report for a fact-check session.
///
/// Contains the verdict, summary, and full markdown report
/// synthesizing evidence from all relevant documents.
@Model
final class EvidenceReport {
    // MARK: - Identification

    @Attribute(.unique) var id: UUID

    // MARK: - Content

    /// The evidence verdict (supported, refuted, etc.).
    var verdict: Verdict

    /// Brief 2-3 sentence summary of findings.
    var summary: String

    /// Full markdown report with citations.
    var fullReport: String

    /// When the report was generated.
    var generatedAt: Date

    // MARK: - Statistics

    /// Number of citations included in the report.
    var citationCount: Int

    /// Number of unique sources (documents) cited.
    var uniqueSourceCount: Int

    /// Number of documents reviewed total.
    var documentsReviewed: Int

    // MARK: - Relationships

    var session: FactCheckSession?

    // MARK: - Initialization

    init(
        verdict: Verdict,
        summary: String,
        fullReport: String,
        citationCount: Int,
        uniqueSourceCount: Int,
        documentsReviewed: Int
    ) {
        self.id = UUID()
        self.verdict = verdict
        self.summary = summary
        self.fullReport = fullReport
        self.generatedAt = Date()
        self.citationCount = citationCount
        self.uniqueSourceCount = uniqueSourceCount
        self.documentsReviewed = documentsReviewed
    }

    // MARK: - Computed Properties

    /// A footnote describing how this report was generated.
    var generationFootnote: String {
        var parts: [String] = []

        // Model and provider info
        if let model = session?.modelName, let provider = session?.providerName {
            parts.append("Generated using \(model) by \(provider)")
        } else if let model = session?.modelName {
            parts.append("Generated using \(model)")
        }

        // Search statistics
        parts.append("Search limited to \(documentsReviewed) documents")
        parts.append("\(uniqueSourceCount) scored as relevant")

        return parts.joined(separator: ", ") + "."
    }

    /// Plain text version of the report for sharing.
    var plainTextReport: String {
        """
        MEDICAL FACT CHECK REPORT
        Generated: \(generatedAt.formatted(date: .abbreviated, time: .shortened))

        VERDICT: \(verdict.rawValue)

        SUMMARY:
        \(summary)

        ---

        \(fullReport)

        ---
        Based on \(uniqueSourceCount) sources, \(citationCount) citations.
        \(documentsReviewed) documents reviewed.

        \(generationFootnote)

        DISCLAIMER: This report is for informational purposes only and should not be used for self-diagnosis or treatment. Always consult qualified healthcare professionals for medical advice.
        """
    }
}
