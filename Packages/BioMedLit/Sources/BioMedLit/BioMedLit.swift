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

/// BioMedLit: A Swift library for biomedical literature retrieval and parsing.
///
/// This library provides services for:
/// - Searching PubMed and Europe PMC databases
/// - Retrieving full-text articles from multiple sources
/// - Parsing JATS XML to HTML and markdown formats
///
/// ## Usage
///
/// ```swift
/// import BioMedLit
///
/// // Configure the library
/// let config = BioMedLitConfiguration(ncbiEmail: "your@email.com")
/// BioMedLit.configure(with: config)
///
/// // Search for articles
/// let searchService = EuropePMCService()
/// let results = try await searchService.search(query: "COVID-19 treatment")
///
/// // Get full text
/// let fullTextService = FullTextService(email: config.ncbiEmail)
/// let fullText = try await fullTextService.fetchFullText(pmcId: "PMC1234567", doi: nil, pmid: "12345678")
/// ```
public enum BioMedLit {
    /// Current version of the BioMedLit library.
    public static let version = "1.0.0"

    /// Shared configuration for the library.
    private(set) static var configuration: BioMedLitConfiguration?

    /// Configure the BioMedLit library.
    ///
    /// Call this method once at app startup to configure logging and other settings.
    ///
    /// - Parameter config: The configuration to use.
    public static func configure(with config: BioMedLitConfiguration) {
        configuration = config
    }

    /// Get the configured logger, or nil if not configured.
    internal static var logger: BioMedLitLogger? {
        configuration?.logger
    }
}

/// Configuration for the BioMedLit library.
public struct BioMedLitConfiguration: Sendable {
    /// Email address for NCBI/Unpaywall API identification.
    public let ncbiEmail: String

    /// Optional logger for debugging and diagnostics.
    public let logger: BioMedLitLogger?

    /// Initialize a new configuration.
    ///
    /// - Parameters:
    ///   - ncbiEmail: Email address for API identification.
    ///   - logger: Optional logger for diagnostics.
    public init(ncbiEmail: String, logger: BioMedLitLogger? = nil) {
        self.ncbiEmail = ncbiEmail
        self.logger = logger
    }
}

/// Protocol for logging within BioMedLit.
///
/// Implement this protocol to integrate BioMedLit logging with your app's
/// logging system (e.g., os_log, SwiftLog, or custom logging).
public protocol BioMedLitLogger: Sendable {
    /// Log a debug message.
    func debug(_ message: String, category: BioMedLitLogCategory)

    /// Log an informational message.
    func info(_ message: String, category: BioMedLitLogCategory)

    /// Log a warning message.
    func warning(_ message: String, category: BioMedLitLogCategory)

    /// Log an error message.
    func error(_ message: String, category: BioMedLitLogCategory)
}

/// Categories for log messages.
public enum BioMedLitLogCategory: String, Sendable {
    case parsing = "parsing"
    case network = "network"
    case fullText = "fullText"
    case search = "search"
}

/// Default logger that prints to console.
///
/// Use this for development or when you don't need custom logging integration.
public struct BioMedLitConsoleLogger: BioMedLitLogger {
    public init() {}

    public func debug(_ message: String, category: BioMedLitLogCategory) {
        #if DEBUG
        print("[BioMedLit:\(category.rawValue)] DEBUG: \(message)")
        #endif
    }

    public func info(_ message: String, category: BioMedLitLogCategory) {
        print("[BioMedLit:\(category.rawValue)] INFO: \(message)")
    }

    public func warning(_ message: String, category: BioMedLitLogCategory) {
        print("[BioMedLit:\(category.rawValue)] WARNING: \(message)")
    }

    public func error(_ message: String, category: BioMedLitLogCategory) {
        print("[BioMedLit:\(category.rawValue)] ERROR: \(message)")
    }
}
