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

// MARK: - Change Log Writer

/// Writes changes to the local change log.
///
/// The change log writer records all local modifications as change files
/// in the sync storage. Each change is:
/// - Assigned a monotonic sequence number
/// - Timestamped for conflict resolution
/// - Linked to the previous change via hash chain
/// - Wrapped in an integrity envelope
///
/// Thread Safety: This class is an actor, providing automatic isolation
/// for all mutable state including sequence numbers and hash chains.
///
/// Example:
/// ```swift
/// let writer = ChangeLogWriter(
///     storage: storage,
///     deviceId: myDeviceId
/// )
///
/// // Record a session creation
/// let change = try await writer.recordUpsert(
///     entity: .session,
///     id: sessionId,
///     data: sessionData
/// )
///
/// // Record a deletion
/// try await writer.recordDelete(entity: .document, id: docId)
/// ```
public actor ChangeLogWriter {
    // MARK: - Properties

    /// Storage backend.
    private let storage: SyncStorageProtocol

    /// This device's unique identifier.
    private let deviceId: String

    /// Current sequence number (increments with each change).
    private var currentSequence: Int

    /// Hash of the last written change (for chain integrity).
    private var lastChangeHash: String?

    /// Current vector clock tracking causality.
    private var vectorClock: VectorClock

    /// Device manifest tracking all written files.
    private var manifest: DeviceManifest

    /// JSON encoder configured for sync files.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: - Initialization

    /// Creates a change log writer.
    ///
    /// - Parameters:
    ///   - storage: Storage backend for writing change files.
    ///   - deviceId: This device's unique identifier.
    ///   - initialSequence: Starting sequence number (default 0).
    ///   - lastHash: Hash of last change for chain continuity.
    ///   - vectorClock: Initial vector clock state.
    public init(
        storage: SyncStorageProtocol,
        deviceId: String,
        initialSequence: Int = 0,
        lastHash: String? = nil,
        vectorClock: VectorClock = VectorClock()
    ) {
        self.storage = storage
        self.deviceId = deviceId
        self.currentSequence = initialSequence
        self.lastChangeHash = lastHash
        self.vectorClock = vectorClock
        self.manifest = DeviceManifest(
            deviceId: deviceId,
            headSequence: initialSequence
        )
    }

    // MARK: - Public Methods

    /// Records an upsert (create or update) operation.
    ///
    /// Creates a change log entry for inserting or updating an entity.
    /// The entity data is included in the change file.
    ///
    /// - Parameters:
    ///   - entity: Type of entity being modified.
    ///   - id: Unique identifier of the entity.
    ///   - data: Complete entity data.
    /// - Returns: The written change entry.
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func recordUpsert<T: Codable & Sendable>(
        entity: SyncEntityType,
        id: String,
        data: T
    ) async throws -> ChangeLogEntry<T> {
        try await recordChange(
            type: .upsert,
            entity: entity,
            id: id,
            data: data
        )
    }

    /// Records a delete operation.
    ///
    /// Creates a change log entry for deleting an entity.
    /// Only the entity reference is recorded, not the data.
    ///
    /// - Parameters:
    ///   - entity: Type of entity being deleted.
    ///   - id: Unique identifier of the entity.
    /// - Returns: The written change entry.
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func recordDelete(
        entity: SyncEntityType,
        id: String
    ) async throws -> ChangeLogEntry<EmptyData> {
        try await recordChange(
            type: .delete,
            entity: entity,
            id: id,
            data: nil as EmptyData?
        )
    }

    /// Gets the current sequence number.
    ///
    /// This is the sequence of the last written change, or the initial
    /// sequence if no changes have been written.
    public func getCurrentSequence() -> Int {
        currentSequence
    }

    /// Gets the current vector clock.
    ///
    /// The vector clock tracks causality across all devices.
    public func getVectorClock() -> VectorClock {
        vectorClock
    }

    /// Gets the current manifest.
    ///
    /// The manifest lists all change files written by this device.
    public func getManifest() -> DeviceManifest {
        manifest
    }

    /// Updates the vector clock after receiving remote changes.
    ///
    /// Merges the remote clock with the local clock to maintain
    /// causality tracking. Call this after processing remote changes.
    ///
    /// - Parameter remote: Vector clock from remote changes.
    public func mergeVectorClock(_ remote: VectorClock) {
        vectorClock.merge(with: remote)
    }

    /// Writes the manifest file to storage.
    ///
    /// Call this periodically or after batches of changes to update
    /// the manifest that other devices read for change discovery.
    ///
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public func writeManifest() async throws {
        let envelope = try createIntegrityEnvelope(manifest)
        let data = try encoder.encode(envelope)
        let path = SyncFileNaming.manifestPath(deviceId: deviceId)
        try await storage.writeFile(data, at: path)
    }

    // MARK: - Private Methods

    /// Records a change to the log.
    ///
    /// This is the core method that creates change entries for both
    /// upserts and deletes.
    private func recordChange<T: Codable & Sendable>(
        type: SyncOperationType,
        entity: SyncEntityType,
        id: String,
        data: T?
    ) async throws -> ChangeLogEntry<T> {
        // Increment sequence for this change
        currentSequence += 1
        vectorClock.increment(for: deviceId)

        // Create timestamp (milliseconds since epoch)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        // Create the operation record
        let operation = SyncOperation(
            type: type,
            entity: entity,
            id: id,
            data: data,
            vectorClock: vectorClock
        )

        // Create the change log entry
        let change = ChangeLogEntry(
            deviceId: deviceId,
            sequence: currentSequence,
            timestamp: timestamp,
            previousHash: lastChangeHash,
            operation: operation
        )

        // Wrap in integrity envelope
        let envelope = try createIntegrityEnvelope(change)

        // Generate filename
        let filename = SyncFileNaming.changeFileName(
            sequence: currentSequence,
            timestamp: timestamp,
            entity: entity,
            operation: type
        )

        // Serialize and write to storage
        let fileData = try encoder.encode(envelope)
        let path = SyncFileNaming.changeFilePath(deviceId: deviceId, filename: filename)
        try await storage.writeFile(fileData, at: path)

        // Compute hash of the change entry for chain linking
        let entryChecksum = try calculateChecksum(change)
        lastChangeHash = entryChecksum

        // Update manifest with both file checksum and entry checksum
        let fileEntry = ManifestFileEntry(
            sequence: currentSequence,
            filename: filename,
            checksum: calculateChecksum(fileData),
            entryChecksum: entryChecksum,
            size: fileData.count,
            timestamp: timestamp
        )
        manifest.addFile(fileEntry)

        return change
    }
}

