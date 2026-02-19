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

/// Tests for Phase 2 change tracking functionality.
final class ChangeTrackingTests: XCTestCase {

    // MARK: - Test Helpers

    var tempDirectory: URL!
    var storage: LocalFolderSyncStorage!

    override func setUpWithError() throws {
        // Create a temporary directory for each test
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-test-\(UUID().uuidString)")
        storage = try LocalFolderSyncStorage(rootURL: tempDirectory)
    }

    override func tearDownWithError() throws {
        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Local Storage Tests

    /// Test writing and reading a file.
    func testLocalStorageWriteRead() async throws {
        let testData = "Hello, World!".data(using: .utf8)!
        try await storage.writeFile(testData, at: "test/file.txt")

        let readData = try await storage.readFile(at: "test/file.txt")
        XCTAssertEqual(testData, readData)
    }

    /// Test listing files in a directory.
    func testLocalStorageListFiles() async throws {
        try await storage.writeFile(Data("a".utf8), at: "dir/a.txt")
        try await storage.writeFile(Data("b".utf8), at: "dir/b.txt")
        try await storage.createDirectory(at: "dir/subdir")

        let files = try await storage.listFiles(at: "dir")
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains { $0.name == "a.txt" })
        XCTAssertTrue(files.contains { $0.name == "b.txt" })
    }

    /// Test listing directories.
    func testLocalStorageListDirectories() async throws {
        try await storage.createDirectory(at: "parent/child1")
        try await storage.createDirectory(at: "parent/child2")
        try await storage.writeFile(Data(), at: "parent/file.txt")

        let dirs = try await storage.listDirectories(at: "parent")
        XCTAssertEqual(dirs.count, 2)
        XCTAssertTrue(dirs.contains("child1"))
        XCTAssertTrue(dirs.contains("child2"))
    }

    /// Test file exists check.
    func testLocalStorageFileExists() async throws {
        try await storage.writeFile(Data(), at: "exists.txt")

        let exists = await storage.fileExists(at: "exists.txt")
        XCTAssertTrue(exists)
        let notExists = await storage.fileExists(at: "not_exists.txt")
        XCTAssertFalse(notExists)
    }

    /// Test delete file.
    func testLocalStorageDeleteFile() async throws {
        try await storage.writeFile(Data(), at: "to_delete.txt")
        let existsBeforeDelete = await storage.fileExists(at: "to_delete.txt")
        XCTAssertTrue(existsBeforeDelete)

        try await storage.deleteFile(at: "to_delete.txt")
        let existsAfterDelete = await storage.fileExists(at: "to_delete.txt")
        XCTAssertFalse(existsAfterDelete)
    }

    /// Test deleting non-existent file doesn't throw.
    func testLocalStorageDeleteNonExistent() async throws {
        // Should not throw
        try await storage.deleteFile(at: "never_existed.txt")
    }

    /// Test quarantine file.
    func testLocalStorageQuarantineFile() async throws {
        let data = Data("corrupt data".utf8)
        try await storage.writeFile(data, at: "bad_file.json")

        let quarantinePath = try await storage.quarantineFile(
            at: "bad_file.json",
            reason: "Checksum mismatch"
        )

        // Original file should be gone
        let originalGone = await storage.fileExists(at: "bad_file.json")
        XCTAssertFalse(originalGone)

        // Should exist in quarantine
        let quarantineExists = await storage.fileExists(at: quarantinePath)
        XCTAssertTrue(quarantineExists)
        XCTAssertTrue(quarantinePath.hasPrefix(SyncConstants.quarantineDirectory))
    }

    // MARK: - Change Log Writer Tests

    /// Test that sequences increment correctly.
    func testChangeLogWriterSequence() async throws {
        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: "test-device"
        )

        struct TestData: Codable, Sendable {
            let value: String
        }

        let change1: ChangeLogEntry<TestData> = try await writer.recordUpsert(
            entity: .session,
            id: "session-1",
            data: TestData(value: "first")
        )

        let change2: ChangeLogEntry<TestData> = try await writer.recordUpsert(
            entity: .session,
            id: "session-1",
            data: TestData(value: "second")
        )

