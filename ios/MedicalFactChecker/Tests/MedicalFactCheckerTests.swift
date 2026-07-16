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

import XCTest
import SwiftData
@testable import MedicalFactChecker

final class CostCalculatorTests: XCTestCase {

    func testKnownModelPricing() {
        // Test that known models return correct pricing
        let gpt4oMiniCost = CostCalculator.calculateCost(
            model: "gpt-4o-mini",
            inputTokens: 1000,
            outputTokens: 100
        )

        // gpt-4o-mini: $0.15/1M input, $0.60/1M output
        // Expected: (1000 * 0.15 / 1_000_000) + (100 * 0.60 / 1_000_000)
        //         = 0.00015 + 0.00006 = 0.00021
        XCTAssertEqual(gpt4oMiniCost, 0.00021, accuracy: 0.00001)
    }

    func testUnknownModelUsesDefault() {
        // Unknown models should use default pricing
        let unknownCost = CostCalculator.calculateCost(
            model: "unknown-model-xyz",
            inputTokens: 1000,
            outputTokens: 100
        )

        // Default: $1.00/1M input, $3.00/1M output
        // Expected: (1000 * 1.0 / 1_000_000) + (100 * 3.0 / 1_000_000)
        //         = 0.001 + 0.0003 = 0.0013
        XCTAssertEqual(unknownCost, 0.0013, accuracy: 0.0001)
    }

    func testCostFormatting() {
        XCTAssertEqual(CostCalculator.formatCost(0.0001), "< $0.001")
        XCTAssertEqual(CostCalculator.formatCost(0.005), "$0.0050")
        XCTAssertEqual(CostCalculator.formatCost(0.123), "$0.123")
        XCTAssertEqual(CostCalculator.formatCost(1.50), "$1.50")
    }

    func testRunCostEstimate() {
        let (minCost, maxCost) = CostCalculator.estimateRunCost(
            model: "gpt-4o-mini",
            documentCount: 20
        )

        // Should return a reasonable range
        XCTAssertGreaterThan(minCost, 0)
        XCTAssertGreaterThan(maxCost, minCost)
        XCTAssertLessThan(maxCost, 1.0)  // Should be under $1 for mini model
    }
}

final class UsageRecordTests: XCTestCase {

    func testMonthKeyGeneration() {
        // Month key should be in YYYY-MM format
        let monthKey = UsageRecord.currentMonthKey
        XCTAssertTrue(monthKey.contains("-"))
        XCTAssertEqual(monthKey.count, 7)
    }

    func testMonthlyCostAggregation() {
        // Create mock records
        let records = [
            createMockRecord(costUSD: 0.01, monthKey: "2024-01"),
            createMockRecord(costUSD: 0.02, monthKey: "2024-01"),
            createMockRecord(costUSD: 0.05, monthKey: "2024-02"),
        ]

        let janCost = UsageRecord.monthlyCost(records: records, monthKey: "2024-01")
        XCTAssertEqual(janCost, 0.03, accuracy: 0.001)

        let febCost = UsageRecord.monthlyCost(records: records, monthKey: "2024-02")
        XCTAssertEqual(febCost, 0.05, accuracy: 0.001)
    }

    private func createMockRecord(costUSD: Double, monthKey: String) -> UsageRecord {
        let record = UsageRecord(
            sessionId: UUID(),
            model: "test",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: costUSD,
            operationType: "test"
        )
        record.monthKey = monthKey
        return record
    }
}

final class WorkflowStepTests: XCTestCase {

    func testTerminalStates() {
        XCTAssertTrue(WorkflowStep.completed.isTerminal)
        XCTAssertTrue(WorkflowStep.failed.isTerminal)
        XCTAssertTrue(WorkflowStep.budgetExceeded.isTerminal)

        XCTAssertFalse(WorkflowStep.idle.isTerminal)
        XCTAssertFalse(WorkflowStep.scoringDocuments.isTerminal)
        XCTAssertFalse(WorkflowStep.generatingReport.isTerminal)
    }

    func testDisplayNames() {
        XCTAssertFalse(WorkflowStep.convertingQuery.displayName.isEmpty)
        XCTAssertFalse(WorkflowStep.completed.displayName.isEmpty)
    }
}

final class VerdictTests: XCTestCase {

    func testVerdictColors() {
        XCTAssertEqual(Verdict.supported.color, "green")
        XCTAssertEqual(Verdict.notSupported.color, "red")
        XCTAssertEqual(Verdict.partiallySupported.color, "orange")
        XCTAssertEqual(Verdict.conflicting.color, "purple")
        XCTAssertEqual(Verdict.insufficientEvidence.color, "gray")
    }

    func testVerdictRawValues() {
        XCTAssertEqual(Verdict.supported.rawValue, "Supported")
        XCTAssertEqual(Verdict.partiallySupported.rawValue, "Partially Supported")
    }
}

final class EmbeddingServiceTests: XCTestCase {

    func testNormalizeToRelevanceScale() {
        // Test score normalization thresholds
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(0.0), 1)
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(0.29), 1)
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(0.30), 2)
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(0.44), 2)
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(0.45), 3)
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(0.54), 3)
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(0.55), 4)
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(0.69), 4)
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(0.70), 5)
        XCTAssertEqual(EmbeddingService.normalizeToRelevanceScale(1.0), 5)
    }

    func testSimilarityIsSymmetric() {
        // If embeddings are available, test that similarity is symmetric
        guard EmbeddingService.isAvailable else {
            // Skip test if embeddings not available (e.g., on some simulators)
            return
        }

        let text1 = "Vitamin D supplementation for COVID-19 treatment"
        let text2 = "Effect of cholecalciferol on coronavirus infection"

        let score1 = EmbeddingService.computeSimilarity(claim: text1, documentText: text2)
        let score2 = EmbeddingService.computeSimilarity(claim: text2, documentText: text1)

        // Scores should be nearly identical (allowing for floating point differences)
        if let s1 = score1, let s2 = score2 {
            XCTAssertEqual(s1, s2, accuracy: 0.001)
        }
    }

    func testSimilarTextHasHigherScore() {
        guard EmbeddingService.isAvailable else { return }

        let claim = "Aspirin prevents heart attacks"
        let related = "Aspirin reduces the risk of cardiovascular events and heart attacks"
        let unrelated = "The weather forecast for tomorrow shows rain"

        let relatedScore = EmbeddingService.computeSimilarity(claim: claim, documentText: related)
        let unrelatedScore = EmbeddingService.computeSimilarity(claim: claim, documentText: unrelated)

        // Related text should score higher than unrelated
        if let rel = relatedScore, let unrel = unrelatedScore {
            XCTAssertGreaterThan(rel, unrel)
        }
    }

    func testBatchScoring() {
        guard EmbeddingService.isAvailable else { return }

        let claim = "Coffee consumption and health benefits"
        let documents = [
            (title: "Effects of caffeine on cardiovascular health", abstract: "This study examines..."),
            (title: "Coffee and longevity: A meta-analysis", abstract: "We analyzed..."),
            (title: "Unrelated topic about geology", abstract: "Rock formations..."),
        ]

        let scores = EmbeddingService.scoreDocuments(claim: claim, documents: documents)

        // Should return scores for all documents
        XCTAssertEqual(scores.count, 3)

        // All scores should be non-nil when embeddings are available
        for score in scores {
            XCTAssertNotNil(score)
            if let s = score {
                XCTAssertGreaterThanOrEqual(s, 0.0)
                XCTAssertLessThanOrEqual(s, 1.0)
            }
        }
    }

    func testScoreRangeValid() {
        guard EmbeddingService.isAvailable else { return }

        let claim = "Medical treatment efficacy"
        let document = "Study of drug effectiveness in clinical trials"

        if let score = EmbeddingService.computeSimilarity(claim: claim, documentText: document) {
            XCTAssertGreaterThanOrEqual(score, 0.0)
            XCTAssertLessThanOrEqual(score, 1.0)
        }
    }
}

// MARK: - FactCheckSession Pagination Tests

final class FactCheckSessionPaginationTests: XCTestCase {

    // MARK: - searchProviderEnum Tests

    func testSearchProviderEnumNilWhenNotSet() {
        let session = FactCheckSession(claim: "Test claim")
        XCTAssertNil(session.searchProviderEnum)
    }

