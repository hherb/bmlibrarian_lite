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

/// The stored Retraction Watch index: read only while current, and replaced
/// only by a download bmlib builds that has not shrunk (retraction_export.py).
final class RetractionIndexStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetractionIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private var file: URL { directory.appendingPathComponent(BioMedLitConstants.retractionIndexFileName) }

    private func store() -> RetractionIndexStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return RetractionIndexStore(directory: directory, session: URLSession(configuration: config), email: "t@example.org")
    }

    /// Store an index file as an earlier refresh would have.
    private func storeIndex(_ rows: [String] = RetractionFixture.rows, dataAsOf: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RetractionFixture.index(rows, dataAsOf: dataAsOf).toBytes().write(to: file)
    }

    // MARK: - Reading

    func testMissingFileIsNoIndex() async {
        let index = await store().currentIndex(now: RetractionFixture.now)
        XCTAssertNil(index)
    }

    func testUnreadableFileIsNoIndex() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not an index".utf8).write(to: file)
        let index = await store().currentIndex(now: RetractionFixture.now)
        XCTAssertNil(index)
    }

    func testStaleIndexIsNotUsed() async throws {
        try storeIndex(dataAsOf: "2026-09-23")  // 36 days before 2026-10-29
        let stale = await store().currentIndex(now: RetractionFixture.now)
        XCTAssertNil(stale)
        try storeIndex(dataAsOf: "2026-09-24")  // control: 35 days is still current
        let current = await store().currentIndex(now: RetractionFixture.now)
        XCTAssertEqual(current?.dataAsOf(), "2026-09-24")
    }

    // MARK: - Refreshing

    func testCurrentIndexIsNotDownloadedAgain() async throws {
        try storeIndex(dataAsOf: RetractionFixture.today)
        let outcome = await store().refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(outcome, .fresh)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty)
    }

    func testRefreshBuildsAndStoresTheDownload() async throws {
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        let store = store()
        let outcome = await store.refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(outcome, .refreshed(noticeCount: 3))
        let index = await store.currentIndex(now: RetractionFixture.now)
        XCTAssertEqual(index?.dataAsOf(), RetractionFixture.today)
        XCTAssertEqual(index?.noticeCount(), 3)
        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.first)
        XCTAssertTrue(url.hasPrefix(BioMedLitConstants.retractionWatchExportURL), url)
        XCTAssertTrue(url.contains("mailto=t@example.org"), url)
        let agent = StubURLProtocol.requestedHeaders.first?["User-Agent"] ?? ""
        XCTAssertTrue(agent.contains("mailto:t@example.org"), agent)
    }

    func testRefusedDownloadKeepsThePreviousFile() async throws {
        try storeIndex(dataAsOf: "2026-01-01")
        let before = try Data(contentsOf: file)
        StubURLProtocol.stubbed = (200, Data("<html><body>Please sign in</body></html>".utf8))
        let outcome = await store().refreshIfStale(now: RetractionFixture.now)
        guard case .refused = outcome else { return XCTFail("an HTML body is refused: \(outcome)") }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testShrunkExportIsRefused() async throws {
        try storeIndex(RetractionFixture.retractions(10), dataAsOf: "2026-01-01")
        let before = try Data(contentsOf: file)
        StubURLProtocol.stubbed = (200, RetractionFixture.csv(RetractionFixture.retractions(9)))
        let outcome = await store().refreshIfStale(now: RetractionFixture.now)
        guard case .refused = outcome else { return XCTFail("90% of the old count is refused: \(outcome)") }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    /// Control: an export as large as the old one replaces it.
    func testUnshrunkExportReplacesAStaleOne() async throws {
        try storeIndex(RetractionFixture.retractions(10), dataAsOf: "2026-01-01")
        StubURLProtocol.stubbed = (200, RetractionFixture.csv(RetractionFixture.retractions(10)))
        let store = store()
        let outcome = await store.refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(outcome, .refreshed(noticeCount: 10))
        let index = await store.currentIndex(now: RetractionFixture.now)
        XCTAssertEqual(index?.dataAsOf(), RetractionFixture.today)
    }

    func testFailedDownloadKeepsThePreviousFile() async throws {
        try storeIndex(dataAsOf: "2026-01-01")
        let before = try Data(contentsOf: file)
        StubURLProtocol.stubbed = (404, Data())
        let outcome = await store().refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(outcome, .failed(.httpStatus(404)))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testCutShortDownloadIsRefused() async throws {
        let body = RetractionFixture.csv()
        StubURLProtocol.stubbed = (200, body)
        StubURLProtocol.headers = ["retractionwatch": ["Content-Length": String(body.count + 100)]]
        let outcome = await store().refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(outcome, .failed(.incompleteResponse))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRefreshUsesAWiFiOnlySession() {
        let config = RetractionIndexStore.wifiOnlyConfiguration()
        XCTAssertFalse(config.allowsExpensiveNetworkAccess)
        XCTAssertFalse(config.allowsConstrainedNetworkAccess)
        XCTAssertEqual(config.timeoutIntervalForRequest, BioMedLitConstants.retractionWatchDownloadTimeoutSeconds)
    }

    func testProductionDirectoryIsUnderTheAppSupportFolder() {
        let path = RetractionIndexStore.productionDirectory.path
        XCTAssertTrue(path.hasSuffix("/\(BioMedLitConstants.appSupportFolderName)/\(BioMedLitConstants.retractionFolderName)"), path)
    }
}
