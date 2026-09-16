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
import XCTest
@testable import BioMedLit

/// A failed Europe PMC request is never an empty page (#256).
///
/// Europe PMC answers an unknown cursor with HTTP 200 and a body holding only
/// its version, which used to read as a search that matched nothing.
final class EuropePMCSearchFailureTests: EutilsStubTestCase {
    /// A service whose requests go to the recording stub.
    private func service() -> EuropePMCService {
        EuropePMCService(session: EutilsRecordingURLProtocol.session())
    }

    /// Answer every search with this body.
    private func serve(_ answer: String) {
        let data = Data(answer.utf8)
        EutilsRecordingURLProtocol.reply = { _, _ in .ok(data) }
    }

    /// One record Europe PMC can send.
    private func record(id: String, title: String = "A title") -> String {
        #"{"id":"\#(id)","source":"MED","pmid":"\#(id)","title":"\#(title)"}"#
    }

    /// Run a search that must fail, and return why.
    private func failedSearch(
        cursor: String = EuropePMCService.initialCursor,
        recordsReceived: Int? = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> RequestFailure? {
        do {
            _ = try await service().search(
                query: "aspirin", pageSize: 25, cursor: cursor, recordsReceived: recordsReceived
            )
            XCTFail("the search should have failed", file: file, line: line)
            return nil
        } catch let failed as SourceRequestError {
            XCTAssertEqual(failed.source, .europePMC, file: file, line: line)
            return failed.failure
        } catch {
            XCTFail("expected a source failure, got \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - Answers that cannot be read

    /// An answer with no hit count cannot be read: it is not a search that matched nothing.
    ///
    /// Checked live on 2026-09-14: an unknown `cursorMark` answers HTTP 200 with
    /// `{"version":"6.9"}`.
    func testAnAnswerWithoutAHitCountCannotBeRead() async {
        for answer in [#"{"version":"6.9"}"#, "<html>Gateway</html>", #"{"hitCount":-1,"resultList":{"result":[]}}"#] {
            EutilsRecordingURLProtocol.reset()
            serve(answer)

            let failure = await failedSearch()

            XCTAssertEqual(failure, .malformedResponse, answer)
        }
    }

    /// An answer with no result list cannot be read.
    ///
    /// A page that holds no list and a page whose list is empty are opposite
    /// answers, and only the second is the evidence base's own.
    func testAnAnswerWithoutAResultListCannotBeRead() async {
        serve(#"{"hitCount":10,"nextCursorMark":"next"}"#)

        let failure = await failedSearch()

        XCTAssertEqual(failure, .malformedResponse)
    }

    /// No hits with an empty list is a search that matched nothing, not a failure.
    func testNoHitsIsNotAFailure() async throws {
        serve(#"{"hitCount":0,"resultList":{"result":[]}}"#)

        let result = try await service().search(query: "aspirin", pageSize: 25)

        XCTAssertEqual(result.totalCount, 0)
        XCTAssertEqual(result.articles, [])
        XCTAssertEqual(result.shortfalls, [])
        XCTAssertNil(result.nextCursor)
        XCTAssertEqual(logger.problems, [])
    }

    /// An unsuccessful status is reported as the status, not as a refused redirect.
    ///
    /// Europe PMC's requests carry no credential, so its redirects are followed.
    func testAnUnsuccessfulStatusIsReportedAsTheStatus() async {
        EutilsRecordingURLProtocol.reply = { _, _ in .status(404) }

        let failure = await failedSearch()

        XCTAssertEqual(failure, .httpStatus(404))
        XCTAssertEqual(failure?.kind, .httpStatus)
    }

    // MARK: - Pages that hold less than they count

    /// An empty page where hits remain is a failed page.
    func testAnEmptyPageWhereHitsRemainIsAFailedPage() async {
        serve(#"{"hitCount":100,"nextCursorMark":"next","resultList":{"result":[]}}"#)

        let failure = await failedSearch(cursor: "current", recordsReceived: 25)

        XCTAssertEqual(failure, .incompleteResponse)
    }

    /// A cursor that ends early leaves every hit not received missing.
    ///
    /// Nothing past an ended cursor can be asked for, so what earlier short
    /// pages left out is counted here too.
    func testACursorThatEndsEarlyLosesEveryHitNotReceived() async throws {
        serve(#"{"hitCount":100,"resultList":{"result":[\#(record(id: "1"))]}}"#)

        let result = try await service().search(
            query: "aspirin", pageSize: 25, cursor: "current", recordsReceived: 40
        )

        XCTAssertEqual(result.articles.map(\.pmid), ["1"])
        XCTAssertNil(result.nextCursor)
        XCTAssertEqual(
            result.shortfalls,
            [RetrievalShortfall.missingRecords(59, from: .europePMC, failure: .incompleteResponse)]
                .compactMap { $0 }
        )
    }

    /// A page of a session saved before the count was kept expects nothing in particular.
    ///
    /// Its cursor can outlive its last hit, so a page that holds fewer records
    /// than the hit count suggests is not evidence that anything was lost.
    func testASessionWithoutACountExpectsNothingOfItsPage() async throws {
        serve(#"{"hitCount":100,"resultList":{"result":[\#(record(id: "1"))]}}"#)

        let result = try await service().search(
            query: "aspirin", pageSize: 25, cursor: "current", recordsReceived: nil
        )

        XCTAssertEqual(result.shortfalls, [])
        XCTAssertEqual(result.recordsReceived, 1)
    }

    /// A record that cannot be read, or that has no title, is one record missing.
    func testARecordThatCannotBeReadIsMissing() async throws {
        serve("""
            {"hitCount":3,"nextCursorMark":"next","resultList":{"result":[\
            \(record(id: "1")),\
            {"id":"2","source":"MED","pmid":"2"},\
            "not a record"\
            ]}}
            """)

        let result = try await service().search(query: "aspirin", pageSize: 25, recordsReceived: 0)

        XCTAssertEqual(result.articles.map(\.pmid), ["1"])
        XCTAssertEqual(result.recordsReceived, 3, "a record that could not be read still came off the cursor")
        XCTAssertEqual(
            result.shortfalls,
            [RetrievalShortfall.missingRecords(2, from: .europePMC, failure: .malformedResponse)]
                .compactMap { $0 }
        )
    }

    // MARK: - The cursor

    /// A next cursor that repeats the one sent is the end of the results.
    func testACursorThatRepeatsItselfIsTheEnd() async throws {
        serve(#"{"hitCount":1,"nextCursorMark":"current","resultList":{"result":[\#(record(id: "1"))]}}"#)

        let result = try await service().search(
            query: "aspirin", pageSize: 25, cursor: "current", recordsReceived: 0
        )

        XCTAssertNil(result.nextCursor)
        XCTAssertEqual(result.shortfalls, [], "every hit arrived")
    }

    /// A page with more to come carries the next cursor.
    func testAPageWithMoreToComeCarriesTheNextCursor() async throws {
        serve(#"{"hitCount":50,"nextCursorMark":"next","resultList":{"result":[\#(record(id: "1"))]}}"#)

        let result = try await service().search(
            query: "aspirin", pageSize: 1, cursor: EuropePMCService.initialCursor, recordsReceived: 0
        )

        XCTAssertEqual(result.nextCursor, "next")
        XCTAssertEqual(result.shortfalls, [])
    }

    // MARK: - The transport

    /// A cancelled request is the user's doing, not a source that failed.
    func testACancelledRequestIsNotASourceFailure() async {
        EutilsRecordingURLProtocol.reply = { _, _ in .transportError(.cancelled) }

        do {
            _ = try await service().search(query: "aspirin", pageSize: 25)
            XCTFail("a cancelled request should not return a page")
        } catch is CancellationError {
            // Expected: nothing is recorded as missing
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
    }
}