    func testSearchProviderEnumPubMed() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        XCTAssertEqual(session.searchProviderEnum, .pubmed)
    }

    func testSearchProviderEnumEuropePMC() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "europepmc"
        XCTAssertEqual(session.searchProviderEnum, .europePMC)
    }

    func testSearchProviderEnumBoth() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "both"
        XCTAssertEqual(session.searchProviderEnum, .both)
    }

    func testSearchProviderEnumSetter() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProviderEnum = .europePMC
        XCTAssertEqual(session.searchProvider, "europepmc")
    }

    // MARK: - canFetchMoreFromAnyProvider Tests

    func testCanFetchMoreFromAnyProviderLegacyFallback() {
        // When no provider is set, falls back to PubMed offset check
        let session = FactCheckSession(claim: "Test claim")
        session.pubmedTotalResults = 100
        session.pubmedOffset = 20

        XCTAssertTrue(session.canFetchMoreFromAnyProvider)

        session.pubmedOffset = 100
        XCTAssertFalse(session.canFetchMoreFromAnyProvider)
    }

    func testCanFetchMoreFromAnyProviderPubMed() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedHasMore = true

        XCTAssertTrue(session.canFetchMoreFromAnyProvider)

        session.pubmedHasMore = false
        XCTAssertFalse(session.canFetchMoreFromAnyProvider)
    }

    func testCanFetchMoreFromAnyProviderEuropePMC() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "europepmc"
        session.europePMCHasMore = true

        XCTAssertTrue(session.canFetchMoreFromAnyProvider)

        session.europePMCHasMore = false
        XCTAssertFalse(session.canFetchMoreFromAnyProvider)
    }

    func testCanFetchMoreFromAnyProviderBoth() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "both"

        // Both have more
        session.pubmedHasMore = true
        session.europePMCHasMore = true
        XCTAssertTrue(session.canFetchMoreFromAnyProvider)

        // Only PubMed has more
        session.pubmedHasMore = true
        session.europePMCHasMore = false
        XCTAssertTrue(session.canFetchMoreFromAnyProvider)

        // Only Europe PMC has more
        session.pubmedHasMore = false
        session.europePMCHasMore = true
        XCTAssertTrue(session.canFetchMoreFromAnyProvider)

        // Neither has more
        session.pubmedHasMore = false
        session.europePMCHasMore = false
        XCTAssertFalse(session.canFetchMoreFromAnyProvider)
    }

    // MARK: - canFetchMoreDocuments Tests

    func testCanFetchMoreDocumentsAliasesAnyProvider() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedHasMore = true

        XCTAssertEqual(session.canFetchMoreDocuments, session.canFetchMoreFromAnyProvider)
    }

    // MARK: - remainingPubMedResults Tests

    func testRemainingPubMedResults() {
        let session = FactCheckSession(claim: "Test claim")
        session.pubmedTotalResults = 150
        session.pubmedOffset = 50

        XCTAssertEqual(session.remainingPubMedResults, 100)
    }

    func testRemainingPubMedResultsNeverNegative() {
        let session = FactCheckSession(claim: "Test claim")
        session.pubmedTotalResults = 50
        session.pubmedOffset = 100  // Offset exceeds total

        XCTAssertEqual(session.remainingPubMedResults, 0)
    }

    // MARK: - remainingEuropePMCResults Tests

    func testRemainingEuropePMCResultsWhenNoMore() {
        let session = FactCheckSession(claim: "Test claim")
        session.europePMCHasMore = false

        XCTAssertEqual(session.remainingEuropePMCResults, 0)
    }

    func testRemainingEuropePMCResultsWithKnownTotal() {
        let session = FactCheckSession(claim: "Test claim")
        session.europePMCHasMore = true
        session.europePMCTotalResults = 200
        session.europePMCOffset = 50

        XCTAssertEqual(session.remainingEuropePMCResults, 150)
    }

    func testRemainingEuropePMCResultsFallsBackToDefault() {
        let session = FactCheckSession(claim: "Test claim")
        session.europePMCHasMore = true
        session.europePMCTotalResults = 0
        session.europePMCOffset = 0

        // Should fall back to defaultMaxResults (20)
        XCTAssertEqual(session.remainingEuropePMCResults, SearchProviderConstants.defaultMaxResults)
    }

    // MARK: - estimatedRemainingResults Tests

    func testEstimatedRemainingResultsLegacyFallback() {
        let session = FactCheckSession(claim: "Test claim")
        session.pubmedTotalResults = 100
        session.pubmedOffset = 30

        XCTAssertEqual(session.estimatedRemainingResults, 70)
    }

    func testEstimatedRemainingResultsPubMed() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedTotalResults = 100
        session.pubmedOffset = 25
        session.pubmedHasMore = true

        XCTAssertEqual(session.estimatedRemainingResults, 75)

        session.pubmedHasMore = false
        XCTAssertEqual(session.estimatedRemainingResults, 0)
    }

    func testEstimatedRemainingResultsEuropePMC() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "europepmc"
        session.europePMCTotalResults = 80
        session.europePMCOffset = 20
        session.europePMCHasMore = true

        XCTAssertEqual(session.estimatedRemainingResults, 60)

        session.europePMCHasMore = false
        XCTAssertEqual(session.estimatedRemainingResults, 0)
    }

    func testEstimatedRemainingResultsBoth() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "both"
        session.pubmedTotalResults = 100
        session.pubmedOffset = 30
        session.pubmedHasMore = true
        session.europePMCTotalResults = 50
        session.europePMCOffset = 10
        session.europePMCHasMore = true

        // PubMed: 70, Europe PMC: 40, Total: 110
        XCTAssertEqual(session.estimatedRemainingResults, 110)
    }

    // MARK: - canGetMoreEvidence Tests

    func testCanGetMoreEvidenceWithResults() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedHasMore = true
        session.smartSearchEnabled = true

        XCTAssertTrue(session.canGetMoreEvidence)
    }

    func testCanGetMoreEvidenceWithSmartSearch() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedHasMore = false
        session.smartSearchEnabled = false

        // Smart search not yet tried
        XCTAssertTrue(session.canGetMoreEvidence)

        session.smartSearchEnabled = true
        XCTAssertFalse(session.canGetMoreEvidence)
    }

    // MARK: - totalFetchedDocuments Tests

    func testTotalFetchedDocumentsEmpty() {
        let session = FactCheckSession(claim: "Test claim")
        XCTAssertEqual(session.totalFetchedDocuments, 0)
    }

    func testTotalFetchedDocumentsNilDocuments() {
        let session = FactCheckSession(claim: "Test claim")
        session.documents = nil
        XCTAssertEqual(session.totalFetchedDocuments, 0)
    }
}

// MARK: - StructuredQuery Tests

final class StructuredQueryTests: XCTestCase {

    // MARK: - SearchConcept Tests

    func testSearchConceptIsEmpty() {
        let emptyConcept = SearchConcept(name: "empty")
        XCTAssertTrue(emptyConcept.isEmpty)

        let withMesh = SearchConcept(name: "test", meshTerms: ["Term1"])
        XCTAssertFalse(withMesh.isEmpty)

        let withKeywords = SearchConcept(name: "test", keywords: ["keyword1"])
        XCTAssertFalse(withKeywords.isEmpty)
    }

    func testSearchConceptAllTerms() {
        let concept = SearchConcept(
            name: "test",
            meshTerms: ["MeSH1", "MeSH2"],
            keywords: ["kw1", "kw2"]
        )
        XCTAssertEqual(concept.allTerms, ["MeSH1", "MeSH2", "kw1", "kw2"])
    }

    // MARK: - StructuredQuery Tests

    func testStructuredQueryIsEmpty() {
        let emptyQuery = StructuredQuery(concepts: [])
        XCTAssertTrue(emptyQuery.isEmpty)

        let queryWithEmptyConcepts = StructuredQuery(concepts: [
            SearchConcept(name: "empty1"),
            SearchConcept(name: "empty2")
        ])
        XCTAssertTrue(queryWithEmptyConcepts.isEmpty)

        let validQuery = StructuredQuery(concepts: [
            SearchConcept(name: "valid", meshTerms: ["Term"])
        ])
        XCTAssertFalse(validQuery.isEmpty)
    }

    func testStructuredQueryParseValidJSON() {
        let json = """
        {
          "concepts": [
            {"name": "amlodipine", "mesh_terms": ["Amlodipine"], "keywords": ["amlodipine"]},
            {"name": "arterial stiffness", "mesh_terms": ["Vascular Stiffness"], "keywords": ["arterial stiffness"]}
          ]
        }
        """

        let query = StructuredQuery.parse(from: json)
        XCTAssertNotNil(query)
        XCTAssertEqual(query?.concepts.count, 2)
        XCTAssertEqual(query?.concepts[0].name, "amlodipine")
        XCTAssertEqual(query?.concepts[0].meshTerms, ["Amlodipine"])
        XCTAssertEqual(query?.concepts[1].name, "arterial stiffness")
    }

    func testStructuredQueryParseMarkdownWrappedJSON() {
        let json = """
        Here's the query:
        ```json
        {
          "concepts": [
            {"name": "test", "mesh_terms": ["TestMeSH"], "keywords": ["testkw"]}
          ]
        }
        ```
        That's it!
        """

        let query = StructuredQuery.parse(from: json)
        XCTAssertNotNil(query)
        XCTAssertEqual(query?.concepts.count, 1)
        XCTAssertEqual(query?.concepts[0].name, "test")
    }

    func testStructuredQueryParseInvalidJSON() {
        let invalid = "This is not JSON at all"
        XCTAssertNil(StructuredQuery.parse(from: invalid))

        let malformed = "{\"concepts\": [}"
        XCTAssertNil(StructuredQuery.parse(from: malformed))
    }

    // MARK: - DateRange Tests

    func testDateRangeLastYears() {
        let range = DateRange.lastYears(5)
        let currentYear = Calendar.current.component(.year, from: Date())

        XCTAssertEqual(range.endYear, currentYear)
        XCTAssertEqual(range.startYear, currentYear - 5)
    }
}

// MARK: - Query Builder Tests

final class QueryBuilderTests: XCTestCase {

    // MARK: - PubMed Query Builder Tests

    func testPubMedQueryBuilderEmptyQuery() {
        let emptyQuery = StructuredQuery(concepts: [])
        let result = PubMedQueryBuilder.build(from: emptyQuery)
        XCTAssertEqual(result, QueryConstants.pubmedHasAbstractFilter)
    }

