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

    /// Unique identifier for this usage record.
    /// Note: @Attribute(.unique) removed for CloudKit compatibility.
    var id: UUID = UUID()

    /// Which session this usage belongs to.
    var sessionId: UUID = UUID()

    /// When the usage occurred.
    var timestamp: Date = Date()

    /// Year-month string for monthly aggregation (e.g., "2024-01").
    var monthKey: String = ""

    // MARK: - Usage Details

    /// Model used for this call.
    var model: String = ""

    /// Number of input tokens.
    var inputTokens: Int = 0

    /// Number of output tokens.
    var outputTokens: Int = 0

    /// Estimated cost in USD.
    var costUSD: Double = 0.0

    /// Type of operation (scoring, citation, report, query).
    var operationType: String = ""

    // MARK: - Initialization

    /// Creates a new usage record.
    ///
    /// - Parameters:
    ///   - sessionId: The session this usage belongs to.
    ///   - model: Model used for this call.
    ///   - inputTokens: Number of input tokens.
    ///   - outputTokens: Number of output tokens.
    ///   - costUSD: Estimated cost in USD.
    ///   - operationType: Type of operation (scoring, citation, report, query).
    init(
        sessionId: UUID,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        costUSD: Double,
        operationType: String
    ) {
        self.sessionId = sessionId
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
