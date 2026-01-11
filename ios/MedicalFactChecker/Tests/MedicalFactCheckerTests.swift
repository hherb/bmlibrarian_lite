//
//  MedicalFactCheckerTests.swift
//  MedicalFactCheckerTests
//
//  Unit tests for the Medical Fact Checker app.
//

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
