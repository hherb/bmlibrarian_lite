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

/// Detects appropriate concurrency levels for LLM API requests.
///
/// Analyzes the provider URL to determine whether parallel requests
/// are beneficial. Cloud APIs support concurrent requests while local
/// inference (Ollama) should use sequential processing.
public enum ConcurrencyDetector {
    /// Detect appropriate concurrency level based on provider URL.
    ///
    /// Examines the URL host to determine if the provider supports
    /// parallel requests. Cloud providers get the default cloud concurrency,
    /// while local providers (localhost, Ollama) use sequential processing.
    ///
    /// - Parameters:
    ///   - providerURL: The LLM API endpoint URL.
    ///   - userOverride: Optional user-specified concurrency level.
    ///     When provided, this value takes precedence over auto-detection.
    /// - Returns: Number of concurrent requests to allow (1 for sequential).
    ///
    /// ## Examples
    ///
    /// ```swift
    /// // Cloud provider - returns 3 (default cloud concurrency)
    /// let anthropicURL = URL(string: "https://api.anthropic.com/v1")!
    /// let level = ConcurrencyDetector.detectConcurrency(providerURL: anthropicURL)
    /// // level == 3
    ///
    /// // Local provider - returns 1 (sequential)
    /// let ollamaURL = URL(string: "http://localhost:11434")!
    /// let level = ConcurrencyDetector.detectConcurrency(providerURL: ollamaURL)
    /// // level == 1
    ///
    /// // User override takes precedence
    /// let level = ConcurrencyDetector.detectConcurrency(
    ///     providerURL: anthropicURL,
    ///     userOverride: 5
    /// )
    /// // level == 5
    /// ```
    public static func detectConcurrency(
        providerURL: URL,
        userOverride: Int? = nil
    ) -> Int {
        // User override always takes precedence
        if let override = userOverride, override > 0 {
            return override
        }

        guard let host = providerURL.host?.lowercased() else {
            // No host (invalid URL) - default to sequential for safety
            return ParallelProcessingConstants.concurrencySequential
        }

        // Check for local/sequential-only hosts first
        if isLocalHost(host) {
            return ParallelProcessingConstants.concurrencySequential
        }

        // Check for known cloud providers
        if isCloudProvider(host) {
            return ParallelProcessingConstants.concurrencyCloudDefault
        }

        // Unknown provider - default to sequential for safety
        // This prevents accidentally overwhelming unknown APIs
        return ParallelProcessingConstants.concurrencySequential
    }

    /// Check if a provider URL represents a cloud API.
    ///
    /// - Parameter providerURL: The LLM API endpoint URL.
    /// - Returns: True if the provider is a known cloud API.
    public static func isCloudProvider(_ providerURL: URL) -> Bool {
        guard let host = providerURL.host?.lowercased() else {
            return false
        }
        return isCloudProvider(host)
    }

    /// Check if a provider URL represents a local inference server.
    ///
    /// - Parameter providerURL: The LLM API endpoint URL.
    /// - Returns: True if the provider is a local server (localhost, Ollama, etc.).
    public static func isLocalProvider(_ providerURL: URL) -> Bool {
        guard let host = providerURL.host?.lowercased() else {
            return false
        }
        return isLocalHost(host)
    }

    // MARK: - Private Helpers

    /// Check if a hostname matches any known cloud provider.
    private static func isCloudProvider(_ host: String) -> Bool {
        for provider in ParallelProcessingConstants.parallelProviders {
            if host.contains(provider) {
                return true
            }
        }
        return false
    }

    /// Check if a hostname indicates a local server.
    private static func isLocalHost(_ host: String) -> Bool {
        for pattern in ParallelProcessingConstants.sequentialHostPatterns {
            if host.contains(pattern) {
                return true
            }
        }
        return false
    }
}
