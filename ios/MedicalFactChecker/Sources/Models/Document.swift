//
//  Document.swift
//  MedicalFactChecker
//
//  PubMed document model with scoring and citations.
//

import Foundation
import SwiftData

/// A PubMed document retrieved for fact-checking.
///
/// Contains article metadata, relevance scoring, and extracted citations.
@Model
final class Document {
    // MARK: - Identification

    @Attribute(.unique) var id: String  // "pmid-12345678"
    var pmid: String
    var title: String
    var abstract: String

    // MARK: - Metadata

    var authors: [String]
    var year: Int?
    var journal: String?
    var doi: String?
    var pmcId: String?
    var meshTerms: [String]
    var publicationDate: String?

    // MARK: - Scoring

    /// LLM relevance score (1-5 scale), nil if not yet scored.
    var relevanceScore: Int?

    /// LLM explanation for the relevance score.
    var scoreExplanation: String?

    /// When the document was scored by LLM.
    var scoredAt: Date?

    // MARK: - Embedding Scoring

    /// Semantic similarity score (0.0-1.0 scale) from NLEmbedding.
    ///
    /// Computed using cosine similarity between the claim and document text.
    /// Nil if embedding scoring is disabled or not yet computed.
    var embeddingScore: Double?

    /// Embedding score converted to 1-5 scale for comparison with LLM score.
    ///
    /// Mapping thresholds tuned for typical sentence embedding similarity:
    /// - < 0.3: Score 1, 0.3-0.45: Score 2, 0.45-0.55: Score 3, 0.55-0.7: Score 4, >= 0.7: Score 5
    var embeddingScoreNormalized: Int? {
        guard let score = embeddingScore else { return nil }
        switch score {
        case ..<0.3: return 1
        case 0.3..<0.45: return 2
        case 0.45..<0.55: return 3
        case 0.55..<0.7: return 4
        default: return 5
        }
    }

    // MARK: - Batch Tracking

    /// Which batch this document was fetched in (1-indexed).
    var batchNumber: Int

    /// Position within the PubMed results (0-indexed).
    var resultPosition: Int

    // MARK: - Relationships

    var session: FactCheckSession?

    @Relationship(deleteRule: .cascade, inverse: \Citation.document)
    var citations: [Citation]

    // MARK: - Initialization

    init(
        pmid: String,
        title: String,
        abstract: String,
        authors: [String] = [],
        batchNumber: Int = 1,
        resultPosition: Int = 0
    ) {
        self.id = "pmid-\(pmid)"
        self.pmid = pmid
        self.title = title
        self.abstract = abstract
        self.authors = authors
        self.batchNumber = batchNumber
        self.resultPosition = resultPosition
        self.meshTerms = []
        self.citations = []
    }

    // MARK: - Computed Properties

    /// Formatted author string for display.
    var formattedAuthors: String {
        guard !authors.isEmpty else { return "Unknown" }
        if authors.count <= 3 {
            return authors.joined(separator: ", ")
        }
        return "\(authors[0]) et al."
    }

    /// Short reference format for citations.
    var shortReference: String {
        let authorPart: String
        if let firstAuthor = authors.first {
            // Extract last name
            let lastName = firstAuthor.components(separatedBy: " ").first ?? firstAuthor
            authorPart = authors.count > 1 ? "\(lastName) et al." : lastName
        } else {
            authorPart = "Unknown"
        }
        let yearPart = year.map { String($0) } ?? "n.d."
        return "\(authorPart), \(yearPart)"
    }

    /// Check if document meets relevance threshold.
    ///
    /// Uses hardcoded threshold of 3 for SwiftData compatibility.
    /// The workflow uses `AppSettings.minScoreThreshold` for filtering.
    var isRelevant: Bool {
        guard let score = relevanceScore else { return false }
        return score >= 3
    }

    /// Check if document meets a specific score threshold.
    ///
    /// - Parameter threshold: Minimum score to consider relevant (1-5).
    /// - Returns: True if scored and score >= threshold.
    func meetsThreshold(_ threshold: Int) -> Bool {
        guard let score = relevanceScore else { return false }
        return score >= threshold
    }

    /// Check if document has been scored.
    var isScored: Bool {
        relevanceScore != nil
    }

    /// Full citation string for references section.
    var fullCitation: String {
        var parts: [String] = []
        parts.append(formattedAuthors)
        if let year = year {
            parts.append("(\(year))")
        }
        parts.append(title)
        if let journal = journal {
            parts.append("*\(journal)*")
        }
        if !pmid.isEmpty {
            parts.append("PMID: \(pmid)")
        }
        return parts.joined(separator: ". ")
    }
}
