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
import os.log

// MARK: - Sync Coordinator

/// High-level coordinator for sync operations.
///
/// The sync coordinator provides a simple, observable API for apps to trigger
/// and monitor sync operations. It handles initialization, state management,
/// and provides SwiftUI-compatible published properties.
///
/// ## Initialization
///
/// Before syncing, the coordinator must be initialized with a storage provider
/// and device information:
///
/// ```swift
/// @StateObject private var syncCoordinator = SyncCoordinator()
///
/// // In onAppear or similar:
/// try await syncCoordinator.initializeWithiCloud(
///     deviceName: "My iPhone",
///     platform: .ios,
///     delegate: myDelegate
/// )
/// ```
///
/// ## Triggering Sync
///
/// ```swift
/// await syncCoordinator.sync()
/// ```
///
/// ## Observing Status
///
/// ```swift
/// if syncCoordinator.status == .syncing {
///     ProgressView()
/// }
/// ```
@MainActor
public final class SyncCoordinator: ObservableObject {

    // MARK: - Published Properties

    /// Current sync status.
    @Published public private(set) var status: SyncCoordinatorStatus = .idle

    /// Last sync result with statistics.
    @Published public private(set) var lastResult: SyncResult?

    /// Timestamp of last successful sync.
    @Published public private(set) var lastSyncTime: Date?

    /// Whether sync is available (storage connected and initialized).
    @Published public private(set) var isAvailable: Bool = false

    /// Number of pending changes to upload.
    @Published public private(set) var pendingChangesCount: Int = 0

    // MARK: - Private Properties

    /// The sync engine instance.
    private var engine: SyncEngine?

    /// Storage provider.
    private var storage: SyncStorageProtocol?

    /// This device's configuration.
    private var deviceConfig: DeviceConfig?

    /// State manager for watermarks and exclusions.
    private var stateManager: SyncStateManager?

    /// Change log writer for recording local changes.
    private var writer: ChangeLogWriter?

