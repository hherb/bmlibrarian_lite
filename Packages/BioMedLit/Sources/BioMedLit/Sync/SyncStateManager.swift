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

// MARK: - Sync State Manager

/// Manages local sync state (watermarks, exclusions, device config).
///
/// The sync state manager is the primary interface for tracking sync progress
/// on a device. It manages:
/// - Watermarks: How far we've processed each remote device's changes
/// - Exclusions: Sessions excluded from sync on this device
/// - Device config: This device's sync configuration
///
/// State is persisted locally and survives app restarts.
///
/// Thread Safety: This class is an actor, providing automatic isolation
/// for all mutable state.
///
/// Example:
/// ```swift
/// let manager = SyncStateManager(
///     storage: storage,
///     deviceConfig: myConfig
/// )
/// try await manager.loadState()
///
/// // Check watermark before reading changes
/// let watermark = manager.getWatermark(for: remoteDeviceId)
///
/// // After processing changes, update watermark
/// try await manager.setWatermark(newSequence, for: remoteDeviceId)
/// ```
public actor SyncStateManager {
    // MARK: - Properties

    /// Storage backend for persisting state.
    private let storage: SyncStorageProtocol

    /// This device's configuration.
    private var deviceConfig: DeviceConfig

    /// Watermarks tracking progress per remote device.
    private var watermarks: SyncWatermarks

    /// Local exclusions (sessions not synced on this device).
    private var exclusions: LocalExclusions

    /// Path for local state file.
    private let localStatePath: String

    /// JSON encoder for state persistence.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: - Initialization

    /// Creates a sync state manager.
    ///
    /// - Parameters:
    ///   - storage: Storage backend for persistence.
    ///   - deviceConfig: This device's configuration.
    ///   - localStatePath: Path for local state file (default: "local_state.json").
    public init(
        storage: SyncStorageProtocol,
        deviceConfig: DeviceConfig,
        localStatePath: String = "local_state.json"
    ) {
        self.storage = storage
        self.deviceConfig = deviceConfig
        self.watermarks = SyncWatermarks()
        self.exclusions = LocalExclusions()
        self.localStatePath = localStatePath
    }

    // MARK: - State Persistence

    /// Loads state from storage.
    ///
    /// Reads the local state file if it exists. If not found or corrupt,
    /// starts with empty state.
    ///
    /// - Throws: `IntegrityError` if state file exists but is corrupt.
    public func loadState() async throws {
        guard await storage.fileExists(at: localStatePath) else {
            // No existing state - start fresh
            return
        }

        let data = try await storage.readFile(at: localStatePath)
        let state: LocalSyncState = try verifyAndExtract(from: data)

        self.watermarks = state.watermarks
        self.exclusions = state.exclusions
    }

    /// Saves state to storage.
    ///
    /// Persists the current watermarks and exclusions.
    ///
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func saveState() async throws {
        let state = LocalSyncState(
            deviceId: deviceConfig.deviceId,
            watermarks: watermarks,
            exclusions: exclusions,
            lastSaved: Date()
        )

        let envelope = try createIntegrityEnvelope(state)
        let data = try encoder.encode(envelope)
        try await storage.writeFile(data, at: localStatePath)
    }

    // MARK: - Watermarks

    /// Gets watermark for a remote device.
    ///
    /// The watermark is the last sequence number we've processed from
    /// that device. Changes with sequence > watermark are new.
    ///
    /// - Parameter deviceId: Remote device identifier.
    /// - Returns: Last processed sequence, or 0 if never synced.
    public func getWatermark(for deviceId: String) -> Int {
        watermarks.watermark(for: deviceId)
    }

    /// Gets all watermarks.
    ///
    /// - Returns: Copy of current watermarks.
    public func getWatermarks() -> SyncWatermarks {
        watermarks
    }

    /// Updates watermark for a remote device.
    ///
    /// Call after successfully processing changes from a device.
    /// Automatically persists state.
    ///
    /// - Parameters:
    ///   - sequence: New watermark value.
    ///   - deviceId: Remote device identifier.
    /// - Throws: `SyncStorageError` if state cannot be saved.
    public func setWatermark(_ sequence: Int, for deviceId: String) async throws {
        watermarks.setWatermark(sequence, for: deviceId)
        try await saveState()
    }

    /// Updates multiple watermarks at once.
    ///
    /// More efficient than multiple setWatermark calls when processing
    /// changes from multiple devices.
    ///
    /// - Parameter newWatermarks: Watermarks to merge (takes max).
    /// - Throws: `SyncStorageError` if state cannot be saved.
    public func mergeWatermarks(_ newWatermarks: SyncWatermarks) async throws {
        for (deviceId, sequence) in newWatermarks.watermarks {
            let current = watermarks.watermark(for: deviceId)
            if sequence > current {
                watermarks.setWatermark(sequence, for: deviceId)
            }
        }
        try await saveState()
    }

    // MARK: - Exclusions

    /// Checks if a session is excluded from sync.
    ///
    /// Excluded sessions exist in the cloud but are not synced to
    /// this device (user deleted locally, removed from scope, or evicted).
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if session is excluded.
    public func isExcluded(_ sessionId: String) -> Bool {
        exclusions.isExcluded(sessionId)
    }

    /// Gets the exclusion reason for a session.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Exclusion reason, or nil if not excluded.
    public func exclusionReason(for sessionId: String) -> ExclusionReason? {
        exclusions.reason(for: sessionId)
    }

    /// Gets all exclusions.
    ///
    /// - Returns: Copy of current exclusions.
    public func getExclusions() -> LocalExclusions {
        exclusions
    }

    /// Excludes a session from sync on this device.
    ///
    /// The session will not be downloaded even if it exists in the cloud.
    /// Automatically persists state.
    ///
    /// - Parameters:
    ///   - sessionId: Session to exclude.
    ///   - reason: Reason for exclusion.
    /// - Throws: `SyncStorageError` if state cannot be saved.
    public func exclude(_ sessionId: String, reason: ExclusionReason) async throws {
        exclusions.exclude(sessionId, reason: reason)
        try await saveState()
    }

    /// Re-includes a previously excluded session.
    ///
    /// The session will be synced on the next sync cycle if it exists
    /// in the cloud and matches the sync scope.
    /// Automatically persists state.
    ///
    /// - Parameter sessionId: Session to include.
    /// - Throws: `SyncStorageError` if state cannot be saved.
    public func include(_ sessionId: String) async throws {
        exclusions.include(sessionId)
        try await saveState()
    }

    // MARK: - Device Configuration

    /// Gets this device's configuration.
    ///
    /// - Returns: Current device configuration.
    public func getDeviceConfig() -> DeviceConfig {
        deviceConfig
    }

    /// Updates and uploads device configuration.
    ///
    /// Updates both the local config and the device file in storage
    /// that other devices read.
    ///
    /// - Parameter config: New device configuration.
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func updateDeviceConfig(_ config: DeviceConfig) async throws {
        self.deviceConfig = config

        let envelope = try createIntegrityEnvelope(config)
        let data = try encoder.encode(envelope)
        let path = SyncFileNaming.deviceFilePath(deviceId: config.deviceId)
        try await storage.writeFile(data, at: path)
    }

    /// Updates the sync scope configuration.
    ///
    /// Convenience method to update just the sync scope.
    ///
    /// - Parameter scope: New sync scope.
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func updateSyncScope(_ scope: SyncScope) async throws {
        var config = deviceConfig
        config.syncScope = scope
        try await updateDeviceConfig(config)
    }

    /// Updates last seen timestamp.
    ///
    /// Call after each successful sync to let other devices know
    /// this device is active.
    ///
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func updateLastSeen() async throws {
        var config = deviceConfig
        config.lastSeen = Date()
        try await updateDeviceConfig(config)
    }

    // MARK: - Registration

    /// Registers this device in the workspace.
    ///
    /// Creates the device configuration file in storage. Call this when
    /// first joining a workspace.
    ///
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func registerDevice() async throws {
        // Ensure devices directory exists
        try await storage.createDirectory(at: SyncConstants.devicesDirectory)

        // Ensure this device's changes directory exists
        try await storage.createDirectory(
            at: SyncFileNaming.deviceChangesDirectory(deviceId: deviceConfig.deviceId)
        )

        // Write device config
        try await updateDeviceConfig(deviceConfig)
    }
}

