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

// MARK: - Integrity Metadata

/// Metadata for verifying content integrity.
///
/// Every sync file includes this metadata to enable verification that
/// the content has not been corrupted or tampered with. The metadata
/// is computed when the file is written and verified when read.
public struct IntegrityMetadata: Codable, Sendable, Equatable {
    /// Envelope format version for future compatibility.
    ///
    /// If the format of the integrity envelope changes, this version
    /// allows readers to handle different formats appropriately.
    public let version: Int

    /// Hash algorithm used (e.g., "sha256").
    ///
    /// Stored explicitly so readers know how to verify the checksum.
    /// Currently only SHA-256 is supported.
    public let algorithm: String

    /// Hex-encoded checksum of the canonical JSON content.
    ///
    /// Computed over the content serialized to canonical JSON format
    /// (sorted keys, no whitespace, UTF-8).
    public let checksum: String

    /// Byte length of the canonical JSON content.
    ///
    /// Provides an additional verification that content wasn't truncated
    /// or extended.
    public let contentLength: Int

    /// Creates integrity metadata.
    ///
    /// - Parameters:
    ///   - version: Envelope format version. Defaults to current version.
    ///   - algorithm: Hash algorithm identifier. Defaults to SHA-256.
    ///   - checksum: Hex-encoded checksum of content.
    ///   - contentLength: Byte length of canonical JSON content.
    public init(
        version: Int = SyncConstants.integrityVersion,
        algorithm: String = SyncConstants.integrityAlgorithm,
        checksum: String,
        contentLength: Int
    ) {
        self.version = version
        self.algorithm = algorithm
        self.checksum = checksum
        self.contentLength = contentLength
    }
}

// MARK: - Integrity Envelope

/// Wrapper that includes content with integrity verification metadata.
///
/// The integrity envelope is the standard format for all sync files.
/// It wraps the actual content with metadata that enables verification
/// of data integrity after transmission or storage.
///
/// Example JSON structure:
/// ```json
/// {
///   "_integrity": {
///     "version": 1,
///     "algorithm": "sha256",
///     "checksum": "abc123...",
///     "contentLength": 1234
///   },
///   "_content": { ... actual data ... }
/// }
/// ```
public struct IntegrityEnvelope<T: Codable & Sendable>: Codable, Sendable {
    /// Integrity metadata for verification.
    public let integrity: IntegrityMetadata

    /// The actual content being wrapped.
    public let content: T

    enum CodingKeys: String, CodingKey {
        case integrity = "_integrity"
        case content = "_content"
    }

    /// Creates an integrity envelope.
    ///
    /// Note: Prefer using `createIntegrityEnvelope(_:)` function which
    /// automatically computes the checksum and length.
    ///
    /// - Parameters:
    ///   - integrity: Pre-computed integrity metadata.
    ///   - content: The content to wrap.
    public init(integrity: IntegrityMetadata, content: T) {
        self.integrity = integrity
        self.content = content
    }
}

// MARK: - Vector Clock

/// Vector clock for tracking causality across devices.
///
/// Vector clocks enable detecting concurrent modifications from different
/// devices. Each device maintains its own sequence counter, and the clock
/// captures the "latest known" sequence from each device at any point.
///
/// This is used to determine:
/// - Whether one change happened-before another
/// - Whether two changes are concurrent (conflict)
/// - How to merge state from multiple devices
public struct VectorClock: Codable, Sendable, Equatable {
    /// Map of device ID to that device's sequence number.
    ///
    /// A device increments its own sequence with each change.
    /// Other devices' sequences are updated when their changes are received.
    public var clocks: [String: Int]

    /// Creates an empty vector clock.
    ///
    /// An empty clock represents a state before any changes.
    public init() {
        self.clocks = [:]
    }

    /// Creates a vector clock with initial values.
    ///
    /// - Parameter clocks: Initial clock values keyed by device ID.
    public init(clocks: [String: Int]) {
        self.clocks = clocks
    }

    /// Gets the sequence number for a device.
    ///
    /// - Parameter deviceId: The device identifier.
    /// - Returns: The sequence number, or 0 if device not in clock.
    public func sequence(for deviceId: String) -> Int {
        clocks[deviceId] ?? 0
    }

    /// Increments the sequence number for a device.
    ///
    /// Called when the device creates a new change.
    ///
    /// - Parameter deviceId: The device identifier.
    /// - Returns: The new sequence number after incrementing.
    @discardableResult
    public mutating func increment(for deviceId: String) -> Int {
        let newValue = (clocks[deviceId] ?? 0) + 1
        clocks[deviceId] = newValue
        return newValue
    }

