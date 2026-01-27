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

/// Constants for the fact-checking workflow.
///
/// Centralizes magic numbers and configuration values used across
/// workflow-related services for maintainability and testability.
enum WorkflowConstants {

    // MARK: - Smart Search

    /// Minimum relevant documents before triggering smart search.
    ///
    /// When the initial search returns fewer relevant documents than this
    /// threshold, the workflow will automatically generate and execute
    /// alternative search queries to find more evidence.
    static let smartSearchThreshold = 3

    // MARK: - Concurrency

    /// Default number of concurrent requests for cloud LLM providers.
    ///
    /// Cloud providers (Anthropic, OpenAI, etc.) can handle multiple
    /// simultaneous requests. This value balances throughput with
    /// rate limit considerations.
    static let cloudConcurrencyDefault = 3

    /// Number of concurrent requests for local inference (Ollama).
    ///
    /// Local inference typically runs on a single GPU/CPU, so concurrent
    /// requests provide no speedup and may cause contention.
    static let localConcurrencyDefault = 1
}
