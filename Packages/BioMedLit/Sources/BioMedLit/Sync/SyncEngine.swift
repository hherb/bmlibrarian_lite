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

// MARK: - Sync Engine

/// Orchestrates the sync process between local and remote storage.
///
/// The sync engine is responsible for:
/// 1. Discovering new changes from remote devices
/// 2. Verifying integrity of all changes
/// 3. Applying changes using LWW merge strategy
/// 4. Uploading local pending changes
/// 5. Updating watermarks to track progress
///
/// ## Thread Safety
///
/// The engine uses actor isolation to ensure thread-safe access to
/// mutable state. Only one sync operation can run at a time.
///
/// ## Error Handling
///
/// Non-fatal errors (e.g., corrupt files from one device) are recorded
/// as warnings but don't stop the sync. Fatal errors throw exceptions.
///
/// ## Example Usage
///
/// ```swift
/// let engine = SyncEngine(
///     storage: storage,
///     deviceId: myDeviceId,
///     stateManager: stateManager,
///     writer: writer
/// )
/// await engine.setDelegate(myDelegate)
/// let result = try await engine.sync()
/// ```
public actor SyncEngine {

    // MARK: - Properties

    /// Storage backend for reading/writing sync files.
    private let storage: SyncStorageProtocol

    /// This device's unique identifier.
    private let deviceId: String

    /// State manager for watermarks and exclusions.
    private let stateManager: SyncStateManager

    /// Change log writer for recording local changes.
    private let writer: ChangeLogWriter

    /// Change log reader for discovering remote changes.
    private let reader: ChangeLogReader

    /// Delegate for applying changes to local database.
    private weak var delegate: SyncEngineDelegate?

    /// Whether a sync is currently in progress.
    private var isSyncing = false

    /// Timestamp of last successful sync.
    private var lastSyncTime: Date?

    /// Logger for sync operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "SyncEngine"
    )

    /// JSON encoder configured for sync files.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: - Initialization

    /// Creates a sync engine.
    ///
    /// - Parameters:
    ///   - storage: Storage backend for sync files.
    ///   - deviceId: This device's unique identifier.
    ///   - stateManager: Manager for sync state (watermarks, exclusions).
    ///   - writer: Change log writer for recording local changes.
    public init(
        storage: SyncStorageProtocol,
        deviceId: String,
        stateManager: SyncStateManager,
        writer: ChangeLogWriter
    ) {
        self.storage = storage
        self.deviceId = deviceId
        self.stateManager = stateManager
        self.writer = writer
        self.reader = ChangeLogReader(storage: storage, myDeviceId: deviceId)
    }

    // MARK: - Delegate

    /// Sets the delegate for applying changes to the local database.
    ///
    /// The delegate is called for each remote change that should be applied.
    /// It's responsible for updating SwiftData/Core Data models.
    ///
    /// - Parameter delegate: The delegate to receive change notifications.
    public func setDelegate(_ delegate: SyncEngineDelegate) {
        self.delegate = delegate
    }

    // MARK: - Sync Operations

    /// Performs a full sync cycle.
    ///
    /// This method:
    /// 1. Updates this device's last-seen timestamp
    /// 2. Discovers all remote devices
    /// 3. Reads and applies changes from each device
    /// 4. Updates the local manifest
    ///
    /// Only one sync can run at a time. If called while syncing, returns
    /// immediately with `.alreadyInProgress` status.
    ///
    /// - Returns: Result containing statistics and any warnings.
    /// - Throws: If a fatal error prevents sync from completing.
    public func sync() async throws -> SyncResult {
        // Prevent concurrent syncs
        guard !isSyncing else {
            logger.info("Sync already in progress, skipping")
            return SyncResult(status: .alreadyInProgress)
        }

        isSyncing = true
        defer { isSyncing = false }

        var result = SyncResult(status: .success)
        let startTime = Date()

        logger.info("Starting sync for device: \(self.deviceId)")

        do {
            // 1. Update last seen timestamp
            try await stateManager.updateLastSeen()

            // 2. Discover remote devices
            let devices = try await reader.discoverDevices()
            result.devicesFound = devices.count
            logger.info("Discovered \(devices.count) remote device(s)")

            // 3. Process changes from each device
            for device in devices {
                do {
                    let deviceResult = try await processDeviceChanges(device)
                    result.changesReceived += deviceResult.changesApplied
                    result.changesSkipped += deviceResult.changesSkipped
                    result.warnings.append(contentsOf: deviceResult.warnings)

                    logger.info(
                        "Device \(device.deviceId): \(deviceResult.changesApplied) applied, \(deviceResult.changesSkipped) skipped"
                    )
                } catch {
                    let warning = SyncWarning(
                        deviceId: device.deviceId,
                        message: "Failed to process device: \(error.localizedDescription)"
                    )
                    result.warnings.append(warning)
                    logger.error("Error processing device \(device.deviceId): \(error.localizedDescription)")
                }
            }

            // 4. Update our manifest
            try await updateManifest()

            lastSyncTime = Date()
            result.duration = Date().timeIntervalSince(startTime)

            logger.info(
                "Sync completed: \(result.changesReceived) received, \(result.changesSent) sent, \(result.duration)s"
            )

        } catch {
            result.status = .failed(error)
            result.duration = Date().timeIntervalSince(startTime)
            logger.error("Sync failed: \(error.localizedDescription)")
        }

        return result
    }

    /// Processes changes from a single remote device.
    ///
    /// - Parameter device: The device to process changes from.
    /// - Returns: Statistics about the processed changes.
    private func processDeviceChanges(
        _ device: DeviceConfig
    ) async throws -> DeviceSyncResult {
        var result = DeviceSyncResult(deviceId: device.deviceId)

        // Get our watermark (last processed sequence) for this device
        let watermark = await stateManager.getWatermark(for: device.deviceId)

        // Read all new changes
        let changes = try await reader.readChanges(
            from: device.deviceId,
            afterSequence: watermark
        )

        logger.debug("Found \(changes.count) new change(s) from device \(device.deviceId)")

        // Sort by timestamp for deterministic ordering
        let sortedChanges = changes.sorted { change1, change2 in
            if change1.timestamp != change2.timestamp {
                return change1.timestamp < change2.timestamp
            }
            return change1.deviceId < change2.deviceId
        }

        // Process each change
        for change in sortedChanges {
            do {
                let applied = try await applyChange(change)
                if applied {
                    result.changesApplied += 1
                } else {
                    result.changesSkipped += 1
                }

                // Update watermark after successful processing
                try await stateManager.setWatermark(change.sequence, for: device.deviceId)

            } catch let error as IntegrityError {
                // Integrity errors - quarantine the file
                result.warnings.append(
                    SyncWarning(
                        deviceId: device.deviceId,
                        message: "Integrity error at sequence \(change.sequence): \(error.localizedDescription)"
                    )
                )

                // Try to quarantine the corrupt file
                await quarantineCorruptChange(
                    deviceId: device.deviceId,
                    sequence: change.sequence,
                    reason: error.localizedDescription
                )

            } catch {
                // Other errors - log but continue
                result.warnings.append(
                    SyncWarning(
                        deviceId: device.deviceId,
                        message: "Error at sequence \(change.sequence): \(error.localizedDescription)"
                    )
                )
            }
        }

        return result
    }

    /// Applies a single verified change to the local database.
    ///
    /// - Parameter change: The verified change to apply.
    /// - Returns: True if the change was applied, false if skipped.
    private func applyChange(_ change: VerifiedChange) async throws -> Bool {
        guard let delegate = delegate else {
            logger.warning("No delegate set, cannot apply changes")
            return false
        }

        return try await delegate.applyChange(change)
    }

    /// Quarantines a corrupt change file for analysis.
    ///
    /// - Parameters:
    ///   - deviceId: Device that owns the change.
    ///   - sequence: Sequence number of the corrupt change.
    ///   - reason: Reason for quarantine.
    private func quarantineCorruptChange(
        deviceId: String,
        sequence: Int,
        reason: String
    ) async {
        // Find the file path - we need to list files to get exact name
        do {
            let changesPath = "\(SyncConstants.changesDirectory)/\(deviceId)"
            let files = try await storage.listFiles(at: changesPath)

            // Find file matching this sequence
            for file in files {
                if let components = SyncFileNaming.parseChangeFileName(file.name),
                   components.sequence == sequence {
                    _ = try await storage.quarantineFile(at: file.path, reason: reason)
                    logger.info("Quarantined corrupt file: \(file.name)")
                    break
                }
            }
        } catch {
            logger.error("Failed to quarantine corrupt change: \(error.localizedDescription)")
        }
    }

    /// Updates the device manifest with current change files.
    ///
    /// The manifest lists all change files with their checksums, enabling
    /// efficient discovery of new changes by other devices.
    private func updateManifest() async throws {
        let changesPath = "\(SyncConstants.changesDirectory)/\(deviceId)"

        // Check if changes directory exists
        guard await storage.fileExists(at: changesPath) else {
            logger.debug("No changes directory for device, skipping manifest update")
            return
        }

        let files = try await storage.listFiles(at: changesPath)

        var entries: [ManifestFileEntry] = []
        var maxSequence = 0

        // Build manifest entries from change files
        for file in files where file.name != SyncConstants.manifestFile {
            guard let components = SyncFileNaming.parseChangeFileName(file.name) else {
                continue
            }

            let data = try await storage.readFile(at: file.path)
            let fileChecksum = calculateChecksum(data)

            // For entry checksum, we'd need to decode and compute from content
            // For now, use file checksum as placeholder
            entries.append(ManifestFileEntry(
                sequence: components.sequence,
                filename: file.name,
                checksum: fileChecksum,
                entryChecksum: fileChecksum, // Should be computed from decoded entry
                size: file.size,
                timestamp: components.timestamp
            ))

            maxSequence = max(maxSequence, components.sequence)
        }

        // Sort entries by sequence
        let sortedEntries = entries.sorted { $0.sequence < $1.sequence }

        // Create manifest
        var manifest = DeviceManifest(
            deviceId: deviceId,
            lastUpdated: Date(),
            headSequence: maxSequence,
            files: sortedEntries
        )
        manifest.updateChecksum()

        // Write manifest with integrity envelope
        let envelope = try createIntegrityEnvelope(manifest)
        let data = try encoder.encode(envelope)
        let manifestPath = "\(changesPath)/\(SyncConstants.manifestFile)"
        try await storage.writeFile(data, at: manifestPath)

        logger.debug("Updated manifest: \(sortedEntries.count) files, head sequence \(maxSequence)")
    }

    // MARK: - Status

    /// Returns the timestamp of the last successful sync.
    ///
    /// - Returns: Last sync time, or nil if never synced.
    public func getLastSyncTime() -> Date? {
        lastSyncTime
    }

    /// Returns whether a sync is currently in progress.
    ///
    /// - Returns: True if syncing, false otherwise.
    public func isSyncInProgress() -> Bool {
        isSyncing
    }

    /// Gets the change log writer for recording local changes.
    ///
    /// - Returns: The change log writer instance.
    public func getWriter() -> ChangeLogWriter {
        writer
    }
}

