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
import OSLog

/// Centralized logging facility for the application.
///
/// Uses OSLog for structured logging with support for different log levels
/// and subsystems. All log messages include timestamps and can be filtered
/// in Console.app using the subsystem identifier.
///
/// Usage:
/// ```swift
/// AppLogger.fullText.info("Fetching full text for PMC123")
/// AppLogger.fullText.error("Failed to fetch: \(error)")
/// ```
enum AppLogger {
    // MARK: - Subsystem

    /// The bundle identifier used as the OSLog subsystem.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.medicalfactchecker"

    // MARK: - Logger Instances

    /// Logger for full-text retrieval operations.
    static let fullText = Logger(subsystem: subsystem, category: "FullText")

    /// Logger for network operations.
    static let network = Logger(subsystem: subsystem, category: "Network")

    /// Logger for XML/JSON parsing operations.
    static let parsing = Logger(subsystem: subsystem, category: "Parsing")

    /// Logger for PubMed API operations.
    static let pubmed = Logger(subsystem: subsystem, category: "PubMed")

    /// Logger for search operations across providers.
    static let search = Logger(subsystem: subsystem, category: "Search")

    /// Logger for LLM service operations.
    static let llm = Logger(subsystem: subsystem, category: "LLM")

    /// Logger for embedding operations.
    static let embedding = Logger(subsystem: subsystem, category: "Embedding")

    /// Logger for general application events.
    static let general = Logger(subsystem: subsystem, category: "General")

    /// Logger for workflow orchestration.
    static let workflow = Logger(subsystem: subsystem, category: "Workflow")

    /// Logger for data persistence operations.
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
}

// MARK: - Logger Extensions

extension Logger {
    /// Log a debug message with optional context.
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - file: Source file (auto-populated).
    ///   - function: Function name (auto-populated).
    ///   - line: Line number (auto-populated).
    func debugWithContext(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let filename = (file as NSString).lastPathComponent
        self.debug("[\(filename):\(line)] \(function) - \(message)")
    }

    /// Log an error with optional context.
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - error: Optional error to include.
    ///   - file: Source file (auto-populated).
    ///   - function: Function name (auto-populated).
    ///   - line: Line number (auto-populated).
    func errorWithContext(
        _ message: String,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let filename = (file as NSString).lastPathComponent
        if let error = error {
            self.error("[\(filename):\(line)] \(function) - \(message): \(error.localizedDescription)")
        } else {
            self.error("[\(filename):\(line)] \(function) - \(message)")
        }
    }
}

// MARK: - Bundle Extension

extension Bundle {
    /// The app's marketing version (CFBundleShortVersionString).
    var marketingVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// The app's build number (CFBundleVersion).
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// A formatted version string combining marketing version and build number.
    ///
    /// Format: "X.Y.Z (Build N)" e.g., "1.3.0 (Build 3)"
    var appVersionString: String {
        "\(marketingVersion) (Build \(buildNumber))"
    }
}
