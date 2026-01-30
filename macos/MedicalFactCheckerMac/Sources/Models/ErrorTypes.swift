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
import SwiftUI

// MARK: - Error Category

/// Categories of errors that can occur during document processing.
///
/// Used to classify and filter errors in the error queue UI.
/// Each category has an associated icon and color for visual distinction.
enum ErrorCategory: String, Codable, CaseIterable, Sendable {
    case network = "Network"
    case llm = "LLM"
    case parsing = "Parsing"
    case timeout = "Timeout"
    case unknown = "Unknown"

    /// SF Symbol icon name for this error category.
    var icon: String {
        switch self {
        case .network: return "wifi.slash"
        case .llm: return "brain"
        case .parsing: return "doc.text.magnifyingglass"
        case .timeout: return "clock.badge.exclamationmark"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Display color for this error category.
    var color: Color {
        switch self {
        case .network: return Color.orange
        case .llm: return Color.purple
        case .parsing: return Color.blue
        case .timeout: return Color.yellow
        case .unknown: return Color.gray
        }
    }
}

// MARK: - Error Categorization Constants

/// Keywords used to categorize errors by type.
///
/// Centralizes the keyword lists used by both `categorizeError` and
/// `categorizeErrorMessage` functions for consistent categorization.
private enum ErrorCategoryKeywords {
    /// Keywords indicating network-related errors.
    static let networkKeywords = [
        "network", "connection", "offline", "internet", "unreachable",
        "no route", "host", "dns", "socket", "ssl", "tls", "certificate"
    ]

    /// Keywords indicating timeout errors.
    static let timeoutKeywords = ["timeout", "timed out", "deadline exceeded"]

    /// Keywords indicating parsing/decoding errors.
    static let parsingKeywords = [
        "parse", "decode", "json", "xml", "invalid format", "malformed",
        "unexpected token", "syntax error", "encoding"
    ]

    /// Keywords indicating LLM/API errors.
    static let llmKeywords = [
        "llm", "model", "api key", "rate limit", "token", "openai",
        "anthropic", "claude", "gpt", "quota", "context length"
    ]
}

// MARK: - Error Categorization Functions

/// Categorize an error based on its type and message.
///
/// Examines the error type and localized description to determine the
/// most appropriate category. URLErrors are automatically classified
/// as network errors.
///
/// - Parameter error: The error to categorize.
/// - Returns: The most appropriate error category.
func categorizeError(_ error: Error) -> ErrorCategory {
    // Check for specific error types first
    if error is URLError {
        return .network
    }

    // Fall back to message-based categorization
    return categorizeErrorMessage(error.localizedDescription)
}

/// Categorize an error from a string message.
///
/// Examines the message content to determine the most appropriate
/// error category based on keyword matching. Case-insensitive.
///
/// - Parameter message: The error message to categorize.
/// - Returns: The most appropriate error category.
func categorizeErrorMessage(_ message: String) -> ErrorCategory {
    let lowercased = message.lowercased()

    // Check network keywords
    if ErrorCategoryKeywords.networkKeywords.contains(where: { lowercased.contains($0) }) {
        return .network
    }

    // Check timeout keywords
    if ErrorCategoryKeywords.timeoutKeywords.contains(where: { lowercased.contains($0) }) {
        return .timeout
    }

    // Check parsing keywords
    if ErrorCategoryKeywords.parsingKeywords.contains(where: { lowercased.contains($0) }) {
        return .parsing
    }

    // Check LLM keywords
    if ErrorCategoryKeywords.llmKeywords.contains(where: { lowercased.contains($0) }) {
        return .llm
    }

    return .unknown
}
