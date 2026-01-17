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
        // Note: In a real test, we'd need to override the monthKey
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
        // Should contain publication type filter
        XCTAssertTrue(result.contains("Clinical Trial[pt]"))
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
        // Should contain keyword in TITLE_ABS field
        XCTAssertTrue(result.contains("TITLE_ABS:amlodipine"))
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