    func testPubMedQueryBuilderSingleConcept() {
        let query = StructuredQuery(concepts: [
            SearchConcept(name: "amlodipine", meshTerms: ["Amlodipine"], keywords: ["amlodipine"])
        ])

        let result = PubMedQueryBuilder.build(from: query)

        // Should contain MeSH term with tag
        XCTAssertTrue(result.contains("\"Amlodipine\"[MeSH]"))
        // Should contain keyword with tiab tag
        XCTAssertTrue(result.contains("amlodipine[tiab]"))
        // Should contain abstract filter
        XCTAssertTrue(result.contains("hasabstract"))
        // Should exclude non-article publication types (exclude-list approach)
        XCTAssertTrue(result.contains("NOT ("))
        XCTAssertTrue(result.contains("Editorial[pt]"))
    }

    func testPubMedQueryBuilderMultipleConcepts() {
        let query = StructuredQuery(concepts: [
            SearchConcept(name: "drug", meshTerms: ["Amlodipine"]),
            SearchConcept(name: "condition", meshTerms: ["Hypertension"])
        ])

        let result = PubMedQueryBuilder.build(from: query)

        // Should have AND between concepts
        XCTAssertTrue(result.contains(") AND ("))
        // Should contain both MeSH terms
        XCTAssertTrue(result.contains("\"Amlodipine\"[MeSH]"))
        XCTAssertTrue(result.contains("\"Hypertension\"[MeSH]"))
    }

    func testPubMedQueryBuilderRespectsTermLimits() {
        let query = StructuredQuery(concepts: [
            SearchConcept(
                name: "many terms",
                meshTerms: ["Term1", "Term2", "Term3", "Term4", "Term5"],
                keywords: ["kw1", "kw2", "kw3", "kw4", "kw5"]
            )
        ])

        let result = PubMedQueryBuilder.build(from: query)

        // Should only include first 3 MeSH terms (per QueryConstants.maxMeSHTermsPerConcept)
        XCTAssertTrue(result.contains("\"Term1\"[MeSH]"))
        XCTAssertTrue(result.contains("\"Term2\"[MeSH]"))
        XCTAssertTrue(result.contains("\"Term3\"[MeSH]"))
        XCTAssertFalse(result.contains("\"Term4\"[MeSH]"))
        XCTAssertFalse(result.contains("\"Term5\"[MeSH]"))

        // Should only include first 3 keywords (per QueryConstants.maxKeywordsPerConcept)
        XCTAssertTrue(result.contains("kw1[tiab]"))
        XCTAssertTrue(result.contains("kw2[tiab]"))
        XCTAssertTrue(result.contains("kw3[tiab]"))
        XCTAssertFalse(result.contains("kw4[tiab]"))
        XCTAssertFalse(result.contains("kw5[tiab]"))
    }

    // MARK: - Europe PMC Query Builder Tests

    func testEuropePMCQueryBuilderEmptyQuery() {
        let emptyQuery = StructuredQuery(concepts: [])
        let result = EuropePMCQueryBuilder.build(from: emptyQuery)
        XCTAssertEqual(result, QueryConstants.europePMCHasAbstractFilter)
    }

    func testEuropePMCQueryBuilderSingleConcept() {
        let query = StructuredQuery(concepts: [
            SearchConcept(name: "amlodipine", meshTerms: ["Amlodipine"], keywords: ["amlodipine"])
        ])

        let result = EuropePMCQueryBuilder.build(from: query)

        // Should contain MeSH in TITLE_ABS field (quoted)
        XCTAssertTrue(result.contains("TITLE_ABS:\"Amlodipine\""))
        // Should contain keyword in TITLE_ABS field (keywords are always quoted)
        XCTAssertTrue(result.contains("TITLE_ABS:\"amlodipine\""))
        // Should contain abstract filter
        XCTAssertTrue(result.contains("HAS_ABSTRACT:y"))
        // Should exclude preprints by default
        XCTAssertTrue(result.contains("NOT SRC:PPR"))
    }

    func testEuropePMCQueryBuilderIncludePreprints() {
        let query = StructuredQuery(
            concepts: [
                SearchConcept(name: "test", meshTerms: ["Test"])
            ],
            excludePreprints: false
        )

        let result = EuropePMCQueryBuilder.build(from: query)

        // Should NOT contain preprint exclusion
        XCTAssertFalse(result.contains("NOT SRC:PPR"))
    }

    func testEuropePMCQueryBuilderNoAbstractFilter() {
        let query = StructuredQuery(
            concepts: [
                SearchConcept(name: "test", meshTerms: ["Test"])
            ],
            requireAbstract: false
        )

        let result = EuropePMCQueryBuilder.build(from: query)

        // Should NOT contain abstract filter at the end
        // (It should still have the base query but without HAS_ABSTRACT:y as a filter)
        XCTAssertTrue(result.contains("TITLE_ABS:\"Test\""))
        XCTAssertFalse(result.contains("HAS_ABSTRACT:y"))
    }

    // MARK: - QueryBuilderFactory Tests

    func testQueryBuilderFactoryRoutesPubMed() {
        let query = StructuredQuery(concepts: [
            SearchConcept(name: "test", meshTerms: ["Test"])
        ])

        let result = QueryBuilderFactory.build(from: query, for: .pubmed)

        // Should use PubMed syntax
        XCTAssertTrue(result.contains("[MeSH]"))
        XCTAssertFalse(result.contains("TITLE_ABS:"))
    }

    func testQueryBuilderFactoryRoutesEuropePMC() {
        let query = StructuredQuery(concepts: [
            SearchConcept(name: "test", meshTerms: ["Test"])
        ])

        let result = QueryBuilderFactory.build(from: query, for: .europePMC)

        // Should use Europe PMC syntax
        XCTAssertTrue(result.contains("TITLE_ABS:"))
        XCTAssertFalse(result.contains("[MeSH]"))
    }

    func testQueryBuilderFactoryBothDefaultsToPubMed() {
        let query = StructuredQuery(concepts: [
            SearchConcept(name: "test", meshTerms: ["Test"])
        ])

        let result = QueryBuilderFactory.build(from: query, for: .both)

        // Should default to PubMed syntax for "both"
        XCTAssertTrue(result.contains("[MeSH]"))
    }
}

// MARK: - ResponseParser Structured Query Tests

final class ResponseParserStructuredQueryTests: XCTestCase {

    func testParseStructuredQueryArrayValidJSON() {
        let json = """
        [
          {"concepts": [{"name": "drug", "mesh_terms": ["Aspirin"], "keywords": ["aspirin"]}]},
          {"concepts": [{"name": "condition", "mesh_terms": ["Pain"], "keywords": ["pain relief"]}]}
        ]
        """

        let queries = ResponseParser.parseStructuredQueryArray(json)

        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(queries[0].concepts[0].name, "drug")
        XCTAssertEqual(queries[0].concepts[0].meshTerms, ["Aspirin"])
        XCTAssertEqual(queries[1].concepts[0].name, "condition")
    }

    func testParseStructuredQueryArrayMarkdownWrapped() {
        let json = """
        Here are the queries:
        ```json
        [
          {"concepts": [{"name": "test", "mesh_terms": ["TestMeSH"], "keywords": []}]}
        ]
        ```
        """

        let queries = ResponseParser.parseStructuredQueryArray(json)

        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries[0].concepts[0].name, "test")
    }

    func testParseStructuredQueryArraySkipsEmptyConcepts() {
        let json = """
        [
          {"concepts": [{"name": "valid", "mesh_terms": ["Term"], "keywords": []}]},
          {"concepts": [{"name": "empty", "mesh_terms": [], "keywords": []}]}
        ]
        """

        let queries = ResponseParser.parseStructuredQueryArray(json)

        // Should only have 1 query since the second one has empty concepts
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries[0].concepts[0].name, "valid")
    }

    func testParseStructuredQueryArrayInvalidJSON() {
        let invalid = "Not valid JSON"
        let queries = ResponseParser.parseStructuredQueryArray(invalid)
        XCTAssertTrue(queries.isEmpty)
    }

    func testParseStructuredQueryArrayEmptyArray() {
        let json = "[]"
        let queries = ResponseParser.parseStructuredQueryArray(json)
        XCTAssertTrue(queries.isEmpty)
    }

    func testParseStructuredQueryArrayMissingConceptsKey() {
        let json = """
        [
          {"name": "no concepts key"}
        ]
        """

        let queries = ResponseParser.parseStructuredQueryArray(json)
        XCTAssertTrue(queries.isEmpty)
    }
}

// MARK: - QueryConstants Tests

final class QueryConstantsTests: XCTestCase {

    func testTermLimitsArePositive() {
        XCTAssertGreaterThan(QueryConstants.maxMeSHTermsPerConcept, 0)
        XCTAssertGreaterThan(QueryConstants.maxKeywordsPerConcept, 0)
    }

    func testPublicationTypesNotEmpty() {
        XCTAssertFalse(QueryConstants.pubmedIncludedPublicationTypes.isEmpty)
        XCTAssertFalse(QueryConstants.excludedPublicationTypes.isEmpty)
    }

    func testPubMedFieldTagsNotEmpty() {
        XCTAssertFalse(QueryConstants.pubmedMeSHFieldTag.isEmpty)
        XCTAssertFalse(QueryConstants.pubmedTitleAbstractFieldTag.isEmpty)
        XCTAssertFalse(QueryConstants.pubmedHasAbstractFilter.isEmpty)
    }

