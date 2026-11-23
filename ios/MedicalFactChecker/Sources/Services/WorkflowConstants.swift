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

    // MARK: - LLM Output Limits

    // A thinking model's thinking counts against the limit, and Claude Haiku
    // 5.5 thinks on Anthropic's OpenAI-compatible endpoint too. Measured on
    // Claude Haiku 5.5 and Sonnet 5.5 with the app's prompts (#813). Only the
    // tokens generated are billed, so the headroom costs nothing.

    /// Most output tokens for a short JSON answer: a relevance score, a query
    /// conversion. The longest measured answer was 513 tokens.
    static let shortAnswerMaxTokens = 2048

    /// Most output tokens for generated text: a HyDE abstract, alternative
    /// queries. The longest measured answers were 1,388 and 1,535 tokens.
    static let generationMaxTokens = 4096

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

    // MARK: - MANTA Shadow

    /// Most characters of a MANTA error kept on a document, as the desktop's
    /// `MANTA_ERROR_MAX_CHARS`: an error page must not fill the store.
    static let mantaErrorMaxLength = 500

    /// The hosts a MANTA URL may name (lowercase): the server binds 127.0.0.1
    /// only, so papers never go to another machine.
    static let mantaLoopbackHosts: Set<String> = ["127.0.0.1", "localhost"]

    // MARK: - Automatic Full-Text Retrieval

    /// Default lowest relevance score (1-5) whose papers are fetched in full
    /// when the automatic full-text setting is on; the user can change it.
    ///
    /// Scores 4 and 5 are the papers that shape the report most, so they are
    /// the ones where the full text (methods, results, funding, conflicts) is
    /// worth the retrieval time. Never lowers the user's own relevance
    /// threshold: a paper the report would not use is not fetched.
    static let fullTextAutoFetchMinScore = 4

    /// Folder, beside BioMedLit's PDF cache, holding the PDFs the reader uploaded.
    ///
    /// Apart from the cache, so clearing it never deletes a copy no source could supply.
    static let uploadedFullTextFolderName = "UploadedFullTexts"

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

    // MARK: - Retraction

    /// How many decoded stored checks are kept, by their JSON text (#647).
    static let decodedRetractionCheckCacheLimit = 2_000

    /// How many decoded run snapshots are kept, by their JSON text (#647).
    static let decodedRetractionSnapshotCacheLimit = 32
}
