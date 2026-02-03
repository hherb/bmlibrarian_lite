// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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
    init(
        verdict: Verdict,
        summary: String,
        fullReport: String,
        citationCount: Int,
        uniqueSourceCount: Int,
        documentsReviewed: Int
    ) {
        self.verdict = verdict
        self.summary = summary
        self.fullReport = fullReport
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