    /// Logger for coordinator operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "SyncCoordinator"
    )

    /// User defaults key for storing device ID.
    private static let deviceIdKey = "com.bmlibrarian.sync.deviceId"

    // MARK: - Initialization

    /// Creates a sync coordinator.
    public init() {}

    // MARK: - Initialization Methods

    /// Initializes sync with iCloud storage.
    ///
    /// Sets up the sync system using iCloud Drive as the storage backend.
    /// This is the primary initialization method for Apple platforms.
    ///
    /// - Parameters:
    ///   - deviceName: Human-readable name for this device.
    ///   - platform: Platform identifier for this device.
    ///   - delegate: Delegate for applying changes to the local database.
    ///   - containerIdentifier: Optional iCloud container ID (nil for default).
    /// - Throws: `SyncStorageError.networkUnavailable` if iCloud unavailable.
    public func initializeWithiCloud(
        deviceName: String,
        platform: SyncPlatform,
        delegate: SyncEngineDelegate,
        containerIdentifier: String? = nil
    ) async throws {
        logger.info("Initializing sync with iCloud")
        status = .initializing

        do {
            // Check iCloud availability
            guard iCloudSyncStorage.isAvailable() else {
                logger.error("iCloud is not available")
                throw SyncStorageError.networkUnavailable
            }

            // Create iCloud storage
            let storage = try iCloudSyncStorage(containerIdentifier: containerIdentifier)
            self.storage = storage

            // Initialize workspace and device
            try await initializeWithStorage(
                storage,
                deviceName: deviceName,
                platform: platform,
                delegate: delegate
            )

            logger.info("iCloud sync initialized successfully")

        } catch {
            status = .error(error)
            logger.error("iCloud sync initialization failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Initializes sync with a local folder.
    ///
    /// Useful for testing or LAN-based sync via shared folders.
    ///
    /// - Parameters:
    ///   - rootURL: Root directory for sync files.
    ///   - deviceName: Human-readable name for this device.
    ///   - platform: Platform identifier for this device.
    ///   - delegate: Delegate for applying changes to the local database.
    /// - Throws: If initialization fails.
    public func initializeWithLocalFolder(
        rootURL: URL,
        deviceName: String,
        platform: SyncPlatform,
        delegate: SyncEngineDelegate
    ) async throws {
        logger.info("Initializing sync with local folder: \(rootURL.path)")
        status = .initializing

        do {
            let storage = try LocalFolderSyncStorage(rootURL: rootURL)
            self.storage = storage

            try await initializeWithStorage(
                storage,
                deviceName: deviceName,
                platform: platform,
                delegate: delegate
            )

            logger.info("Local folder sync initialized successfully")

        } catch {
            status = .error(error)
            logger.error("Local folder sync initialization failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Common initialization logic for any storage provider.
    private func initializeWithStorage(
        _ storage: SyncStorageProtocol,
        deviceName: String,
        platform: SyncPlatform,
        delegate: SyncEngineDelegate
    ) async throws {
        // Initialize or load workspace
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.getOrCreateWorkspace()

        // Get or create device registration
        let deviceConfig = try await getOrCreateDevice(
            initializer: initializer,
            name: deviceName,
            platform: platform
        )
        self.deviceConfig = deviceConfig

        // Create state manager
        let stateManager = SyncStateManager(
            storage: storage,
            deviceConfig: deviceConfig
        )
        try await stateManager.loadState()
        self.stateManager = stateManager

        // Create change log writer
        // Load initial sequence from existing changes
        let initialSequence = try await loadInitialSequence(
            storage: storage,
            deviceId: deviceConfig.deviceId
        )
        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: deviceConfig.deviceId,
            initialSequence: initialSequence
        )
        self.writer = writer

        // Create sync engine
        let engine = SyncEngine(
            storage: storage,
            deviceId: deviceConfig.deviceId,
            stateManager: stateManager,
            writer: writer
        )
        await engine.setDelegate(delegate)
        self.engine = engine

        isAvailable = true
        status = .idle
    }

    /// Loads the initial sequence number from existing changes.
    private func loadInitialSequence(
        storage: SyncStorageProtocol,
        deviceId: String
    ) async throws -> Int {
        let changesPath = "\(SyncConstants.changesDirectory)/\(deviceId)"

        guard await storage.fileExists(at: changesPath) else {
            return 0
        }

        let files = try await storage.listFiles(at: changesPath)
        var maxSequence = 0

        for file in files {
            if let components = SyncFileNaming.parseChangeFileName(file.name) {
                maxSequence = max(maxSequence, components.sequence)
            }
        }

        return maxSequence
    }

    /// Gets or creates a device registration.
    private func getOrCreateDevice(
        initializer: WorkspaceInitializer,
        name: String,
        platform: SyncPlatform
    ) async throws -> DeviceConfig {
        // Try to load stored device ID
        if let storedDeviceId = loadStoredDeviceId(),
           let existingDevice = try await initializer.loadDevice(deviceId: storedDeviceId) {
            logger.info("Found existing device: \(storedDeviceId)")

            // Update last seen
            var updatedDevice = existingDevice
            updatedDevice.lastSeen = Date()
            try await initializer.updateDevice(updatedDevice)

            return updatedDevice
        }

        // Try to find by name
        if let existingDevice = try await initializer.findDevice(byName: name, platform: platform) {
            logger.info("Found device by name: \(existingDevice.deviceId)")
            saveStoredDeviceId(existingDevice.deviceId)

            // Update last seen
            var updatedDevice = existingDevice
            updatedDevice.lastSeen = Date()
            try await initializer.updateDevice(updatedDevice)

            return updatedDevice
        }

        // Register new device
        let newDevice = try await initializer.registerDevice(name: name, platform: platform)
        saveStoredDeviceId(newDevice.deviceId)
        return newDevice
    }

    /// Loads the stored device ID from user defaults.
    private func loadStoredDeviceId() -> String? {
        UserDefaults.standard.string(forKey: Self.deviceIdKey)
    }

    /// Saves the device ID to user defaults.
    private func saveStoredDeviceId(_ deviceId: String) {
        UserDefaults.standard.set(deviceId, forKey: Self.deviceIdKey)
    }

    // MARK: - Sync Operations

    /// Triggers a sync operation.
    ///
    /// Downloads and applies remote changes, then uploads local changes.
    /// Only one sync can run at a time.
    public func sync() async {
        guard let engine = engine else {
            logger.warning("Sync requested but engine not initialized")
            return
        }

        guard status != .syncing else {
            logger.info("Sync already in progress")
            return
        }

        logger.info("Starting sync")
        status = .syncing

        do {
            let result = try await engine.sync()
            lastResult = result
            lastSyncTime = Date()

            switch result.status {
            case .success:
                status = .idle
                logger.info(
                    "Sync completed: \(result.changesReceived) received, \(result.changesSent) sent"
                )
            case .alreadyInProgress:
                status = .idle
            case .failed(let error):
                status = .error(error)
                logger.error("Sync failed: \(error.localizedDescription)")
            }

        } catch {
            status = .error(error)
            logger.error("Sync error: \(error.localizedDescription)")
        }
    }

    /// Records a change to be synced.
    ///
    /// Call this when local data changes to record the change for sync.
    ///
    /// - Parameters:
    ///   - entity: The type of entity that changed.
    ///   - id: The entity's unique identifier.
    ///   - data: The entity data to sync.
    /// - Returns: The recorded change log entry.
    /// - Throws: If the change cannot be recorded.
    @discardableResult
    public func recordUpsert<T: Codable & Sendable>(
        entity: SyncEntityType,
        id: String,
        data: T
    ) async throws -> ChangeLogEntry<T> {
        guard let writer = writer else {
            throw SyncStorageError.networkUnavailable
        }

        let entry: ChangeLogEntry<T> = try await writer.recordUpsert(
            entity: entity,
            id: id,
            data: data
        )

        pendingChangesCount += 1
        logger.debug("Recorded upsert: \(entity.rawValue) \(id)")

        return entry
    }

    /// Records a delete operation to be synced.
    ///
    /// - Parameters:
    ///   - entity: The type of entity deleted.
    ///   - id: The entity's unique identifier.
    /// - Returns: The recorded change log entry.
    /// - Throws: If the change cannot be recorded.
    @discardableResult
    public func recordDelete(
        entity: SyncEntityType,
        id: String
    ) async throws -> ChangeLogEntry<EmptyData> {
        guard let writer = writer else {
            throw SyncStorageError.networkUnavailable
        }

        let entry = try await writer.recordDelete(
            entity: entity,
            id: id
        )

        pendingChangesCount += 1
        logger.debug("Recorded delete: \(entity.rawValue) \(id)")

        return entry
    }

    // MARK: - Status

    /// Gets the current device ID, if initialized.
    public var deviceId: String? {
        deviceConfig?.deviceId
    }

    /// Gets the current device name, if initialized.
    public var deviceName: String? {
        deviceConfig?.name
    }

    /// Resets the sync state for troubleshooting.
    ///
    /// Clears local sync state but preserves the device registration.
    /// Use this if sync gets into a bad state.
    public func resetSyncState() async {
        guard let stateManager = stateManager else { return }

        logger.warning("Resetting sync state")
        await stateManager.resetWatermarks()
        pendingChangesCount = 0
    }
}

// MARK: - Coordinator Status

/// Status of the sync coordinator.
public enum SyncCoordinatorStatus: Equatable, Sendable {
    /// Sync is idle and ready.
    case idle

    /// Sync is being initialized.
    case initializing

    /// Sync is in progress.
    case syncing

    /// Sync encountered an error.
    case error(Error)

    public static func == (lhs: SyncCoordinatorStatus, rhs: SyncCoordinatorStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.initializing, .initializing), (.syncing, .syncing):
            return true
        case (.error, .error):
            // Simplified: any error equals any error
            return true
        default:
            return false
        }
    }
}

// MARK: - Sync State Manager Extension

extension SyncStateManager {
    /// Resets all watermarks to zero.
    ///
    /// Used for troubleshooting when sync state becomes inconsistent.
    func resetWatermarks() async {
        // This would need to be implemented in the actual SyncStateManager
        // For now, this is a placeholder
    }
}
