import Foundation

// MARK: - Integrity Metadata

/// Metadata for verifying content integrity within a sync file.
///
/// This structure is embedded in every sync file and contains the information
/// needed to verify that the file contents have not been corrupted or tampered with.
///
/// ## Verification Process
/// 1. Extract the content from the file
/// 2. Serialize it to canonical JSON (sorted keys, no whitespace)
/// 3. Compute the SHA-256 hash
/// 4. Compare with the stored checksum and length
///
/// ## Example
/// ```swift
/// let metadata = IntegrityMetadata(
///     checksum: "a1b2c3...",
///     contentLength: 1234
/// )
/// ```
public struct IntegrityMetadata: Codable, Sendable, Equatable {
    /// Envelope format version for future compatibility.
    ///
    /// If we need to change the envelope format, we can increment this
    /// version and add migration logic.
    public let version: Int

    /// Hash algorithm used for the checksum (e.g., "sha256").
    ///
    /// Stored explicitly so we can upgrade to stronger algorithms
    /// in the future while still reading old files.
    public let algorithm: String

    /// Hex-encoded checksum of the canonical JSON content.
    ///
    /// This is the SHA-256 hash of the content after serializing
    /// to canonical JSON (sorted keys, compact format).
    public let checksum: String

    /// Byte length of the canonical JSON content.
    ///
    /// Provides an additional check against data corruption.
    /// Must match the actual serialized content length.
    public let contentLength: Int

    /// Creates integrity metadata with the specified values.
    ///
    /// - Parameters:
    ///   - version: Envelope format version. Defaults to current version.
    ///   - algorithm: Hash algorithm identifier. Defaults to "sha256".
    ///   - checksum: Hex-encoded checksum of the content.
    ///   - contentLength: Byte length of the serialized content.
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
/// Every sync file is wrapped in this envelope, which contains both the
/// actual content and the metadata needed to verify its integrity.
///
/// ## JSON Structure
/// ```json
/// {
///     "_integrity": {
///         "version": 1,
///         "algorithm": "sha256",
///         "checksum": "a1b2c3...",
///         "contentLength": 1234
///     },
///     "_content": { ... actual data ... }
/// }
/// ```
///
/// The underscore prefix on field names is intentional to distinguish
/// envelope metadata from content fields.
///
/// ## Example
/// ```swift
/// let envelope = try createIntegrityEnvelope(myData)
/// // Write envelope to file
///
/// // Later, read and verify
/// let verified = try verifyAndExtract(envelope)
/// ```
public struct IntegrityEnvelope<T: Codable & Sendable>: Codable, Sendable {
    /// Integrity metadata for verification.
    public let integrity: IntegrityMetadata

    /// The actual content being wrapped.
    public let content: T

    /// Coding keys with underscore prefix to avoid collisions with content fields.
    enum CodingKeys: String, CodingKey {
        case integrity = "_integrity"
        case content = "_content"
    }

    /// Creates an integrity envelope wrapping the given content.
    ///
    /// Note: This initializer does not compute the checksum. Use the
    /// `createIntegrityEnvelope(_:)` function to create a properly
    /// initialized envelope with computed integrity metadata.
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

/// Vector clock for tracking causality across multiple devices.
///
/// A vector clock is a data structure that allows us to determine the
/// causal ordering of events in a distributed system. Each device maintains
/// a counter, and comparing these counters tells us whether one event
/// happened before another or if they are concurrent.
///
/// ## How It Works
/// - Each device has a counter starting at 0
/// - When a device creates a change, it increments its own counter
/// - When receiving a change, the clock is merged (max of each device's counter)
/// - Comparing clocks tells us: happened-before, happened-after, or concurrent
///
/// ## Example
/// ```swift
/// var clock = VectorClock()
/// clock.increment(for: "device-a")  // Returns 1
/// clock.increment(for: "device-a")  // Returns 2
///
/// let otherClock = VectorClock(clocks: ["device-a": 1, "device-b": 3])
/// clock.merge(with: otherClock)
/// // clock now has: ["device-a": 2, "device-b": 3]
/// ```
public struct VectorClock: Codable, Sendable, Equatable {
    /// Map of device ID to that device's sequence number.
    ///
    /// Devices not in this map are implicitly at sequence 0.
    public var clocks: [String: Int]

    /// Creates an empty vector clock (all devices at sequence 0).
    public init() {
        self.clocks = [:]
    }

    /// Creates a vector clock with the specified initial values.
    ///
    /// - Parameter clocks: Initial device sequence numbers.
    public init(clocks: [String: Int]) {
        self.clocks = clocks
    }

