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

import BioMedLit
import Foundation
import SwiftData
import XCTest
@testable import MedicalFactChecker

/// Every query a session ran is kept, with the documents each found, so the
/// reader can see them all and how much each one found.
@MainActor
final class SearchQueryLogTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        StringArrayTransformer.register()
        container = try ModelContainer(
            for: Schema(versionedSchema: SchemaV2.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    // MARK: - Fixtures

    private func record(
        _ kind: SearchQueryRecord.Kind,
        _ query: String,
        provider: SearchProvider = .pubmed,
        ids: [String]?,
        hits: Int? = nil
    ) -> SearchQueryRecord {
        SearchQueryRecord(
            kind: kind, provider: provider.rawValue, query: query,
            europePMCQuery: nil, documentIDs: ids, totalHits: hits
        )
    }

    private func document(in session: FactCheckSession, score: Int?) -> Document {
        let document = Document(pmid: UUID().uuidString, title: "T", abstract: "A", authors: [])
        document.relevanceScore = score
        document.session = session
        context.insert(document)
        return document
    }

    // MARK: - The log

    /// A later page of the same query adds its documents to that query, once each.
    func testALaterPageOfAQueryAddsToIt() {
        let log = SearchQueryLog.recording(
            record(.initial, "q", ids: ["b", "c"], hits: 40),
            into: [record(.initial, "q", ids: ["a", "b"], hits: 30)]
        )

        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].documentIDs, ["a", "b", "c"])
        XCTAssertEqual(log[0].totalHits, 40)
    }

    /// Another query, or the same one asked of another provider, is listed after.
    func testAnotherQueryIsListedAfter() {
        var log = [record(.initial, "q", ids: ["a"])]
        log = SearchQueryLog.recording(record(.alternative, "q2", ids: ["b"]), into: log)
        log = SearchQueryLog.recording(record(.initial, "q", provider: .europePMC, ids: ["c"]), into: log)

        XCTAssertEqual(log.map(\.query), ["q", "q2", "q"])
        XCTAssertEqual(
            (0..<log.count).map { SearchQueryLog.label(at: $0, in: log) },
            ["Initial query", "Alternative 1", "Initial query (2)"]
        )
    }

    /// A query whose documents were not recorded is not given a partial count.
    func testAnUnrecordedQueryStaysUnrecorded() {
        let log = SearchQueryLog.recording(
            record(.initial, "q", ids: ["b"]), into: [record(.initial, "q", ids: nil)]
        )

        XCTAssertNil(log[0].documentIDs)
        XCTAssertNil(SearchQueryLog.statistics(of: log[0], scores: [:], minScore: 3))
    }

    // MARK: - The counts

    /// Found counts every document the query added; relevant those at or above the threshold.
    func testTheCountsAreTheQuerysOwn() {
        let stats = SearchQueryLog.statistics(
            of: record(.initial, "q", ids: ["a", "b", "c", "d"]),
            scores: ["a": 5, "b": 3, "c": 2, "z": 5],
            minScore: 3
        )

        XCTAssertEqual(stats, SearchQueryStatistics(found: 4, scored: 3, relevant: 2))
    }

    /// The line names documents not scored yet, and the matches where known.
    func testTheLineNamesWhatIsNotScoredYet() {
        let stats = SearchQueryStatistics(found: 12, scored: 10, relevant: 4)

        XCTAssertEqual(
            SearchQueryLog.statisticsLine(stats, totalHits: nil),
            "12 found · 4 relevant · 2 not scored"
        )
        XCTAssertEqual(
            SearchQueryLog.statisticsLine(SearchQueryStatistics(found: 3, scored: 3, relevant: 1), totalHits: 7),
            "3 found · 1 relevant · \(7.formatted()) matches"
        )
    }

    // MARK: - A session

    /// Each query's documents count for it, not for the others.
    func testASessionCountsEachQuerysDocuments() throws {
        let session = FactCheckSession(claim: "c")
        context.insert(session)
        session.pubmedQuery = "q"
        let first = [document(in: session, score: 5), document(in: session, score: 1)]
        session.recordSearchQuery(record(.initial, "q", ids: first.map(\.id), hits: 100))
        let second = [document(in: session, score: 4)]
        session.recordSearchQuery(record(.alternative, "q2", ids: second.map(\.id), hits: 9))

        let rows = session.searchQueryStatistics(minScore: 3)

        XCTAssertEqual(rows.map { $0.record.query }, ["q", "q2"])
        XCTAssertEqual(rows[0].statistics, SearchQueryStatistics(found: 2, scored: 2, relevant: 1))
        XCTAssertEqual(rows[1].statistics, SearchQueryStatistics(found: 1, scored: 1, relevant: 1))
    }

    /// A session saved before queries were logged still lists its initial query,
    /// with every document when it ran no other.
    func testASessionSavedBeforeTheLogListsItsQuery() {
        let session = FactCheckSession(claim: "c")
        context.insert(session)
        session.pubmedQuery = "q"
        _ = document(in: session, score: 5)

        let rows = session.searchQueryStatistics(minScore: 3)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].record.kind, .initial)
        XCTAssertEqual(rows[0].statistics, SearchQueryStatistics(found: 1, scored: 1, relevant: 1))
    }

    /// Its smart search queries are listed too, without counts it did not keep.
    func testASessionSavedBeforeTheLogListsItsAlternatives() throws {
        let session = FactCheckSession(claim: "c")
        context.insert(session)
        session.pubmedQuery = "q"
        session.alternativeQueries = String(
            decoding: try JSONEncoder().encode([[SearchConcept(name: "aspirin", keywords: ["aspirin"])]]),
            as: UTF8.self
        )

        let rows = session.searchQueryStatistics(minScore: 3)

        XCTAssertEqual(rows.map { $0.record.kind }, [.initial, .alternative])
        XCTAssertTrue(rows[1].record.query.contains("aspirin"))
        XCTAssertNil(rows[0].statistics)
        XCTAssertNil(rows[1].statistics)
    }

    /// A new query run by such a session keeps the queries it ran before, and
    /// its documents count for it alone.
    func testANewQueryOfASessionSavedBeforeTheLogKeepsTheEarlierOnes() {
        let session = FactCheckSession(claim: "c")
        context.insert(session)
        session.pubmedQuery = "q"
        let earlier = document(in: session, score: 5)
        let found = document(in: session, score: 4)

        session.recordSearchQuery(record(.alternative, "q2", ids: [found.id]))

        let rows = session.searchQueries()
        XCTAssertEqual(rows.map(\.query), ["q", "q2"])
        XCTAssertEqual(rows[0].documentIDs, [earlier.id])
        XCTAssertEqual(rows[1].documentIDs, [found.id])
    }

    /// A new session's first search is its first query, and nothing else.
    func testANewSessionsFirstSearchIsItsOnlyQuery() {
        let session = FactCheckSession(claim: "c")
        context.insert(session)
        session.pubmedQuery = "q"
        let found = document(in: session, score: 4)

        session.recordSearchQuery(record(.initial, "q", provider: .europePMC, ids: [found.id]))

        let rows = session.searchQueries()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].documentIDs, [found.id])
    }
}
