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
import BioMedLit

/// Which papers are fetched in full automatically, and how much of a fetched
/// text citation extraction reads.
///
/// Pure functions, so the rules can be tested without a workflow, a network or
/// a model container.
enum FullTextAutoFetch {
    /// The lowest score fetched: the app's constant, but never below the
    /// user's own relevance threshold.
    ///
    /// A paper under that threshold is not in the report, so fetching it would
    /// spend retrieval time on text nothing reads.
    ///
    /// - Parameter minScoreThreshold: The user's relevance threshold (1-5).
    /// - Returns: The lowest score (1-5) whose papers are fetched.
    static func minimumScore(minScoreThreshold: Int) -> Int {
        max(WorkflowConstants.fullTextAutoFetchMinScore, minScoreThreshold)
    }

    /// The documents to fetch full text for.
    ///
    /// A document qualifies when it scores high enough, nothing has been
    /// attempted for it yet, and there is something to look it up by. "Nothing
    /// attempted" includes a recorded "no source had it": asking again on every
    /// run would repeat the same failing round trips. The reader can still
    /// retry one by hand from the full-text tab.
    ///
    /// The exception is a document holding only a PDF link that was never
    /// downloaded (``Document/holdsOnlyUndownloadedPDFLink``): it is fetched
    /// again. That covers how builds before #464 stored an Unpaywall landing
    /// page, and also a PDF whose download failed in this build. A re-fetch
    /// that could not reach the open-access copy keeps the stored link
    /// (``storedLinkKept(_:refetched:)``).
    ///
    /// - Parameters:
    ///   - documents: Candidate documents, in the order to fetch them.
    ///   - minScoreThreshold: The user's relevance threshold (1-5).
    /// - Returns: The qualifying documents, in the order given.
    static func documentsToFetch(
        from documents: [Document],
        minScoreThreshold: Int
    ) -> [Document] {
        let minimum = minimumScore(minScoreThreshold: minScoreThreshold)
        return documents.filter { document in
            document.meetsThreshold(minimum)
                && ((!document.hasFullText && !document.fullTextAttempted)
                    || document.holdsOnlyUndownloadedPDFLink)
                && hasIdentifier(document)
        }
    }

    /// Why a re-fetch result must not replace the PDF link a document holds.
    ///
    /// The chain falls back to a weaker result (the abstract, another link, the
    /// DOI page) when Unpaywall, the landing page it names, OpenAlex, or a PDF
    /// either names (#478, #480) could not settle whether a free copy exists, and applying that
    /// fallback would clear the
    /// stored link for good: the document would no longer hold an undownloaded
    /// PDF link, so nothing would fetch it again. A lookup that settled nothing
    /// is not one that found nothing, so the stored link is kept and the next
    /// run tries again (#464).
    struct StoredLinkKept: LocalizedError, Equatable {
        /// What left the open-access copy unassessed.
        let shortfall: OpenAccessShortfall

        /// The shortfall's own sentence (#466), what became of the stored link,
        /// and "try again later" only where waiting can help: not for a source
        /// that answered, nor for one that was not configured.
        var errorDescription: String? {
            let retrying = shortfall.entries.contains { $0.failure.map { !$0.isAnswer } ?? false }
            return "\(shortfall.notice) The PDF link already stored was kept."
                + (retrying ? " Try again later." : "")
        }
    }

    /// Decide whether a re-fetch result may replace what a document holds.
    ///
    /// - Parameters:
    ///   - document: The document fetched again.
    ///   - result: What the chain returned for it.
    /// - Returns: The refusal when the document holds only an undownloaded PDF
    ///   link and the result is a fallback the chain settled on because the
    ///   open-access copy went unassessed; `nil` when it may be applied.
    static func storedLinkKept(
        _ document: Document, refetched result: BMLFullTextResult
    ) -> StoredLinkKept? {
        guard document.holdsOnlyUndownloadedPDFLink,
              let shortfall = result.openAccessShortfall else { return nil }
        return StoredLinkKept(shortfall: shortfall)
    }