    func testEuropePMCFieldsNotEmpty() {
        XCTAssertFalse(QueryConstants.europePMCTitleAbstractField.isEmpty)
        XCTAssertFalse(QueryConstants.europePMCHasAbstractFilter.isEmpty)
        XCTAssertFalse(QueryConstants.europePMCExcludePreprintsFilter.isEmpty)
    }
}

// MARK: - Pagination State Tests (Phase 4)

final class OffsetPaginationStateTests: XCTestCase {

    func testFetchedCount() {
        let state = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        XCTAssertEqual(state.fetchedCount, 30)
    }

    func testHasMoreWhenResultsRemain() {
        let state = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        XCTAssertTrue(state.hasMore)
    }

    func testHasMoreWhenExhausted() {
        let state = OffsetPaginationState(totalCount: 100, offset: 90, batchSize: 10)
        XCTAssertFalse(state.hasMore)
    }

    func testHasMoreWhenExactlyAtEnd() {
        let state = OffsetPaginationState(totalCount: 50, offset: 40, batchSize: 10)
        XCTAssertFalse(state.hasMore)
    }

    func testLogicalOffset() {
        let state = OffsetPaginationState(totalCount: 100, offset: 40, batchSize: 20)
        XCTAssertEqual(state.logicalOffset, 40)
    }

    func testNextOffset() {
        let state = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 15)
        XCTAssertEqual(state.nextOffset, 35)
    }

    func testEquatable() {
        let state1 = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let state2 = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let state3 = OffsetPaginationState(totalCount: 100, offset: 30, batchSize: 10)

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }
}

final class CursorPaginationStateTests: XCTestCase {

    func testInitialCursor() {
        XCTAssertEqual(CursorPaginationState.initialCursor, "*")
    }

    func testHasMoreWithNextCursor() {
        let state = CursorPaginationState(
            totalCount: 100,
            fetchedCount: 20,
            currentCursor: "*",
            nextCursor: "AoJxyz123"
        )
        XCTAssertTrue(state.hasMore)
    }

    func testHasMoreWithNilCursor() {
        let state = CursorPaginationState(
            totalCount: 100,
            fetchedCount: 100,
            currentCursor: "AoJxyz123",
            nextCursor: nil
        )
        XCTAssertFalse(state.hasMore)
    }

    func testHasMoreWhenFetchedEqualsTotal() {
        let state = CursorPaginationState(
            totalCount: 50,
            fetchedCount: 50,
            currentCursor: "*",
            nextCursor: "sometoken"  // Even with next cursor, should be false
        )
        XCTAssertFalse(state.hasMore)
    }

    func testLogicalOffset() {
        let state = CursorPaginationState(
            totalCount: 100,
            fetchedCount: 40,
            currentCursor: "*",
            nextCursor: nil
        )
        XCTAssertEqual(state.logicalOffset, 40)
    }

    func testInitialFactory() {
        let state = CursorPaginationState.initial()
        XCTAssertEqual(state.totalCount, 0)
        XCTAssertEqual(state.fetchedCount, 0)
        XCTAssertNil(state.currentCursor)
        XCTAssertNil(state.nextCursor)
        XCTAssertFalse(state.hasMore)
    }

    func testEquatable() {
        let state1 = CursorPaginationState(
            totalCount: 100,
            fetchedCount: 20,
            currentCursor: "*",
            nextCursor: "abc"
        )
        let state2 = CursorPaginationState(
            totalCount: 100,
            fetchedCount: 20,
            currentCursor: "*",
            nextCursor: "abc"
        )
        let state3 = CursorPaginationState(
            totalCount: 100,
            fetchedCount: 20,
            currentCursor: "*",
            nextCursor: "xyz"
        )

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }
}

final class CombinedPaginationStateTests: XCTestCase {

    func testTotalCountCombinesBoth() {
        let pubmed = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let europePMC = CursorPaginationState(
            totalCount: 50,
            fetchedCount: 15,
            currentCursor: "*",
            nextCursor: "abc"
        )
        let combined = CombinedPaginationState(
            pubmedPagination: pubmed,
            europePMCPagination: europePMC
        )

        XCTAssertEqual(combined.totalCount, 150)
    }

    func testFetchedCountCombinesBoth() {
        let pubmed = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let europePMC = CursorPaginationState(
            totalCount: 50,
            fetchedCount: 15,
            currentCursor: "*",
            nextCursor: "abc"
        )
        let combined = CombinedPaginationState(
            pubmedPagination: pubmed,
            europePMCPagination: europePMC
        )

        // PubMed: 20 + 10 = 30, Europe PMC: 15
        XCTAssertEqual(combined.fetchedCount, 45)
    }

    func testHasMoreWhenBothHaveMore() {
        let pubmed = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let europePMC = CursorPaginationState(
            totalCount: 50,
            fetchedCount: 15,
            currentCursor: "*",
            nextCursor: "abc"
        )
        let combined = CombinedPaginationState(
            pubmedPagination: pubmed,
            europePMCPagination: europePMC
        )

        XCTAssertTrue(combined.hasMore)
    }

    func testHasMoreWhenOnlyPubMedHasMore() {
        let pubmed = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let europePMC = CursorPaginationState(
            totalCount: 50,
            fetchedCount: 50,
            currentCursor: "abc",
            nextCursor: nil
        )
        let combined = CombinedPaginationState(
            pubmedPagination: pubmed,
            europePMCPagination: europePMC
        )

        XCTAssertTrue(combined.hasMore)
    }

    func testHasMoreWhenOnlyEuropePMCHasMore() {
        let pubmed = OffsetPaginationState(totalCount: 30, offset: 20, batchSize: 10)
        let europePMC = CursorPaginationState(
            totalCount: 50,
            fetchedCount: 15,
            currentCursor: "*",
            nextCursor: "abc"
        )
        let combined = CombinedPaginationState(
            pubmedPagination: pubmed,
            europePMCPagination: europePMC
        )

        XCTAssertTrue(combined.hasMore)
    }

    func testHasMoreWhenBothExhausted() {
        let pubmed = OffsetPaginationState(totalCount: 30, offset: 20, batchSize: 10)
        let europePMC = CursorPaginationState(
            totalCount: 50,
            fetchedCount: 50,
            currentCursor: "abc",
            nextCursor: nil
        )
        let combined = CombinedPaginationState(
            pubmedPagination: pubmed,
            europePMCPagination: europePMC
        )

        XCTAssertFalse(combined.hasMore)
    }

    func testNextPubMedOffset() {
        let pubmed = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let europePMC = CursorPaginationState.initial()
        let combined = CombinedPaginationState(
            pubmedPagination: pubmed,
            europePMCPagination: europePMC
        )

        XCTAssertEqual(combined.nextPubMedOffset, 30)
    }

    func testNextEuropePMCCursor() {
        let pubmed = OffsetPaginationState(totalCount: 100, offset: 0, batchSize: 10)
        let europePMC = CursorPaginationState(
            totalCount: 50,
            fetchedCount: 15,
            currentCursor: "*",
            nextCursor: "AoJxyz123"
        )
        let combined = CombinedPaginationState(
            pubmedPagination: pubmed,
            europePMCPagination: europePMC
        )

        XCTAssertEqual(combined.nextEuropePMCCursor, "AoJxyz123")
    }
}

// MARK: - UnifiedSearchResult Tests (Phase 4)

final class UnifiedSearchResultTests: XCTestCase {

    func testEmptyResultFactory() {
        let result = UnifiedSearchResult.empty(provider: .pubmed)

        XCTAssertTrue(result.articles.isEmpty)
        XCTAssertEqual(result.totalCount, 0)
        XCTAssertEqual(result.provider, .pubmed)
        XCTAssertFalse(result.hasMore)
    }

    func testEmptyResultForEuropePMC() {
        let result = UnifiedSearchResult.empty(provider: .europePMC)

        XCTAssertEqual(result.provider, .europePMC)
        XCTAssertNil(result.nextCursorMark)
    }

    func testHasMoreDelegatesToPagination() {
        let pagination = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let result = UnifiedSearchResult(
            articles: [],
            totalCount: 100,
            pagination: pagination,
            provider: .pubmed
        )

        XCTAssertTrue(result.hasMore)
    }

    func testNextCursorMarkWithCursorPagination() {
        let pagination = CursorPaginationState(
            totalCount: 100,
            fetchedCount: 20,
            currentCursor: "*",
            nextCursor: "AoJxyz123"
        )
        let result = UnifiedSearchResult(
            articles: [],
            totalCount: 100,
            pagination: pagination,
            provider: .europePMC
        )

        XCTAssertEqual(result.nextCursorMark, "AoJxyz123")
    }

    func testNextCursorMarkWithOffsetPagination() {
        let pagination = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let result = UnifiedSearchResult(
            articles: [],
            totalCount: 100,
            pagination: pagination,
            provider: .pubmed
        )

        XCTAssertNil(result.nextCursorMark)
    }

    // MARK: - Bug Fix Tests: nextOffset should return next position, not current

    func testNextOffsetWithOffsetPaginationReturnsNextPosition() {
        // Bug fix test: nextOffset should return offset + batchSize, not just offset
        let pagination = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let result = UnifiedSearchResult(
            articles: [],
            totalCount: 100,
            pagination: pagination,
            provider: .pubmed
        )

        // nextOffset should be 30 (20 + 10), not 20
        XCTAssertEqual(result.nextOffset, 30)
        XCTAssertNotEqual(result.nextOffset, pagination.logicalOffset)
    }