        XCTAssertEqual(change1.sequence, 1)
        XCTAssertEqual(change2.sequence, 2)
        XCTAssertNil(change1.previousHash)
        XCTAssertNotNil(change2.previousHash)
    }

    /// Test that vector clock increments correctly.
    func testChangeLogWriterVectorClock() async throws {
        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: "device-a"
        )

        struct TestData: Codable, Sendable {
            let value: Int
        }

        _ = try await writer.recordUpsert(
            entity: .document,
            id: "doc-1",
            data: TestData(value: 1)
        )

        let clock = await writer.getVectorClock()
        XCTAssertEqual(clock.sequence(for: "device-a"), 1)
    }

    /// Test delete operation.
    func testChangeLogWriterDelete() async throws {
        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: "test-device"
        )

        let change = try await writer.recordDelete(
            entity: .document,
            id: "doc-to-delete"
        )

        XCTAssertEqual(change.operation.type, .delete)
        XCTAssertEqual(change.operation.entity, .document)
        XCTAssertEqual(change.operation.id, "doc-to-delete")
        XCTAssertNil(change.operation.data)
    }

    /// Test that change files are written to storage.
    func testChangeLogWriterFilesWritten() async throws {
        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: "file-test-device"
        )

        struct TestData: Codable, Sendable {
            let name: String
        }

        _ = try await writer.recordUpsert(
            entity: .session,
            id: "session-1",
            data: TestData(name: "test session")
        )

        // Check that the change file exists
        let changesPath = "changes/file-test-device"
        let files = try await storage.listFiles(at: changesPath)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].name.contains("session_upsert"))
    }

    // MARK: - Workspace Models Tests

    /// Test device config serialization round trip.
    func testDeviceConfigSerialization() throws {
        let config = DeviceConfig(
            deviceId: "test-123",
            name: "Test Device",
            platform: .ios,
            syncScope: SyncScope(
                mode: .selective,
                sessionFilter: SessionFilter(mode: .whitelist, ids: ["s1", "s2"])
            )
        )

        let envelope = try createIntegrityEnvelope(config)
        let extracted: DeviceConfig = try verifyAndExtract(envelope)

        XCTAssertEqual(config.deviceId, extracted.deviceId)
        XCTAssertEqual(config.name, extracted.name)
        XCTAssertEqual(config.platform, extracted.platform)
        XCTAssertEqual(config.syncScope.mode, extracted.syncScope.mode)
        XCTAssertEqual(config.syncScope.sessionFilter?.ids, extracted.syncScope.sessionFilter?.ids)
    }

    /// Test workspace config defaults.
    func testWorkspaceConfigDefaults() {
        let config = WorkspaceConfig()

        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.schemaVersion, SyncConstants.schemaVersion)
        XCTAssertEqual(config.encryption, .none)
    }

    /// Test sync watermarks operations.
    func testSyncWatermarks() {
        var watermarks = SyncWatermarks()

        // Initial watermark is 0
        XCTAssertEqual(watermarks.watermark(for: "device-a"), 0)

        // Set watermark
        watermarks.setWatermark(42, for: "device-a")
        XCTAssertEqual(watermarks.watermark(for: "device-a"), 42)

        // Set another device
        watermarks.setWatermark(100, for: "device-b")
        XCTAssertEqual(watermarks.watermark(for: "device-b"), 100)

        // Original still preserved
        XCTAssertEqual(watermarks.watermark(for: "device-a"), 42)
    }

    /// Test local exclusions operations.
    func testLocalExclusions() {
        var exclusions = LocalExclusions()

        // Not excluded initially
        XCTAssertFalse(exclusions.isExcluded("session-1"))

        // Exclude
        exclusions.exclude("session-1", reason: .userDeletedLocal)
        XCTAssertTrue(exclusions.isExcluded("session-1"))
        XCTAssertEqual(exclusions.reason(for: "session-1"), .userDeletedLocal)

        // Include again
        exclusions.include("session-1")
        XCTAssertFalse(exclusions.isExcluded("session-1"))
        XCTAssertNil(exclusions.reason(for: "session-1"))
    }

    /// Test device manifest operations.
    func testDeviceManifest() {
        var manifest = DeviceManifest(deviceId: "test-device")

        XCTAssertEqual(manifest.headSequence, 0)
        XCTAssertTrue(manifest.files.isEmpty)

        // Add file entry
        let entry = ManifestFileEntry(
            sequence: 1,
            filename: "000001_123_session_upsert.json",
            checksum: "abc123",
            entryChecksum: "entry456",
            size: 1024,
            timestamp: 123
        )
        manifest.addFile(entry)

        XCTAssertEqual(manifest.headSequence, 1)
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertFalse(manifest.manifestChecksum.isEmpty)
    }

    // MARK: - Sync State Manager Tests

    /// Test sync state manager watermark operations.
    func testSyncStateManagerWatermarks() async throws {
        let config = DeviceConfig(
            deviceId: "state-test-device",
            name: "Test",
            platform: .macos
        )

        let manager = SyncStateManager(
            storage: storage,
            deviceConfig: config
        )

        // Initial watermark is 0
        let initial = await manager.getWatermark(for: "remote-device")
        XCTAssertEqual(initial, 0)

        // Set watermark
        try await manager.setWatermark(50, for: "remote-device")

        let updated = await manager.getWatermark(for: "remote-device")
        XCTAssertEqual(updated, 50)
    }

    /// Test sync state manager exclusions.
    func testSyncStateManagerExclusions() async throws {
        let config = DeviceConfig(
            deviceId: "exclusion-test",
            name: "Test",
            platform: .ios
        )

        let manager = SyncStateManager(
            storage: storage,
            deviceConfig: config
        )

        // Not excluded initially
        let isExcluded = await manager.isExcluded("session-x")
        XCTAssertFalse(isExcluded)

        // Exclude
        try await manager.exclude("session-x", reason: .autoEvicted)

        let isNowExcluded = await manager.isExcluded("session-x")
        XCTAssertTrue(isNowExcluded)

        let reason = await manager.exclusionReason(for: "session-x")
        XCTAssertEqual(reason, .autoEvicted)

        // Include
        try await manager.include("session-x")

        let isStillExcluded = await manager.isExcluded("session-x")
        XCTAssertFalse(isStillExcluded)
    }

    /// Test sync state persistence.
    func testSyncStatePersistence() async throws {
        let config = DeviceConfig(
            deviceId: "persist-test",
            name: "Test",
            platform: .macos
        )

        // Create first manager and set state
        let manager1 = SyncStateManager(
            storage: storage,
            deviceConfig: config,
            localStatePath: "persist_test_state.json"
        )

        try await manager1.setWatermark(100, for: "remote-1")
        try await manager1.exclude("session-1", reason: .userRemovedFromScope)

        // Create second manager and load state
        let manager2 = SyncStateManager(
            storage: storage,
            deviceConfig: config,
            localStatePath: "persist_test_state.json"
        )
        try await manager2.loadState()

        // Verify state was persisted
        let watermark = await manager2.getWatermark(for: "remote-1")
        XCTAssertEqual(watermark, 100)

        let isExcluded = await manager2.isExcluded("session-1")
        XCTAssertTrue(isExcluded)
    }

    /// Test device registration.
    func testDeviceRegistration() async throws {
        let config = DeviceConfig(
            deviceId: "register-test",
            name: "My Device",
            platform: .ios
        )

        let manager = SyncStateManager(
            storage: storage,
            deviceConfig: config
        )

        try await manager.registerDevice()

        // Check device file exists
        let devicePath = SyncFileNaming.deviceFilePath(deviceId: "register-test")
        let deviceFileExists = await storage.fileExists(at: devicePath)
        XCTAssertTrue(deviceFileExists)

        // Check changes directory exists
        let changesPath = SyncFileNaming.deviceChangesDirectory(deviceId: "register-test")
        let dirs = try await storage.listDirectories(at: SyncConstants.changesDirectory)
        XCTAssertTrue(dirs.contains("register-test"))
    }

    // MARK: - Change Log Reader Tests

    /// Test discover devices with no devices.
    func testDiscoverDevicesEmpty() async throws {
        let reader = ChangeLogReader(storage: storage, myDeviceId: "my-device")

        let devices = try await reader.discoverDevices()
        XCTAssertTrue(devices.isEmpty)
    }

    /// Test discover devices filters out self.
    func testDiscoverDevicesFiltersSelf() async throws {
        // Register two devices
        let myConfig = DeviceConfig(
            deviceId: "my-device",
            name: "My Device",
            platform: .ios
        )
        let otherConfig = DeviceConfig(
            deviceId: "other-device",
            name: "Other Device",
            platform: .macos
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601

        let myEnvelope = try createIntegrityEnvelope(myConfig)
        let myData = try encoder.encode(myEnvelope)
        try await storage.writeFile(myData, at: SyncFileNaming.deviceFilePath(deviceId: "my-device"))

        let otherEnvelope = try createIntegrityEnvelope(otherConfig)
        let otherData = try encoder.encode(otherEnvelope)
        try await storage.writeFile(otherData, at: SyncFileNaming.deviceFilePath(deviceId: "other-device"))

        // Reader for my-device should only see other-device
        let reader = ChangeLogReader(storage: storage, myDeviceId: "my-device")
        let devices = try await reader.discoverDevices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].deviceId, "other-device")
    }

    /// Test read changes from empty device.
    func testReadChangesEmpty() async throws {
        let reader = ChangeLogReader(storage: storage, myDeviceId: "reader-device")

        let changes = try await reader.readChanges(from: "other-device", afterSequence: 0)
        XCTAssertTrue(changes.isEmpty)
    }

    // MARK: - Integration Test

    /// Test full write/read cycle between two devices.
    func testWriteReadCycle() async throws {
        // Device 1 writes changes
        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: "writer-device"
        )

        struct SessionData: Codable, Sendable, Equatable {
            let question: String
        }

        _ = try await writer.recordUpsert(
            entity: .session,
            id: "session-1",
            data: SessionData(question: "Test question")
        )

        try await writer.writeManifest()

        // Device 2 reads changes
        let reader = ChangeLogReader(storage: storage, myDeviceId: "reader-device")

        let changes = try await reader.readChanges(from: "writer-device", afterSequence: 0)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].sequence, 1)

        // Decode the change
        let decoded: ChangeLogEntry<SessionData> = try reader.decodeChange(changes[0])
        XCTAssertEqual(decoded.operation.entity, .session)
        XCTAssertEqual(decoded.operation.data?.question, "Test question")
    }
}
