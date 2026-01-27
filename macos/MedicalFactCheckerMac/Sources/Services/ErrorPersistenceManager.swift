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
actor ErrorPersistenceManager {
    // MARK: - Properties

    /// SwiftData model container for persistence.
    private let modelContainer: ModelContainer

    /// Logger for error persistence operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.factcheckermac",
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

    /// Save an error with explicit Error object.
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
    @MainActor
    func loadTransientErrors(sessionId: String) throws -> [TransientErrorEntry] {
        let errors = try loadErrors(sessionId: sessionId)
        return errors.map { $0.toTransient() }
    }

    /// Get the count of errors for a session.
    @MainActor
    func errorCount(sessionId: String) throws -> Int {
        let context = modelContainer.mainContext
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(predicate: predicate)
        return try context.fetchCount(descriptor)
    }

    // MARK: - Delete Operations

    /// Clear all errors for a session.
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
    @MainActor
    func removeErrors(pmids: [String], sessionId: String) throws {
        let context = modelContainer.mainContext
        let pmidSet = Set(pmids)

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
    @MainActor
    func incrementRetryCount(pmids: [String], sessionId: String) throws {
        let context = modelContainer.mainContext
        let pmidSet = Set(pmids)

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
    @MainActor
    func errorCountsByCategory(sessionId: String) throws -> [ErrorCategory: Int] {
        let errors = try loadErrors(sessionId: sessionId)
        return Dictionary(grouping: errors, by: { $0.errorCategory })
            .mapValues { $0.count }
    }

    /// Load errors filtered by category.
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
