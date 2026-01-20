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

// MARK: - Workspace Initializer

/// Initializes a sync workspace for a new or existing device.
///
/// The workspace initializer handles:
/// - Creating the directory structure for sync
/// - Initializing workspace configuration
/// - Registering new devices
/// - Loading existing device configurations
///
/// ## Workspace Structure
///
/// ```
/// /BMLibrarian/
/// ├── workspace.json          # Workspace metadata
/// ├── devices/
/// │   └── {device_id}.json    # Device registrations
/// ├── changes/
/// │   └── {device_id}/        # Per-device change logs
/// └── snapshots/              # Periodic full-state snapshots
/// ```
///
/// ## Example Usage
///
/// ```swift
/// let initializer = WorkspaceInitializer(storage: storage)
/// let workspace = try await initializer.getOrCreateWorkspace()
/// let device = try await initializer.registerDevice(
///     name: "My iPhone",
///     platform: .ios
/// )
/// ```
public struct WorkspaceInitializer: Sendable {

    // MARK: - Properties

    /// Storage backend for reading/writing files.
    private let storage: SyncStorageProtocol

    /// Logger for initialization operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "WorkspaceInitializer"
    )

    /// JSON encoder configured for sync files.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: - Initialization

    /// Creates a workspace initializer.
    ///
    /// - Parameter storage: Storage backend to use for the workspace.
    public init(storage: SyncStorageProtocol) {
        self.storage = storage
    }

    // MARK: - Workspace Operations

    /// Initializes a new workspace.
    ///
    /// Creates the directory structure and workspace configuration file.
    /// This should only be called once when setting up a new workspace.
    ///
    /// - Parameter encryption: Encryption mode for the workspace (default: none).
    /// - Returns: The created workspace configuration.
    /// - Throws: If directories or files cannot be created.
    public func initializeWorkspace(
        encryption: EncryptionMode = .none
    ) async throws -> WorkspaceConfig {
        logger.info("Initializing new workspace")

        // Create directory structure
        try await storage.createDirectory(at: SyncConstants.devicesDirectory)
        try await storage.createDirectory(at: SyncConstants.changesDirectory)
        try await storage.createDirectory(at: SyncConstants.snapshotsDirectory)

        // Create workspace configuration
        let config = WorkspaceConfig(encryption: encryption)
        let envelope = try createIntegrityEnvelope(config)
        let data = try encoder.encode(envelope)
        try await storage.writeFile(data, at: SyncConstants.workspaceFile)

        logger.info("Workspace initialized successfully")
        return config
    }

    /// Loads an existing workspace configuration.
    ///
    /// - Returns: The workspace configuration, or nil if not found.
    /// - Throws: If the file exists but cannot be read or verified.
    public func loadWorkspace() async throws -> WorkspaceConfig? {
        guard await storage.fileExists(at: SyncConstants.workspaceFile) else {
            return nil
        }

        let data = try await storage.readFile(at: SyncConstants.workspaceFile)
        let config: WorkspaceConfig = try verifyAndExtract(from: data)

        logger.debug("Loaded workspace config, schema version \(config.schemaVersion)")
        return config
    }

    /// Gets or creates a workspace.
    ///
    /// If a workspace exists, loads and verifies it. If not, creates a new one.
    /// This is the recommended entry point for workspace initialization.
    ///
    /// - Parameter encryption: Encryption mode for new workspace (ignored if exists).
    /// - Returns: The workspace configuration.
    /// - Throws: `IntegrityError.schemaVersionTooNew` if workspace is incompatible.
    public func getOrCreateWorkspace(
        encryption: EncryptionMode = .none
    ) async throws -> WorkspaceConfig {
        if let existing = try await loadWorkspace() {
            // Verify compatibility
            if existing.minCompatibleVersion > SyncConstants.schemaVersion {
                logger.error(
                    "Workspace requires schema version \(existing.minCompatibleVersion), we only support \(SyncConstants.schemaVersion)"
                )
                throw IntegrityError.schemaVersionTooNew(
                    found: existing.minCompatibleVersion,
                    maxSupported: SyncConstants.schemaVersion
                )
            }
            return existing
        }

        return try await initializeWorkspace(encryption: encryption)
    }

    /// Checks if a workspace exists.
    ///
    /// - Returns: True if the workspace configuration file exists.
    public func workspaceExists() async -> Bool {
        await storage.fileExists(at: SyncConstants.workspaceFile)
    }

    // MARK: - Device Operations

    /// Registers a new device in the workspace.
    ///
    /// Creates a device configuration with a new UUID and writes it to storage.
    /// Also creates the device's change log directory.
    ///
    /// - Parameters:
    ///   - name: Human-readable name for the device (e.g., "My iPhone").
    ///   - platform: Platform identifier for the device.
    /// - Returns: The created device configuration with generated device ID.
    /// - Throws: If the device cannot be registered.
    public func registerDevice(
        name: String,
        platform: SyncPlatform
    ) async throws -> DeviceConfig {
        let deviceId = UUID().uuidString

        logger.info("Registering new device: \(name) (\(platform.rawValue)) with ID \(deviceId)")

        let config = DeviceConfig(
            deviceId: deviceId,
            name: name,
            platform: platform
        )

        // Write device configuration
        let envelope = try createIntegrityEnvelope(config)
        let data = try encoder.encode(envelope)
        let devicePath = SyncFileNaming.deviceFilePath(deviceId: deviceId)
        try await storage.writeFile(data, at: devicePath)

        // Create device's changes directory
        let changesPath = "\(SyncConstants.changesDirectory)/\(deviceId)"
        try await storage.createDirectory(at: changesPath)

        logger.info("Device registered successfully")
        return config
    }

    /// Loads an existing device configuration.
    ///
    /// - Parameter deviceId: The device's unique identifier.
    /// - Returns: The device configuration, or nil if not found.
    /// - Throws: If the file exists but cannot be read or verified.
    public func loadDevice(deviceId: String) async throws -> DeviceConfig? {
        let devicePath = SyncFileNaming.deviceFilePath(deviceId: deviceId)

        guard await storage.fileExists(at: devicePath) else {
            return nil
        }

        let data = try await storage.readFile(at: devicePath)
        let config: DeviceConfig = try verifyAndExtract(from: data)
        return config
    }

    /// Lists all registered devices.
    ///
    /// - Returns: Array of device configurations for all registered devices.
    /// - Throws: If devices cannot be read.
    public func listDevices() async throws -> [DeviceConfig] {
        guard await storage.fileExists(at: SyncConstants.devicesDirectory) else {
            return []
        }

        let files = try await storage.listFiles(at: SyncConstants.devicesDirectory)
        var devices: [DeviceConfig] = []

        for file in files where file.name.hasSuffix(".json") {
            do {
                let data = try await storage.readFile(at: file.path)
                let config: DeviceConfig = try verifyAndExtract(from: data)
                devices.append(config)
            } catch {
                logger.warning("Could not load device \(file.name): \(error.localizedDescription)")
            }
        }

        return devices
    }

    /// Updates an existing device configuration.
    ///
    /// - Parameter config: The updated device configuration.
    /// - Throws: If the device cannot be updated.
    public func updateDevice(_ config: DeviceConfig) async throws {
        let envelope = try createIntegrityEnvelope(config)
        let data = try encoder.encode(envelope)
        let devicePath = SyncFileNaming.deviceFilePath(deviceId: config.deviceId)
        try await storage.writeFile(data, at: devicePath)

        logger.debug("Updated device configuration for \(config.deviceId)")
    }

    /// Finds a device by name.
    ///
    /// Useful for reconnecting to an existing device registration after
    /// app reinstall. Searches by exact name match.
    ///
    /// - Parameters:
    ///   - name: The device name to search for.
    ///   - platform: Optionally filter by platform.
    /// - Returns: Matching device configuration, or nil if not found.
    public func findDevice(
        byName name: String,
        platform: SyncPlatform? = nil
    ) async throws -> DeviceConfig? {
        let devices = try await listDevices()

        return devices.first { device in
            device.name == name && (platform == nil || device.platform == platform)
        }
    }

    /// Gets or registers a device.
    ///
    /// Attempts to find an existing device by name, or registers a new one
    /// if not found. This is useful for handling app reinstalls where we
    /// want to reuse the existing device identity.
    ///
    /// - Parameters:
    ///   - name: Device name to search for or register.
    ///   - platform: Platform identifier.
    /// - Returns: Existing or newly registered device configuration.
    public func getOrRegisterDevice(
        name: String,
        platform: SyncPlatform
    ) async throws -> DeviceConfig {
        if let existing = try await findDevice(byName: name, platform: platform) {
            logger.info("Found existing device: \(existing.deviceId)")
            return existing
        }

        return try await registerDevice(name: name, platform: platform)
    }
}

// MARK: - Device Info Provider

/// Protocol for providing device information.
///
/// Implement this to customize how device name and platform are determined.
public protocol DeviceInfoProvider: Sendable {
    /// Gets the human-readable device name.
    func getDeviceName() -> String

    /// Gets the platform identifier.
    func getPlatform() -> SyncPlatform
}

/// Default device info provider using system APIs.
public struct SystemDeviceInfoProvider: DeviceInfoProvider {

    public init() {}

    public func getDeviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Unknown Device"
        #endif
    }

    public func getPlatform() -> SyncPlatform {
        #if os(iOS)
        return .ios
        #elseif os(macOS)
        return .macos
        #else
        return .desktop
        #endif
    }
}

#if os(iOS)
import UIKit
#endif