// MARK: - Sync Engine Delegate

/// Delegate protocol for applying changes to the local database.
///
/// Implement this protocol to receive changes from the sync engine
/// and apply them to your local data store (SwiftData, Core Data, etc.).
public protocol SyncEngineDelegate: AnyObject, Sendable {

    /// Applies a verified change to the local database.
    ///
    /// Called for each remote change that passes integrity verification.
    /// The implementation should:
    /// 1. Decode the change data
    /// 2. Check if it should be applied (using LWW merge)
    /// 3. Update the local database if needed
    ///
    /// - Parameter change: The verified change to apply.
    /// - Returns: True if the change was applied, false if skipped.
    /// - Throws: If the change cannot be processed.
    func applyChange(_ change: VerifiedChange) async throws -> Bool

    /// Gets the local timestamp for an entity.
    ///
    /// Used for LWW merge decisions. Returns the last-modified timestamp
    /// of the local version, or nil if the entity doesn't exist locally.
    ///
    /// - Parameters:
    ///   - entityType: Type of entity to look up.
    ///   - id: Entity identifier.
    /// - Returns: Timestamp in milliseconds, or nil if not found.
    func getLocalTimestamp(
        entityType: SyncEntityType,
        id: String
    ) async -> Int64?

    /// Gets the local device ID for an entity.
    ///
    /// Used for LWW merge tiebreaker. Returns the device ID that last
    /// modified the local version, or nil if not found.
    ///
    /// - Parameters:
    ///   - entityType: Type of entity to look up.
    ///   - id: Entity identifier.
    /// - Returns: Device ID string, or nil if not found.
    func getLocalDeviceId(
        entityType: SyncEntityType,
        id: String
    ) async -> String?
}