    func testNextOffsetWithCursorPaginationReturnsFetchedCount() {
        // For cursor pagination, nextOffset should return fetchedCount
        let pagination = CursorPaginationState(
            totalCount: 100,
            fetchedCount: 40,
            currentCursor: "*",
            nextCursor: "abc123"
        )
        let result = UnifiedSearchResult(
            articles: [],
            totalCount: 100,
            pagination: pagination,
            provider: .europePMC
        )

        XCTAssertEqual(result.nextOffset, 40)
    }

    func testNextOffsetWithCombinedPaginationReturnsNextPubMedOffset() {
        // For combined pagination, nextOffset should return PubMed's next offset
        let pubmed = OffsetPaginationState(totalCount: 100, offset: 20, batchSize: 10)
        let europePMC = CursorPaginationState(
            totalCount: 50,
            fetchedCount: 15,
            currentCursor: "*",
            nextCursor: "abc"
        )
        let combined = CombinedPaginationState(
            pubmedPagination: pubmed,
            europePMCPagination: europePMC
        )
        let result = UnifiedSearchResult(
            articles: [],
            totalCount: 150,
            pagination: combined,
            provider: .both
        )

        // Should return PubMed's next offset (30), not logical offset (20)
        XCTAssertEqual(result.nextOffset, 30)
    }

    func testNextOffsetIsConsistentWithPagination() {
        // Verify nextOffset advances correctly for subsequent pages
        let firstPage = OffsetPaginationState(totalCount: 100, offset: 0, batchSize: 20)
        let firstResult = UnifiedSearchResult(
            articles: [],
            totalCount: 100,
            pagination: firstPage,
            provider: .pubmed
        )

        // First page nextOffset should be 20
        XCTAssertEqual(firstResult.nextOffset, 20)

        // Simulate using nextOffset for second page
        let secondPage = OffsetPaginationState(totalCount: 100, offset: firstResult.nextOffset, batchSize: 20)
        let secondResult = UnifiedSearchResult(
            articles: [],
            totalCount: 100,
            pagination: secondPage,
            provider: .pubmed
        )

        // Second page nextOffset should be 40
        XCTAssertEqual(secondResult.nextOffset, 40)
    }
}

// MARK: - SearchError Tests (Phase 4)

final class SearchErrorTests: XCTestCase {

    func testPartialFailureDescription() {
        let error = SearchError.partialFailure(successfulProvider: .pubmed)
        XCTAssertTrue(error.errorDescription?.contains("PubMed") ?? false)
    }

    func testNoResultsDescription() {
        let error = SearchError.noResults
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("No results") ?? false)
    }

    func testInvalidConfigurationDescription() {
        let error = SearchError.invalidConfiguration("Missing API key")
        XCTAssertTrue(error.errorDescription?.contains("Missing API key") ?? false)
    }

    func testNetworkErrorDescription() {
        let error = SearchError.networkError("Connection timeout")
        XCTAssertTrue(error.errorDescription?.contains("Connection timeout") ?? false)
    }

    func testEquatable() {
        let error1 = SearchError.noResults
        let error2 = SearchError.noResults
        let error3 = SearchError.invalidConfiguration("test")

        XCTAssertEqual(error1, error2)
        XCTAssertNotEqual(error1, error3)
    }
}

// MARK: - Query Syntax Detection Tests (Phase 4)

final class QuerySyntaxDetectionTests: XCTestCase {

    // MARK: - isPubMedSyntax Tests

    func testIsPubMedSyntaxWithMeSHTag() {
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("\"Aspirin\"[MeSH]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("\"Aspirin\"[mesh]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("\"Aspirin\"[Mesh]"))
    }

    func testIsPubMedSyntaxWithFieldTags() {
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("aspirin[tiab]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("aspirin[ti]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("aspirin[ab]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("\"Smith J\"[au]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("JAMA[ta]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("2020[dp]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("\"Review\"[pt]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("english[la]"))
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("free full text[sb]"))
    }

    func testIsPubMedSyntaxWithHasAbstract() {
        XCTAssertTrue(QueryTranslator.isPubMedSyntax("aspirin AND hasabstract"))
    }

    func testIsPubMedSyntaxWithPlainText() {
        XCTAssertFalse(QueryTranslator.isPubMedSyntax("aspirin cardiovascular"))
        XCTAssertFalse(QueryTranslator.isPubMedSyntax("vitamin D supplementation"))
    }

    func testIsPubMedSyntaxWithEuropePMCSyntax() {
        XCTAssertFalse(QueryTranslator.isPubMedSyntax("TITLE_ABS:aspirin"))
        XCTAssertFalse(QueryTranslator.isPubMedSyntax("HAS_ABSTRACT:y"))
    }

    // MARK: - isEuropePMCSyntax Tests

    func testIsEuropePMCSyntaxWithMeSHTerm() {
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("MeSH_TERM:\"Aspirin\""))
    }

    func testIsEuropePMCSyntaxWithFieldPrefixes() {
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("TITLE_ABS:aspirin"))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("TITLE:aspirin"))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("ABSTRACT:aspirin"))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("AUTH:\"Smith J\""))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("JOURNAL:\"JAMA\""))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("PUB_YEAR:2020"))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("PUB_TYPE:\"review\""))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("LANG:\"eng\""))
    }

    func testIsEuropePMCSyntaxWithFilters() {
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("HAS_ABSTRACT:y"))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("OPEN_ACCESS:y"))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("NOT SRC:PPR"))
    }

    func testIsEuropePMCSyntaxCaseInsensitive() {
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("title_abs:aspirin"))
        XCTAssertTrue(QueryTranslator.isEuropePMCSyntax("has_abstract:y"))
    }

    func testIsEuropePMCSyntaxWithPlainText() {
        XCTAssertFalse(QueryTranslator.isEuropePMCSyntax("aspirin cardiovascular"))
        XCTAssertFalse(QueryTranslator.isEuropePMCSyntax("vitamin D supplementation"))
    }

    func testIsEuropePMCSyntaxWithPubMedSyntax() {
        XCTAssertFalse(QueryTranslator.isEuropePMCSyntax("\"Aspirin\"[MeSH]"))
        XCTAssertFalse(QueryTranslator.isEuropePMCSyntax("aspirin[tiab]"))
    }
}

// MARK: - CheckpointManager Tests (Phase 2)

final class CheckpointManagerTests: XCTestCase {
    var modelContainer: ModelContainer!
    var checkpointManager: CheckpointManager!

