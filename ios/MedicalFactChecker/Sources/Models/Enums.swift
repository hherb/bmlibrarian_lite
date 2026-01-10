//
//  Enums.swift
//  MedicalFactChecker
//
//  Enumeration types used throughout the app.
//

import Foundation

/// Current step in the fact-checking workflow.
enum WorkflowStep: String, Codable, CaseIterable {
    case idle
    case convertingQuery
    case searchingPubMed
    case scoringDocuments
    case awaitingUserDecision  // Waiting for user to approve fetching more docs
    case extractingCitations
    case generatingReport
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
}

/// Evidence verdict for the fact-check report.
enum Verdict: String, Codable {
    case supported = "Supported"
    case partiallySupported = "Partially Supported"
    case notSupported = "Not Supported"
    case insufficientEvidence = "Insufficient Evidence"
    case conflicting = "Conflicting Evidence"

    var color: String {
        switch self {
        case .supported: return "green"
        case .partiallySupported: return "orange"
        case .notSupported: return "red"
        case .insufficientEvidence: return "gray"
        case .conflicting: return "purple"
        }
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