// MARK: - Local Sync State

/// Local state persisted on device.
///
/// This captures all the local-only state that doesn't sync to other
/// devices but needs to survive app restarts.
struct LocalSyncState: Codable, Sendable {
    /// Device that owns this state.
    let deviceId: String

    /// Watermarks tracking sync progress.
    let watermarks: SyncWatermarks

    /// Sessions excluded from sync.
    let exclusions: LocalExclusions

    /// When state was last saved.
    let lastSaved: Date
}

// MARK: - Factory

/// Factory for creating sync state managers.
public enum SyncStateManagerFactory {
    /// Creates and initializes a sync state manager.
    ///
    /// Loads existing state if available.
    ///
    /// - Parameters:
    ///   - storage: Storage backend.
    ///   - deviceConfig: This device's configuration.
    ///   - localStatePath: Path for state file.
    /// - Returns: Initialized state manager.
    /// - Throws: `IntegrityError` if state file is corrupt.
    public static func create(
        storage: SyncStorageProtocol,
        deviceConfig: DeviceConfig,
        localStatePath: String = "local_state.json"
    ) async throws -> SyncStateManager {
        let manager = SyncStateManager(
            storage: storage,
            deviceConfig: deviceConfig,
            localStatePath: localStatePath
        )
        try await manager.loadState()
        return manager
    }
}