// MARK: - Empty Data

/// Placeholder type for delete operations that have no data.
///
/// Delete operations record the entity being deleted but don't include
/// entity data. This type serves as a placeholder for the generic parameter.
public struct EmptyData: Codable, Sendable, Equatable {
    /// Creates empty data.
    public init() {}
}

// MARK: - Change Log Writer Factory

/// Factory for creating change log writers with proper initialization.
///
/// Use this to create writers that resume from the current state,
/// properly linking to the existing hash chain.
public enum ChangeLogWriterFactory {
    /// Creates a change log writer initialized from existing state.
    ///
    /// Reads the device's manifest to determine the current sequence
    /// and last change hash for chain continuity.
    ///
    /// - Parameters:
    ///   - storage: Storage backend.
    ///   - deviceId: Device identifier.
    /// - Returns: Initialized change log writer.
    /// - Throws: `IntegrityError` or `SyncStorageError` on failure.
    public static func create(
        storage: SyncStorageProtocol,
        deviceId: String
    ) async throws -> ChangeLogWriter {
        // Check if manifest exists
        let manifestPath = SyncFileNaming.manifestPath(deviceId: deviceId)
        guard await storage.fileExists(at: manifestPath) else {
            // No existing manifest - start fresh
            return ChangeLogWriter(
                storage: storage,
                deviceId: deviceId
            )
        }

        // Read and verify manifest
        let manifestData = try await storage.readFile(at: manifestPath)
        let manifest: DeviceManifest = try verifyAndExtract(from: manifestData)

        // Get the entry checksum from the last file for chain linking
        let lastHash = manifest.files
            .max(by: { $0.sequence < $1.sequence })?
            .entryChecksum

        // Reconstruct vector clock from manifest
        var clock = VectorClock()
        clock.clocks[deviceId] = manifest.headSequence

        return ChangeLogWriter(
            storage: storage,
            deviceId: deviceId,
            initialSequence: manifest.headSequence,
            lastHash: lastHash,
            vectorClock: clock
        )
    }
}
