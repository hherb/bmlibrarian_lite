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

import Foundation

// MARK: - Budget Checker

/// Pure functions for checking budget limits.
///
/// Provides validation logic for per-run and monthly budget constraints.
/// All functions are stateless and throw `BudgetError` on violation.
///
/// ## Example
///
/// ```swift
/// do {
///     try BudgetChecker.validateBudget(
///         runUsed: 0.50,
///         runLimit: 1.00,
///         monthlyUsed: 5.00,
///         monthlyLimit: 10.00
///     )
/// } catch let error as BudgetError {
///     print("Budget exceeded: \(error.localizedDescription)")
/// }
/// ```
public enum BudgetChecker {
    /// Budget limits for validation.
    public struct Limits: Sendable {
        /// Maximum allowed cost per workflow run in USD.
        public let perRun: Double

        /// Maximum allowed cost per month in USD.
        public let monthly: Double

        /// Create budget limits.
        ///
        /// - Parameters:
        ///   - perRun: Maximum cost per run in USD.
        ///   - monthly: Maximum cost per month in USD.
        public init(perRun: Double, monthly: Double) {
            self.perRun = perRun
            self.monthly = monthly
        }
    }

    /// Current usage for budget checking.
    public struct Usage: Sendable {
        /// Cost used in the current run in USD.
        public let currentRun: Double

        /// Cost used this month in USD (excluding current run).
        public let monthlyTotal: Double

        /// Create usage data.
        ///
        /// - Parameters:
        ///   - currentRun: Cost used in current run.
        ///   - monthlyTotal: Total monthly cost (excluding current run).
        public init(currentRun: Double, monthlyTotal: Double) {
            self.currentRun = currentRun
            self.monthlyTotal = monthlyTotal
        }

        /// Total monthly usage including current run.
        public var totalMonthly: Double {
            monthlyTotal + currentRun
        }
    }

    /// Validate budget constraints.
    ///
    /// Checks both per-run and monthly budget limits. Throws an appropriate
    /// `BudgetError` if either limit is exceeded.
    ///
    /// - Parameters:
    ///   - usage: Current usage data.
    ///   - limits: Budget limits to enforce.
    /// - Throws: `BudgetError` if any limit is exceeded.
    public static func validate(usage: Usage, limits: Limits) throws {
        // Check per-run budget first (more immediate constraint)
        if usage.currentRun >= limits.perRun {
            throw BudgetError.runBudgetExceeded(
                used: usage.currentRun,
                limit: limits.perRun
            )
        }

        // Check monthly budget
        if usage.totalMonthly >= limits.monthly {
            throw BudgetError.monthlyBudgetExceeded(
                used: usage.totalMonthly,
                limit: limits.monthly
            )
        }
    }

    /// Validate budget using individual values.
    ///
    /// Convenience overload for cases where you don't want to construct
    /// `Usage` and `Limits` objects.
    ///
    /// - Parameters:
    ///   - runUsed: Cost used in the current run in USD.
    ///   - runLimit: Maximum allowed cost per run in USD.
    ///   - monthlyUsed: Total monthly cost (including current run) in USD.
    ///   - monthlyLimit: Maximum allowed cost per month in USD.
    /// - Throws: `BudgetError` if any limit is exceeded.
    public static func validateBudget(
        runUsed: Double,
        runLimit: Double,
        monthlyUsed: Double,
        monthlyLimit: Double
    ) throws {
        if runUsed >= runLimit {
            throw BudgetError.runBudgetExceeded(used: runUsed, limit: runLimit)
        }

        if monthlyUsed >= monthlyLimit {
            throw BudgetError.monthlyBudgetExceeded(used: monthlyUsed, limit: monthlyLimit)
        }
    }

    /// Check if monthly budget is exceeded before starting a workflow.
    ///
    /// Use this for pre-flight checks before initializing a new workflow.
    ///
    /// - Parameters:
    ///   - monthlyUsed: Total monthly cost in USD.
    ///   - monthlyLimit: Maximum allowed cost per month in USD.
    /// - Returns: True if budget is available (not exceeded).
    public static func hasMonthlyBudget(used: Double, limit: Double) -> Bool {
        used < limit
    }

    /// Calculate remaining budget.
    ///
    /// - Parameters:
    ///   - usage: Current usage data.
    ///   - limits: Budget limits.
    /// - Returns: Tuple of (remaining per-run, remaining monthly).
    public static func remainingBudget(usage: Usage, limits: Limits) -> (perRun: Double, monthly: Double) {
        let remainingRun = max(0, limits.perRun - usage.currentRun)
        let remainingMonthly = max(0, limits.monthly - usage.totalMonthly)
        return (remainingRun, remainingMonthly)
    }
}

// MARK: - Budget Error

/// Errors thrown when budget limits are exceeded.
///
/// Provides detailed information about which limit was exceeded
/// and the actual vs allowed amounts.
public enum BudgetError: LocalizedError, Equatable, Sendable {
    /// Per-run budget limit exceeded.
    case runBudgetExceeded(used: Double, limit: Double)

    /// Monthly budget limit exceeded.
    case monthlyBudgetExceeded(used: Double, limit: Double)

    public var errorDescription: String? {
        switch self {
        case .runBudgetExceeded(let used, let limit):
            return "Run budget exceeded: \(CostCalculator.formatCost(used)) used of \(CostCalculator.formatCost(limit)) limit"
        case .monthlyBudgetExceeded(let used, let limit):
            return "Monthly budget exceeded: \(CostCalculator.formatCost(used)) used of \(CostCalculator.formatCost(limit)) limit"
        }
    }

    /// Whether this is a monthly (vs per-run) budget error.
    public var isMonthlyLimit: Bool {
        if case .monthlyBudgetExceeded = self {
            return true
        }
        return false
    }
}