    override func setUp() async throws {
        // Create in-memory model container for testing
        let schema = Schema([ProcessingCheckpoint.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: schema, configurations: [config])
        checkpointManager = CheckpointManager(modelContainer: modelContainer)
    }

    override func tearDown() async throws {
        modelContainer = nil
        checkpointManager = nil
    }

    func testSaveAndLoadCheckpoint() async throws {
        // Create a checkpoint using ScoringCheckpoint (Codable)
        let checkpoint = ScoringCheckpoint(pmid: "12345", score: 4, rationale: "Relevant study")
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: checkpoint
        )

        // Load the checkpoint
        let loaded: ScoringCheckpoint? = await checkpointManager.loadCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring"
        )

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.score, 4)
        XCTAssertEqual(loaded?.rationale, "Relevant study")
        XCTAssertEqual(loaded?.pmid, "12345")
        XCTAssertFalse(loaded?.isError ?? true)
    }

    func testGetCheckpointedPMIDs() async throws {
        // Save multiple checkpoints
        let checkpoint1 = ScoringCheckpoint(pmid: "12345", score: 4, rationale: "Relevant")
        let checkpoint2 = ScoringCheckpoint(pmid: "67890", score: 2, rationale: "Not relevant")

        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: checkpoint1
        )
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "67890",
            step: "scoring",
            result: checkpoint2
        )

        // Get checkpointed PMIDs
        let pmids = await checkpointManager.getCheckpointedPMIDs(sessionId: "session1", step: "scoring")

        XCTAssertTrue(pmids.contains("12345"))
        XCTAssertTrue(pmids.contains("67890"))
        XCTAssertEqual(pmids.count, 2)
    }

    func testCheckpointOverwrite() async throws {
        // Save initial checkpoint
        let initial = ScoringCheckpoint(pmid: "12345", score: 3, rationale: "Initial")
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: initial
        )

        // Overwrite with updated checkpoint
        let updated = ScoringCheckpoint(pmid: "12345", score: 5, rationale: "Updated")
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: updated
        )

        // Load and verify it was updated
        let loaded: ScoringCheckpoint? = await checkpointManager.loadCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring"
        )

        XCTAssertEqual(loaded?.score, 5)
        XCTAssertEqual(loaded?.rationale, "Updated")
    }

    func testLoadCheckpointNotFound() async throws {
        // Try to load a checkpoint that doesn't exist
        let loaded: ScoringCheckpoint? = await checkpointManager.loadCheckpoint(
            sessionId: "nonexistent",
            pmid: "12345",
            step: "scoring"
        )

        XCTAssertNil(loaded)
    }

    func testGetCheckpointedPMIDsEmpty() async throws {
        // Get PMIDs for a session with no checkpoints
        let pmids = await checkpointManager.getCheckpointedPMIDs(sessionId: "empty_session", step: "scoring")

        XCTAssertTrue(pmids.isEmpty)
    }

    func testCheckpointIsolationBySession() async throws {
        // Save checkpoints for different sessions
        let checkpoint1 = ScoringCheckpoint(pmid: "12345", score: 4, rationale: "Session 1")
        let checkpoint2 = ScoringCheckpoint(pmid: "12345", score: 2, rationale: "Session 2")

        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: checkpoint1
        )
        try await checkpointManager.saveCheckpoint(
            sessionId: "session2",
            pmid: "12345",
            step: "scoring",
            result: checkpoint2
        )

        // Verify isolation
        let loaded1: ScoringCheckpoint? = await checkpointManager.loadCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring"
        )
        let loaded2: ScoringCheckpoint? = await checkpointManager.loadCheckpoint(
            sessionId: "session2",
            pmid: "12345",
            step: "scoring"
        )

        XCTAssertEqual(loaded1?.score, 4)
        XCTAssertEqual(loaded2?.score, 2)
    }

    func testCheckpointIsolationByStep() async throws {
        // Save checkpoints for different steps
        let scoringCheckpoint = ScoringCheckpoint(pmid: "12345", score: 4, rationale: "Scoring")

        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: scoringCheckpoint
        )

        // Citation step should have no checkpoints
        let citationPmids = await checkpointManager.getCheckpointedPMIDs(
            sessionId: "session1",
            step: "citation"
        )

        XCTAssertTrue(citationPmids.isEmpty)
    }

    func testDeleteCheckpoints() async throws {
        // Save checkpoints
        let checkpoint1 = ScoringCheckpoint(pmid: "12345", score: 4, rationale: "Test 1")
        let checkpoint2 = ScoringCheckpoint(pmid: "67890", score: 3, rationale: "Test 2")

        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: checkpoint1
        )
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "67890",
            step: "scoring",
            result: checkpoint2
        )

        // Verify they exist
        let pmidsBefore = await checkpointManager.getCheckpointedPMIDs(sessionId: "session1", step: "scoring")
        XCTAssertEqual(pmidsBefore.count, 2)

        // Delete checkpoints
        try await checkpointManager.deleteCheckpoints(sessionId: "session1")

        // Verify they're gone
        let pmidsAfter = await checkpointManager.getCheckpointedPMIDs(sessionId: "session1", step: "scoring")
        XCTAssertTrue(pmidsAfter.isEmpty)
    }

    func testGetCheckpointCount() async throws {
        // Save checkpoints
        let checkpoint1 = ScoringCheckpoint(pmid: "12345", score: 4, rationale: "Test 1")
        let checkpoint2 = ScoringCheckpoint(pmid: "67890", score: 3, rationale: "Test 2")
        let checkpoint3 = ScoringCheckpoint(pmid: "11111", score: 5, rationale: "Test 3")

        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: checkpoint1
        )
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "67890",
            step: "scoring",
            result: checkpoint2
        )
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "11111",
            step: "scoring",
            result: checkpoint3
        )

        let count = await checkpointManager.getCheckpointCount(sessionId: "session1", step: "scoring")
        XCTAssertEqual(count, 3)
    }

    func testErrorCheckpointPersistence() async throws {
        // Save an error checkpoint
        let errorCheckpoint = ScoringCheckpoint(
            pmid: "12345",
            score: 0,
            rationale: "Parse error",
            isError: true,
            errorMessage: "Failed to parse LLM response"
        )

        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: errorCheckpoint
        )

        // Load and verify error data
        let loaded: ScoringCheckpoint? = await checkpointManager.loadCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring"
        )

        XCTAssertNotNil(loaded)
        XCTAssertTrue(loaded?.isError ?? false)
        XCTAssertEqual(loaded?.errorMessage, "Failed to parse LLM response")
    }
}

// MARK: - ScoringCheckpoint Tests (Phase 2)

final class ScoringCheckpointTests: XCTestCase {

    func testCreateFromScoringResultSuccess() {
        // Create a successful ScoringResult
        let result = ScoringResult.success(
            pmid: "12345",
            score: 4,
            rationale: "Highly relevant study",
            usage: nil
        )

        // Convert to checkpoint
        let checkpoint = ScoringCheckpoint(from: result)

        XCTAssertEqual(checkpoint.pmid, "12345")
        XCTAssertEqual(checkpoint.score, 4)
        XCTAssertEqual(checkpoint.rationale, "Highly relevant study")
        XCTAssertFalse(checkpoint.isError)
        XCTAssertNil(checkpoint.errorMessage)
    }

    func testCreateFromScoringResultFailure() {
        // Create a failed ScoringResult
        let result = ScoringResult.failure(
            pmid: "12345",
            error: NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "API timeout"]),
            usage: nil
        )

        // Convert to checkpoint
        let checkpoint = ScoringCheckpoint(from: result)

        XCTAssertEqual(checkpoint.pmid, "12345")
        XCTAssertEqual(checkpoint.score, 0)  // Default for errors
        XCTAssertTrue(checkpoint.isError)
        XCTAssertNotNil(checkpoint.errorMessage)
    }

    func testCreateFromScoringResultParseFailure() {
        // Create a parse failure ScoringResult
        let result = ScoringResult.parseFailure(
            pmid: "12345",
            message: "Could not extract score from response",
            usage: nil
        )

        // Convert to checkpoint
        let checkpoint = ScoringCheckpoint(from: result)

        XCTAssertEqual(checkpoint.pmid, "12345")
        XCTAssertTrue(checkpoint.isError)
        XCTAssertEqual(checkpoint.rationale, "Could not extract score from response")
    }

    func testCodableRoundTrip() throws {
        // Create a checkpoint
        let original = ScoringCheckpoint(
            pmid: "12345",
            score: 4,
            rationale: "Test rationale",
            isError: false,
            errorMessage: nil
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Decode from JSON
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ScoringCheckpoint.self, from: data)

        // Verify
        XCTAssertEqual(decoded.pmid, original.pmid)
        XCTAssertEqual(decoded.score, original.score)
        XCTAssertEqual(decoded.rationale, original.rationale)
        XCTAssertEqual(decoded.isError, original.isError)
        XCTAssertEqual(decoded.errorMessage, original.errorMessage)
    }
}

// MARK: - ProgressMessage Tests (Phase 2)

final class ProgressMessageTests: XCTestCase {

    func testProgressFraction() {
        let message = ProgressMessage(
            type: .documentCompleted,
            pmid: "12345",
            step: "scoring",
            current: 5,
            total: 20
        )

        XCTAssertEqual(message.progressFraction, 0.25, accuracy: 0.001)
    }

    func testProgressFractionZeroTotal() {
        let message = ProgressMessage(
            type: .documentCompleted,
            pmid: "12345",
            step: "scoring",
            current: 0,
            total: 0
        )

        XCTAssertEqual(message.progressFraction, 0)
    }

    func testIsError() {
        let errorMessage = ProgressMessage(
            type: .documentFailed,
            pmid: "12345",
            step: "scoring",
            current: 5,
            total: 20,
            error: "API timeout"
        )

        XCTAssertTrue(errorMessage.isError)

        let successMessage = ProgressMessage(
            type: .documentCompleted,
            pmid: "12345",
            step: "scoring",
            current: 5,
            total: 20
        )

        XCTAssertFalse(successMessage.isError)
    }
}

// MARK: - PhaseProgress Tests (Phase 2)

final class PhaseProgressTests: XCTestCase {

    func testProgressFraction() {
        var progress = PhaseProgress(step: "scoring")
        progress.total = 20
        progress.completed = 10

        XCTAssertEqual(progress.progressFraction, 0.5, accuracy: 0.001)
    }

    func testIsComplete() {
        var progress = PhaseProgress(step: "scoring")
        progress.total = 10
        progress.completed = 10

        XCTAssertTrue(progress.isComplete)

        progress.completed = 5
        XCTAssertFalse(progress.isComplete)
    }

    func testSuccessfulCount() {
        var progress = PhaseProgress(step: "scoring")
        progress.total = 20
        progress.completed = 15
        progress.skipped = 5
        progress.failed = 2

        // Successful = completed - skipped - failed = 15 - 5 - 2 = 8
        XCTAssertEqual(progress.successful, 8)
    }
}

// MARK: - ProcessingProgress Tests (Phase 2)

final class ProcessingProgressTests: XCTestCase {

    func testOverallProgress() {
        var progress = ProcessingProgress()

        progress.scoring.total = 20
        progress.scoring.completed = 10
        progress.citation.total = 10
        progress.citation.completed = 5

        // Total work: 30, completed: 15 = 50%
        XCTAssertEqual(progress.overallProgress, 0.5, accuracy: 0.001)
    }

    func testIsComplete() {
        var progress = ProcessingProgress()

        progress.scoring.total = 10
        progress.scoring.completed = 10
        progress.citation.total = 5
        progress.citation.completed = 5

        XCTAssertTrue(progress.isComplete)

        progress.citation.completed = 3
        XCTAssertFalse(progress.isComplete)
    }
}

// MARK: - Error Categorization Tests (Phase 4)

final class ErrorCategorizationTests: XCTestCase {

    // MARK: - categorizeErrorMessage Tests

    func testCategorizeNetworkErrors() {
        XCTAssertEqual(categorizeErrorMessage("Network connection failed"), .network)
        XCTAssertEqual(categorizeErrorMessage("No internet connection available"), .network)
        XCTAssertEqual(categorizeErrorMessage("Host unreachable"), .network)
        XCTAssertEqual(categorizeErrorMessage("Connection was lost"), .network)
        XCTAssertEqual(categorizeErrorMessage("Server went offline"), .network)
        XCTAssertEqual(categorizeErrorMessage("DNS lookup failed"), .network)
        XCTAssertEqual(categorizeErrorMessage("SSL certificate error"), .network)
    }

