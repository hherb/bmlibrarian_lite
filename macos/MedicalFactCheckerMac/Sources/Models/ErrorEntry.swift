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
import SwiftData

// MARK: - Persistent Error Entry

/// A persistent error entry stored in SwiftData.
///
/// Tracks processing errors for documents, allowing users to review
/// failed items and retry processing after the app restarts.
@Model
final class ErrorEntry {
    /// Unique identifier for this error entry.
    var id: UUID

    /// PubMed identifier of the failed document.
    var pmid: String

    /// Processing step where the error occurred ("scoring" or "citation").
    var step: String

    /// Human-readable error message.
    var message: String

    /// Error category as raw string value (ErrorCategory.rawValue).
    var category: String

    /// When the error occurred.
    var timestamp: Date

    /// Session identifier linking this error to a FactCheckSession.
    var sessionId: String

    /// Number of times this document has been retried.
    var retryCount: Int

    /// Create a new error entry.
    ///
    /// - Parameters:
    ///   - pmid: PubMed identifier of the failed document.
    ///   - step: Processing step where the error occurred.
    ///   - message: Human-readable error message.
    ///   - category: Error category (defaults to .unknown).
    ///   - sessionId: Session identifier.
    ///   - retryCount: Number of previous retry attempts (defaults to 0).
    init(
        pmid: String,
        step: String,
        message: String,
        category: ErrorCategory = .unknown,
        sessionId: String,
        retryCount: Int = 0
    ) {
        self.id = UUID()
        self.pmid = pmid
        self.step = step
        self.message = message
        self.category = category.rawValue
        self.timestamp = Date()
        self.sessionId = sessionId
        self.retryCount = retryCount
    }

    /// The error category enum value for the stored category string.
    var errorCategory: ErrorCategory {
        ErrorCategory(rawValue: category) ?? .unknown
    }
}

// MARK: - Transient Error Entry

/// A non-persistent error entry for in-memory use.
///
/// Used for UI display when errors don't need to survive app restarts.
struct TransientErrorEntry: Identifiable, Sendable {
    /// Unique identifier for this error entry.
    let id = UUID()

    /// PubMed identifier of the failed document.
    let pmid: String

    /// Processing step where the error occurred.
    let step: String

    /// Human-readable error message.
    let message: String

    /// Automatically categorized error type.
    let category: ErrorCategory

    /// When the error occurred.
    let timestamp: Date

    /// Create a new transient error entry with automatic categorization.
    init(pmid: String, step: String, message: String, timestamp: Date = Date()) {
        self.pmid = pmid
        self.step = step
        self.message = message
        self.category = categorizeErrorMessage(message)
        self.timestamp = timestamp
    }

    /// Create a transient error entry with explicit category.
    init(pmid: String, step: String, message: String, category: ErrorCategory, timestamp: Date = Date()) {
        self.pmid = pmid
        self.step = step
        self.message = message
        self.category = category
        self.timestamp = timestamp
    }
}

// MARK: - Conversion Extension

extension ErrorEntry {
    /// Convert a persistent error entry to a transient entry for UI display.
    func toTransient() -> TransientErrorEntry {
        TransientErrorEntry(
            pmid: pmid,
            step: step,
            message: message,
            category: errorCategory,
            timestamp: timestamp
        )
    }
}
