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

/// Types of progress updates emitted during parallel processing.
///
/// Used to communicate specific events to the UI layer for responsive feedback.
enum ProgressType: Sendable {
    /// A document has started processing.
    case documentStarted

    /// A document has completed processing successfully.
    case documentCompleted

    /// A document was skipped (already checkpointed).
    case documentSkipped

    /// A document failed to process.
    case documentFailed

    /// A batch of documents has completed.
    case batchCompleted

    /// An entire processing phase has completed.
    case phaseCompleted
}

/// Progress update message for UI feedback during parallel processing.
///
/// Contains all information needed to update progress indicators:
/// - Current document being processed
/// - Overall progress (current/total)
/// - Any error information
///
/// ## Thread Safety
///
/// This struct is fully `Sendable` for safe passage across actor boundaries.
///
/// ## Example
///
/// ```swift
/// let message = ProgressMessage(
///     type: .documentCompleted,
///     pmid: "12345678",
///     step: "scoring",
///     current: 5,
///     total: 20
/// )
/// await progressDelegate?.didReceiveProgress(message)
/// ```
struct ProgressMessage: Sendable {
    /// The type of progress event.
    let type: ProgressType

    /// PubMed ID of the affected document, if applicable.
    let pmid: String?

    /// Processing step ("scoring" or "citation").
    let step: String

    /// Number of documents completed so far.
    let current: Int

    /// Total number of documents to process.
    let total: Int

    /// Error message if the document failed.
    let error: String?

    /// Create a progress message.
    ///
    /// - Parameters:
    ///   - type: The type of progress event.
    ///   - pmid: PubMed ID of the affected document.
    ///   - step: Processing step ("scoring" or "citation").
    ///   - current: Number of documents completed so far.
    ///   - total: Total number of documents to process.
    ///   - error: Optional error message for failed documents.
    init(
        type: ProgressType,
        pmid: String?,
        step: String,
        current: Int,
        total: Int,
        error: String? = nil
    ) {
        self.type = type
        self.pmid = pmid
        self.step = step
        self.current = current
        self.total = total
        self.error = error
    }

    /// Computed progress fraction (0.0 to 1.0).
    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    /// Whether this represents an error state.
    var isError: Bool {
        type == .documentFailed && error != nil
    }
}

/// Protocol for receiving progress updates during parallel processing.
///
/// Implementations should be classes (or actors) using appropriate synchronization
/// since updates may arrive from concurrent tasks. The protocol is class-bound
/// to allow weak references in closures.
///
/// ## Example Implementation
///
/// ```swift
/// @MainActor
/// class WorkflowProgressTracker: ProgressDelegate {
///     @Published var scoringProgress: ProgressMessage?
///     @Published var errors: [String] = []
///
///     func didReceiveProgress(_ message: ProgressMessage) async {
///         scoringProgress = message
///     }
///
///     func didCompletePhase(_ step: String, count: Int) async {
///         print("Completed \(step) for \(count) documents")
///     }
///
///     func didEncounterError(_ pmid: String, step: String, error: String) async {
///         errors.append("[\(pmid)] \(step): \(error)")
///     }
/// }
/// ```
protocol ProgressDelegate: AnyObject, Sendable {
    /// Called when a progress update is available.
    ///
    /// - Parameter message: The progress update details.
    func didReceiveProgress(_ message: ProgressMessage) async

    /// Called when a processing phase completes.
    ///
    /// - Parameters:
    ///   - step: The completed step ("scoring" or "citation").
    ///   - count: Number of documents processed in this phase.
    func didCompletePhase(_ step: String, count: Int) async

    /// Called when an error occurs during processing.
    ///
    /// Errors are also included in progress messages with type `.documentFailed`,
    /// but this method provides a dedicated error handling path.
    ///
    /// - Parameters:
    ///   - pmid: PubMed ID of the failed document.
    ///   - step: Processing step where the error occurred.
    ///   - error: Error description.
    func didEncounterError(_ pmid: String, step: String, error: String) async
}

/// Aggregate progress state for tracking multiple processing phases.
///
/// Useful for UI components that need to display overall progress
/// across both scoring and citation extraction phases.
struct ProcessingProgress: Sendable {
    /// Progress for the scoring phase.
    var scoring: PhaseProgress

    /// Progress for the citation extraction phase.
    var citation: PhaseProgress

    /// Overall progress across all phases (0.0 to 1.0).
    var overallProgress: Double {
        let totalWork = Double(scoring.total + citation.total)
        guard totalWork > 0 else { return 0 }
        let completedWork = Double(scoring.completed + citation.completed)
        return completedWork / totalWork
    }

    /// Whether all phases are complete.
    var isComplete: Bool {
        scoring.isComplete && citation.isComplete
    }

    /// Create initial progress state.
    init() {
        self.scoring = PhaseProgress(step: "scoring")
        self.citation = PhaseProgress(step: "citation")
    }
}

/// Progress state for a single processing phase.
struct PhaseProgress: Sendable {
    /// Processing step name.
    let step: String

    /// Total documents to process.
    var total: Int = 0

    /// Documents completed (success + skipped + failed).
    var completed: Int = 0

    /// Documents skipped (already checkpointed).
    var skipped: Int = 0

    /// Documents that failed processing.
    var failed: Int = 0

    /// Progress fraction (0.0 to 1.0).
    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    /// Whether this phase is complete.
    var isComplete: Bool {
        total > 0 && completed >= total
    }

    /// Number of successful completions.
    var successful: Int {
        completed - skipped - failed
    }
}