    func testCategorizeTimeoutErrors() {
        XCTAssertEqual(categorizeErrorMessage("Request timed out"), .timeout)
        XCTAssertEqual(categorizeErrorMessage("Operation timeout after 30 seconds"), .timeout)
        XCTAssertEqual(categorizeErrorMessage("The operation timed out"), .timeout)
        XCTAssertEqual(categorizeErrorMessage("Deadline exceeded"), .timeout)
    }

    func testCategorizeParsingErrors() {
        XCTAssertEqual(categorizeErrorMessage("JSON parsing error"), .parsing)
        XCTAssertEqual(categorizeErrorMessage("Failed to decode response"), .parsing)
        XCTAssertEqual(categorizeErrorMessage("XML parse error at line 5"), .parsing)
        XCTAssertEqual(categorizeErrorMessage("Invalid format: expected number"), .parsing)
        XCTAssertEqual(categorizeErrorMessage("Malformed response received"), .parsing)
        XCTAssertEqual(categorizeErrorMessage("Unexpected token in JSON"), .parsing)
    }

    func testCategorizeLLMErrors() {
        XCTAssertEqual(categorizeErrorMessage("LLM rate limit exceeded"), .llm)
        XCTAssertEqual(categorizeErrorMessage("Invalid API key"), .llm)
        XCTAssertEqual(categorizeErrorMessage("Model not found"), .llm)
        XCTAssertEqual(categorizeErrorMessage("Token limit exceeded"), .llm)
        XCTAssertEqual(categorizeErrorMessage("OpenAI service unavailable"), .llm)
        XCTAssertEqual(categorizeErrorMessage("Anthropic API error"), .llm)
        XCTAssertEqual(categorizeErrorMessage("Claude context length exceeded"), .llm)
        XCTAssertEqual(categorizeErrorMessage("Quota exceeded for this billing period"), .llm)
    }

    func testCategorizeUnknownErrors() {
        XCTAssertEqual(categorizeErrorMessage("Something went wrong"), .unknown)
        XCTAssertEqual(categorizeErrorMessage("An error occurred"), .unknown)
        XCTAssertEqual(categorizeErrorMessage("Unexpected error"), .unknown)
    }

    func testCategorizeCaseInsensitive() {
        XCTAssertEqual(categorizeErrorMessage("NETWORK ERROR"), .network)
        XCTAssertEqual(categorizeErrorMessage("Timeout Occurred"), .timeout)
        XCTAssertEqual(categorizeErrorMessage("JSON Parse Failed"), .parsing)
        XCTAssertEqual(categorizeErrorMessage("LLM SERVICE ERROR"), .llm)
    }

    // MARK: - categorizeError Tests

    func testCategorizeURLError() {
        let urlError = URLError(.notConnectedToInternet)
        XCTAssertEqual(categorizeError(urlError), .network)

        let timeoutError = URLError(.timedOut)
        XCTAssertEqual(categorizeError(timeoutError), .network)  // URLError is always network
    }

    func testCategorizeGenericError() {
        let error = NSError(
            domain: "test",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Rate limit exceeded"]
        )
        XCTAssertEqual(categorizeError(error), .llm)
    }
}

// MARK: - Error Category Tests (Phase 4)

final class ErrorCategoryTests: XCTestCase {

    func testAllCasesExist() {
        let allCases = ErrorCategory.allCases
        XCTAssertTrue(allCases.contains(.network))
        XCTAssertTrue(allCases.contains(.llm))
        XCTAssertTrue(allCases.contains(.parsing))
        XCTAssertTrue(allCases.contains(.timeout))
        XCTAssertTrue(allCases.contains(.unknown))
    }

    func testRawValues() {
        XCTAssertEqual(ErrorCategory.network.rawValue, "Network")
        XCTAssertEqual(ErrorCategory.llm.rawValue, "LLM")
        XCTAssertEqual(ErrorCategory.parsing.rawValue, "Parsing")
        XCTAssertEqual(ErrorCategory.timeout.rawValue, "Timeout")
        XCTAssertEqual(ErrorCategory.unknown.rawValue, "Unknown")
    }

    func testIconsNotEmpty() {
        for category in ErrorCategory.allCases {
            XCTAssertFalse(category.icon.isEmpty, "Icon for \(category) should not be empty")
        }
    }

    func testCodable() throws {
        let original = ErrorCategory.network
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ErrorCategory.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}

// MARK: - Transient Error Entry Tests (Phase 4)

final class TransientErrorEntryTests: XCTestCase {

    func testAutomaticCategorization() {
        let networkError = TransientErrorEntry(
            pmid: "12345",
            step: "scoring",
            message: "Network connection lost"
        )
        XCTAssertEqual(networkError.category, .network)

        let llmError = TransientErrorEntry(
            pmid: "67890",
            step: "scoring",
            message: "LLM rate limit exceeded"
        )
        XCTAssertEqual(llmError.category, .llm)
    }

    func testExplicitCategoryInitializer() {
        let error = TransientErrorEntry(
            pmid: "12345",
            step: "citation",
            message: "Custom error message",
            category: .timeout
        )

        XCTAssertEqual(error.category, .timeout)
        XCTAssertEqual(error.message, "Custom error message")
    }

    func testIdentifiable() {
        let error1 = TransientErrorEntry(
            pmid: "12345",
            step: "scoring",
            message: "Error 1"
        )
        let error2 = TransientErrorEntry(
            pmid: "12345",
            step: "scoring",
            message: "Error 1"
        )

        // Each instance should have a unique ID
        XCTAssertNotEqual(error1.id, error2.id)
    }

    func testTimestampDefault() {
        let beforeCreation = Date()
        let error = TransientErrorEntry(
            pmid: "12345",
            step: "scoring",
            message: "Test"
        )
        let afterCreation = Date()

        XCTAssertGreaterThanOrEqual(error.timestamp, beforeCreation)
        XCTAssertLessThanOrEqual(error.timestamp, afterCreation)
    }
}

// MARK: - Sort Option Tests (Phase 4)

final class SortOptionTests: XCTestCase {

    func testAllCasesExist() {
        let allCases = SortOption.allCases
        XCTAssertTrue(allCases.contains(.scoreHighToLow))
        XCTAssertTrue(allCases.contains(.scoreLowToHigh))
        XCTAssertTrue(allCases.contains(.titleAZ))
        XCTAssertTrue(allCases.contains(.titleZA))
        XCTAssertTrue(allCases.contains(.yearNewest))
        XCTAssertTrue(allCases.contains(.yearOldest))
    }

    func testRawValues() {
        XCTAssertEqual(SortOption.scoreHighToLow.rawValue, "Score (High to Low)")
        XCTAssertEqual(SortOption.scoreLowToHigh.rawValue, "Score (Low to High)")
        XCTAssertEqual(SortOption.titleAZ.rawValue, "Title (A-Z)")
        XCTAssertEqual(SortOption.titleZA.rawValue, "Title (Z-A)")
        XCTAssertEqual(SortOption.yearNewest.rawValue, "Year (Newest First)")
        XCTAssertEqual(SortOption.yearOldest.rawValue, "Year (Oldest First)")
    }

    func testAccessibilityDescriptions() {
        for option in SortOption.allCases {
            XCTAssertFalse(
                option.accessibilityDescription.isEmpty,
                "Accessibility description for \(option) should not be empty"
            )
        }
    }

    func testCodable() throws {
        let original = SortOption.yearNewest
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SortOption.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}

// MARK: - Document Sorting Tests (Phase 4)

final class DocumentSortingTests: XCTestCase {

    // Helper to create mock sortable documents
    struct MockDocument: SortableDocument {
        let score: Int?
        let title: String?
        let year: Int?
        let pmid: String  // For identification in tests

        var sortableTitle: String? { title }

        init(pmid: String, score: Int? = nil, title: String? = nil, year: Int? = nil) {
            self.pmid = pmid
            self.score = score
            self.title = title
            self.year = year
        }
    }

    func testSortByScoreHighToLow() {
        let documents = [
            MockDocument(pmid: "1", score: 3),
            MockDocument(pmid: "2", score: 5),
            MockDocument(pmid: "3", score: 1),
            MockDocument(pmid: "4", score: 4),
        ]

        let sorted = documents.sorted(by: .scoreHighToLow)

        XCTAssertEqual(sorted[0].pmid, "2")  // Score 5
        XCTAssertEqual(sorted[1].pmid, "4")  // Score 4
        XCTAssertEqual(sorted[2].pmid, "1")  // Score 3
        XCTAssertEqual(sorted[3].pmid, "3")  // Score 1
    }

    func testSortByScoreLowToHigh() {
        let documents = [
            MockDocument(pmid: "1", score: 3),
            MockDocument(pmid: "2", score: 5),
            MockDocument(pmid: "3", score: 1),
        ]

        let sorted = documents.sorted(by: .scoreLowToHigh)

        XCTAssertEqual(sorted[0].pmid, "3")  // Score 1
        XCTAssertEqual(sorted[1].pmid, "1")  // Score 3
        XCTAssertEqual(sorted[2].pmid, "2")  // Score 5
    }

    func testSortByTitleAZ() {
        let documents = [
            MockDocument(pmid: "1", title: "Zebra study"),
            MockDocument(pmid: "2", title: "Apple research"),
            MockDocument(pmid: "3", title: "Medical review"),
        ]

        let sorted = documents.sorted(by: .titleAZ)

        XCTAssertEqual(sorted[0].pmid, "2")  // Apple
        XCTAssertEqual(sorted[1].pmid, "3")  // Medical
        XCTAssertEqual(sorted[2].pmid, "1")  // Zebra
    }

