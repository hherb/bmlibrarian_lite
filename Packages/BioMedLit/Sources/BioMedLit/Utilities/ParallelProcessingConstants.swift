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

/// Constants for parallel processing of LLM requests.
///
/// Defines concurrency levels, provider detection, and retry configuration
/// for parallel document scoring and citation extraction.
public enum ParallelProcessingConstants {
    // MARK: - Concurrency Levels

    /// Sequential processing (one request at a time).
    ///
    /// Used for local inference providers like Ollama where parallel
    /// requests provide no benefit and may cause resource contention.
    public static let concurrencySequential = 1

    /// Moderate parallel concurrency for cloud APIs.
    ///
    /// Balances throughput with rate limit headroom. Suitable for
    /// most cloud providers under typical usage patterns.
    public static let concurrencyModerate = 3

    /// Aggressive parallel concurrency for high-throughput scenarios.
    ///
    /// Use with caution - may trigger rate limits on some providers.
    /// Best suited for providers with generous rate limits or
    /// when processing large document sets.
    public static let concurrencyAggressive = 5

    /// Default concurrency level for cloud providers.
    public static let concurrencyCloudDefault = concurrencyModerate

    // MARK: - Provider Detection

    /// Known cloud API provider hostnames that support parallel requests.
    ///
    /// These providers have infrastructure designed for concurrent requests
    /// and benefit from parallel processing. Local providers (localhost,
    /// Ollama) are excluded as they typically run on limited hardware.
    public static let parallelProviders: Set<String> = [
        "api.anthropic.com",
        "api.openai.com",
        "api.deepseek.com",
        "generativelanguage.googleapis.com",
        "api.groq.com",
        "api.together.xyz",
        "api.fireworks.ai",
        "api.mistral.ai",
        "api.cohere.ai",
    ]

    /// Hostname patterns indicating local/sequential-only providers.
    ///
    /// Requests to these hosts are processed sequentially to avoid
    /// overloading local inference hardware.
    public static let sequentialHostPatterns: [String] = [
        "localhost",
        "127.0.0.1",
        "0.0.0.0",
        "::1",
    ]

    // MARK: - Retry Configuration

    /// Base delay in seconds for exponential backoff between retries.
    public static let retryBaseDelaySeconds: Double = 1.0

    /// Maximum delay in seconds between retry attempts.
    public static let retryMaxDelaySeconds: Double = 10.0

    /// Minimum jitter multiplier for randomizing retry delays.
    ///
    /// Jitter prevents thundering herd when multiple requests fail simultaneously.
    public static let retryJitterMin: Double = 0.75

    /// Maximum jitter multiplier for randomizing retry delays.
    public static let retryJitterMax: Double = 1.25

    /// Maximum number of retry attempts for failed requests.
    public static let maxRetries = 3

    // MARK: - Batch Sizes (for future batched prompts implementation)

    /// Default number of documents per scoring prompt batch.
    public static let scoringBatchSizeDefault = 3

    /// Default number of documents per citation extraction batch.
    public static let citationBatchSizeDefault = 2
}
