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

    /// How many more times the model is asked for alternative queries when its
    /// answer holds none that can be used.
    ///
    /// An answer that does not parse as a list of queries, or that has no
    /// content, is asked for again — each time a paid call (user's decision,
    /// 2026-09-16). When no answer is usable, smart search is marked as tried,
    /// so no later batch asks and pays again.
    static let maxQueryRetries = 2

    /// Most failed document titles to name in a user-facing notice before counting.
    ///
    /// Above this the notice reports a count instead. Naming is more useful —
    /// the reader can tell which document is missing a result — but a notice
    /// long enough to be skipped reports nothing at all.
    static let maxFailedTitlesToName = 3

    // MARK: - Automatic Full-Text Retrieval

    /// Lowest relevance score (1-5) whose papers are fetched in full when the
    /// automatic full-text setting is on.
    ///
    /// Scores 4 and 5 are the papers that shape the report most, so they are
    /// the ones where the full text (methods, results, funding, conflicts) is
    /// worth the retrieval time. Never lowers the user's own relevance
    /// threshold: a paper the report would not use is not fetched.
    static let fullTextAutoFetchMinScore = 4

    /// Most characters of a paper's full text handed to citation extraction.
    ///
    /// About 10,000 tokens. Bounds the cost per paper, since every relevant
    /// paper is a separate paid call. A longer text is cut and the prompt says
    /// so, so the model does not treat the cut as the end of the paper.
    static let maxCitationFullTextCharacters = 40_000

    /// Characters per token assumed when estimating what a text costs to send.
    ///
    /// A rough rule for English prose; it only has to be close enough to keep a
    /// batch of full texts from overshooting the run budget by several times.
    static let charactersPerToken = 4

    /// Tokens in the unit model prices are quoted per.
    static let tokensPerMillion = 1_000_000

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
