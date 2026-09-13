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

/// A PubMed search reports how many articles match, not how many it fetched (#251).
///
/// The total came from the batch size, so a query with thousands of matches
/// reported one batch's worth and `nextOffset` was `nil` on the first page: the
/// app stored the batch size as the number of matches and never fetched more.
final class PubMedSearchTotalTests: RecordingLoggerTestCase {
    /// Start each test with no recorded requests and the default reply.
    override func setUp() {
        super.setUp()
        EutilsRecordingURLProtocol.reset()
    }

    /// Leave the stub's shared state clean for the next test class.
    override func tearDown() {
        EutilsRecordingURLProtocol.reset()
        super.tearDown()
    }

    /// Answer esearch with this body and efetch with one article per PMID.
    private func serve(searchAnswer: String) {
        let searchData = Data(searchAnswer.utf8)
        EutilsRecordingURLProtocol.reply = { request, _ in
            guard request.url?.lastPathComponent == "efetch.fcgi" else { return .ok(searchData) }
            return .ok(Data("""
                <PubmedArticleSet><PubmedArticle><MedlineCitation><PMID>12345</PMID>\
                <Article><ArticleTitle>A title</ArticleTitle></Article></MedlineCitation>\
                </PubmedArticle></PubmedArticleSet>
                """.utf8))
        }
    }

    /// A service whose requests go to the recording stub.
    private func service() -> PubMedService {
        PubMedService(email: "researcher@example.org", session: EutilsRecordingURLProtocol.session())
    }

    /// The total is esearch's `count`, and the next page starts after this batch.
    func testTheTotalIsTheCountOfAllMatches() async throws {
        serve(searchAnswer: #"{"esearchresult":{"count":"25000","idlist":["12345"]}}"#)

        let result = try await service().search(query: "aspirin", maxResults: 1, offset: 40)

        XCTAssertEqual(result.totalCount, 25000)
        XCTAssertEqual(result.nextOffset, 41)
        XCTAssertEqual(logger.problems, [])
    }

    /// An empty batch past the end still reports how many articles match.
    func testAnEmptyBatchStillReportsTheTotal() async throws {
        serve(searchAnswer: #"{"esearchresult":{"count":"3","idlist":[]}}"#)

        let result = try await service().search(query: "aspirin", maxResults: 10, offset: 10)

        XCTAssertEqual(result.totalCount, 3)
        XCTAssertNil(result.nextOffset)
        XCTAssertEqual(EutilsRecordingURLProtocol.recorded.count, 1, "an empty batch needs no efetch")
    }

    /// Without a usable count, the total is what was seen, and a warning says so.
    func testAMissingCountEndsPaginationAndWarns() async throws {
        for answer in [
            #"{"esearchresult":{"idlist":["12345"]}}"#,
            #"{"esearchresult":{"count":"many","idlist":["12345"]}}"#
        ] {
            EutilsRecordingURLProtocol.reset()
            logger.reset()
            serve(searchAnswer: answer)

            let result = try await service().search(query: "aspirin", maxResults: 1, offset: 40)

            XCTAssertEqual(result.totalCount, 41, answer)
            XCTAssertNil(result.nextOffset, answer)
            XCTAssertEqual(logger.problems.count, 1, "\(answer): \(logger.recorded)")
        }
    }
}
