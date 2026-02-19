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

import XCTest
@testable import BioMedLit

/// Unit tests for selective sync functionality.
///
/// Tests eviction candidate selection, sync scope filtering,
/// and storage management features.
final class SelectiveSyncTests: XCTestCase {

    // MARK: - Eviction Candidate Selection Tests

    /// Tests that LRU strategy selects least recently accessed sessions first.
    func testEvictionCandidateLRU() {
        let sessions = [
            makeSession(id: "1", lastAccessed: Date(timeIntervalSinceNow: -SyncConstants.secondsPerHour)), // oldest
            makeSession(id: "2", lastAccessed: Date(timeIntervalSinceNow: -SyncConstants.secondsPerHour / 2)), // middle
            makeSession(id: "3", lastAccessed: Date()) // newest access
        ]

        // Test using the pure function directly
        let candidates = selectEvictionCandidates(
            from: sessions,
            strategy: .lru,
            minKeep: 1
        )

        // Should have 2 candidates (keeping 1)
        XCTAssertEqual(candidates.count, 2)
        // Oldest accessed should be first candidate
        XCTAssertEqual(candidates.first?.id, "1")
        // Second oldest should be second
        XCTAssertEqual(candidates[1].id, "2")
    }

    /// Tests that largest strategy selects biggest sessions first.
    func testEvictionCandidateLargest() {
        let sessions = [
            makeSession(id: "1", sizeMB: 100),
            makeSession(id: "2", sizeMB: 500), // largest
            makeSession(id: "3", sizeMB: 200)
        ]

        // Test using the pure function directly
        let candidates = selectEvictionCandidates(
            from: sessions,
            strategy: .largest,
            minKeep: 1
        )

        // Largest should be first candidate
        XCTAssertEqual(candidates.first?.id, "2")
        // Second largest should be next
        XCTAssertEqual(candidates[1].id, "3")
    }

    /// Tests that oldest strategy selects sessions by creation date.
    func testEvictionCandidateOldest() {
        let sessions = [
            makeSession(id: "1", createdAt: Date(timeIntervalSinceNow: -SyncConstants.secondsPerDay * 30)), // oldest
            makeSession(id: "2", createdAt: Date(timeIntervalSinceNow: -SyncConstants.secondsPerDay * 7)),
            makeSession(id: "3", createdAt: Date()) // newest
        ]

        // Test using the pure function directly
        let candidates = selectEvictionCandidates(
            from: sessions,
            strategy: .oldest,
            minKeep: 1
        )

        // Oldest created should be first candidate
        XCTAssertEqual(candidates.first?.id, "1")
    }

    /// Tests that noReport strategy prioritizes sessions without reports.
    func testEvictionCandidateNoReport() {
        let sessions = [
            makeSession(id: "1", hasReport: true),
            makeSession(id: "2", hasReport: false), // no report - prioritize
            makeSession(id: "3", hasReport: true)
        ]

        // Test using the pure function directly
        let candidates = selectEvictionCandidates(
            from: sessions,
            strategy: .noReport,
            minKeep: 1
        )

        // Session without report should be first candidate
        XCTAssertEqual(candidates.first?.id, "2")
    }

    /// Tests that minKeep is respected in eviction selection.
    func testEvictionRespectsMinKeep() {
        let sessions = [
            makeSession(id: "1"),
            makeSession(id: "2"),
            makeSession(id: "3")
        ]

        // minKeep = 3 means keep all 3
        let candidates = selectEvictionCandidates(
            from: sessions,
            strategy: .lru,
            minKeep: 3
        )

        // Should have no candidates when minKeep equals session count
        XCTAssertTrue(candidates.isEmpty)
    }

    /// Tests that minKeep prevents eviction when sessions are fewer.
    func testEvictionMinKeepExceedsCount() {
        let sessions = [
            makeSession(id: "1"),
            makeSession(id: "2")
        ]

        // minKeep = 5 exceeds session count
        let candidates = selectEvictionCandidates(
            from: sessions,
            strategy: .lru,
            minKeep: 5
        )

        // Should have no candidates
        XCTAssertTrue(candidates.isEmpty)
    }

