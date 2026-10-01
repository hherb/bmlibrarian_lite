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
                && !document.hasFullText
                && !document.fullTextAttempted
                && hasIdentifier(document)
        }
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
}
