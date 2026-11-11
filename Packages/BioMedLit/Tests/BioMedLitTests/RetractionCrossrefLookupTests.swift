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

import XCTest
import BmlibCore
@testable import BioMedLit

/// Crossref retraction lookups over a stubbed transport: a failed batch leaves
/// only its own DOIs unanswered, and none of them reads as "not retracted".
final class RetractionCrossrefLookupTests: XCTestCase {
    private static let notice = """
    {"DOI": "10.1000/a0", "updated-by": [
      {"DOI": "10.1000/notice", "type": "retraction", "source": "retraction-watch",
       "updated": {"date-parts": [[2020, 1, 1]]}}]}
    """

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func lookup() -> RetractionCrossrefLookup {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return RetractionCrossrefLookup(
            email: "t@example.org", session: URLSession(configuration: config), retry: Self.fastRetry
        )
    }

    /// The production attempt count without its seconds of backoff.
    private static let fastRetry = RetryConfiguration(
        maxAttempts: RetryConfiguration.networkDefault.maxAttempts,
        initialDelay: 0.001, maxDelay: 0.001, backoffMultiplier: 1, jitterFactor: 0
    )

    private static func body(_ items: String) -> Data {
        Data(#"{"status":"ok","message-type":"work-list","message":{"items":[\#(items)]}}"#.utf8)
    }

    func testServedBatchParses() async throws {
        StubURLProtocol.stubbed = (200, Self.body(Self.notice))
        let out = try await lookup().results(for: ["10.1000/a0", "10.1000/a1"])
        guard case .served(_, let evidence, _) = out["10.1000/a0"]?.result else {
            return XCTFail("a0 should be served: \(String(describing: out["10.1000/a0"]))")
        }
        XCTAssertFalse(evidence.isEmpty)
        XCTAssertNil(out["10.1000/a0"]?.failure)
        XCTAssertEqual(out["10.1000/a1"]?.result, CrossrefResult.notKnown)
        XCTAssertNil(out["10.1000/a1"]?.failure)
    }

    func testEmptyInputMakesNoRequest() async throws {
        let out = try await lookup().results(for: [])
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty)
    }

    func testOneFailedBatchLeavesOnlyItsDOIsUnreachable() async throws {
        let first = (0..<50).map { "10.1000/a\($0)" }
        let second = (0..<10).map { "10.1000/b\($0)" }
        StubURLProtocol.routes = [
            "doi:10.1000/a0,": (429, Data()),
            "doi:10.1000/b0,": (200, Self.body(#"{"DOI": "10.1000/b0"}"#)),
        ]
        let out = try await lookup().results(for: first + second)
        for doi in first {
            guard case .unreachable = out[doi]?.result else { return XCTFail("\(doi) should be unreachable") }
            XCTAssertEqual(out[doi]?.failure, .httpStatus(429))
        }
        guard case .served = out["10.1000/b0"]?.result else { return XCTFail("b0 should be served") }
        XCTAssertEqual(out["10.1000/b1"]?.result, CrossrefResult.notKnown)
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 3 + 1)  // three attempts, then the second batch
    }

    func test429ThenSuccess() async throws {
        StubURLProtocol.sequences = ["api.crossref.org": [(429, Data())]]
        StubURLProtocol.stubbed = (200, Self.body(Self.notice))
        let out = try await lookup().results(for: ["10.1000/a0"])
        guard case .served = out["10.1000/a0"]?.result else { return XCTFail("should be served") }
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 2)
    }

    /// A status bmlib does not read as an answer is asked once, never retried,
    /// and leaves the DOI unanswered with that status, never "not retracted":
    /// even when its body is a well-formed list naming no retraction.
    func testNonRetryableStatusIsUnreachableAfterOneRequest() async throws {
        for status in [400, 404] {
            StubURLProtocol.reset()
            StubURLProtocol.stubbed = (status, Self.body(""))
            let out = try await lookup().results(for: ["10.1000/a0"])
            guard case .unreachable = out["10.1000/a0"]?.result else {
                return XCTFail("\(status) should be unreachable: \(String(describing: out["10.1000/a0"]))")
            }
            XCTAssertEqual(out["10.1000/a0"]?.failure, .httpStatus(status))
            XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1, "\(status) is not retried")
        }
    }

    func testMalformedJSONIsUnreachable() async throws {
        StubURLProtocol.stubbed = (200, Data("not json".utf8))
        let out = try await lookup().results(for: ["10.1000/a0"])
        guard case .unreachable = out["10.1000/a0"]?.result else { return XCTFail("should be unreachable") }
        XCTAssertEqual(out["10.1000/a0"]?.failure, .malformedResponse)
    }

    func testNetworkErrorIsUnreachable() async throws {
        StubURLProtocol.failures = ["api.crossref.org": URLError(.cannotFindHost)]
        let out = try await lookup().results(for: ["10.1000/a0"])
        XCTAssertEqual(out["10.1000/a0"]?.failure, .connection)
        XCTAssertEqual(out["10.1000/a0"]?.result, CrossrefResult.unreachable(reason: RequestFailure.connection.describe()))
    }

    func testUserAgentCarriesMailto() async throws {
        StubURLProtocol.stubbed = (200, Self.body(""))
        _ = try await lookup().results(for: ["10.1000/a0"])
        let agent = StubURLProtocol.requestedHeaders.first?["User-Agent"] ?? ""
        XCTAssertTrue(agent.contains("mailto:t@example.org"), agent)
    }

    func testCancellationThrows() async {
        StubURLProtocol.failures = ["api.crossref.org": URLError(.cancelled)]
        do {
            _ = try await lookup().results(for: ["10.1000/a0"])
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error.isCancellation)
        }
    }

    /// #647: one lookup is shared by every screen, so callers let in while
    /// another sleeps must queue behind it, never send at the same moment.
    func testConcurrentCallersArePacedOneAfterAnother() async throws {
        StubURLProtocol.stubbed = (200, Self.body(""))
        let shared = lookup()
        let start = Date()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
                group.addTask { _ = try await shared.results(for: ["10.1000/c\(i)"]) }
            }
            try await group.waitForAll()
        }

        // the first sends at once, the other two an interval apart
        let interval = TransparencyConstants.minimumRequestInterval
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 2 * interval * 0.95)
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 3)
    }
}
