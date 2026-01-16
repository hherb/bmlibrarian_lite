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

    /// Unique identifier for this document (format: "pmid-12345678").
    /// Note: @Attribute(.unique) removed for CloudKit compatibility.
    var id: String = ""
    var pmid: String = ""
    var title: String = ""
    var abstract: String = ""

    // MARK: - Metadata

    /// Document authors (stored as transformable for CoreData compatibility).
    @Attribute(.transformable(by: StringArrayTransformer.name.rawValue))
    var authors: [String] = []

    var year: Int?
    var journal: String?
    var doi: String?
    var pmcId: String?

    /// MeSH terms for the document (stored as transformable for CoreData compatibility).
    @Attribute(.transformable(by: StringArrayTransformer.name.rawValue))
    var meshTerms: [String] = []

    var publicationDate: String?

    // MARK: - Source Tracking

    /// The search provider that returned this document.
    ///
    /// Stored as raw string value of `SearchProvider` enum:
    /// - "pubmed": PubMed/NCBI
    /// - "europePMC": Europe PMC
    /// - "both": Found by both providers (merged result)
    var searchSource: String?

    /// The `SearchProvider` enum value for the stored source string.
    ///
    /// Returns `.pubmed` as default if no source is set (for backwards compatibility).
    var searchSourceEnum: SearchProvider {
        guard let source = searchSource else { return .pubmed }
        return SearchProvider(rawValue: source) ?? .pubmed
    }

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
    ///
    /// Note: This logic mirrors `EmbeddingService.normalizeToRelevanceScale()`.
    /// Duplicated here to avoid service dependency in the model layer.
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
    var batchNumber: Int = 1

    /// Position within the PubMed results (0-indexed).
    var resultPosition: Int = 0

    // MARK: - Full Text

    /// The full text content in markdown format (from Europe PMC XML conversion).
    ///
    /// Nil if full text was not retrieved or only PDF is available.
    var fullTextContent: String?

    /// Local file path to the cached PDF, if available.
    ///
    /// Stored as a relative path within Application Support for portability.
    var fullTextPDFPath: String?

    /// Source from which the full text was retrieved.
    ///
    /// Stored as raw string value of `FullTextSource` enum:
    /// - "europepmc": Europe PMC XML (converted to markdown)
    /// - "unpaywall": Unpaywall open access PDF
    /// - "doi": Publisher website (opened in browser)
    var fullTextSource: String?

    /// When the full text was successfully fetched.
    var fullTextFetchedAt: Date?

    /// True if full text fetch was attempted but no source was available.
    ///
    /// Used to avoid repeated failed lookups for the same document.
    var fullTextUnavailable: Bool = false

    /// Whether full text is known to be available in PubMed Central.
    ///
    /// Set from search results metadata (Europe PMC `inPMC` flag or presence of PMC ID).
    /// Used to display availability indicator before user attempts to fetch full text.
    var hasFullTextInPMC: Bool = false

    // MARK: - Relationships

    var session: FactCheckSession?

    @Relationship(deleteRule: .cascade, inverse: \Citation.document)
    var citations: [Citation]? = []

    // MARK: - Initialization

    /// Creates a new document from PubMed metadata.
    ///
    /// - Parameters:
    ///   - pmid: PubMed identifier.
    ///   - title: Article title.
    ///   - abstract: Article abstract text.
    ///   - authors: Author names (defaults to empty).
    ///   - batchNumber: Which batch this document was fetched in (1-indexed).
    ///   - resultPosition: Position within search results (0-indexed).
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

    // MARK: - Full Text Computed Properties

    /// Whether full text is available for this document.
    ///
    /// True if either markdown content or a cached PDF is available.
    var hasFullText: Bool {
        fullTextContent != nil || fullTextPDFPath != nil
    }

    /// Whether a full text fetch has been attempted (success or failure).
    ///
    /// Used to avoid redundant fetch attempts.
    var fullTextAttempted: Bool {
        fullTextFetchedAt != nil || fullTextUnavailable
    }

    /// Human-readable display name for the full text source.
    ///
    /// Returns nil if no full text source is set.
    var fullTextSourceDisplay: String? {
        guard let source = fullTextSource else { return nil }
        switch source {
        case "europepmc": return "Europe PMC"
        case "unpaywall": return "Unpaywall"
        case "doi": return "Publisher"
        case "cached": return "Cached"
        default: return source.capitalized
        }
    }

    /// The `FullTextSource` enum value for the stored source string.
    ///
    /// Returns nil if no source is set or if the string doesn't match a known source.
    var fullTextSourceEnum: FullTextSource? {
        guard let source = fullTextSource else { return nil }
        return FullTextSource(rawValue: source)
    }

    /// SF Symbol icon name for the full text source.
    var fullTextSourceIcon: String? {
        fullTextSourceEnum?.iconName
    }

    /// Update the document with a successful full text result.
    ///
    /// - Parameter result: The full text retrieval result.
    func applyFullTextResult(_ result: FullTextResult) {
        fullTextSource = result.source.rawValue
        fullTextFetchedAt = Date()
        fullTextUnavailable = false

        switch result.content {
        case .markdown(let content):
            fullTextContent = content
            fullTextPDFPath = nil
        case .pdfURL:
            // PDF path will be set after download
            fullTextContent = nil
        case .webURL:
            // Web URLs don't store content locally
            fullTextContent = nil
            fullTextPDFPath = nil
        }
    }

    /// Mark the document as having no full text available.
    func markFullTextUnavailable() {
        fullTextUnavailable = true
        fullTextFetchedAt = nil
        fullTextContent = nil
        fullTextPDFPath = nil
        fullTextSource = nil
    }

    /// Clear cached full text data to allow re-fetching.
    func clearFullTextCache() {
        fullTextContent = nil
        fullTextPDFPath = nil
        fullTextSource = nil
        fullTextFetchedAt = nil
        fullTextUnavailable = false
    }
}
