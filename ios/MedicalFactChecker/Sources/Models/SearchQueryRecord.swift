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

/// One search query a session ran, and the documents it brought into the session.
///
/// A session runs its initial query (page after page, as more evidence is
/// fetched) and, through smart search, alternative queries. Each is kept once,
/// with every document it added, so the reader can see every query that was
/// asked and how much each one found.
struct SearchQueryRecord: Codable, Equatable, Sendable {
    /// Where the query came from.
    enum Kind: String, Codable, Sendable {
        /// The query the claim was converted to.
        case initial
        /// A query smart search generated when the initial one found too little.
        case alternative
    }

    /// Where the query came from.
    let kind: Kind

    /// The provider the query was asked of, as a `SearchProvider` raw value.
    let provider: String

    /// The query as it was sent (PubMed syntax when both providers were asked).
    let query: String

    /// The query as Europe PMC was asked it, when that is not ``query``:
    /// both providers were searched and Europe PMC was sent a translation.
    let europePMCQuery: String?

    /// The documents this query added to the session, by `Document.id`, in the
    /// order they were added.
    ///
    /// `nil` when it was not recorded: a query run by a session saved before
    /// queries were logged. A document another query had already found is not
    /// added again, so it counts for the query that found it first.
    var documentIDs: [String]?

    /// How many matches the source(s) reported for the query, the latest page's.
    ///
    /// `nil` when not known.
    var totalHits: Int?

    /// The provider the query was asked of.
    var searchProvider: SearchProvider? { SearchProvider(rawValue: provider) }

    /// Whether `other` is the same query, asked of the same provider.
    func isSameQuery(as other: SearchQueryRecord) -> Bool {
        kind == other.kind && provider == other.provider && query == other.query
    }
}

/// How much one query found, and how much of it was relevant.
struct SearchQueryStatistics: Equatable, Sendable {
    /// Documents the query added to the session.
    let found: Int

    /// Of those, the documents scored so far.
    let scored: Int

    /// Of those, the documents scored at or above the relevance threshold.
    let relevant: Int
}

/// Pure rules for the session's log of queries.
enum SearchQueryLog {
    /// The log with `run` recorded in it.
    ///
    /// A query already in the log (the same kind, provider and query: a later
    /// page of it) gains the run's documents and its latest count of matches;
    /// a new one is added at the end. A record whose documents were not
    /// recorded stays unrecorded: its count would be only the latest pages'.
    ///
    /// - Parameters:
    ///   - run: The query as it was just run, with the documents it added.
    ///   - log: The queries recorded so far, in the order they first ran.
    /// - Returns: The log with the run recorded.
    static func recording(_ run: SearchQueryRecord, into log: [SearchQueryRecord]) -> [SearchQueryRecord] {
        var log = log
        guard let index = log.firstIndex(where: { $0.isSameQuery(as: run) }) else {
            log.append(run)
            return log
        }
        var existing = log[index]
        if let held = existing.documentIDs {
            let heldSet = Set(held)
            existing.documentIDs = held + (run.documentIDs ?? []).filter { !heldSet.contains($0) }
        }
        existing.totalHits = run.totalHits ?? existing.totalHits
        log[index] = existing
        return log
    }

    /// How much `record` found, and how much of it was relevant.
    ///
    /// - Parameters:
    ///   - record: The query.
    ///   - scores: The relevance score of every scored document in the session,
    ///     by `Document.id`; a document not scored yet is absent.
    ///   - minScore: The lowest score that counts as relevant.
    /// - Returns: The query's counts, or `nil` when its documents were not recorded.
    static func statistics(
        of record: SearchQueryRecord,
        scores: [String: Int],
        minScore: Int
    ) -> SearchQueryStatistics? {
        guard let ids = record.documentIDs else { return nil }
        let held = ids.compactMap { scores[$0] }
        return SearchQueryStatistics(
            found: ids.count,
            scored: held.count,
            relevant: held.filter { $0 >= minScore }.count
        )
    }

    /// The reader's name for the query at `index` of the log.
    ///
    /// The initial query is "Initial query"; smart search's are numbered in
    /// the order they ran ("Alternative 1", "Alternative 2", …).
    ///
    /// - Parameters:
    ///   - index: The query's place in the log.
    ///   - log: The session's queries.
    /// - Returns: The query's name.
    static func label(at index: Int, in log: [SearchQueryRecord]) -> String {
        let record = log[index]
        switch record.kind {
        case .initial:
            let initials = log.prefix(index + 1).filter { $0.kind == .initial }.count
            return initials > 1 ? "Initial query (\(initials))" : "Initial query"
        case .alternative:
            let number = log.prefix(index + 1).filter { $0.kind == .alternative }.count
            return "Alternative \(number)"
        }
    }

    /// The reader's line for a query's counts, e.g. "12 found · 4 relevant".
    ///
    /// Documents not scored yet are named, so a running search does not read
    /// as having found nothing relevant; the source's count of matches is
    /// added where it is known.
    ///
    /// - Parameters:
    ///   - statistics: The query's counts.
    ///   - totalHits: The matches the source(s) reported, if known.
    /// - Returns: The line.
    static func statisticsLine(_ statistics: SearchQueryStatistics, totalHits: Int?) -> String {
        var parts = ["\(statistics.found) found", "\(statistics.relevant) relevant"]
        let unscored = statistics.found - statistics.scored
        if unscored > 0 {
            parts.append("\(unscored) not scored")
        }
        if let totalHits {
            parts.append("\(totalHits.formatted()) matches")
        }
        return parts.joined(separator: " · ")
    }
}
