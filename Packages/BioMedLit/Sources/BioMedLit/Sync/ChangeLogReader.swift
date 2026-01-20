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

// MARK: - Change Log Reader

/// Reads and verifies changes from remote devices.
///
/// The change log reader discovers other devices in the workspace,
/// reads their manifests, and fetches new changes. All data is verified
/// against checksums before being returned.
///
/// Thread Safety: This is a value type (struct) with no mutable state.
/// It's safe to use from any context.
///
/// Example:
/// ```swift
/// let reader = ChangeLogReader(storage: storage, myDeviceId: deviceId)
///
/// // Discover other devices
/// let devices = try await reader.discoverDevices()
///
/// // Read new changes from each device
/// for device in devices {
///     let changes = try await reader.readChanges(
///         from: device.deviceId,
///         afterSequence: watermarks.watermark(for: device.deviceId)
///     )
///     // Process changes...
/// }
/// ```
public struct ChangeLogReader: Sendable {
    // MARK: - Properties

    /// Storage backend.
    private let storage: SyncStorageProtocol

    /// This device's ID (to skip own changes).
    private let myDeviceId: String

    // MARK: - Initialization

    /// Creates a change log reader.
    ///
    /// - Parameters:
    ///   - storage: Storage backend to read from.
    ///   - myDeviceId: This device's identifier (own changes are skipped).
    public init(storage: SyncStorageProtocol, myDeviceId: String) {
        self.storage = storage
        self.myDeviceId = myDeviceId
    }

    // MARK: - Device Discovery

    /// Discovers all devices in the workspace.
    ///
    /// Reads the devices directory and returns configuration for all
    /// registered devices except this one.
    ///
    /// - Returns: Array of device configurations.
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func discoverDevices() async throws -> [DeviceConfig] {
        // List all files in devices directory
        let deviceFiles: [SyncFileInfo]
        do {
            deviceFiles = try await storage.listFiles(at: SyncConstants.devicesDirectory)
        } catch SyncStorageError.directoryNotFound {
            // No devices directory yet
            return []
        }

        var devices: [DeviceConfig] = []

        for file in deviceFiles {
            // Skip non-JSON files
            guard file.name.hasSuffix(".\(SyncConstants.syncFileExtension)") else {
                continue
            }

            do {
                let data = try await storage.readFile(at: file.path)
                let config: DeviceConfig = try verifyAndExtract(from: data)

                // Skip self
                if config.deviceId != myDeviceId {
                    devices.append(config)
                }
            } catch {
                // Log warning but continue with other devices
                // A corrupt device file shouldn't stop discovery
                continue
            }
        }

        return devices
    }

    /// Discovers all remote devices (alias for discoverDevices).
    ///
    /// - Returns: Array of remote device configurations.
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func discoverRemoteDevices() async throws -> [DeviceConfig] {
        try await discoverDevices()
    }

    // MARK: - Manifest Reading

    /// Reads the manifest for a device.
    ///
    /// - Parameter deviceId: Device identifier.
    /// - Returns: Device manifest, or nil if not found.
    /// - Throws: `IntegrityError` if manifest is corrupt.
    public func readManifest(for deviceId: String) async throws -> DeviceManifest? {
        let path = SyncFileNaming.manifestPath(deviceId: deviceId)

        guard await storage.fileExists(at: path) else {
            return nil
        }

        let data = try await storage.readFile(at: path)
        return try verifyAndExtract(from: data)
    }

    // MARK: - Change Reading

    /// Reads changes from a device that are newer than a watermark.
    ///
    /// Returns verified changes sorted by sequence number. Each change
    /// has been verified against the manifest checksum.
    ///
    /// - Parameters:
    ///   - deviceId: Device identifier.
    ///   - afterSequence: Only return changes after this sequence.
    /// - Returns: Array of verified changes in sequence order.
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func readChanges(
        from deviceId: String,
        afterSequence: Int
    ) async throws -> [VerifiedChange] {
        // Read manifest to get file list
        guard let manifest = try await readManifest(for: deviceId) else {
            return []
        }

        // Filter to files newer than watermark
        let newFiles = manifest.files
            .filter { $0.sequence > afterSequence }
            .sorted { $0.sequence < $1.sequence }

        var changes: [VerifiedChange] = []

        for fileEntry in newFiles {
            let path = SyncFileNaming.changeFilePath(
                deviceId: deviceId,
                filename: fileEntry.filename
            )

            let data = try await storage.readFile(at: path)

            // Verify file checksum matches manifest
            let actualChecksum = calculateChecksum(data)
            guard actualChecksum == fileEntry.checksum else {
                throw IntegrityError.checksumMismatch(
                    expected: fileEntry.checksum,
                    actual: actualChecksum
                )
            }

            changes.append(VerifiedChange(
                deviceId: deviceId,
                sequence: fileEntry.sequence,
                timestamp: fileEntry.timestamp,
                data: data
            ))
        }

        return changes
    }

