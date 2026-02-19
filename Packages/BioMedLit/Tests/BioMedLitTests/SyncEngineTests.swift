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

/// Tests for Phase 3 sync engine functionality.
final class SyncEngineTests: XCTestCase {

    // MARK: - Test Setup

    var tempDirectory: URL!
    var storage: LocalFolderSyncStorage!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        storage = try LocalFolderSyncStorage(rootURL: tempDirectory)
    }

    override func tearDownWithError() throws {
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - LWW Merge Strategy Tests

    /// Test that later timestamp wins in LWW merge.
    func testLWWMergeTimestampWins() {
        let localTs: Int64 = 1000
        let remoteTs: Int64 = 2000

        let shouldApply = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: remoteTs, deviceId: "device-b"),
            local: (timestamp: localTs, deviceId: "device-a")
        )

        XCTAssertTrue(shouldApply, "Later timestamp should win")
    }

    /// Test that local wins when timestamp is later.
    func testLWWMergeLocalWins() {
        let localTs: Int64 = 2000
        let remoteTs: Int64 = 1000

        let shouldApply = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: remoteTs, deviceId: "device-b"),
            local: (timestamp: localTs, deviceId: "device-a")
        )

        XCTAssertFalse(shouldApply, "Local with later timestamp should win")
    }

    /// Test device ID tiebreaker when timestamps are equal.
    func testLWWMergeTiebreaker() {
        let timestamp: Int64 = 1000

        // Higher device ID wins
        let shouldApply1 = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: timestamp, deviceId: "device-b"),
            local: (timestamp: timestamp, deviceId: "device-a")
        )
        XCTAssertTrue(shouldApply1, "Higher device ID should win on tie")

        // Lower device ID loses
        let shouldApply2 = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: timestamp, deviceId: "device-a"),
            local: (timestamp: timestamp, deviceId: "device-b")
        )
        XCTAssertFalse(shouldApply2, "Lower device ID should lose on tie")
    }

    /// Test that remote always applies when no local version exists.
    func testLWWMergeNoLocal() {
        let shouldApply = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: 1000, deviceId: "device-a"),
            local: nil
        )

        XCTAssertTrue(shouldApply, "Should always apply when no local version")
    }

    /// Test shouldKeepLocal is inverse of shouldApplyRemote.
    func testLWWShouldKeepLocal() {
        let local = (timestamp: Int64(2000), deviceId: "device-a")
        let remote = (timestamp: Int64(1000), deviceId: "device-b")

        let shouldApply = LWWMergeStrategy.shouldApplyRemote(remote: remote, local: local)
        let shouldKeep = LWWMergeStrategy.shouldKeepLocal(local: local, remote: remote)

        XCTAssertNotEqual(shouldApply, shouldKeep, "shouldKeepLocal should be inverse of shouldApplyRemote")
    }

    /// Test delete wins when timestamp is later.
    func testLWWDeleteWins() {
        XCTAssertTrue(
            LWWMergeStrategy.deleteWins(deleteTimestamp: 2000, dataTimestamp: 1000),
            "Delete with later timestamp should win"
        )

        XCTAssertFalse(
            LWWMergeStrategy.deleteWins(deleteTimestamp: 1000, dataTimestamp: 2000),
            "Delete with earlier timestamp should lose"
        )

        XCTAssertTrue(
            LWWMergeStrategy.deleteWins(deleteTimestamp: 1000, dataTimestamp: 1000),
            "Delete with equal timestamp should win"
        )
    }

    /// Test per-field merge.
    func testLWWMergeFields() {
        let localTimestamps = ["title": Int64(1000), "notes": Int64(2000)]
        let remoteTimestamps = ["title": Int64(3000), "notes": Int64(1000)]
        let localData: [String: Any] = ["title": "Local Title", "notes": "Local Notes"]
        let remoteData: [String: Any] = ["title": "Remote Title", "notes": "Remote Notes"]

        let result = LWWMergeStrategy.mergeFields(
            localTimestamps: localTimestamps,
            remoteTimestamps: remoteTimestamps,
            localData: localData,
            remoteData: remoteData
        )

        // title: remote wins (3000 > 1000)
        XCTAssertEqual(result.timestamps["title"], 3000)
        XCTAssertEqual(result.data["title"] as? String, "Remote Title")

        // notes: local wins (2000 > 1000)
        XCTAssertEqual(result.timestamps["notes"], 2000)
        XCTAssertEqual(result.data["notes"] as? String, "Local Notes")
    }

    // MARK: - Workspace Initializer Tests

    /// Test workspace initialization creates directory structure.
    func testWorkspaceInitialization() async throws {
        let initializer = WorkspaceInitializer(storage: storage)

        let config = try await initializer.initializeWorkspace()

        XCTAssertEqual(config.version, SyncConstants.workspaceConfigVersion)
        XCTAssertEqual(config.schemaVersion, SyncConstants.schemaVersion)
        XCTAssertEqual(config.encryption, .none)

        // Verify workspace file created
        let workspaceFileExists = await storage.fileExists(at: SyncConstants.workspaceFile)
        XCTAssertTrue(workspaceFileExists)

        // Verify directories created
        let directories = try await storage.listDirectories(at: "")
        XCTAssertTrue(directories.contains(SyncConstants.devicesDirectory))
        XCTAssertTrue(directories.contains(SyncConstants.changesDirectory))
        XCTAssertTrue(directories.contains(SyncConstants.snapshotsDirectory))
    }

    /// Test workspace load after create.
    func testWorkspaceLoadAfterCreate() async throws {
        let initializer = WorkspaceInitializer(storage: storage)

        // Create
        let created = try await initializer.initializeWorkspace()

        // Load
        let loaded = try await initializer.loadWorkspace()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(created.schemaVersion, loaded?.schemaVersion)
        XCTAssertEqual(created.encryption, loaded?.encryption)
    }

    /// Test getOrCreateWorkspace creates when not exists.
    func testGetOrCreateWorkspaceCreates() async throws {
        let initializer = WorkspaceInitializer(storage: storage)

        let existsBefore = await initializer.workspaceExists()
        XCTAssertFalse(existsBefore)

        let config = try await initializer.getOrCreateWorkspace()

        let existsAfter = await initializer.workspaceExists()
        XCTAssertTrue(existsAfter)
        XCTAssertEqual(config.schemaVersion, SyncConstants.schemaVersion)
    }

    /// Test getOrCreateWorkspace loads when exists.
    func testGetOrCreateWorkspaceLoads() async throws {
        let initializer = WorkspaceInitializer(storage: storage)

        // Create first
        let original = try await initializer.initializeWorkspace()

        // getOrCreate should return existing
        let loaded = try await initializer.getOrCreateWorkspace()

        XCTAssertEqual(original.schemaVersion, loaded.schemaVersion)
    }

    // MARK: - Device Registration Tests

    /// Test device registration creates device config.
    func testDeviceRegistration() async throws {
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.initializeWorkspace()

        let device = try await initializer.registerDevice(
            name: "Test iPhone",
            platform: .ios
        )

        XCTAssertFalse(device.deviceId.isEmpty)
        XCTAssertEqual(device.name, "Test iPhone")
        XCTAssertEqual(device.platform, .ios)
        XCTAssertEqual(device.syncScope.mode, SyncConstants.defaultSyncMode)

        // Verify device file created
        let devicePath = SyncFileNaming.deviceFilePath(deviceId: device.deviceId)
        let deviceFileExists = await storage.fileExists(at: devicePath)
        XCTAssertTrue(deviceFileExists)

        // Verify changes directory created
        let changesPath = "\(SyncConstants.changesDirectory)/\(device.deviceId)"
        let changesDirExists = await storage.fileExists(at: changesPath)
        XCTAssertTrue(changesDirExists)
    }

    /// Test device load by ID.
    func testLoadDeviceById() async throws {
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.initializeWorkspace()

        let registered = try await initializer.registerDevice(
            name: "Test Device",
            platform: .macos
        )

        let loaded = try await initializer.loadDevice(deviceId: registered.deviceId)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.deviceId, registered.deviceId)
        XCTAssertEqual(loaded?.name, registered.name)
        XCTAssertEqual(loaded?.platform, registered.platform)
    }

    /// Test list devices.
    func testListDevices() async throws {
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.initializeWorkspace()

        // Register multiple devices
        _ = try await initializer.registerDevice(name: "Device A", platform: .ios)
        _ = try await initializer.registerDevice(name: "Device B", platform: .macos)

        let devices = try await initializer.listDevices()

        XCTAssertEqual(devices.count, 2)
        XCTAssertTrue(devices.contains { $0.name == "Device A" })
        XCTAssertTrue(devices.contains { $0.name == "Device B" })
    }

    /// Test find device by name.
    func testFindDeviceByName() async throws {
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.initializeWorkspace()

        let registered = try await initializer.registerDevice(
            name: "Unique Name",
            platform: .ios
        )

        let found = try await initializer.findDevice(byName: "Unique Name")
        let notFound = try await initializer.findDevice(byName: "Not Exists")

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.deviceId, registered.deviceId)
        XCTAssertNil(notFound)
    }

    // MARK: - Sync Engine Tests

    /// Test sync engine initialization.
    func testSyncEngineInitialization() async throws {
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.initializeWorkspace()

        let deviceConfig = try await initializer.registerDevice(
            name: "Test Device",
            platform: .ios
        )

        let stateManager = SyncStateManager(
            storage: storage,
            deviceConfig: deviceConfig
        )

        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: deviceConfig.deviceId
        )

        let engine = SyncEngine(
            storage: storage,
            deviceId: deviceConfig.deviceId,
            stateManager: stateManager,
            writer: writer
        )

        let syncInProgress = await engine.isSyncInProgress()
        XCTAssertFalse(syncInProgress)
        let lastSyncTime = await engine.getLastSyncTime()
        XCTAssertNil(lastSyncTime)
    }

    /// Test sync result structure.
    func testSyncResultStructure() {
        var result = SyncResult(status: .success)
        result.devicesFound = 2
        result.changesReceived = 10
        result.changesSent = 5
        result.duration = 1.5

        XCTAssertEqual(result.devicesFound, 2)
        XCTAssertEqual(result.changesReceived, 10)
        XCTAssertEqual(result.changesSent, 5)
        XCTAssertEqual(result.duration, 1.5)
    }

    /// Test sync warning structure.
    func testSyncWarningStructure() {
        let warning = SyncWarning(deviceId: "device-123", message: "Test warning")

        XCTAssertEqual(warning.deviceId, "device-123")
        XCTAssertEqual(warning.message, "Test warning")
    }

    // MARK: - Integration Tests

    /// Test two-device discovery.
    func testTwoDeviceDiscovery() async throws {
        // Device A setup
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.initializeWorkspace()
        let configA = try await initializer.registerDevice(name: "Device A", platform: .ios)

        // Device B setup (same storage simulates iCloud sync)
        let configB = try await initializer.registerDevice(name: "Device B", platform: .macos)

        // Reader for device A should discover device B
        let readerA = ChangeLogReader(storage: storage, myDeviceId: configA.deviceId)
        let devicesFromA = try await readerA.discoverDevices()

        XCTAssertEqual(devicesFromA.count, 1)
        XCTAssertEqual(devicesFromA.first?.deviceId, configB.deviceId)
        XCTAssertEqual(devicesFromA.first?.name, "Device B")

        // Reader for device B should discover device A
        let readerB = ChangeLogReader(storage: storage, myDeviceId: configB.deviceId)
        let devicesFromB = try await readerB.discoverDevices()

        XCTAssertEqual(devicesFromB.count, 1)
        XCTAssertEqual(devicesFromB.first?.deviceId, configA.deviceId)
    }

    /// Test change recording and reading.
    func testChangeRecordingAndReading() async throws {
        // Setup workspace and device
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.initializeWorkspace()
        let deviceConfig = try await initializer.registerDevice(name: "Test Device", platform: .ios)

        // Create writer
        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: deviceConfig.deviceId
        )

        // Record some changes
        struct TestData: Codable, Sendable, Equatable {
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

        // Verify sequences
        XCTAssertEqual(change1.sequence, 1)
        XCTAssertEqual(change2.sequence, 2)
        XCTAssertNil(change1.previousHash)
        XCTAssertNotNil(change2.previousHash)

        // Verify vector clock
        let clock = await writer.getVectorClock()
        XCTAssertEqual(clock.sequence(for: deviceConfig.deviceId), 2)
    }

    // MARK: - Conflict Info Tests

    /// Test conflict info structure.
    func testConflictInfoStructure() {
        let info = ConflictInfo(
            entityType: .session,
            entityId: "session-123",
            localTimestamp: 1000,
            localDeviceId: "device-a",
            remoteTimestamp: 2000,
            remoteDeviceId: "device-b",
            winner: .remote
        )

        XCTAssertEqual(info.entityType, .session)
        XCTAssertEqual(info.entityId, "session-123")
        XCTAssertEqual(info.localTimestamp, 1000)
        XCTAssertEqual(info.localDeviceId, "device-a")
        XCTAssertEqual(info.remoteTimestamp, 2000)
        XCTAssertEqual(info.remoteDeviceId, "device-b")
        XCTAssertEqual(info.winner, .remote)
    }

    // MARK: - iCloud Availability Test

    /// Test iCloud availability check (will return false in test environment).
    func testICloudAvailabilityCheck() {
        // In test environment, iCloud is typically not available
        // This just verifies the API works
        _ = iCloudSyncStorage.isAvailable()
        // No assertion - just verifying it doesn't crash
    }

    // MARK: - Coordinator Status Tests

    /// Test coordinator status equality.
    func testCoordinatorStatusEquality() {
        XCTAssertEqual(SyncCoordinatorStatus.idle, SyncCoordinatorStatus.idle)
        XCTAssertEqual(SyncCoordinatorStatus.syncing, SyncCoordinatorStatus.syncing)
        XCTAssertEqual(SyncCoordinatorStatus.initializing, SyncCoordinatorStatus.initializing)

        // Any error equals any error (simplified comparison)
        let error1 = SyncStorageError.networkUnavailable
        let error2 = SyncStorageError.fileNotFound("test")
        XCTAssertEqual(SyncCoordinatorStatus.error(error1), SyncCoordinatorStatus.error(error2))

        // Different states are not equal
        XCTAssertNotEqual(SyncCoordinatorStatus.idle, SyncCoordinatorStatus.syncing)
    }
}
