// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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
import BioMedLit

/// Current step in the fact-checking workflow.
enum WorkflowStep: String, Codable, CaseIterable {
    case idle
    case convertingQuery
    case searchingPubMed
    case scoringDocuments
    case awaitingUserDecision  // Waiting for user to approve fetching more docs
    case extractingCitations
    case generatingReport
    case fetchingMoreEvidence  // Fetching additional evidence after report generation
    case completed
    case failed
    case budgetExceeded

    var displayName: String {
        switch self {
        case .idle: return "Ready"
        case .convertingQuery: return "Analyzing claim..."
        case .searchingPubMed: return "Searching PubMed..."
        case .scoringDocuments: return "Scoring documents..."
        case .awaitingUserDecision: return "Awaiting decision..."
        case .extractingCitations: return "Extracting citations..."
        case .generatingReport: return "Generating report..."
        case .fetchingMoreEvidence: return "Fetching more evidence..."
        case .completed: return "Complete"
        case .failed: return "Failed"
        case .budgetExceeded: return "Budget exceeded"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .budgetExceeded:
            return true
        default:
            return false
        }
    }

    /// Whether this step is waiting for user input (not actively processing).
    var isPaused: Bool {
        switch self {
        case .idle, .awaitingUserDecision:
            return true
        default:
            return false
        }
    }

    /// Whether this step should show a progress spinner.
    /// True for active processing states, false for terminal, paused, or idle states.
    var isProcessing: Bool {
        !isTerminal && !isPaused
    }
}

// Verdict is now imported from BioMedLit package.
// Re-export for backward compatibility.
@_exported import enum BioMedLit.Verdict

// MARK: - Verdict Extension for App Compatibility

extension Verdict {
    /// Legacy color property for backward compatibility.
    /// Maps to the `colorName` property in BioMedLit.
    var color: String {
        colorName
    }
}

/// Reason for stopping the workflow.
enum StopReason: String, Codable {
    case completed
    case userCancelled
    case budgetExceeded
    case noResults
    case apiError
}
