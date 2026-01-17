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

/// Protocol for errors that can indicate whether retry is appropriate.
public protocol RetryableError: Error {
    /// Whether this error is transient and the operation should be retried.
    var isRetryable: Bool { get }
}

/// Configuration for retry behavior.
public struct RetryConfiguration: Sendable {
    /// Maximum number of retry attempts.
    public let maxAttempts: Int

    /// Initial delay between retries in seconds.
    public let initialDelay: TimeInterval

    /// Maximum delay between retries in seconds.
    public let maxDelay: TimeInterval

    /// Multiplier for exponential backoff.
    public let backoffMultiplier: Double

    /// Random jitter factor (0.0 to 1.0) to add variance to delays.
    public let jitterFactor: Double

    /// Initialize a retry configuration.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum number of retry attempts.
    ///   - initialDelay: Initial delay between retries in seconds.
    ///   - maxDelay: Maximum delay between retries in seconds.
    ///   - backoffMultiplier: Multiplier for exponential backoff.
    ///   - jitterFactor: Random jitter factor (0.0 to 1.0).
    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        backoffMultiplier: Double = 2.0,
        jitterFactor: Double = 0.2
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.jitterFactor = jitterFactor
    }

    /// Default configuration for network operations.
    public static let networkDefault = RetryConfiguration(
        maxAttempts: 3,
        initialDelay: 1.0,
        maxDelay: 30.0,
        backoffMultiplier: 2.0,
        jitterFactor: 0.2
    )

    /// Configuration for server errors (more aggressive retry).
    public static let serverError = RetryConfiguration(
        maxAttempts: 5,
        initialDelay: 5.0,
        maxDelay: 60.0,
        backoffMultiplier: 2.0,
        jitterFactor: 0.2
    )

    /// Configuration for PDF downloads (longer timeouts).
    public static let pdfDownload = RetryConfiguration(
        maxAttempts: 3,
        initialDelay: 2.0,
        maxDelay: 30.0,
        backoffMultiplier: 2.0,
        jitterFactor: 0.1
    )
}

/// Helper for retrying operations with exponential backoff.
public enum RetryHelper {
    /// Retry an async operation with exponential backoff.
    ///
    /// - Parameters:
    ///   - config: Retry configuration.
    ///   - shouldRetry: Closure to determine if an error should be retried.
    ///   - operation: The async operation to retry.
    /// - Returns: The result of the operation.
    /// - Throws: The last error if all retries fail.
    public static func retry<T>(
        config: RetryConfiguration = .networkDefault,
        shouldRetry: @escaping (Error) -> Bool = { _ in true },
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var delay = config.initialDelay

        for attempt in 1...config.maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if we should retry
                guard shouldRetry(error), attempt < config.maxAttempts else {
                    throw error
                }

                // Log the retry attempt
                BioMedLit.logger?.warning(
                    "Retry attempt \(attempt)/\(config.maxAttempts) after error: \(error.localizedDescription)",
                    category: .network
                )

                // Calculate delay with jitter
                let jitter = delay * config.jitterFactor * Double.random(in: -1...1)
                let actualDelay = min(delay + jitter, config.maxDelay)

                // Wait before retrying
                try await Task.sleep(nanoseconds: UInt64(actualDelay * 1_000_000_000))

                // Increase delay for next attempt
                delay = min(delay * config.backoffMultiplier, config.maxDelay)
            }
        }

        throw lastError ?? RetryError.maxAttemptsExceeded
    }

    /// Predicate that only retries transient/retryable errors.
    public static func retryOnlyTransient(_ error: Error) -> Bool {
        if let retryable = error as? RetryableError {
            return retryable.isRetryable
        }
        // Default to retrying network errors
        return isNetworkError(error)
    }

    /// Check if an error is a network-related error.
    private static func isNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError

        // URLError codes that are typically transient
        let transientCodes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorSecureConnectionFailed
        ]

        return nsError.domain == NSURLErrorDomain && transientCodes.contains(nsError.code)
    }
}

/// Errors that can occur during retry operations.
public enum RetryError: LocalizedError {
    case maxAttemptsExceeded

    public var errorDescription: String? {
        switch self {
        case .maxAttemptsExceeded:
            return "Maximum retry attempts exceeded"
        }
    }
}
