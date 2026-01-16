//
//  SearchProviderTests.swift
//  Medical Fact CheckerTests
//
//  Unit tests for search provider abstraction, including SearchProvider,
//  SearchResultMerger, pagination, and QueryTranslator.
//

import Testing
import Foundation
@testable import Medical_Fact_Checker

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
        #expect(SearchProvider.both.iconName == "rectangle.on.rectangle")
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

    @Test func shortNames() {
        #expect(SearchProvider.pubmed.shortName == "PM")
        #expect(SearchProvider.europePMC.shortName == "EPMC")
        #expect(SearchProvider.both.shortName == "Both")
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
        #expect(options.maxResults == SearchOptions.SearchOptionsDefaults.defaultMaxResults)
        #expect(options.offset == 0)
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

// MARK: - Pagination State Tests

struct OffsetPaginationStateTests {
    @Test func hasMoreWhenNotExhausted() {
        let state = OffsetPaginationState(totalCount: 100, offset: 0, batchSize: 20)
        #expect(state.hasMore == true)
        #expect(state.fetchedCount == 20)
        #expect(state.nextOffset == 20)
    }

    @Test func noMoreWhenExhausted() {
        let state = OffsetPaginationState(totalCount: 100, offset: 80, batchSize: 20)
        #expect(state.hasMore == false)
        #expect(state.fetchedCount == 100)
    }

    @Test func logicalOffset() {
        let state = OffsetPaginationState(totalCount: 100, offset: 40, batchSize: 20)
        #expect(state.logicalOffset == 40)
    }
}

struct CursorPaginationStateTests {
    @Test func initialCursor() {
        #expect(CursorPaginationState.initialCursor == "*")
    }

    @Test func hasMoreWithNextCursor() {
        let state = CursorPaginationState(
            totalCount: 100,
            fetchedCount: 20,
            currentCursor: "*",
            nextCursor: "AoEp2345"
        )
        #expect(state.hasMore == true)
    }

    @Test func noMoreWhenCursorNil() {
        let state = CursorPaginationState(
            totalCount: 20,
            fetchedCount: 20,
            currentCursor: "AoEp2345",
            nextCursor: nil
        )
        #expect(state.hasMore == false)
    }

    @Test func noMoreWhenAllFetched() {
        let state = CursorPaginationState(
            totalCount: 20,
            fetchedCount: 20,
            currentCursor: "AoEp2345",
            nextCursor: "AoEp5678"  // Even with cursor, no more if all fetched
        )
        #expect(state.hasMore == false)
    }

    @Test func initialState() {
        let state = CursorPaginationState.initial()
        #expect(state.totalCount == 0)
        #expect(state.fetchedCount == 0)
        #expect(state.currentCursor == nil)
        #expect(state.nextCursor == nil)
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
        let pubmedArticles = [
            makeArticle(pmid: "12345678", title: "Study A", source: .pubmed, position: 0),
            makeArticle(pmid: "87654321", title: "Study B", source: .pubmed, position: 1),
        ]
        let europePMCArticles = [
            makeArticle(pmid: "12345678", title: "Study A", source: .europePMC, position: 0),  // Duplicate
            makeArticle(pmid: "11111111", title: "Study C", source: .europePMC, position: 1),
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

// MARK: - QueryTranslator Tests

struct QueryTranslatorTests {
    @Test func isPubMedSyntaxDetection() {
        #expect(QueryTranslator.isPubMedSyntax("\"Aspirin\"[MeSH]") == true)
        #expect(QueryTranslator.isPubMedSyntax("aspirin[tiab]") == true)
        #expect(QueryTranslator.isPubMedSyntax("hasabstract") == true)
        #expect(QueryTranslator.isPubMedSyntax("author[au]") == true)
        #expect(QueryTranslator.isPubMedSyntax("plain text query") == false)
    }

    @Test func isEuropePMCSyntaxDetection() {
        #expect(QueryTranslator.isEuropePMCSyntax("MeSH_TERM:Aspirin") == true)
        #expect(QueryTranslator.isEuropePMCSyntax("TITLE_ABS:aspirin") == true)
        #expect(QueryTranslator.isEuropePMCSyntax("HAS_ABSTRACT:Y") == true)
        #expect(QueryTranslator.isEuropePMCSyntax("SRC:PPR") == true)
        #expect(QueryTranslator.isEuropePMCSyntax("plain text query") == false)
    }

    @Test func stubRemovesHasAbstract() {
        let query = "aspirin AND hasabstract"
        let translated = QueryTranslator.pubmedToEuropePMC(query)

        // Stub should remove hasabstract (we add HAS_ABSTRACT:Y separately)
        #expect(!translated.lowercased().contains("hasabstract"))
    }

    @Test func stubRemovesPubMedFieldTags() {
        let query = "aspirin[tiab] AND \"Cardiovascular\"[MeSH]"
        let translated = QueryTranslator.pubmedToEuropePMC(query)

        // Stub strips field tags (full translation in Phase 4)
        #expect(!translated.contains("[tiab]"))
        #expect(!translated.contains("[MeSH]"))
    }

    @Test func stubCleansWhitespace() {
        let query = "aspirin   AND   hasabstract   AND  "
        let translated = QueryTranslator.pubmedToEuropePMC(query)

        // Should clean up extra whitespace and trailing AND
        #expect(!translated.contains("  "))  // No double spaces
        #expect(!translated.hasSuffix("AND"))
    }

    @Test func stubPreservesQueryWhenAlreadyClean() {
        let query = "aspirin cardiovascular disease"
        let translated = QueryTranslator.pubmedToEuropePMC(query)

        // Plain text query should pass through mostly unchanged
        #expect(translated.contains("aspirin"))
        #expect(translated.contains("cardiovascular"))
    }

    @Test func europePMCToPubMedPassthrough() {
        // Stub just returns the query unchanged
        let query = "TITLE_ABS:aspirin AND MeSH_TERM:Cardiovascular"
        let translated = QueryTranslator.europePMCToPubMed(query)

        #expect(translated == query)
    }
}

// MARK: - QueryValidator Tests

struct QueryValidatorTests {
    @Test func validQueryPasses() {
        let result = QueryValidator.validateEuropePMCQuery("aspirin AND cardiovascular")
        #expect(result.isValid == true)
        #expect(result.errors.isEmpty)
    }

    @Test func unbalancedParenthesesFails() {
        let result = QueryValidator.validateEuropePMCQuery("(aspirin AND (cardiovascular)")
        #expect(result.isValid == false)
        #expect(result.errors.contains { $0.contains("parentheses") })
    }

    @Test func unbalancedQuotesFails() {
        let result = QueryValidator.validateEuropePMCQuery("\"aspirin AND cardiovascular")
        #expect(result.isValid == false)
        #expect(result.errors.contains { $0.contains("quotes") })
    }

    @Test func untranslatedPubMedSyntaxWarns() {
        let result = QueryValidator.validateEuropePMCQuery("aspirin[tiab]")
        #expect(result.isValid == true)  // Still valid, just warns
        #expect(result.warnings.contains { $0.contains("untranslated") })
    }

    @Test func pubmedValidatorDetectsEuropePMCSyntax() {
        let result = QueryValidator.validatePubMedQuery("TITLE_ABS:aspirin")
        #expect(result.isValid == true)
        #expect(result.warnings.contains { $0.contains("Europe PMC") })
    }
}

// MARK: - UnifiedSearchResult Tests

struct UnifiedSearchResultTests {
    @Test func emptyResultFactory() {
        let result = UnifiedSearchResult.empty(provider: .pubmed)
        #expect(result.articles.isEmpty)
        #expect(result.totalCount == 0)
        #expect(result.provider == .pubmed)
        #expect(result.hasMore == false)
    }

    @Test func hasMoreProperty() {
        let result = UnifiedSearchResult(
            articles: [],
            totalCount: 100,
            pagination: OffsetPaginationState(totalCount: 100, offset: 0, batchSize: 20),
            provider: .pubmed
        )
        #expect(result.hasMore == true)
    }

    @Test func nextOffsetProperty() {
        let result = UnifiedSearchResult(
            articles: [],
            totalCount: 100,
            pagination: OffsetPaginationState(totalCount: 100, offset: 40, batchSize: 20),
            provider: .pubmed
        )
        #expect(result.nextOffset == 40)  // logicalOffset of pagination
    }
}
