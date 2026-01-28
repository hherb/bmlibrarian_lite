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

/// Persisted checkpoint for resumable document processing.
///
/// Stores the result of processing a single document (scoring or citation extraction)
/// so that interrupted sessions can be resumed without reprocessing completed work.
/// Each checkpoint is uniquely identified by (sessionId, pmid, step).
///
/// ## Usage
///
/// Checkpoints are created after each document is processed:
/// ```swift
/// let checkpoint = ProcessingCheckpoint(
///     sessionId: session.id.uuidString,
///     pmid: document.pmid,
///     step: "scoring",
///     resultJSON: encodedResult
/// )
/// modelContext.insert(checkpoint)
/// ```
///
/// On session resume, existing checkpoints are loaded to skip already-processed documents.
@Model
final class ProcessingCheckpoint {
    // MARK: - Stored Properties

    /// Unique identifier for the fact-check session.
    ///
    /// Links this checkpoint to a specific FactCheckSession.
    var sessionId: String

    /// PubMed identifier of the processed document.
    ///
    /// Used to match checkpoints back to Document objects.
    var pmid: String

    /// Processing step that was completed.
    ///
    /// Valid values: "scoring", "citation"
    var step: String

    /// JSON-encoded result data.
    ///
    /// Contains the serialized processing result (e.g., ScoringCheckpoint).
    /// Using JSON string allows flexible storage of different result types.
    var resultJSON: String

    /// Timestamp when the checkpoint was created or last updated.
    var createdAt: Date

    // MARK: - Initialization

    /// Create a new processing checkpoint.
    ///
    /// - Parameters:
    ///   - sessionId: The session identifier (typically UUID string).
    ///   - pmid: The document's PubMed ID.
    ///   - step: Processing step ("scoring" or "citation").
    ///   - resultJSON: JSON-encoded result data.
    init(sessionId: String, pmid: String, step: String, resultJSON: String) {
        self.sessionId = sessionId
        self.pmid = pmid
        self.step = step
        self.resultJSON = resultJSON
        self.createdAt = Date()
    }
}