    /// Tests that stub sessions are filtered out of eviction candidates.
    func testEvictionFiltersStubs() {
        let sessions = [
            makeSession(id: "1", syncState: .full),
            makeSession(id: "2", syncState: .stub), // already a stub
            makeSession(id: "3", syncState: .evicted) // already evicted
        ]

        // Test using the pure function directly
        let candidates = selectEvictionCandidates(
            from: sessions,
            strategy: .lru,
            minKeep: 0
        )

        // Only full session should be candidate
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.id, "1")
    }

    // MARK: - Session Pinning Tests

    /// Tests that pinned sessions cannot be evicted.
    func testPinnedSessionNotEvicted() async throws {
        let manager = SessionEvictionManager(
            storageMonitor: createMockStorageMonitor(),
            delegate: MockEvictionDelegate()
        )

        await manager.pinSession("session-1")

        let isPinned1 = await manager.isPinned("session-1")
        XCTAssertTrue(isPinned1)
        let isPinned2 = await manager.isPinned("session-2")
        XCTAssertFalse(isPinned2)
    }

    /// Tests pinning and unpinning a session.
    func testPinUnpinSession() async throws {
        let manager = SessionEvictionManager(
            storageMonitor: createMockStorageMonitor(),
            delegate: MockEvictionDelegate()
        )

        // Initially not pinned
        let initiallyPinned = await manager.isPinned("session-1")
        XCTAssertFalse(initiallyPinned)

        // Pin it
        await manager.pinSession("session-1")
        let afterPin = await manager.isPinned("session-1")
        XCTAssertTrue(afterPin)

        // Unpin it
        await manager.unpinSession("session-1")
        let afterUnpin = await manager.isPinned("session-1")
        XCTAssertFalse(afterUnpin)
    }

    /// Tests that evicting a pinned session throws an error.
    func testEvictPinnedSessionFails() async throws {
        let delegate = MockEvictionDelegate()
        let manager = SessionEvictionManager(
            storageMonitor: createMockStorageMonitor(),
            delegate: delegate
        )

        await manager.pinSession("session-1")

        do {
            _ = try await manager.evictSession("session-1")
            XCTFail("Expected error when evicting pinned session")
        } catch let error as StorageError {
            switch error {
            case .evictionFailed(let reason):
                XCTAssertTrue(reason.contains("pinned"))
            default:
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Sync Scope Tests

    /// Tests whitelist filtering in selective mode.
    func testSyncScopeWhitelist() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = try LocalFolderSyncStorage(rootURL: tempDir)
        let deviceConfig = DeviceConfig(
            deviceId: "test-device",
            name: "Test Device",
            platform: .ios,
            syncScope: SyncScope(
                mode: .selective,
                sessionFilter: SessionFilter(mode: .whitelist, ids: ["session-1", "session-3"])
            )
        )

        let manager = SyncScopeManager(storage: storage, deviceConfig: deviceConfig)

        // Whitelisted sessions should be in scope
        let inScope1 = await manager.isInScope("session-1")
        XCTAssertTrue(inScope1)
        let inScope3 = await manager.isInScope("session-3")
        XCTAssertTrue(inScope3)

        // Non-whitelisted session should be out of scope
        let inScope2 = await manager.isInScope("session-2")
        XCTAssertFalse(inScope2)
    }

    /// Tests that full mode includes all sessions.
    func testSyncScopeFullMode() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = try LocalFolderSyncStorage(rootURL: tempDir)
        let deviceConfig = DeviceConfig(
            deviceId: "test-device",
            name: "Test Device",
            platform: .macos,
            syncScope: SyncScope(mode: .full)
        )

        let manager = SyncScopeManager(storage: storage, deviceConfig: deviceConfig)

        // All sessions should be in scope in full mode
        let fullScope1 = await manager.isInScope("session-1")
        XCTAssertTrue(fullScope1)
        let fullScope2 = await manager.isInScope("session-2")
        XCTAssertTrue(fullScope2)
        let fullScopeAny = await manager.isInScope("any-session")
        XCTAssertTrue(fullScopeAny)
    }

    /// Tests that minimal mode excludes all sessions.
    func testSyncScopeMinimalMode() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = try LocalFolderSyncStorage(rootURL: tempDir)
        let deviceConfig = DeviceConfig(
            deviceId: "test-device",
            name: "Test Device",
            platform: .ios,
            syncScope: SyncScope(mode: .minimal)
        )

        let manager = SyncScopeManager(storage: storage, deviceConfig: deviceConfig)

        // All sessions should be out of scope in minimal mode
        let minScope1 = await manager.isInScope("session-1")
        XCTAssertFalse(minScope1)
        let minScope2 = await manager.isInScope("session-2")
        XCTAssertFalse(minScope2)
    }

    /// Tests local exclusion functionality.
    func testLocalExclusion() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = try LocalFolderSyncStorage(rootURL: tempDir)
        let deviceConfig = DeviceConfig(
            deviceId: "test-device",
            name: "Test Device",
            platform: .ios,
            syncScope: SyncScope(mode: .full)
        )

        let manager = SyncScopeManager(storage: storage, deviceConfig: deviceConfig)

        // Initially in scope
        let initiallyInScope = await manager.isInScope("session-1")
        XCTAssertTrue(initiallyInScope)

        // Exclude locally
        await manager.excludeLocally("session-1", reason: .userDeletedLocal)

        // Now out of scope
        let afterExclude = await manager.isInScope("session-1")
        XCTAssertFalse(afterExclude)
        let isExcluded = await manager.isExcluded("session-1")
        XCTAssertTrue(isExcluded)
        let reason = await manager.getExclusionReason("session-1")
        XCTAssertEqual(reason, .userDeletedLocal)

        // Include again
        await manager.includeLocally("session-1")

        // Back in scope
        let afterInclude = await manager.isInScope("session-1")
        XCTAssertTrue(afterInclude)
        let stillExcluded = await manager.isExcluded("session-1")
        XCTAssertFalse(stillExcluded)
    }

    /// Tests recent mode date filtering.
    func testSyncScopeRecentMode() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = try LocalFolderSyncStorage(rootURL: tempDir)
        let deviceConfig = DeviceConfig(
            deviceId: "test-device",
            name: "Test Device",
            platform: .ios,
            syncScope: SyncScope(
                mode: .recent,
                sessionFilter: SessionFilter(mode: .recent, recentDays: 30)
            )
        )

        let manager = SyncScopeManager(storage: storage, deviceConfig: deviceConfig)

        // Recent session should be in scope (7 days ago)
        let recentDate = Date(timeIntervalSinceNow: -SyncConstants.secondsPerDay * 7)
        let recentInScope = await manager.isInScope("session-1", sessionDate: recentDate)
        XCTAssertTrue(recentInScope)

        // Old session should be out of scope (60 days ago)
        let oldDate = Date(timeIntervalSinceNow: -SyncConstants.secondsPerDay * 60)
        let oldInScope = await manager.isInScope("session-2", sessionDate: oldDate)
        XCTAssertFalse(oldInScope)
    }

    // MARK: - Storage Monitor Tests

    /// Tests storage info caching.
    func testStorageInfoCaching() async throws {
        let delegate = MockStorageDelegate()
        let monitor = StorageMonitor(delegate: delegate)

        // First call should query delegate
        let info1 = try await monitor.getStorageInfo()
        XCTAssertEqual(info1.usedMB, 100)
        XCTAssertEqual(delegate.calculateCallCount, 1)

        // Second call should use cache
        let info2 = try await monitor.getStorageInfo()
        XCTAssertEqual(info2.usedMB, 100)
        XCTAssertEqual(delegate.calculateCallCount, 1) // Still 1

        // Force refresh should query again
        let info3 = try await monitor.getStorageInfo(forceRefresh: true)
        XCTAssertEqual(info3.usedMB, 100)
        XCTAssertEqual(delegate.calculateCallCount, 2)
    }

    /// Tests cache invalidation.
    func testStorageInfoInvalidation() async throws {
        let delegate = MockStorageDelegate()
        let monitor = StorageMonitor(delegate: delegate)

        // Initial query
        _ = try await monitor.getStorageInfo()
        XCTAssertEqual(delegate.calculateCallCount, 1)

        // Invalidate cache
        await monitor.invalidateCache()

        // Next query should hit delegate again
        _ = try await monitor.getStorageInfo()
        XCTAssertEqual(delegate.calculateCallCount, 2)
    }

    /// Tests storage exceeded check.
    func testIsStorageExceeded() async throws {
        let delegate = MockStorageDelegate()
        delegate.usedMB = 600
        let monitor = StorageMonitor(delegate: delegate)

        // Should exceed 500 MB limit
        let exceeded500 = try await monitor.isStorageExceeded(maxMB: 500)
        XCTAssertTrue(exceeded500)

        // Should not exceed 1000 MB limit
        let exceeded1000 = try await monitor.isStorageExceeded(maxMB: 1000)
        XCTAssertFalse(exceeded1000)
    }

    /// Tests recommended eviction calculation.
    func testRecommendedEvictionMB() async throws {
        let delegate = MockStorageDelegate()
        delegate.usedMB = 600
        let monitor = StorageMonitor(delegate: delegate)

        // With 500 MB max and 0.9 target ratio:
        // Target = 500 * 0.9 = 450 MB
        // Need to free = 600 - 450 = 150 MB
        let toFree = try await monitor.getRecommendedEvictionMB(maxMB: 500)
        XCTAssertEqual(toFree, 150)

        // If under limit, should return 0
        let noEviction = try await monitor.getRecommendedEvictionMB(maxMB: 700)
        XCTAssertEqual(noEviction, 0)
    }

    // MARK: - Fetch Status Tests

    /// Tests fetch result status values.
    func testFetchResultStatus() {
        let fetched = FetchResult(status: .fetched)
        XCTAssertEqual(fetched.status, .fetched)

        let alreadyFull = FetchResult(status: .alreadyFull)
        XCTAssertEqual(alreadyFull.status, .alreadyFull)

        let inProgress = FetchResult(status: .alreadyInProgress)
        XCTAssertEqual(inProgress.status, .alreadyInProgress)

        let restored = FetchResult(status: .restoredFromSnapshot)
        XCTAssertEqual(restored.status, .restoredFromSnapshot)
    }

    // MARK: - Session Stub Tests

    /// Tests session stub creation.
    func testSessionStubCreation() {
        let tenMegabytes = 10 * 1024 * 1024
        let stub = SessionStub(
            id: "test-session",
            claim: "Test research claim",
            createdAt: Date(timeIntervalSinceNow: -SyncConstants.secondsPerDay),
            documentCount: 25,
            citationCount: 50,
            hasReport: true,
            contentSizeBytes: tenMegabytes
        )

        XCTAssertEqual(stub.id, "test-session")
        XCTAssertEqual(stub.claim, "Test research claim")
        XCTAssertEqual(stub.documentCount, 25)
        XCTAssertEqual(stub.citationCount, 50)
        XCTAssertTrue(stub.hasReport)
        XCTAssertEqual(stub.contentSizeBytes, tenMegabytes)
    }

    /// Tests session stub encoding and decoding.
    func testSessionStubCodable() throws {
        let original = SessionStub(
            id: "test-session",
            claim: "Test claim",
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            documentCount: 10,
            citationCount: 20,
            hasReport: false,
            contentSizeBytes: 5000,
            evictedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionStub.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.claim, original.claim)
        XCTAssertEqual(decoded.documentCount, original.documentCount)
        XCTAssertEqual(decoded.citationCount, original.citationCount)
        XCTAssertEqual(decoded.hasReport, original.hasReport)
        XCTAssertEqual(decoded.contentSizeBytes, original.contentSizeBytes)
    }

    // MARK: - Eviction Result Tests

    /// Tests eviction result structure.
    func testEvictionResult() {
        let result = EvictionResult(sessionsEvicted: 3, mbFreed: 150)
        XCTAssertEqual(result.sessionsEvicted, 3)
        XCTAssertEqual(result.mbFreed, 150)
    }

    // MARK: - Helper Methods

    /// Creates a mock session with specified properties for testing.
    ///
    /// - Parameters:
    ///   - id: Unique session identifier.
    ///   - sizeMB: Storage size in megabytes. Defaults to 100.
    ///   - hasReport: Whether session has a report. Defaults to true.
    ///   - lastAccessed: Last access timestamp. Defaults to now.
    ///   - createdAt: Creation timestamp. Defaults to one day ago.
    ///   - syncState: Sync state. Defaults to full.
    /// - Returns: A configured SessionStorageInfo for testing.
    private func makeSession(
        id: String,
        sizeMB: Int = 100,
        hasReport: Bool = true,
        lastAccessed: Date = Date(),
        createdAt: Date = Date(timeIntervalSinceNow: -SyncConstants.secondsPerDay),
        syncState: RecordSyncState = .full
    ) -> SessionStorageInfo {
        SessionStorageInfo(
            id: id,
            title: "Session \(id)",
            sizeMB: sizeMB,
            documentCount: 10,
            hasReport: hasReport,
            lastAccessedAt: lastAccessed,
            createdAt: createdAt,
            syncState: syncState
        )
    }
}

// MARK: - Mock Implementations

/// Creates a mock storage monitor for testing.
private func createMockStorageMonitor() -> StorageMonitor {
    StorageMonitor(delegate: MockStorageDelegate())
}

/// Mock storage delegate for testing.
private final class MockStorageDelegate: StorageMonitorDelegate, @unchecked Sendable {
    /// Number of times calculateStorageInfo was called.
    var calculateCallCount = 0

    /// Storage used (configurable for tests).
    var usedMB = 100

    func calculateStorageInfo() async throws -> StorageInfo {
        calculateCallCount += 1
        return StorageInfo(usedMB: usedMB)
    }

    func getSessionStorageInfo(sessionId: String) async throws -> SessionStorageInfo? {
        nil
    }
}

/// Mock eviction delegate for testing.
private final class MockEvictionDelegate: SessionEvictionDelegate, @unchecked Sendable {
    /// Freed MB to return from eviction.
    var freedMB = 100

    /// Evicted session IDs (for verification).
    var evictedSessions: [String] = []

    func evictSessionContent(_ sessionId: String) async throws -> Int {
        evictedSessions.append(sessionId)
        return freedMB
    }

    func saveSessionStub(_ sessionId: String, stub: SessionStub) async throws {
        // No-op for testing
    }
}