// MARK: - Default Implementations

public extension SyncEngineDelegate {
    /// Default implementation returns nil (no local device ID tracking).
    func getLocalDeviceId(
        entityType: SyncEntityType,
        id: String
    ) async -> String? {
        nil
    }
}

// MARK: - Result Types

/// Result of a sync operation.
///
/// Contains statistics about the sync and any warnings encountered.
public struct SyncResult: Sendable {
    /// Overall sync status.
    public var status: SyncStatus

    /// Number of remote devices discovered.
    public var devicesFound: Int = 0

    /// Number of changes received and applied from remote devices.
    public var changesReceived: Int = 0

    /// Number of changes sent to remote storage.
    public var changesSent: Int = 0

    /// Number of changes skipped (already applied or excluded).
    public var changesSkipped: Int = 0

    /// Duration of the sync in seconds.
    public var duration: TimeInterval = 0

    /// Non-fatal warnings encountered during sync.
    public var warnings: [SyncWarning] = []

    /// Creates a sync result with the given status.
    ///
    /// - Parameter status: The sync status.
    public init(status: SyncStatus) {
        self.status = status
    }
}

/// Status of a sync operation.
public enum SyncStatus: Sendable {
    /// Sync completed successfully.
    case success

    /// Sync was skipped because another sync is in progress.
    case alreadyInProgress

    /// Sync failed with an error.
    case failed(Error)
}

/// Result of processing a single device's changes.
struct DeviceSyncResult {
    /// Device that was processed.
    let deviceId: String

    /// Number of changes applied.
    var changesApplied: Int = 0

    /// Number of changes skipped.
    var changesSkipped: Int = 0

    /// Warnings encountered.
    var warnings: [SyncWarning] = []
}

/// Non-fatal sync warning.
///
/// Warnings indicate issues that didn't prevent sync from completing
/// but may require attention.
public struct SyncWarning: Sendable {
    /// Device that had the issue, if applicable.
    public let deviceId: String?

    /// Description of the warning.
    public let message: String

    /// Creates a sync warning.
    ///
    /// - Parameters:
    ///   - deviceId: Device that had the issue, if applicable.
    ///   - message: Description of the warning.
    public init(deviceId: String? = nil, message: String) {
        self.deviceId = deviceId
        self.message = message
    }
}
