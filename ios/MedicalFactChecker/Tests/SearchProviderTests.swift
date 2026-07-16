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

import Testing
import Foundation
@testable import MedicalFactChecker

// MARK: - SearchProvider Tests

struct SearchProviderTests {
    @Test func displayNames() {
        #expect(SearchProvider.pubmed.displayName == "PubMed")
        #expect(SearchProvider.europePMC.displayName == "Europe PMC")
        #expect(SearchProvider.both.displayName == "Both (merged)")
    }

    @Test func iconNames() {
        #expect(SearchProvider.pubmed.iconName == "building.columns")
        #expect(SearchProvider.europePMC.iconName == "globe.europe.africa")
        #expect(SearchProvider.both.iconName == "arrow.triangle.merge")
    }

    @Test func supportsPreprints() {
        #expect(SearchProvider.pubmed.supportsPreprints == false)
        #expect(SearchProvider.europePMC.supportsPreprints == true)
        #expect(SearchProvider.both.supportsPreprints == true)
    }

    @Test func rawValueRoundTrip() {
        for provider in SearchProvider.allCases {
            let rawValue = provider.rawValue
            let decoded = SearchProvider(rawValue: rawValue)
            #expect(decoded == provider)
        }
    }

    @Test func baseURLs() {
        #expect(SearchProvider.pubmed.baseURL.contains("ncbi.nlm.nih.gov"))
        #expect(SearchProvider.europePMC.baseURL.contains("ebi.ac.uk"))
        #expect(SearchProvider.both.baseURL.isEmpty)
    }

    @Test func descriptions() {
        // All providers should have non-empty descriptions for UI
        for provider in SearchProvider.allCases {
            #expect(!provider.description.isEmpty)
        }
    }
}

// MARK: - SearchOptions Tests

struct SearchOptionsTests {
    @Test func defaultValues() {
        let options = SearchOptions()
        #expect(options.provider == .pubmed)
        #expect(options.includePreprints == false)
        #expect(options.maxResults == SearchProviderConstants.defaultMaxResults)
        #expect(options.offset == 0)
        #expect(options.cursorMark == nil)
    }

    @Test func customValues() {
        var options = SearchOptions()
        options.provider = .europePMC
        options.includePreprints = true
        options.maxResults = 50
        options.offset = 100

        #expect(options.provider == .europePMC)
        #expect(options.includePreprints == true)
        #expect(options.maxResults == 50)
        #expect(options.offset == 100)
    }
}

// MARK: - UnifiedArticleMetadata Tests

struct UnifiedArticleMetadataTests {
    @Test func idGenerationWithPMID() {
        let article = UnifiedArticleMetadata(
            pmid: "12345678",
            title: "Test Article",
            abstract: "Abstract text",
            source: .pubmed
        )
        #expect(article.id == "pubmed-12345678")
    }

    @Test func idGenerationWithDOIOnly() {
        let article = UnifiedArticleMetadata(
            pmid: "",
            doi: "10.1234/test",
            title: "Test Article",
            abstract: "Abstract text",
            source: .europePMC
        )
        // Should use DOI when PMID is empty
        #expect(article.id.contains("europepmc-"))
    }

    @Test func fullMetadata() {
        let article = UnifiedArticleMetadata(
            pmid: "12345678",
            pmcId: "PMC9876543",
            doi: "10.1234/test",
            title: "Test Article",
            abstract: "Abstract text",
            authors: ["Smith J", "Jones K"],
            journal: "Test Journal",
            publicationDate: "2024-01-15",
            year: 2024,
            meshTerms: ["Term1", "Term2"],
            source: .pubmed,
            isPreprint: false,
            batchNumber: 1,
            resultPosition: 0
        )

        #expect(article.pmid == "12345678")
        #expect(article.pmcId == "PMC9876543")
        #expect(article.doi == "10.1234/test")
        #expect(article.authors.count == 2)
        #expect(article.year == 2024)
        #expect(article.meshTerms.count == 2)
        #expect(article.source == .pubmed)
        #expect(article.isPreprint == false)
    }
}

// MARK: - SearchResultMerger Tests

struct SearchResultMergerTests {
    // Helper to create test articles
    func makeArticle(
        pmid: String = "",
        doi: String? = nil,
        pmcId: String? = nil,
        title: String,
        source: SearchProvider,
        position: Int = 0
    ) -> UnifiedArticleMetadata {
        UnifiedArticleMetadata(
            pmid: pmid,
            pmcId: pmcId,
            doi: doi,
            title: title,
            abstract: "Abstract for \(title)",
            source: source,
            resultPosition: position
        )
    }

    @Test func titleSimilarityIdentical() {
        let similarity = SearchResultMerger.titleSimilarity(
            "Effects of Aspirin on Cardiovascular Disease",
            "Effects of Aspirin on Cardiovascular Disease"
        )
        #expect(similarity == 1.0)
    }

    @Test func titleSimilarityDifferent() {
        let similarity = SearchResultMerger.titleSimilarity(
            "Effects of Aspirin on Cardiovascular Disease",
            "Machine Learning in Cancer Diagnosis"
        )
        #expect(similarity < 0.3)
    }