    /// Whether the retrieval chain has anything to look the document up by.
    ///
    /// The raw `pmid` slot counts as well as the PubMed ID: it also holds a
    /// preprint's accession, and the chain resolves that by the identifier
    /// kind, so a preprint without a PMC ID is still fetchable.
    private static func hasIdentifier(_ document: Document) -> Bool {
        func present(_ value: String?) -> Bool {
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        return present(document.pmcId) || present(document.doi) || present(document.pmid)
    }

    /// The article text to give citation extraction, and whether it was cut.
    ///
    /// Nil when the document has no analysable full text, which includes an
    /// abstract-only deposit: its text is the abstract already in the prompt.
    ///
    /// - Parameters:
    ///   - document: The document to read.
    ///   - maxCharacters: The longest text to return.
    /// - Returns: The text and whether it was shortened to fit, or nil.
    static func citationText(
        for document: Document,
        maxCharacters: Int = WorkflowConstants.maxCitationFullTextCharacters
    ) -> (text: String, truncated: Bool)? {
        guard let full = document.analyzableFullText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !full.isEmpty else { return nil }
        guard full.count > maxCharacters else { return (full, false) }
        return (String(full.prefix(maxCharacters)), true)
    }

    // MARK: - Settings gates

    /// The article text citation extraction should read for one document.
    ///
    /// Only for the papers the setting is about, so a text fetched by hand for
    /// a lower-scored paper does not change what that paper costs.
    ///
    /// - Parameters:
    ///   - document: The document to read.
    ///   - autoFetchEnabled: The automatic full-text setting.
    ///   - minScoreThreshold: The user's relevance threshold (1-5).
    /// - Returns: The text and whether it was cut, or nil to use the abstract.
    static func citationFullText(
        for document: Document,
        autoFetchEnabled: Bool,
        minScoreThreshold: Int
    ) -> (text: String, truncated: Bool)? {
        guard autoFetchEnabled,
              document.meetsThreshold(minimumScore(minScoreThreshold: minScoreThreshold))
        else { return nil }
        return citationText(for: document)
    }

    /// Whether a document is due a transparency pass.
    ///
    /// With the setting on, an analysis made before the full text arrived is
    /// redone. With it off the rule is the one the app always had.
    ///
    /// - Parameters:
    ///   - document: The document to check.
    ///   - autoFetchEnabled: The automatic full-text setting.
    /// - Returns: Whether transparency analysis should run for it.
    static func needsTransparencyPass(_ document: Document, autoFetchEnabled: Bool) -> Bool {
        document.needsTransparencyAnalysis
            || (autoFetchEnabled && document.transparencyNeedsFullTextRerun)
    }

    // MARK: - Retrieval

    /// A document whose full text could not be retrieved or stored, and why.
    struct Failure {
        /// The document that failed.
        let document: Document
        /// What went wrong.
        let error: Error
    }

    /// Retrieve each target in turn.
    ///
    /// A document no source had is recorded as such: the expected outcome for
    /// a closed-access paper, not a failure. Any other error leaves the
    /// document as it was, so the next run retries it, and is returned.
    /// Nothing but cancellation stops the loop.
    ///
    /// - Parameters:
    ///   - targets: The documents to fetch, in order.
    ///   - fetch: Retrieves one document's text and applies it to the document.
    ///   - persist: Saves the changes made to the documents.
    ///   - onProgress: Called before each fetch with its 1-based position and the total.
    /// - Returns: The documents that failed, in run order.
    /// - Throws: `CancellationError` when the work is cancelled.
    static func retrieve(
        _ targets: [Document],
        fetch: (Document) async throws -> Void,
        persist: () throws -> Void,
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) async throws -> [Failure] {
        var failures: [Failure] = []
        for (index, document) in targets.enumerated() {
            try Task.checkCancellation()
            onProgress(index + 1, targets.count)
            do {
                try await fetch(document)
            } catch FullTextError.noFullTextAvailable {
                document.markFullTextUnavailable()
            } catch where isCancellation(error) {
                // A cancelled fetch is not a dead source, and not a failure.
                throw CancellationError()
            } catch {
                failures.append(Failure(document: document, error: error))
                continue
            }
            do {
                try persist()
            } catch {
                failures.append(Failure(document: document, error: error))
            }
        }
        return failures
    }

    /// Whether an error means the work was cancelled rather than failed.
    ///
    /// A cancelled request surfaces as `URLError.cancelled` as often as
    /// `CancellationError`. (BioMedLit's `Error.isCancellation` is internal.)
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: - Budget

    /// Keep full texts only while the estimated input cost fits the budget left.
    ///
    /// The run budget is checked once before the citation calls are made, and
    /// each of them is now up to a full text long, so the check alone no longer
    /// bounds what the batch can spend. Texts are kept in order until the next
    /// would cross the line; the rest fall back to their abstracts.
    ///
    /// - Parameters:
    ///   - inputs: The citation inputs, in the order they are paid for.
    ///   - remainingUSD: What the run may still spend.
    ///   - usdPerInputToken: The model's price for one input token.
    /// - Returns: The inputs to send, and how many lost their full text.
    static func fittingBudget(
        _ inputs: [CitationInput],
        remainingUSD: Double,
        usdPerInputToken: Double
    ) -> (inputs: [CitationInput], droppedCount: Int) {
        var remaining = remainingUSD
        var dropped = 0
        let fitted = inputs.map { input -> CitationInput in
            guard let text = input.fullText else { return input }
            let tokens = Double(text.count) / Double(WorkflowConstants.charactersPerToken)
            let cost = tokens * usdPerInputToken
            if cost <= remaining {
                remaining -= cost
                return input
            }
            dropped += 1
            return CitationInput(
                pmid: input.pmid, title: input.title, abstract: input.abstract,
                authors: input.authors, year: input.year
            )
        }
        return (fitted, dropped)
    }

    /// The notice for full texts left out to stay within the run budget.
    ///
    /// - Parameter count: How many papers were read from the abstract instead.
    /// - Returns: A sentence saying so.
    static func budgetNotice(droppedCount count: Int) -> String {
        "To stay within the run budget, \(count) paper\(count == 1 ? "" : "s") "
            + "scored for full text \(count == 1 ? "was" : "were") read from the abstract instead."
    }
}