    /// Merges another vector clock (takes max of each component).
    ///
    /// After merging, this clock represents knowledge of all changes
    /// known to either clock.
    ///
    /// - Parameter other: The other vector clock to merge.
    public mutating func merge(with other: VectorClock) {
        for (deviceId, sequence) in other.clocks {
            clocks[deviceId] = max(clocks[deviceId] ?? 0, sequence)
        }
    }

    /// Checks if this clock causally happened-before another.
    ///
    /// Clock A happened-before clock B if:
    /// - All of A's components are <= B's components
    /// - At least one component is strictly less
    ///
    /// - Parameter other: The other vector clock.
    /// - Returns: True if this clock happened before the other.
    public func happenedBefore(_ other: VectorClock) -> Bool {
        var atLeastOneLess = false
        let allDevices = Set(clocks.keys).union(other.clocks.keys)

        for deviceId in allDevices {
            let thisSeq = sequence(for: deviceId)
            let otherSeq = other.sequence(for: deviceId)

            if thisSeq > otherSeq {
                // This clock has newer info - can't be before
                return false
            }
            if thisSeq < otherSeq {
                atLeastOneLess = true
            }
        }

        return atLeastOneLess
    }

    /// Checks if two clocks are concurrent (neither happened-before the other).
    ///
    /// Concurrent changes represent a conflict that needs resolution.
    ///
    /// - Parameter other: The other vector clock.
    /// - Returns: True if the clocks are concurrent.
    public func isConcurrent(with other: VectorClock) -> Bool {
        !happenedBefore(other) && !other.happenedBefore(self) && self != other
    }
}

// MARK: - Sync Operation

/// A single sync operation in the change log.
///
/// Represents one atomic change to the data, either creating/updating
/// an entity (upsert) or deleting it.
public struct SyncOperation<T: Codable & Sendable>: Codable, Sendable {
    /// Operation type (upsert or delete).
    public let type: SyncOperationType

    /// Entity type being modified.
    public let entity: SyncEntityType

    /// Entity UUID being modified.
    public let id: String

    /// Entity data (nil for deletes).
    ///
    /// For upserts, this contains the complete entity state.
    /// For deletes, this is nil.
    public let data: T?

    /// Vector clock at time of operation.
    ///
    /// Captures the causal context when this operation occurred.
    public let vectorClock: VectorClock

    /// Creates a sync operation.
    ///
    /// - Parameters:
    ///   - type: Operation type (upsert or delete).
    ///   - entity: Type of entity being modified.
    ///   - id: Unique identifier of the entity.
    ///   - data: Entity data (nil for deletes).
    ///   - vectorClock: Vector clock at operation time.
    public init(
        type: SyncOperationType,
        entity: SyncEntityType,
        id: String,
        data: T?,
        vectorClock: VectorClock
    ) {
        self.type = type
        self.entity = entity
        self.id = id
        self.data = data
        self.vectorClock = vectorClock
    }
}

// MARK: - Change Log Entry

/// A single entry in the device change log.
///
/// Change logs are append-only files that record all modifications
/// made by a device. Each entry forms a hash chain with the previous
/// entry for tamper detection.
///
/// The filename format is: `{sequence}_{timestamp}_{entity}_{operation}.json`
/// Example: `000042_1705772400000_session_upsert.json`
public struct ChangeLogEntry<T: Codable & Sendable>: Codable, Sendable {
    /// Schema version of this entry.
    ///
    /// Allows handling format changes over time.
    public let schemaVersion: Int

    /// Device that created this change.
    ///
    /// Combined with sequence, uniquely identifies this change globally.
    public let deviceId: String

    /// Monotonic sequence number for this device.
    ///
    /// Strictly increasing. Gaps indicate missing changes.
    public let sequence: Int

    /// Timestamp in milliseconds since Unix epoch.
    ///
    /// Used for last-writer-wins conflict resolution.
    public let timestamp: Int64

    /// Hash of the previous change (nil for first change).
    ///
    /// Forms a hash chain for tamper detection.
    public let previousHash: String?

    /// The operation being recorded.
    public let operation: SyncOperation<T>

    /// Creates a change log entry.
    ///
    /// - Parameters:
    ///   - schemaVersion: Schema version. Defaults to current.
    ///   - deviceId: Device creating this change.
    ///   - sequence: Monotonic sequence number.
    ///   - timestamp: Timestamp in milliseconds.
    ///   - previousHash: Hash of previous entry (nil for first).
    ///   - operation: The sync operation.
    public init(
        schemaVersion: Int = SyncConstants.schemaVersion,
        deviceId: String,
        sequence: Int,
        timestamp: Int64,
        previousHash: String?,
        operation: SyncOperation<T>
    ) {
        self.schemaVersion = schemaVersion
        self.deviceId = deviceId
        self.sequence = sequence
        self.timestamp = timestamp
        self.previousHash = previousHash
        self.operation = operation
    }
}
