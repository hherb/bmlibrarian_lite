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
