//
//  RetryHelper.swift
//  MedicalFactChecker
//
//  Retry utility with exponential backoff for network operations.
//

import Foundation

/// Configuration for retry behavior.
struct RetryConfiguration {
    /// Maximum number of retry attempts.
    let maxAttempts: Int

    /// Initial delay before the first retry (in seconds).
    let initialDelay: TimeInterval

    /// Maximum delay between retries (in seconds).
    let maxDelay: TimeInterval

    /// Multiplier applied to delay after each retry.
    let backoffMultiplier: Double

    /// Optional jitter factor (0.0-1.0) to randomize delays.
    let jitterFactor: Double

    /// Default configuration for network requests.
    static let networkDefault = RetryConfiguration(
        maxAttempts: 3,
        initialDelay: 1.0,
        maxDelay: 30.0,
        backoffMultiplier: 2.0,
        jitterFactor: 0.1
    )

    /// Configuration for PDF downloads (longer delays, more attempts).
    static let pdfDownload = RetryConfiguration(
        maxAttempts: 4,
        initialDelay: 2.0,
        maxDelay: 60.0,
        backoffMultiplier: 2.0,
        jitterFactor: 0.15
    )

    /// Configuration for quick retries (short operations).
    static let quick = RetryConfiguration(
        maxAttempts: 2,
        initialDelay: 0.5,
        maxDelay: 5.0,
        backoffMultiplier: 2.0,
        jitterFactor: 0.1
    )

    /// Initialize with custom configuration.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum number of retry attempts.
    ///   - initialDelay: Initial delay before the first retry (seconds).
    ///   - maxDelay: Maximum delay between retries (seconds).
    ///   - backoffMultiplier: Multiplier applied to delay after each retry.
    ///   - jitterFactor: Jitter factor (0.0-1.0) to randomize delays.
    init(
        maxAttempts: Int,
        initialDelay: TimeInterval,
        maxDelay: TimeInterval,
        backoffMultiplier: Double,
        jitterFactor: Double
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = max(0, initialDelay)
        self.maxDelay = max(initialDelay, maxDelay)
        self.backoffMultiplier = max(1.0, backoffMultiplier)
        self.jitterFactor = min(1.0, max(0.0, jitterFactor))
    }
}

/// Errors that can occur during retry operations.
enum RetryError: LocalizedError {
    /// All retry attempts exhausted.
    case exhausted(attempts: Int, lastError: Error)

    /// Operation was cancelled.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .exhausted(let attempts, let lastError):
            return "Operation failed after \(attempts) attempts: \(lastError.localizedDescription)"
        case .cancelled:
            return "Operation was cancelled"
        }
    }
}

/// Utility for retrying async operations with exponential backoff.
///
/// Implements retry logic with configurable exponential backoff and jitter
/// to handle transient network failures gracefully.
///
/// Usage:
/// ```swift
/// let result = try await RetryHelper.retry(config: .networkDefault) {
///     try await fetchData(from: url)
/// }
/// ```
enum RetryHelper {
    /// Execute an async operation with retry on failure.
    ///
    /// The operation is retried with exponential backoff when it throws an error.
    /// The delay between retries increases exponentially up to the configured maximum.
    ///
    /// - Parameters:
    ///   - config: Retry configuration specifying attempts, delays, and backoff.
    ///   - shouldRetry: Optional closure to determine if a specific error should trigger retry.
    ///                  Defaults to retrying all errors.
    ///   - operation: The async operation to execute and potentially retry.
    /// - Returns: The result of the successful operation.
    /// - Throws: `RetryError.exhausted` if all attempts fail, or the operation's error if
    ///           `shouldRetry` returns false.
    static func retry<T>(
        config: RetryConfiguration = .networkDefault,
        shouldRetry: ((Error) -> Bool)? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var currentDelay = config.initialDelay

        for attempt in 1...config.maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if we should retry this error
                if let shouldRetry = shouldRetry, !shouldRetry(error) {
                    throw error
                }

                // Don't delay after the last attempt
                if attempt < config.maxAttempts {
                    let delayWithJitter = applyJitter(delay: currentDelay, factor: config.jitterFactor)

                    AppLogger.network.debug(
                        "Retry attempt \(attempt)/\(config.maxAttempts) failed, retrying in \(String(format: "%.2f", delayWithJitter))s: \(error.localizedDescription)"
                    )

                    try await Task.sleep(nanoseconds: UInt64(delayWithJitter * 1_000_000_000))

                    // Increase delay for next attempt
                    currentDelay = min(currentDelay * config.backoffMultiplier, config.maxDelay)
                }
            }

            // Check for cancellation between attempts
            try Task.checkCancellation()
        }

        throw RetryError.exhausted(attempts: config.maxAttempts, lastError: lastError!)
    }

    /// Apply jitter to a delay value.
    ///
    /// Jitter helps prevent thundering herd problems by randomizing retry times
    /// across multiple clients.
    ///
    /// - Parameters:
    ///   - delay: The base delay value.
    ///   - factor: Jitter factor (0.0-1.0), representing the maximum percentage deviation.
    /// - Returns: Delay with random jitter applied.
    private static func applyJitter(delay: TimeInterval, factor: Double) -> TimeInterval {
        guard factor > 0 else { return delay }
        let jitterRange = delay * factor
        let jitter = Double.random(in: -jitterRange...jitterRange)
        return max(0, delay + jitter)
    }

    /// Check if an error is likely transient and worth retrying.
    ///
    /// This is a convenience predicate for common network errors that are
    /// typically transient and may succeed on retry.
    ///
    /// - Parameter error: The error to check.
    /// - Returns: True if the error is likely transient.
    static func isTransientError(_ error: Error) -> Bool {
        // URLError codes that are typically transient
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .dnsLookupFailed,
                 .cannotFindHost,
                 .secureConnectionFailed:
                return true
            default:
                return false
            }
        }

        // NSError codes for network issues
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }

        return false
    }

    /// Predicate that only retries transient network errors.
    ///
    /// Use this with the `shouldRetry` parameter when you only want to retry
    /// network-related failures, not application logic errors.
    static let retryOnlyTransient: (Error) -> Bool = { error in
        isTransientError(error)
    }
}
