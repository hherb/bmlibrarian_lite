//
//  UsageRecord.swift
//  MedicalFactChecker
//
//  Token and cost usage tracking for budget management.
//

import Foundation
import SwiftData

/// A record of LLM API usage for budget tracking.
///
/// Records are created for each LLM call and aggregated
/// to track per-run and monthly spending.
@Model
final class UsageRecord {
    // MARK: - Identification

    @Attribute(.unique) var id: UUID

    /// Which session this usage belongs to.
    var sessionId: UUID

    /// When the usage occurred.
    var timestamp: Date

    /// Year-month string for monthly aggregation (e.g., "2024-01").
    var monthKey: String

    // MARK: - Usage Details

    /// Model used for this call.
    var model: String

    /// Number of input tokens.
    var inputTokens: Int

    /// Number of output tokens.
    var outputTokens: Int

    /// Estimated cost in USD.
    var costUSD: Double

    /// Type of operation (scoring, citation, report, query).
    var operationType: String

    // MARK: - Initialization

    init(
        sessionId: UUID,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        costUSD: Double,
        operationType: String
    ) {
        self.id = UUID()
        self.sessionId = sessionId
        self.timestamp = Date()
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.operationType = operationType

        // Generate month key for aggregation
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        self.monthKey = formatter.string(from: Date())
    }
}

// MARK: - Usage Aggregation

extension UsageRecord {
    /// Calculate total cost for a given month.
    static func monthlyCost(records: [UsageRecord], monthKey: String) -> Double {
        records
            .filter { $0.monthKey == monthKey }
            .reduce(0) { $0 + $1.costUSD }
    }

    /// Calculate total cost for a session.
    static func sessionCost(records: [UsageRecord], sessionId: UUID) -> Double {
        records
            .filter { $0.sessionId == sessionId }
            .reduce(0) { $0 + $1.costUSD }
    }

    /// Get current month key.
    static var currentMonthKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }
}
