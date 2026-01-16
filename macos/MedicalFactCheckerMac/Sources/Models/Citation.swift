//
//  Citation.swift
//  MedicalFactChecker
//
//  Extracted citation passage from a document.
//

import Foundation
import SwiftData

/// An extracted citation passage from a document.
///
/// Contains a specific quote from the abstract that supports
/// or refutes the medical claim being fact-checked.
@Model
final class Citation {
    // MARK: - Identification

    /// Unique identifier for this citation.
    /// Note: @Attribute(.unique) removed for CloudKit compatibility.
    var id: UUID = UUID()

    // MARK: - Content

    /// The extracted passage/quote from the document.
    var passage: String = ""

    /// Why this passage is relevant to the claim.
    var context: String?

    /// When the citation was extracted.
    var extractedAt: Date = Date()

    // MARK: - Relationships

    var document: Document?

    // MARK: - Initialization

    /// Creates a new citation with the extracted passage.
    ///
    /// - Parameters:
    ///   - passage: The extracted passage/quote from the document.
    ///   - context: Why this passage is relevant to the claim.
    init(passage: String, context: String? = nil) {
        self.passage = passage
        self.context = context
    }

    // MARK: - Computed Properties

    /// Formatted citation for inline use in the report.
    var formattedInlineCitation: String {
        guard let doc = document else {
            return "\"\(passage)\""
        }
        return "\"\(passage)\" [\(doc.shortReference)]"
    }
}