    func testSortByTitleZA() {
        let documents = [
            MockDocument(pmid: "1", title: "Zebra study"),
            MockDocument(pmid: "2", title: "Apple research"),
            MockDocument(pmid: "3", title: "Medical review"),
        ]

        let sorted = documents.sorted(by: .titleZA)

        XCTAssertEqual(sorted[0].pmid, "1")  // Zebra
        XCTAssertEqual(sorted[1].pmid, "3")  // Medical
        XCTAssertEqual(sorted[2].pmid, "2")  // Apple
    }

    func testSortByYearNewest() {
        let documents = [
            MockDocument(pmid: "1", year: 2020),
            MockDocument(pmid: "2", year: 2024),
            MockDocument(pmid: "3", year: 2018),
        ]

        let sorted = documents.sorted(by: .yearNewest)

        XCTAssertEqual(sorted[0].pmid, "2")  // 2024
        XCTAssertEqual(sorted[1].pmid, "1")  // 2020
        XCTAssertEqual(sorted[2].pmid, "3")  // 2018
    }

    func testSortByYearOldest() {
        let documents = [
            MockDocument(pmid: "1", year: 2020),
            MockDocument(pmid: "2", year: 2024),
            MockDocument(pmid: "3", year: 2018),
        ]

        let sorted = documents.sorted(by: .yearOldest)

        XCTAssertEqual(sorted[0].pmid, "3")  // 2018
        XCTAssertEqual(sorted[1].pmid, "1")  // 2020
        XCTAssertEqual(sorted[2].pmid, "2")  // 2024
    }

    func testSortHandlesNilScores() {
        let documents = [
            MockDocument(pmid: "1", score: nil),
            MockDocument(pmid: "2", score: 5),
            MockDocument(pmid: "3", score: nil),
            MockDocument(pmid: "4", score: 3),
        ]

        let sorted = documents.sorted(by: .scoreHighToLow)

        // Documents with scores should come first
        XCTAssertEqual(sorted[0].pmid, "2")  // Score 5
        XCTAssertEqual(sorted[1].pmid, "4")  // Score 3
        // Nil scores treated as 0, so they come last
    }

    func testSortHandlesNilTitles() {
        let documents = [
            MockDocument(pmid: "1", title: nil),
            MockDocument(pmid: "2", title: "Beta"),
            MockDocument(pmid: "3", title: "Alpha"),
        ]

        let sorted = documents.sorted(by: .titleAZ)

        // Nil titles treated as empty string, so they sort first
        XCTAssertEqual(sorted[0].pmid, "1")  // nil (empty)
        XCTAssertEqual(sorted[1].pmid, "3")  // Alpha
        XCTAssertEqual(sorted[2].pmid, "2")  // Beta
    }

    func testSortTitleCaseInsensitive() {
        let documents = [
            MockDocument(pmid: "1", title: "zebra"),
            MockDocument(pmid: "2", title: "APPLE"),
            MockDocument(pmid: "3", title: "Banana"),
        ]

        let sorted = documents.sorted(by: .titleAZ)

        XCTAssertEqual(sorted[0].pmid, "2")  // APPLE
        XCTAssertEqual(sorted[1].pmid, "3")  // Banana
        XCTAssertEqual(sorted[2].pmid, "1")  // zebra
    }
}

// MARK: - Error Persistence Manager Tests (Phase 4)

final class ErrorPersistenceManagerTests: XCTestCase {
    var modelContainer: ModelContainer!
    var errorManager: ErrorPersistenceManager!

    override func setUp() async throws {
        // Create in-memory model container for testing
        let schema = Schema([ErrorEntry.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: schema, configurations: [config])
        errorManager = ErrorPersistenceManager(modelContainer: modelContainer)
    }

    override func tearDown() async throws {
        modelContainer = nil
        errorManager = nil
    }

    func testSaveAndLoadError() async throws {
        try await errorManager.saveError(
            pmid: "12345",
            step: "scoring",
            message: "Network connection failed",
            sessionId: "session1"
        )

        let errors = try await errorManager.loadErrors(sessionId: "session1")

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].pmid, "12345")
        XCTAssertEqual(errors[0].step, "scoring")
        XCTAssertEqual(errors[0].message, "Network connection failed")
        XCTAssertEqual(errors[0].errorCategory, .network)
    }

    func testLoadTransientErrors() async throws {
        try await errorManager.saveError(
            pmid: "12345",
            step: "scoring",
            message: "Test error",
            sessionId: "session1"
        )

        let transientErrors = try await errorManager.loadTransientErrors(sessionId: "session1")

        XCTAssertEqual(transientErrors.count, 1)
        XCTAssertEqual(transientErrors[0].pmid, "12345")
    }

    func testClearErrors() async throws {
        try await errorManager.saveError(
            pmid: "12345",
            step: "scoring",
            message: "Error 1",
            sessionId: "session1"
        )
        try await errorManager.saveError(
            pmid: "67890",
            step: "scoring",
            message: "Error 2",
            sessionId: "session1"
        )

        try await errorManager.clearErrors(sessionId: "session1")

        let errors = try await errorManager.loadErrors(sessionId: "session1")
        XCTAssertTrue(errors.isEmpty)
    }

    func testRemoveErrors() async throws {
        try await errorManager.saveError(
            pmid: "12345",
            step: "scoring",
            message: "Error 1",
            sessionId: "session1"
        )
        try await errorManager.saveError(
            pmid: "67890",
            step: "scoring",
            message: "Error 2",
            sessionId: "session1"
        )

        try await errorManager.removeErrors(pmids: ["12345"], sessionId: "session1")

        let errors = try await errorManager.loadErrors(sessionId: "session1")
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].pmid, "67890")
    }

    func testIncrementRetryCount() async throws {
        try await errorManager.saveError(
            pmid: "12345",
            step: "scoring",
            message: "Test error",
            sessionId: "session1"
        )

        try await errorManager.incrementRetryCount(pmids: ["12345"], sessionId: "session1")

        let errors = try await errorManager.loadErrors(sessionId: "session1")
        XCTAssertEqual(errors[0].retryCount, 1)

        try await errorManager.incrementRetryCount(pmids: ["12345"], sessionId: "session1")

        let errorsAfter = try await errorManager.loadErrors(sessionId: "session1")
        XCTAssertEqual(errorsAfter[0].retryCount, 2)
    }

    func testErrorCount() async throws {
        try await errorManager.saveError(
            pmid: "12345",
            step: "scoring",
            message: "Error 1",
            sessionId: "session1"
        )
        try await errorManager.saveError(
            pmid: "67890",
            step: "scoring",
            message: "Error 2",
            sessionId: "session1"
        )
        try await errorManager.saveError(
            pmid: "11111",
            step: "citation",
            message: "Error 3",
            sessionId: "session1"
        )

        let count = try await errorManager.errorCount(sessionId: "session1")
        XCTAssertEqual(count, 3)
    }

    func testErrorCountsByCategory() async throws {
        try await errorManager.saveError(
            pmid: "12345",
            step: "scoring",
            message: "Network connection failed",
            sessionId: "session1"
        )
        try await errorManager.saveError(
            pmid: "67890",
            step: "scoring",
            message: "Request timed out",
            sessionId: "session1"
        )
        try await errorManager.saveError(
            pmid: "11111",
            step: "scoring",
            message: "Server offline",
            sessionId: "session1"
        )

        let counts = try await errorManager.errorCountsByCategory(sessionId: "session1")

        XCTAssertEqual(counts[.network], 2)
        XCTAssertEqual(counts[.timeout], 1)
    }

    func testSessionIsolation() async throws {
        try await errorManager.saveError(
            pmid: "12345",
            step: "scoring",
            message: "Error for session 1",
            sessionId: "session1"
        )
        try await errorManager.saveError(
            pmid: "67890",
            step: "scoring",
            message: "Error for session 2",
            sessionId: "session2"
        )

        let session1Errors = try await errorManager.loadErrors(sessionId: "session1")
        let session2Errors = try await errorManager.loadErrors(sessionId: "session2")

        XCTAssertEqual(session1Errors.count, 1)
        XCTAssertEqual(session1Errors[0].pmid, "12345")
        XCTAssertEqual(session2Errors.count, 1)
        XCTAssertEqual(session2Errors[0].pmid, "67890")
    }

    func testGetExhaustedRetries() async throws {
        try await errorManager.saveError(
            pmid: "12345",
            step: "scoring",
            message: "Error 1",
            sessionId: "session1"
        )
        try await errorManager.saveError(
            pmid: "67890",
            step: "scoring",
            message: "Error 2",
            sessionId: "session1"
        )

        // Increment retry count for first error 3 times
        try await errorManager.incrementRetryCount(pmids: ["12345"], sessionId: "session1")
        try await errorManager.incrementRetryCount(pmids: ["12345"], sessionId: "session1")
        try await errorManager.incrementRetryCount(pmids: ["12345"], sessionId: "session1")

        let exhausted = try await errorManager.getExhaustedRetries(sessionId: "session1", maxRetries: 3)

        XCTAssertEqual(exhausted.count, 1)
        XCTAssertTrue(exhausted.contains("12345"))
        XCTAssertFalse(exhausted.contains("67890"))
    }
}