    @Test func titleSimilarityPartial() {
        let similarity = SearchResultMerger.titleSimilarity(
            "Effects of Aspirin on Cardiovascular Disease",
            "Aspirin Effects on Heart Disease: A Review"
        )
        // Should have moderate similarity
        #expect(similarity > 0.3)
        #expect(similarity < 1.0)
    }

    @Test func areDuplicatesByPMID() {
        let articleA = makeArticle(pmid: "12345678", title: "Article A", source: .pubmed)
        let articleB = makeArticle(pmid: "12345678", title: "Article B Different Title", source: .europePMC)

        #expect(SearchResultMerger.areDuplicates(articleA, articleB) == true)
    }

    @Test func areDuplicatesByDOI() {
        let articleA = makeArticle(
            doi: "10.1234/test.2024.001",
            title: "Article A",
            source: .pubmed
        )
        let articleB = makeArticle(
            doi: "10.1234/TEST.2024.001",  // Different case
            title: "Article B Different Title",
            source: .europePMC
        )

        #expect(SearchResultMerger.areDuplicates(articleA, articleB) == true)
    }

    @Test func areDuplicatesByPMCId() {
        let articleA = makeArticle(
            pmcId: "PMC9876543",
            title: "Article A",
            source: .pubmed
        )
        let articleB = makeArticle(
            pmcId: "pmc9876543",  // Different case
            title: "Article B Different Title",
            source: .europePMC
        )

        #expect(SearchResultMerger.areDuplicates(articleA, articleB) == true)
    }

    @Test func areDuplicatesBySimilarTitle() {
        let articleA = makeArticle(
            title: "Effects of Metformin on Type 2 Diabetes",
            source: .pubmed
        )
        let articleB = makeArticle(
            title: "Effects of Metformin on Type 2 Diabetes: A Review",
            source: .europePMC
        )

        // These have very similar titles
        #expect(SearchResultMerger.areDuplicates(articleA, articleB) == true)
    }

    @Test func notDuplicatesWhenDifferent() {
        let articleA = makeArticle(
            pmid: "11111111",
            doi: "10.1234/aaa",
            title: "Cardiovascular Effects of Exercise",
            source: .pubmed
        )
        let articleB = makeArticle(
            pmid: "22222222",
            doi: "10.1234/bbb",
            title: "Machine Learning in Medical Imaging",
            source: .europePMC
        )

        #expect(SearchResultMerger.areDuplicates(articleA, articleB) == false)
    }

    @Test func mergeRemovesDuplicatesByPMID() {
        // Titles must be distinct beyond short words: the merger also
        // deduplicates by title similarity, ignoring words under 2 characters.
        let pubmedArticles = [
            makeArticle(pmid: "12345678", title: "Study Alpha", source: .pubmed, position: 0),
            makeArticle(pmid: "87654321", title: "Study Beta", source: .pubmed, position: 1),
        ]
        let europePMCArticles = [
            makeArticle(pmid: "12345678", title: "Study Alpha", source: .europePMC, position: 0),  // Duplicate
            makeArticle(pmid: "11111111", title: "Study Gamma", source: .europePMC, position: 1),
        ]

        let pubmedResult = UnifiedSearchResult(
            articles: pubmedArticles,
            totalCount: 2,
            pagination: OffsetPaginationState(totalCount: 2, offset: 0, batchSize: 2),
            provider: .pubmed
        )
        let europePMCResult = UnifiedSearchResult(
            articles: europePMCArticles,
            totalCount: 2,
            pagination: OffsetPaginationState(totalCount: 2, offset: 0, batchSize: 2),
            provider: .europePMC
        )

        let merged = SearchResultMerger.merge(
            pubmedResult: pubmedResult,
            europePMCResult: europePMCResult
        )

        // Should have 3 unique articles: A, B, C (one duplicate removed)
        #expect(merged.articles.count == 3)

        // PubMed version of duplicate should be kept (higher priority)
        let articleA = merged.articles.first { $0.pmid == "12345678" }
        #expect(articleA?.source == .pubmed)
    }

    @Test func mergeEmptyResults() {
        let emptyPubmed = UnifiedSearchResult.empty(provider: .pubmed)
        let emptyEuropePMC = UnifiedSearchResult.empty(provider: .europePMC)

        let merged = SearchResultMerger.merge(
            pubmedResult: emptyPubmed,
            europePMCResult: emptyEuropePMC
        )

        #expect(merged.articles.isEmpty)
        #expect(merged.totalCount == 0)
    }

    @Test func mergePubmedOnlyWhenEuropePMCEmpty() {
        let pubmedArticles = [
            makeArticle(pmid: "12345678", title: "Study A", source: .pubmed, position: 0),
        ]
        let pubmedResult = UnifiedSearchResult(
            articles: pubmedArticles,
            totalCount: 1,
            pagination: OffsetPaginationState(totalCount: 1, offset: 0, batchSize: 1),
            provider: .pubmed
        )
        let emptyEuropePMC = UnifiedSearchResult.empty(provider: .europePMC)

        let merged = SearchResultMerger.merge(
            pubmedResult: pubmedResult,
            europePMCResult: emptyEuropePMC
        )

        #expect(merged.articles.count == 1)
    }
}
