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

    // MARK: - Scoring

    /// LLM relevance score (1-5 scale), nil if not yet scored or if scoring failed.
    var relevanceScore: Int?

    /// LLM explanation for the relevance score.
    var scoreExplanation: String?

    /// When the document was scored by LLM.
    var scoredAt: Date?

    /// True if LLM scoring was attempted but failed to parse after all retries.
    var scoreParseFailed: Bool = false

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

    // MARK: - Source Tracking

    /// The search provider that returned this document.
    ///
    /// Stored as raw string value of `SearchProvider` enum:
    /// - "pubmed": PubMed/NCBI
    /// - "europePMC": Europe PMC
    /// - "both": Found by both providers (merged result)
    var searchSource: String?

    /// Whether this is a preprint (Europe PMC only).
    var isPreprint: Bool = false

    /// The `SearchProvider` enum value for the stored source string.
    ///
    /// Returns `.pubmed` as default if no source is set (for backwards compatibility).
    var searchSourceEnum: SearchProvider {
        guard let source = searchSource else { return .pubmed }
        return SearchProvider(rawValue: source) ?? .pubmed
    }

    // MARK: - Full Text

    /// The full text content (markdown format for XML sources, nil for PDF-only).
    var fullTextContent: String?

    /// The full text content in HTML format (from Europe PMC XML conversion).
    ///
    /// Preferred over markdown for proper table and figure rendering.
    var fullTextHTML: String?

    /// URL to the locally cached PDF file, if available.
    var fullTextPDFPath: String?

    /// Source of the full text (for display and debugging).
    /// Values: "europepmc", "unpaywall", "doi"
    var fullTextSource: String?

    /// When the full text was fetched.
    var fullTextFetchedAt: Date?

    /// True if full text fetch was attempted but no source was available.
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

    /// Title with HTML entities decoded and tags stripped for display.
    ///
    /// PubMed and Europe PMC titles often contain HTML entities (`&lt;i&gt;`)
    /// and formatting tags (`<i>`, `<sup>`) that should be rendered as plain text.
    var displayTitle: String {
        decodeHTMLEntities(title)
    }

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

    /// Check if document has been scored (or scoring was attempted but failed).
    var isScored: Bool {
        relevanceScore != nil || scoreParseFailed
    }

    // MARK: - Full Text Computed Properties

    /// Whether full text is available for this document.
    var hasFullText: Bool {
        fullTextContent != nil || fullTextPDFPath != nil
    }

    /// Whether we've already tried to fetch full text (success or failure).
    var fullTextAttempted: Bool {
        fullTextFetchedAt != nil || fullTextUnavailable
    }

    /// Display name for the full text source.
    var fullTextSourceDisplay: String? {
        guard let source = fullTextSource else { return nil }
        switch source {
        case "europepmc": return "Europe PMC"
        case "unpaywall": return "Unpaywall"
        case "doi": return "Publisher"
        default: return source.capitalized
        }
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

    /// The `AppFullTextSource` enum value for the stored source string.
    ///
    /// Returns nil if no source is set or if the string doesn't match a known source.
    var fullTextSourceEnum: AppFullTextSource? {
        guard let source = fullTextSource else { return nil }
        return AppFullTextSource(rawValue: source)
    }

    /// SF Symbol icon name for the full text source.
    var fullTextSourceIcon: String? {
        fullTextSourceEnum?.iconName
    }

    // MARK: - Full Text Update Methods

    /// Update the document with a successful full text result.
    ///
    /// - Parameter result: The full text retrieval result.
    func applyFullTextResult(_ result: AppFullTextResult) {
        fullTextSource = result.source.rawValue
        fullTextFetchedAt = Date()
        fullTextUnavailable = false

        switch result.content {
        case .markdown(let content):
            fullTextContent = content
            fullTextHTML = nil
            fullTextPDFPath = nil
        case .html(let htmlContent):
            fullTextHTML = htmlContent
            fullTextContent = nil
            fullTextPDFPath = nil
        case .pdfURL:
            // PDF path will be set after download
            fullTextContent = nil
            fullTextHTML = nil
        case .webURL:
            // Web URLs don't store content locally
            fullTextContent = nil
            fullTextHTML = nil
            fullTextPDFPath = nil
        }
    }

    /// Mark the document as having no full text available.
    func markFullTextUnavailable() {
        fullTextUnavailable = true
        fullTextFetchedAt = nil
        fullTextContent = nil
        fullTextHTML = nil
        fullTextPDFPath = nil
        fullTextSource = nil
    }

    /// Clear cached full text data to allow re-fetching.
    func clearFullTextCache() {
        fullTextContent = nil
        fullTextHTML = nil
        fullTextPDFPath = nil
        fullTextSource = nil
        fullTextFetchedAt = nil
        fullTextUnavailable = false
    }

    // MARK: - Private Helpers

    /// Decodes HTML entities and removes HTML tags for plain text display.
    ///
    /// Handles common entities found in PubMed/Europe PMC titles:
    /// - Named entities: `&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;`, `&nbsp;`
    /// - Numeric entities: `&#60;`, `&#x3C;`
    /// - HTML tags: `<i>`, `</i>`, `<b>`, `<sup>`, etc.
    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string

        // Named HTML entities
        let namedEntities: [String: String] = [
            "&lt;": "<",
            "&gt;": ">",
            "&amp;": "&",
            "&quot;": "\"",
            "&apos;": "'",
            "&nbsp;": " ",
            "&ndash;": "–",
            "&mdash;": "—",
            "&lsquo;": "'",
            "&rsquo;": "'",
            "&ldquo;": "\u{201C}",
            "&rdquo;": "\u{201D}",
            "&hellip;": "…",
            "&deg;": "°",
            "&plusmn;": "±",
            "&times;": "×",
            "&divide;": "÷",
            "&micro;": "µ",
            "&alpha;": "α",
            "&beta;": "β",
            "&gamma;": "γ",
            "&delta;": "δ",
        ]

        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Numeric entities (decimal): &#60; -> <
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range)

            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let code = Int(result[codeRange]),
                   let scalar = Unicode.Scalar(code) {
                    let char = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: char)
                    }
                }
            }
        }

        // Numeric entities (hex): &#x3C; -> <
        if let regex = try? NSRegularExpression(pattern: "&#[xX]([0-9a-fA-F]+);", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range)

            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let code = Int(result[codeRange], radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    let char = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: char)
                    }
                }
            }
        }

        // Remove HTML tags (after decoding entities, since tags might have been encoded)
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        return result
    }
}