    /// Gets the sequence number for a specific device.
    ///
    /// - Parameter deviceId: The device identifier.
    /// - Returns: The device's sequence number, or 0 if not in the clock.
    public func sequence(for deviceId: String) -> Int {
        clocks[deviceId] ?? 0
    }

    /// Increments the sequence number for a device and returns the new value.
    ///
    /// This should be called when the device creates a new change.
    ///
    /// - Parameter deviceId: The device creating the change.
    /// - Returns: The new sequence number after incrementing.
    @discardableResult
    public mutating func increment(for deviceId: String) -> Int {
        let newValue = (clocks[deviceId] ?? 0) + 1
        clocks[deviceId] = newValue
        return newValue
    }

    /// Merges another vector clock into this one by taking the maximum of each device's sequence.
    ///
    /// This should be called when receiving changes from another device
    /// to update our knowledge of the global state.
    ///
    /// - Parameter other: The vector clock to merge.
    public mutating func merge(with other: VectorClock) {
        for (deviceId, sequence) in other.clocks {
            clocks[deviceId] = max(clocks[deviceId] ?? 0, sequence)
        }
    }

    /// Determines if this clock causally happened before another clock.
    ///
    /// Clock A happened before clock B if:
    /// - All of A's sequences are <= B's sequences, AND
    /// - At least one of A's sequences is < B's sequence
    ///
    /// - Parameter other: The clock to compare against.
    /// - Returns: True if this clock happened before the other.
    public func happenedBefore(_ other: VectorClock) -> Bool {
        var atLeastOneLess = false
        let allDevices = Set(clocks.keys).union(other.clocks.keys)

        for deviceId in allDevices {
            let thisSeq = sequence(for: deviceId)
            let otherSeq = other.sequence(for: deviceId)

            if thisSeq > otherSeq {
                // This clock has a higher sequence for this device,
                // so it cannot have happened before the other
                return false
            }
            if thisSeq < otherSeq {
                atLeastOneLess = true
            }
        }

        return atLeastOneLess
    }

    /// Determines if two clocks are concurrent (neither happened before the other).
    ///
    /// Concurrent events indicate potential conflicts that need resolution.
    ///
    /// - Parameter other: The clock to compare against.
    /// - Returns: True if the clocks are concurrent.
    public func isConcurrent(with other: VectorClock) -> Bool {
        !happenedBefore(other) && !other.happenedBefore(self) && self != other
    }
}

// MARK: - Sync Operation

/// A single sync operation representing a change to an entity.
///
/// Operations are the atomic unit of change in the sync system. Each operation
/// represents either an insert/update (upsert) or a delete of a specific entity.
///
/// ## Generic Type Parameter
/// The type parameter `T` represents the entity data being synced. For upserts,
/// this contains the full entity data. For deletes, data is nil.
///
/// ## Example
/// ```swift
/// let operation = SyncOperation(
///     type: .upsert,
///     entity: .session,
///     id: "session-123",
///     data: sessionData,
///     vectorClock: clock
/// )
/// ```
public struct SyncOperation<T: Codable & Sendable>: Codable, Sendable {
    /// The type of operation (upsert or delete).
    public let type: SyncOperationType

    /// The entity type being modified (session, document, etc.).
    public let entity: SyncEntityType

    /// The unique identifier of the entity being modified.
    ///
    /// This is typically a UUID string that identifies the specific
    /// session, document, or other entity.
    public let id: String

    /// The entity data for upserts, or nil for deletes.
    ///
    /// For upsert operations, this contains the complete current state
    /// of the entity. For delete operations, this is nil since we only
    /// need to know which entity to delete.
    public let data: T?

    /// The vector clock at the time this operation was created.
    ///
    /// Used for conflict detection and resolution. The clock reflects
    /// what the creating device knew about the global state.
    public let vectorClock: VectorClock

    /// Creates a sync operation.
    ///
    /// - Parameters:
    ///   - type: Whether this is an upsert or delete.
    ///   - entity: The type of entity being modified.
    ///   - id: The entity's unique identifier.
    ///   - data: The entity data (required for upsert, nil for delete).
    ///   - vectorClock: The creating device's vector clock.
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

/// A single entry in a device's change log.
///
/// The change log is an append-only sequence of entries that records all
/// changes made by a device. Each entry includes the operation performed
/// and metadata for ordering and integrity verification.
///
/// ## Chain Integrity
/// Each entry (except the first) contains the hash of the previous entry.
/// This creates a hash chain similar to a blockchain, allowing detection
/// of missing or tampered entries.
///
/// ## Example
/// ```swift
/// let entry = ChangeLogEntry(
///     deviceId: "device-abc",
///     sequence: 42,
///     timestamp: Int64(Date().timeIntervalSince1970 * 1000),
///     previousHash: "abc123...",
///     operation: operation
/// )
/// ```
public struct ChangeLogEntry<T: Codable & Sendable>: Codable, Sendable {
    /// Schema version of this entry format.
    ///
    /// Allows for future format changes while maintaining backward compatibility.
    public let schemaVersion: Int