    /// Reads and decodes a specific change.
    ///
    /// Decodes the verified change data into a typed change log entry.
    ///
    /// - Parameter change: Verified change data.
    /// - Returns: Decoded and verified change entry.
    /// - Throws: `IntegrityError` if decoding or verification fails.
    public func decodeChange<T: Codable & Sendable>(
        _ change: VerifiedChange
    ) throws -> ChangeLogEntry<T> {
        try verifyAndExtract(from: change.data)
    }

    // MARK: - Batch Discovery

    /// Discovers all new changes from all remote devices.
    ///
    /// This is a convenience method that discovers devices, reads their
    /// manifests, and fetches all changes newer than the provided watermarks.
    ///
    /// - Parameter watermarks: Current watermarks for each device.
    /// - Returns: Discovery result with changes and updated watermarks.
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func discoverNewChanges(
        watermarks: SyncWatermarks
    ) async throws -> ChangeDiscoveryResult {
        let devices = try await discoverDevices()
        var allChanges: [VerifiedChange] = []
        var newWatermarks = watermarks
        var warnings: [ChangeDiscoveryWarning] = []

        for device in devices {
            do {
                let changes = try await readChanges(
                    from: device.deviceId,
                    afterSequence: watermarks.watermark(for: device.deviceId)
                )

                allChanges.append(contentsOf: changes)

                // Update watermark to highest sequence seen
                if let maxSequence = changes.map(\.sequence).max() {
                    newWatermarks.setWatermark(maxSequence, for: device.deviceId)
                }
            } catch {
                // Record warning but continue with other devices
                warnings.append(ChangeDiscoveryWarning(
                    deviceId: device.deviceId,
                    message: "Failed to read changes: \(error.localizedDescription)",
                    error: error
                ))
            }
        }

        // Sort all changes by timestamp for merge ordering
        allChanges.sort { $0.timestamp < $1.timestamp }

        return ChangeDiscoveryResult(
            changes: allChanges,
            newWatermarks: newWatermarks,
            warnings: warnings
        )
    }
}

// MARK: - Verified Change

/// A change that has been verified against the manifest.
///
/// The raw data is included for decoding - integrity has been verified
/// but the specific type is not yet decoded.
public struct VerifiedChange: Sendable {
    /// Source device ID.
    public let deviceId: String

    /// Sequence number (unique within device).
    public let sequence: Int

    /// Timestamp in milliseconds since Unix epoch.
    public let timestamp: Int64

    /// Raw JSON data (integrity verified against manifest).
    public let data: Data

    /// Creates a verified change.
    ///
    /// - Parameters:
    ///   - deviceId: Source device identifier.
    ///   - sequence: Sequence number.
    ///   - timestamp: Timestamp in milliseconds.
    ///   - data: Verified raw JSON data.
    public init(
        deviceId: String,
        sequence: Int,
        timestamp: Int64,
        data: Data
    ) {
        self.deviceId = deviceId
        self.sequence = sequence
        self.timestamp = timestamp
        self.data = data
    }
}

// MARK: - Change Discovery Result

/// Result of discovering new changes from remote devices.
public struct ChangeDiscoveryResult: Sendable {
    /// All new changes sorted by timestamp.
    public let changes: [VerifiedChange]

    /// Updated watermarks after processing.
    public let newWatermarks: SyncWatermarks

    /// Any warnings encountered (non-fatal errors).
    public let warnings: [ChangeDiscoveryWarning]

    /// Whether any new changes were found.
    public var hasChanges: Bool {
        !changes.isEmpty
    }

    /// Total number of changes found.
    public var changeCount: Int {
        changes.count
    }

    /// Creates a discovery result.
    ///
    /// - Parameters:
    ///   - changes: Discovered changes.
    ///   - newWatermarks: Updated watermarks.
    ///   - warnings: Any warnings encountered.
    public init(
        changes: [VerifiedChange],
        newWatermarks: SyncWatermarks,
        warnings: [ChangeDiscoveryWarning]
    ) {
        self.changes = changes
        self.newWatermarks = newWatermarks
        self.warnings = warnings
    }
}

// MARK: - Change Discovery Warning

/// Warning during change discovery (non-fatal).
///
/// Warnings are recorded when some devices or files couldn't be read
/// but discovery continued with remaining data.
public struct ChangeDiscoveryWarning: Sendable {
    /// Device that had the issue.
    public let deviceId: String

    /// Human-readable description of the warning.
    public let message: String

    /// The underlying error, if any.
    public let error: Error?

    /// Creates a discovery warning.
    ///
    /// - Parameters:
    ///   - deviceId: Device identifier.
    ///   - message: Warning message.
    ///   - error: Underlying error.
    public init(
        deviceId: String,
        message: String,
        error: Error?
    ) {
        self.deviceId = deviceId
        self.message = message
        self.error = error
    }
}
