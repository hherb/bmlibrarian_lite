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

/// Available search providers for biomedical literature.
public enum SearchProvider: String, Sendable, Codable, CaseIterable {
    /// PubMed via NCBI E-utilities.
    case pubmed

    /// Europe PMC REST API.
    case europePMC

    /// Search both providers and merge results.
    case both

    /// Display name for the provider.
    public var displayName: String {
        switch self {
        case .pubmed:
            return "PubMed"
        case .europePMC:
            return "Europe PMC"
        case .both:
            return "Both"
        }
    }

    /// Description of what the provider offers.
    public var description: String {
        switch self {
        case .pubmed:
            return "NCBI PubMed - US National Library of Medicine"
        case .europePMC:
            return "Europe PMC - European biomedical literature database"
        case .both:
            return "Search both PubMed and Europe PMC for comprehensive results"
        }
    }
}

/// Article metadata from a search result.
public struct SearchArticle: Sendable, Identifiable, Equatable {
    /// Unique identifier (typically PMID).
    public let id: String

    /// PubMed ID.
    public let pmid: String

    /// PubMed Central ID (if available).
    public let pmcId: String?

    /// Digital Object Identifier (if available).
    public let doi: String?

    /// Article title.
    public let title: String

    /// Article abstract.
    public let abstract: String

    /// Author list as a formatted string.
    public let authors: String

    /// Journal name.
    public let journal: String

    /// Publication year.
    public let year: String

    /// Publication date (if available).
    public let publicationDate: String?

    /// Whether full text is available in PMC.
    public let hasFullText: Bool

    /// Whether the article is open access.
    public let isOpenAccess: Bool

    /// Source provider of this result.
    public let source: SearchProvider

    public init(
        pmid: String,
        pmcId: String? = nil,
        doi: String? = nil,
        title: String,
        abstract: String,
        authors: String,
        journal: String,
        year: String,
        publicationDate: String? = nil,
        hasFullText: Bool = false,
        isOpenAccess: Bool = false,
        source: SearchProvider
    ) {
        self.id = pmid
        self.pmid = pmid
        self.pmcId = pmcId
        self.doi = doi
        self.title = title
        self.abstract = abstract
        self.authors = authors
        self.journal = journal
        self.year = year
        self.publicationDate = publicationDate
        self.hasFullText = hasFullText
        self.isOpenAccess = isOpenAccess
        self.source = source
    }
}

/// Result of a search operation.
public struct SearchResult: Sendable {
    /// Articles found in the search.
    public let articles: [SearchArticle]

    /// Total number of results available (may be more than returned).
    public let totalCount: Int

    /// Cursor for pagination (Europe PMC).
    public let nextCursor: String?

    /// Offset for pagination (PubMed).
    public let nextOffset: Int?

    /// The query that was executed.
    public let query: String

    /// The provider that returned these results.
    public let provider: SearchProvider

    public init(
        articles: [SearchArticle],
        totalCount: Int,
        nextCursor: String? = nil,
        nextOffset: Int? = nil,
        query: String,
        provider: SearchProvider
    ) {
        self.articles = articles
        self.totalCount = totalCount
        self.nextCursor = nextCursor
        self.nextOffset = nextOffset
        self.query = query
        self.provider = provider
    }

    /// Whether there are more results available.
    public var hasMore: Bool {
        articles.count < totalCount
    }
}
