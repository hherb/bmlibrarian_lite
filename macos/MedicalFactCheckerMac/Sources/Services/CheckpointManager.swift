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

/// Manages checkpoint persistence for resumable document processing.
///
/// This actor provides thread-safe operations for saving and loading processing
/// checkpoints. It wraps SwiftData operations to ensure consistency when
/// multiple documents are being processed concurrently.
///
/// ## Thread Safety
///
/// `CheckpointManager` is an actor, ensuring all database operations are
/// serialized. The `ModelContext` is created internally for the actor's
/// isolation context.
///
/// ## Usage
///
/// ```swift
/// let manager = CheckpointManager(modelContainer: container)
///
/// // Save a checkpoint after scoring
/// let checkpoint = ScoringCheckpoint(pmid: "12345", score: 4, rationale: "Relevant")
/// try await manager.saveCheckpoint(
///     sessionId: sessionId,
///     pmid: "12345",
///     step: "scoring",
///     result: checkpoint
/// )
///
/// // Load checkpoint on resume
/// if let saved: ScoringCheckpoint = await manager.loadCheckpoint(
///     sessionId: sessionId,
///     pmid: "12345",
///     step: "scoring"
/// ) {
///     // Use restored checkpoint
/// }
/// ```
actor CheckpointManager {
    // MARK: - Dependencies

    private let modelContainer: ModelContainer
    private var modelContext: ModelContext?

    // MARK: - Initialization

    /// Create a checkpoint manager with a model container.
    ///
    /// - Parameter modelContainer: The SwiftData model container for persistence.
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Private Helpers

    /// Get or create the model context for this actor.
    ///
    /// Creates a new context on first access, bound to this actor's isolation.
    private func getContext() -> ModelContext {
        if let context = modelContext {
            return context
        }
        let context = ModelContext(modelContainer)
        modelContext = context
        return context
    }

    // MARK: - Public API

    /// Save a checkpoint for a processed document.
    ///
    /// If a checkpoint already exists for the same (sessionId, pmid, step) combination,
    /// it will be updated rather than creating a duplicate.
    ///
    /// - Parameters:
    ///   - sessionId: The session identifier.
    ///   - pmid: The document's PubMed ID.
    ///   - step: Processing step ("scoring" or "citation").
    ///   - result: Codable result data to persist.
    /// - Throws: Encoding errors or SwiftData save errors.
    func saveCheckpoint<T: Codable>(
        sessionId: String,
        pmid: String,
        step: String,
        result: T
    ) throws {
        let context = getContext()

        // Encode result to JSON
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(result)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        // Capture values for predicate (SwiftData macro requirement)
        let targetSessionId = sessionId
        let targetPmid = pmid
        let targetStep = step

        // Check for existing checkpoint
        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == targetSessionId && $0.pmid == targetPmid && $0.step == targetStep
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        if let existing = try? context.fetch(descriptor).first {
            // Update existing checkpoint
            existing.resultJSON = jsonString
            existing.createdAt = Date()
        } else {
            // Insert new checkpoint
            let checkpoint = ProcessingCheckpoint(
                sessionId: sessionId,
                pmid: pmid,
                step: step,
                resultJSON: jsonString
            )
            context.insert(checkpoint)
        }

        try context.save()
    }

    /// Load a checkpoint for a specific document.
    ///
    /// - Parameters:
    ///   - sessionId: The session identifier.
    ///   - pmid: The document's PubMed ID.
    ///   - step: Processing step ("scoring" or "citation").
    /// - Returns: The decoded checkpoint data, or nil if not found.
    func loadCheckpoint<T: Codable>(
        sessionId: String,
        pmid: String,
        step: String
    ) -> T? {
        let context = getContext()

        // Capture values for predicate
        let targetSessionId = sessionId
        let targetPmid = pmid
        let targetStep = step

        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == targetSessionId && $0.pmid == targetPmid && $0.step == targetStep
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoint = try? context.fetch(descriptor).first,
              let data = checkpoint.resultJSON.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Get all PMIDs that have been checkpointed for a session and step.
    ///
    /// Used to determine which documents can be skipped on session resume.
    ///
    /// - Parameters:
    ///   - sessionId: The session identifier.
    ///   - step: Processing step ("scoring" or "citation").
    /// - Returns: Set of checkpointed PMIDs.
    func getCheckpointedPMIDs(sessionId: String, step: String) -> Set<String> {
        let context = getContext()

        // Capture values for predicate
        let targetSessionId = sessionId
        let targetStep = step

        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == targetSessionId && $0.step == targetStep
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoints = try? context.fetch(descriptor) else {
            return []
        }

        return Set(checkpoints.map { $0.pmid })
    }

    /// Delete all checkpoints for a session.
    ///
    /// Call this when a session completes successfully to clean up checkpoint data.
    ///
    /// - Parameter sessionId: The session identifier.
    /// - Throws: SwiftData delete errors.
    func deleteCheckpoints(sessionId: String) throws {
        let context = getContext()

        // Capture value for predicate
        let targetSessionId = sessionId

        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == targetSessionId
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoints = try? context.fetch(descriptor) else {
            return
        }

        for checkpoint in checkpoints {
            context.delete(checkpoint)
        }

        try context.save()
    }

    /// Get the count of checkpoints for a session and step.
    ///
    /// Useful for progress reporting when resuming a session.
    ///
    /// - Parameters:
    ///   - sessionId: The session identifier.
    ///   - step: Processing step ("scoring" or "citation").
    /// - Returns: Number of checkpoints.
    func getCheckpointCount(sessionId: String, step: String) -> Int {
        let context = getContext()

        // Capture values for predicate
        let targetSessionId = sessionId
        let targetStep = step

        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == targetSessionId && $0.step == targetStep
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        return (try? context.fetchCount(descriptor)) ?? 0
    }
}
