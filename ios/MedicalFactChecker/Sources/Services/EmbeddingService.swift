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
import NaturalLanguage

/// Service for computing semantic similarity between texts using NLEmbedding.
///
/// Uses Apple's on-device sentence embeddings to compute cosine similarity
/// between a claim and document abstracts. This provides a fast, free alternative
/// to LLM-based scoring for relevance assessment.
///
/// Thread-safe and stateless - each call is independent.
enum EmbeddingService {

    // MARK: - Configuration

    /// Preferred embedding language.
    private static let preferredLanguage: NLLanguage = .english

    // MARK: - Public API

    /// Check if sentence embeddings are available for English.
    ///
    /// - Returns: True if NLEmbedding is available on this device.
    static var isAvailable: Bool {
        NLEmbedding.sentenceEmbedding(for: preferredLanguage) != nil
    }

    /// Compute semantic similarity between a claim and document text.
    ///
    /// - Parameters:
    ///   - claim: The medical claim being fact-checked.
    ///   - documentText: Combined title and abstract of the document.
    /// - Returns: Cosine similarity score (0.0 to 1.0), or nil if embeddings unavailable.
    static func computeSimilarity(claim: String, documentText: String) -> Double? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: preferredLanguage) else {
            return nil
        }

        // Get vector representations
        guard let claimVector = embedding.vector(for: claim),
              let docVector = embedding.vector(for: documentText) else {
            return nil
        }

        // Compute cosine similarity
        let similarity = cosineSimilarity(claimVector, docVector)
        return max(0.0, min(1.0, similarity))
    }

    /// Score multiple documents against a claim.
    ///
    /// More efficient than calling computeSimilarity repeatedly since
    /// the claim embedding is computed only once.
    ///
    /// - Parameters:
    ///   - claim: The medical claim being fact-checked.
    ///   - documents: Array of (title, abstract) tuples.
    /// - Returns: Array of similarity scores (0.0 to 1.0), nil for failed embeddings.
    static func scoreDocuments(
        claim: String,
        documents: [(title: String, abstract: String)]
    ) -> [Double?] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: preferredLanguage) else {
            return Array(repeating: nil, count: documents.count)
        }

        guard let claimVector = embedding.vector(for: claim) else {
            return Array(repeating: nil, count: documents.count)
        }

        return documents.map { doc in
            let documentText = combineDocumentText(title: doc.title, abstract: doc.abstract)
            guard let docVector = embedding.vector(for: documentText) else {
                return nil
            }
            let similarity = cosineSimilarity(claimVector, docVector)
            return max(0.0, min(1.0, similarity))
        }
    }

    /// Convert a raw similarity score (0.0-1.0) to a 1-5 relevance scale.
    ///
    /// Mapping thresholds are tuned for typical sentence embedding similarity distributions:
    /// - < 0.3: Score 1 (not relevant)
    /// - 0.3-0.45: Score 2 (marginally relevant)
    /// - 0.45-0.55: Score 3 (moderately relevant)
    /// - 0.55-0.7: Score 4 (highly relevant)
    /// - >= 0.7: Score 5 (directly relevant)
    ///
    /// - Parameter similarity: Raw cosine similarity (0.0 to 1.0).
    /// - Returns: Normalized score (1 to 5).
    static func normalizeToRelevanceScale(_ similarity: Double) -> Int {
        switch similarity {
        case ..<0.3: return 1
        case 0.3..<0.45: return 2
        case 0.45..<0.55: return 3
        case 0.55..<0.7: return 4
        default: return 5
        }
    }

    // MARK: - Private Helpers

    /// Combine document title and abstract into a single text for embedding.
    ///
    /// - Parameters:
    ///   - title: Document title.
    ///   - abstract: Document abstract.
    /// - Returns: Combined text with title given slight emphasis.
    private static func combineDocumentText(title: String, abstract: String) -> String {
        "\(title). \(abstract)"
    }

    /// Compute cosine similarity between two vectors.
    ///
    /// - Parameters:
    ///   - vectorA: First embedding vector.
    ///   - vectorB: Second embedding vector.
    /// - Returns: Cosine similarity (-1.0 to 1.0, typically 0.0 to 1.0 for embeddings).
    private static func cosineSimilarity(_ vectorA: [Double], _ vectorB: [Double]) -> Double {
        guard vectorA.count == vectorB.count, !vectorA.isEmpty else { return 0.0 }

        var dotProduct: Double = 0.0
        var normA: Double = 0.0
        var normB: Double = 0.0

        for i in 0..<vectorA.count {
            dotProduct += vectorA[i] * vectorB[i]
            normA += vectorA[i] * vectorA[i]
            normB += vectorB[i] * vectorB[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0.0 }

        return dotProduct / denominator
    }
}