    /// The device that created this change.
    ///
    /// This is the device's unique identifier (typically a UUID).
    public let deviceId: String

    /// Monotonically increasing sequence number for this device.
    ///
    /// Starts at 1 for each device and increases by 1 for each change.
    /// Used for ordering and detecting gaps in the change log.
    public let sequence: Int

    /// Timestamp when this change was created, in milliseconds since Unix epoch.
    ///
    /// Used for last-write-wins conflict resolution and display purposes.
    /// Note: Device clocks may not be synchronized, so this is not
    /// reliable for strict ordering across devices.
    public let timestamp: Int64

    /// SHA-256 hash of the previous change entry, or nil for the first entry.
    ///
    /// Creates a hash chain for detecting missing or tampered entries.
    /// The hash is computed over the canonical JSON of the previous entry.
    public let previousHash: String?

    /// The sync operation being recorded.
    public let operation: SyncOperation<T>

    /// Creates a change log entry.
    ///
    /// - Parameters:
    ///   - schemaVersion: Entry format version. Defaults to current version.
    ///   - deviceId: The creating device's identifier.
    ///   - sequence: The sequence number for this device.
    ///   - timestamp: Creation time in milliseconds since Unix epoch.
    ///   - previousHash: Hash of the previous entry (nil for first entry).
    ///   - operation: The sync operation being recorded.
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

// MARK: - Manifest File Entry

/// An entry in a device's manifest file listing a change file.
///
/// The manifest provides a summary of all change files for a device,
/// including checksums for quick integrity verification without reading
/// each file.
///
/// ## Purpose
/// - Quick discovery of available changes from a device
/// - Integrity verification without reading full files
/// - Efficient sync by comparing manifests
public struct ManifestFileEntry: Codable, Sendable, Equatable {
    /// Sequence number of the change.
    ///
    /// Matches the sequence in the change log entry and the filename.
    public let sequence: Int

    /// Filename of the change file.
    ///
    /// The file is located in the device's changes directory.
    public let filename: String

    /// SHA-256 checksum of the entire file.
    ///
    /// This is the hash of the file contents, including the integrity
    /// envelope. Used for quick verification without parsing.
    public let checksum: String

    /// File size in bytes.
    ///
    /// Useful for estimating download time and storage requirements.
    public let size: Int

    /// Creation timestamp in milliseconds since Unix epoch.
    ///
    /// Matches the timestamp in the change log entry.
    public let timestamp: Int64

    /// Creates a manifest file entry.
    ///
    /// - Parameters:
    ///   - sequence: The change's sequence number.
    ///   - filename: The change file's name.
    ///   - checksum: SHA-256 hash of the file contents.
    ///   - size: File size in bytes.
    ///   - timestamp: Creation time in milliseconds since Unix epoch.
    public init(
        sequence: Int,
        filename: String,
        checksum: String,
        size: Int,
        timestamp: Int64
    ) {
        self.sequence = sequence
        self.filename = filename
        self.checksum = checksum
        self.size = size
        self.timestamp = timestamp
    }
}

// MARK: - Device Manifest

/// A device's complete manifest listing all its change files.
///
/// The manifest is the source of truth for what changes a device has created.
/// Other devices read manifests to discover and sync changes.
public struct DeviceManifest: Codable, Sendable {
    /// The device that owns this manifest.
    public let deviceId: String

    /// Timestamp when this manifest was last updated, in milliseconds since Unix epoch.
    public let lastUpdated: Int64

    /// List of all change files, sorted by sequence.
    public let files: [ManifestFileEntry]

    /// Combined checksum of all file checksums for quick comparison.
    ///
    /// If two manifests have the same manifestChecksum, their file lists
    /// are identical without needing to compare individual entries.
    public let manifestChecksum: String

    /// Creates a device manifest.
    ///
    /// - Parameters:
    ///   - deviceId: The device's identifier.
    ///   - lastUpdated: Update time in milliseconds since Unix epoch.
    ///   - files: List of change file entries.
    ///   - manifestChecksum: Combined checksum of all files.
    public init(
        deviceId: String,
        lastUpdated: Int64,
        files: [ManifestFileEntry],
        manifestChecksum: String
    ) {
        self.deviceId = deviceId
        self.lastUpdated = lastUpdated
        self.files = files
        self.manifestChecksum = manifestChecksum
    }
}
