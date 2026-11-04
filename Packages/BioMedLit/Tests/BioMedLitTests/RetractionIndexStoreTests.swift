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
    private var refusalFile: URL { directory.appendingPathComponent("\(BioMedLitConstants.retractionIndexFileName).refused") }

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

    /// A refused export would be refused again: not downloaded again within the
    /// day, by a later launch either (#647).
    func testARefusedExportIsNotDownloadedAgainWithinTheDay() async throws {
        try storeIndex(RetractionFixture.retractions(10), dataAsOf: "2026-01-01")
        StubURLProtocol.stubbed = (200, RetractionFixture.csv(RetractionFixture.retractions(9)))
        let first = await store().refreshIfStale(now: RetractionFixture.now)
        guard case .refused = first else { return XCTFail("a shrunk export is refused: \(first)") }
        StubURLProtocol.stubbed = (200, RetractionFixture.csv(RetractionFixture.retractions(10)))
        let again = await store().refreshIfStale(now: RetractionFixture.now.addingTimeInterval(60 * 60))
        XCTAssertEqual(again, first)
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
    }

    /// With no stored copy a refusal is waited out too, by a later launch either (Android's
    /// `a refusal holds across launches`).
    func testARefusalWithNoStoredIndexHoldsAcrossLaunches() async {
        StubURLProtocol.stubbed = (200, Data("<html><body>Please sign in</body></html>".utf8))
        let first = await store().refreshIfStale(now: RetractionFixture.now)
        guard case .refused = first else { return XCTFail("an HTML body is refused: \(first)") }
        let again = await store().refreshIfStale(now: RetractionFixture.now.addingTimeInterval(60 * 60))
        XCTAssertEqual(again, first)
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
    }

    /// A refusal record that cannot be read does not stop a download.
    func testAnUnreadableRefusalRecordIsNoWait() async throws {
        try writeRefusal("garbage")
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        let outcome = await store().refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(outcome, .refreshed(noticeCount: 3))
    }

    /// A refusal dated after `now` (recorded under a clock since set back) is
    /// not waited out until that date: the index would go unconsulted meanwhile.
    func testARefusalDatedAheadIsNoWait() async throws {
        let ahead = RetractionFixture.now.addingTimeInterval(30 * BioMedLitConstants.retractionWatchRefusedBackoffSeconds)
        try writeRefusal("\(ahead.timeIntervalSince1970)\nthe export shrank from 10 to 9 notices")
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        let outcome = await store().refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(outcome, .refreshed(noticeCount: 3))
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
    }

    /// Write the refusal record as `text`.
    private func writeRefusal(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(
            to: directory.appendingPathComponent("\(BioMedLitConstants.retractionIndexFileName).refused"),
            atomically: true, encoding: .utf8)
    }

    /// Control: a day after a refusal the export is downloaded again, and a
    /// stored copy clears the refusal.
    func testARefusedExportIsDownloadedAgainAfterADay() async throws {
        try storeIndex(RetractionFixture.retractions(10), dataAsOf: "2026-01-01")
        StubURLProtocol.stubbed = (200, RetractionFixture.csv(RetractionFixture.retractions(9)))
        _ = await store().refreshIfStale(now: RetractionFixture.now)
        let dayLater = RetractionFixture.now.addingTimeInterval(BioMedLitConstants.retractionWatchRefusedBackoffSeconds)
        StubURLProtocol.stubbed = (200, RetractionFixture.csv(RetractionFixture.retractions(10)))
        let outcome = await store().refreshIfStale(now: dayLater)
        XCTAssertEqual(outcome, .refreshed(noticeCount: 10))
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 2)
        let refusal = directory.appendingPathComponent("\(BioMedLitConstants.retractionIndexFileName).refused")
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusal.path))
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

    /// Launch and a run may both ask while the copy is stale: one download serves both.
    func testConcurrentRefreshesDownloadOnce() async throws {
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        let store = store()
        async let first = store.refreshIfStale(now: RetractionFixture.now)
        async let second = store.refreshIfStale(now: RetractionFixture.now)
        _ = await (first, second)
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
        let index = await store.currentIndex(now: RetractionFixture.now)
        XCTAssertEqual(index?.dataAsOf(), RetractionFixture.today)
    }

    /// A run reads the stored copy while a refresh builds the next one (#681):
    /// the build holds the actor, so an isolated read would wait it out.
    func testAReadNeverWaitsForAnIndexBuild() async throws {
        try storeIndex(dataAsOf: RetractionFixture.today)
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        let started = expectation(description: "the build started")
        let release = DispatchSemaphore(value: 0)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let store = RetractionIndexStore(
            directory: directory, session: URLSession(configuration: config), email: "t@example.org"
        ) { csv, dataAsOf in
            started.fulfill()
            release.wait()
            return try buildRetractionIndex(csv: csv, dataAsOf: dataAsOf)
        }
        // Stale for the refresh, so it downloads and builds; current for the read.
        let later = RetractionFixture.now.addingTimeInterval(
            Double(BioMedLitConstants.retractionWatchMaxAgeDays + 1) * TransparencyConstants.secondsPerDay
        )
        let refresh = Task { await store.refreshIfStale(now: later) }
        await fulfillment(of: [started], timeout: 10)

        let read = expectation(description: "the read returned")
        let reader = Task {
            let index = await store.currentIndex(now: RetractionFixture.now)
            read.fulfill()
            return index
        }
        await fulfillment(of: [read], timeout: 5)
        release.signal()
        let index = await reader.value
        XCTAssertEqual(index?.dataAsOf(), RetractionFixture.today)
        let outcome = await refresh.value
        XCTAssertEqual(outcome, .refreshed(noticeCount: 3))
    }

    /// A local write failure says nothing about the export: no day's wait, the next refresh downloads again (#700).
    func testAnIndexThatCannotBeStoredIsNoWait() async throws {
        // a non-empty folder where the index goes: the atomic rename over it fails
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file.appendingPathComponent("blocker"))
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        let first = await store().refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(first, .notStored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusalFile.path))
        // control: once it can be written, a new launch an hour later stores it
        try FileManager.default.removeItem(at: file)
        let again = await store().refreshIfStale(now: RetractionFixture.now.addingTimeInterval(60 * 60))
        XCTAssertEqual(again, .refreshed(noticeCount: 3))
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 2)
    }

    /// Too little free space downloads nothing and records no wait: a full
    /// disk no longer downloads the export on every run (#702). Unknown space
    /// is no reason to skip.
    func testTooLittleFreeSpaceDownloadsNothingAndIsNoWait() async throws {
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let store = { (free: Int64?) in
            RetractionIndexStore(
                directory: self.directory, session: URLSession(configuration: config), email: "t@example.org",
                freeBytes: { _ in free }
            ) { try buildRetractionIndex(csv: $0, dataAsOf: $1) }
        }
        let full = await store(BioMedLitConstants.retractionWatchMinFreeBytes - 1).refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(full, .notStored)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusalFile.path))
        // controls: exactly enough room downloads, and so does unknown room
        let room = await store(BioMedLitConstants.retractionWatchMinFreeBytes).refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(room, .refreshed(noticeCount: 3))
        try FileManager.default.removeItem(at: file)
        let unknown = await store(nil).refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(unknown, .refreshed(noticeCount: 3))
    }

    /// The production free-space query answers for a folder not yet made.
    func testTheFreeSpaceOfAMissingFolderIsKnown() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNotNil(RetractionIndexStore.availableBytes(at: directory))
    }

    /// A write that fails keeps the previous index as it was (#700).
    func testAnIndexThatCannotBeStoredKeepsThePreviousOne() async throws {
        try storeIndex(dataAsOf: "2026-01-01")
        let before = try Data(contentsOf: file)
        // a read-only folder: nothing can be written or renamed into it
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        let outcome = await store().refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(outcome, .notStored)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    /// Control: the guard lasts one download; a failed one is tried again by the next call.
    func testAFailedRefreshIsTriedAgain() async throws {
        StubURLProtocol.stubbed = (404, Data())
        let store = store()
        _ = await store.refreshIfStale(now: RetractionFixture.now)
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        let outcome = await store.refreshIfStale(now: RetractionFixture.now)
        XCTAssertEqual(outcome, .refreshed(noticeCount: 3))
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 2)
    }

    /// The ~68 MB copy is downloaded again, never backed up.
    func testIndexFolderIsExcludedFromBackup() async throws {
        StubURLProtocol.stubbed = (200, RetractionFixture.csv())
        _ = await store().refreshIfStale(now: RetractionFixture.now)
        let values = try URL(fileURLWithPath: directory.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
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
