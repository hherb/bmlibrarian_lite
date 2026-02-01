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
import os.log

// MARK: - Error Persistence Manager

/// Manages persistence of processing errors using SwiftData.
///
/// This actor provides thread-safe CRUD operations for error entries,
/// supporting the error queue UI and retry functionality.
///
/// ## Thread Safety
///
/// All operations are performed on the main actor via the `@MainActor`
/// annotation on methods that access the model context. This ensures
/// SwiftData operations happen on the correct thread.
///
/// ## Usage
///
/// ```swift
/// let manager = ErrorPersistenceManager(modelContainer: container)
///
/// // Save an error
/// try await manager.saveError(
///     pmid: "12345678",
///     step: "scoring",
///     message: "Network timeout",
///     sessionId: session.id.uuidString
/// )
///
/// // Load errors for display
/// let errors = try await manager.loadErrors(sessionId: session.id.uuidString)
/// ```
actor ErrorPersistenceManager {
    // MARK: - Properties

    /// SwiftData model container for persistence.
    private let modelContainer: ModelContainer

    /// Logger for error persistence operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.factchecker",
        category: "ErrorPersistence"
    )

    // MARK: - Initialization

    /// Create an error persistence manager.
    ///
    /// - Parameter modelContainer: The SwiftData model container.
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Save Operations

    /// Save an error to persistent storage.
    ///
    /// Creates a new ErrorEntry with automatic categorization based on
    /// the error message content.
    ///
    /// - Parameters:
    ///   - pmid: PubMed identifier of the failed document.
    ///   - step: Processing step where the error occurred.
    ///   - message: Human-readable error message.
    ///   - sessionId: Session identifier.
    /// - Throws: SwiftData errors if persistence fails.
    @MainActor
    func saveError(
        pmid: String,
        step: String,
        message: String,
        sessionId: String
    ) throws {
        let context = modelContainer.mainContext
        let category = categorizeErrorMessage(message)

        let entry = ErrorEntry(
            pmid: pmid,
            step: step,
            message: message,
            category: category,
            sessionId: sessionId
        )

        context.insert(entry)
        try context.save()

        logger.debug("Saved error for PMID \(pmid): \(message)")
    }

    /// Save an error with explicit category.
    ///
    /// Use this when you already have an Error object and want to preserve
    /// its categorization.
    ///
    /// - Parameters:
    ///   - pmid: PubMed identifier of the failed document.
    ///   - step: Processing step where the error occurred.
    ///   - error: The error that occurred.
    ///   - sessionId: Session identifier.
    /// - Throws: SwiftData errors if persistence fails.
    @MainActor
    func saveError(
        pmid: String,
        step: String,
        error: Error,
        sessionId: String
    ) throws {
        let context = modelContainer.mainContext
        let category = categorizeError(error)

        let entry = ErrorEntry(
            pmid: pmid,
            step: step,
            message: error.localizedDescription,
            category: category,
            sessionId: sessionId
        )

        context.insert(entry)
        try context.save()

        logger.debug("Saved error for PMID \(pmid): \(error.localizedDescription)")
    }

    // MARK: - Load Operations

    /// Load all errors for a session.
    ///
    /// Returns errors sorted by timestamp (most recent first).
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Array of error entries for the session.
    /// - Throws: SwiftData errors if fetch fails.
    @MainActor
    func loadErrors(sessionId: String) throws -> [ErrorEntry] {
        let context = modelContainer.mainContext
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Load errors as transient entries for UI display.
    ///
    /// Converts persistent entries to transient entries suitable for
    /// binding in SwiftUI views.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Array of transient error entries.
    /// - Throws: SwiftData errors if fetch fails.
    @MainActor
    func loadTransientErrors(sessionId: String) throws -> [TransientErrorEntry] {
        let errors = try loadErrors(sessionId: sessionId)
        return errors.map { $0.toTransient() }
    }

    /// Get the count of errors for a session.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Number of errors for the session.
    /// - Throws: SwiftData errors if fetch fails.
    @MainActor
    func errorCount(sessionId: String) throws -> Int {
        let context = modelContainer.mainContext
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(predicate: predicate)
        return try context.fetchCount(descriptor)
    }

    // MARK: - Delete Operations

    /// Clear all errors for a session.
    ///
    /// Use this when a session completes or when the user dismisses
    /// all errors from the queue.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Throws: SwiftData errors if deletion fails.
    @MainActor
    func clearErrors(sessionId: String) throws {
        let context = modelContainer.mainContext
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(predicate: predicate)
        let errors = try context.fetch(descriptor)

        for error in errors {
            context.delete(error)
        }
        try context.save()

        logger.debug("Cleared \(errors.count) errors for session \(sessionId)")
    }

    /// Remove errors for specific PMIDs.
    ///
    /// Use this when documents have been successfully retried and their
    /// errors should be removed from the queue.
    ///
    /// - Parameters:
    ///   - pmids: List of PMIDs to remove errors for.
    ///   - sessionId: Session identifier.
    /// - Throws: SwiftData errors if deletion fails.
    @MainActor
    func removeErrors(pmids: [String], sessionId: String) throws {
        let context = modelContainer.mainContext
        let pmidSet = Set(pmids)

        // Fetch all errors for session, then filter in memory
        // (SwiftData predicates don't support Set.contains)
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(predicate: predicate)
        let allErrors = try context.fetch(descriptor)

        let matchingErrors = allErrors.filter { pmidSet.contains($0.pmid) }
        for error in matchingErrors {
            context.delete(error)
        }
        try context.save()

        logger.debug("Removed errors for \(matchingErrors.count) PMIDs")
    }

    // MARK: - Retry Tracking

    /// Increment retry count for specific PMIDs.
    ///
    /// Call this before retrying failed documents to track how many
    /// times each document has been retried.
    ///
    /// - Parameters:
    ///   - pmids: List of PMIDs to update.
    ///   - sessionId: Session identifier.
    /// - Throws: SwiftData errors if update fails.
    @MainActor
    func incrementRetryCount(pmids: [String], sessionId: String) throws {
        let context = modelContainer.mainContext
        let pmidSet = Set(pmids)

        // Fetch all errors for session, then filter in memory
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(predicate: predicate)
        let allErrors = try context.fetch(descriptor)

        let matchingErrors = allErrors.filter { pmidSet.contains($0.pmid) }
        for error in matchingErrors {
            error.retryCount += 1
        }
        try context.save()

        logger.debug("Incremented retry count for \(matchingErrors.count) errors")
    }

    /// Get errors that have exceeded the maximum retry count.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - maxRetries: Maximum number of retries allowed.
    /// - Returns: PMIDs of errors that have exceeded the retry limit.
    /// - Throws: SwiftData errors if fetch fails.
    @MainActor
    func getExhaustedRetries(sessionId: String, maxRetries: Int) throws -> [String] {
        let context = modelContainer.mainContext
        let predicate = #Predicate<ErrorEntry> {
            $0.sessionId == sessionId && $0.retryCount >= maxRetries
        }
        let descriptor = FetchDescriptor<ErrorEntry>(predicate: predicate)
        let errors = try context.fetch(descriptor)
        return errors.map { $0.pmid }
    }

    // MARK: - Category Queries

    /// Get error counts grouped by category for a session.
    ///
    /// Useful for displaying category filter chips in the error queue UI.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Dictionary mapping category to error count.
    /// - Throws: SwiftData errors if fetch fails.
    @MainActor
    func errorCountsByCategory(sessionId: String) throws -> [ErrorCategory: Int] {
        let errors = try loadErrors(sessionId: sessionId)
        return Dictionary(grouping: errors, by: { $0.errorCategory })
            .mapValues { $0.count }
    }

    /// Load errors filtered by category.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - category: Category to filter by.
    /// - Returns: Array of error entries matching the category.
    /// - Throws: SwiftData errors if fetch fails.
    @MainActor
    func loadErrors(sessionId: String, category: ErrorCategory) throws -> [ErrorEntry] {
        let context = modelContainer.mainContext
        let categoryRaw = category.rawValue
        let predicate = #Predicate<ErrorEntry> {
            $0.sessionId == sessionId && $0.category == categoryRaw
        }
        let descriptor = FetchDescriptor<ErrorEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }
}
