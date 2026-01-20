# Phase 1: Core Sync Foundation

## Overview

This phase establishes the foundational data types and pure functions for cross-platform sync in the BioMedLit Swift package. All code is designed to be side-effect-free and testable.

**Goal**: Create the integrity verification layer that ensures data is never silently corrupted.

**Package Location**: `Packages/BioMedLit/Sources/BioMedLit/Sync/`

## Golden Rules Compliance

- **No magic numbers**: All constants in `SyncConstants.swift`
- **Type hints**: Full Swift type annotations on all functions
- **Docstrings**: Documentation comments on all public APIs
- **Pure functions**: Integrity functions are stateless and side-effect-free
- **Input validation**: All external data verified before processing

## Implementation Steps

### Step 1: Create Sync Constants

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/SyncConstants.swift`

```swift
import Foundation

// MARK: - Sync Constants

/// Constants for the sync module.
/// All magic numbers and strings are centralized here per golden rules.
public enum SyncConstants {
    // MARK: - Integrity

    /// Current integrity envelope version.
    public static let integrityVersion = 1

    /// Hash algorithm identifier.
    public static let integrityAlgorithm = "sha256"

    /// Current schema version for sync data.
    public static let schemaVersion = 1

    /// Minimum schema version that can be read.
    public static let minCompatibleSchemaVersion = 1

    // MARK: - File Naming

    /// Number of digits for sequence numbers (zero-padded).
    public static let sequenceDigits = 6

    /// File extension for sync files.
    public static let syncFileExtension = "json"

    // MARK: - Directory Names

    /// Root sync directory name.
    public static let syncRootDirectory = "BMLibrarian"

    /// Devices subdirectory.
    public static let devicesDirectory = "devices"

    /// Changes subdirectory.
    public static let changesDirectory = "changes"

    /// Snapshots subdirectory.
    public static let snapshotsDirectory = "snapshots"

    /// Quarantine subdirectory for corrupt files.
    public static let quarantineDirectory = ".quarantine"

    // MARK: - File Names

    /// Workspace metadata file.
    public static let workspaceFile = "workspace.json"

    /// Per-device manifest file.
    public static let manifestFile = "manifest.json"

    /// Per-device cursor file.
    public static let cursorFile = "cursor.json"

    // MARK: - Verification

    /// Hours between full integrity verification.
    public static let fullVerifyIntervalHours = 24

    /// Number of recent changes to verify chain integrity.
    public static let chainVerifyDepth = 100

    /// Maximum retry attempts for resending corrupt data.
    public static let maxResendAttempts = 3

    // MARK: - Storage Management

    /// Default maximum local storage in megabytes.
    public static let defaultMaxStorageMB = 500

    /// Target ratio when evicting (evict until at this % of max).
    public static let evictionTargetRatio = 0.9

    /// Minimum sessions to keep during auto-eviction.
    public static let defaultMinSessionsToKeep = 5

    /// Default days before auto-eviction.
    public static let defaultAutoEvictDays = 90

    // MARK: - Sync Scope

    /// Default sync mode for new devices.
    public static let defaultSyncMode = SyncMode.full

    // MARK: - Timing

    /// Maximum seconds to wait for iCloud file download.
    public static let iCloudDownloadTimeoutSeconds = 30

    /// Cache duration for storage info in seconds.
    public static let storageCacheDurationSeconds: TimeInterval = 60

    /// Debounce interval for change observation in seconds.
    public static let changeDebounceIntervalSeconds: TimeInterval = 1.0

    /// Minimum interval between background syncs in seconds.
    public static let backgroundSyncIntervalSeconds: TimeInterval = 15 * 60
}

// MARK: - Enums

/// Sync mode determines what data a device downloads.
public enum SyncMode: String, Codable, Sendable {
    /// Sync all data (default for desktops).
    case full

    /// Only sync whitelisted sessions.
    case selective

    /// Only sync sessions from last N days.
    case recent

    /// Only sync metadata, fetch content on-demand.
    case minimal
}

/// Record sync state on a device.
public enum RecordSyncState: String, Codable, Sendable {
    /// Complete record with all content.
    case full

    /// Metadata only, content available on-demand.
    case stub

    /// Was full, now stub (freed local storage).
    case evicted

    /// Exists only on this device, not synced.
    case localOnly

    /// Deleted locally, still exists in cloud.
    case deletedLocal
}

/// Sync operation types.
public enum SyncOperationType: String, Codable, Sendable {
    case upsert
    case delete
}

/// Entity types that can be synced.
public enum SyncEntityType: String, Codable, Sendable {
    case session
    case document
    case citation
    case report
    case usageRecord
    case settings
}

/// Platform identifiers.
public enum SyncPlatform: String, Codable, Sendable {
    case ios
    case macos
    case android
    case desktop
}
```

### Step 2: Create Integrity Error Types

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/IntegrityError.swift`

```swift
import Foundation

// MARK: - Integrity Errors

/// Errors that occur during integrity verification.
public enum IntegrityError: Error, LocalizedError, Sendable {
    /// The integrity envelope is missing or malformed.
    case missingEnvelope

    /// The checksum algorithm is not supported.
    case unsupportedAlgorithm(String)

    /// The computed checksum does not match the expected value.
    case checksumMismatch(expected: String, actual: String)

    /// The content length does not match the expected value.
    case lengthMismatch(expected: Int, actual: Int)

    /// The chain hash does not match (gap or tampering detected).
    case chainBroken(sequence: Int, expected: String, actual: String)

    /// A file listed in the manifest is missing.
    case missingFile(String)

    /// A file exists that is not in the manifest.
    case unexpectedFile(String)

    /// The schema version is newer than supported.
    case schemaVersionTooNew(found: Int, maxSupported: Int)

    /// JSON encoding/decoding failed.
    case jsonError(Error)

    public var errorDescription: String? {
        switch self {
        case .missingEnvelope:
            return "Missing integrity envelope"
        case .unsupportedAlgorithm(let algorithm):
            return "Unsupported checksum algorithm: \(algorithm)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected.prefix(16))..., got \(actual.prefix(16))..."
        case .lengthMismatch(let expected, let actual):
            return "Content length mismatch: expected \(expected), got \(actual)"
        case .chainBroken(let sequence, let expected, let actual):
            return "Chain broken at sequence \(sequence): expected \(expected.prefix(16))..., got \(actual.prefix(16))..."
        case .missingFile(let filename):
            return "Missing file: \(filename)"
        case .unexpectedFile(let filename):
            return "Unexpected file: \(filename)"
        case .schemaVersionTooNew(let found, let maxSupported):
            return "Schema version \(found) not supported (max: \(maxSupported)). Please update the app."
        case .jsonError(let error):
            return "JSON error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Recovery Result

/// Result of attempting to recover from corruption.
public enum RecoveryResult: Sendable {
    /// File was skipped (non-critical).
    case skipped

    /// State was rebuilt from snapshot.
    case rebuiltFromSnapshot(snapshotId: String)

    /// Requested source device to resend.
    case pendingResend

    /// Recovery failed, user notification required.
    case failed(reason: String)
}
```

### Step 3: Create Integrity Envelope Models

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/IntegrityModels.swift`

```swift
import Foundation

// MARK: - Integrity Metadata

/// Metadata for verifying content integrity.
public struct IntegrityMetadata: Codable, Sendable, Equatable {
    /// Envelope format version.
    public let version: Int

    /// Hash algorithm used (e.g., "sha256").
    public let algorithm: String

    /// Hex-encoded checksum of the canonical JSON content.
    public let checksum: String

    /// Byte length of the canonical JSON content.
    public let contentLength: Int

    /// Creates integrity metadata.
    ///
    /// - Parameters:
    ///   - version: Envelope format version.
    ///   - algorithm: Hash algorithm identifier.
    ///   - checksum: Hex-encoded checksum.
    ///   - contentLength: Content byte length.
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
public struct IntegrityEnvelope<T: Codable & Sendable>: Codable, Sendable {
    /// Integrity metadata for verification.
    public let integrity: IntegrityMetadata

    /// The actual content.
    public let content: T

    enum CodingKeys: String, CodingKey {
        case integrity = "_integrity"
        case content = "_content"
    }

    /// Creates an integrity envelope.
    ///
    /// - Parameters:
    ///   - integrity: Integrity metadata.
    ///   - content: The content to wrap.
    public init(integrity: IntegrityMetadata, content: T) {
        self.integrity = integrity
        self.content = content
    }
}

// MARK: - Vector Clock

/// Vector clock for tracking causality across devices.
public struct VectorClock: Codable, Sendable, Equatable {
    /// Map of device ID to sequence number.
    public var clocks: [String: Int]

    /// Creates an empty vector clock.
    public init() {
        self.clocks = [:]
    }

    /// Creates a vector clock with initial values.
    ///
    /// - Parameter clocks: Initial clock values.
    public init(clocks: [String: Int]) {
        self.clocks = clocks
    }

    /// Gets the sequence for a device.
    ///
    /// - Parameter deviceId: The device identifier.
    /// - Returns: The sequence number, or 0 if not present.
    public func sequence(for deviceId: String) -> Int {
        clocks[deviceId] ?? 0
    }

    /// Increments the sequence for a device.
    ///
    /// - Parameter deviceId: The device identifier.
    /// - Returns: The new sequence number.
    @discardableResult
    public mutating func increment(for deviceId: String) -> Int {
        let newValue = (clocks[deviceId] ?? 0) + 1
        clocks[deviceId] = newValue
        return newValue
    }

    /// Merges another vector clock (takes max of each).
    ///
    /// - Parameter other: The other vector clock.
    public mutating func merge(with other: VectorClock) {
        for (deviceId, sequence) in other.clocks {
            clocks[deviceId] = max(clocks[deviceId] ?? 0, sequence)
        }
    }

    /// Checks if this clock happened before another.
    ///
    /// - Parameter other: The other vector clock.
    /// - Returns: True if this clock is causally before other.
    public func happenedBefore(_ other: VectorClock) -> Bool {
        var atLeastOneLess = false
        let allDevices = Set(clocks.keys).union(other.clocks.keys)

        for deviceId in allDevices {
            let thisSeq = sequence(for: deviceId)
            let otherSeq = other.sequence(for: deviceId)

            if thisSeq > otherSeq {
                return false
            }
            if thisSeq < otherSeq {
                atLeastOneLess = true
            }
        }

        return atLeastOneLess
    }

    /// Checks if two clocks are concurrent (neither happened before the other).
    ///
    /// - Parameter other: The other vector clock.
    /// - Returns: True if the clocks are concurrent.
    public func isConcurrent(with other: VectorClock) -> Bool {
        !happenedBefore(other) && !other.happenedBefore(self) && self != other
    }
}

// MARK: - Sync Operation

/// A single sync operation in the change log.
public struct SyncOperation<T: Codable & Sendable>: Codable, Sendable {
    /// Operation type (upsert or delete).
    public let type: SyncOperationType

    /// Entity type being modified.
    public let entity: SyncEntityType

    /// Entity UUID.
    public let id: String

    /// Entity data (nil for deletes).
    public let data: T?

    /// Vector clock at time of operation.
    public let vectorClock: VectorClock

    /// Creates a sync operation.
    ///
    /// - Parameters:
    ///   - type: Operation type.
    ///   - entity: Entity type.
    ///   - id: Entity identifier.
    ///   - data: Entity data (nil for deletes).
    ///   - vectorClock: Current vector clock.
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
public struct ChangeLogEntry<T: Codable & Sendable>: Codable, Sendable {
    /// Schema version of this entry.
    public let schemaVersion: Int

    /// Device that created this change.
    public let deviceId: String

    /// Monotonic sequence number for this device.
    public let sequence: Int

    /// Milliseconds since Unix epoch.
    public let timestamp: Int64

    /// Hash of the previous change (nil for first).
    public let previousHash: String?

    /// The operation being recorded.
    public let operation: SyncOperation<T>

    /// Creates a change log entry.
    ///
    /// - Parameters:
    ///   - schemaVersion: Schema version.
    ///   - deviceId: Device identifier.
    ///   - sequence: Sequence number.
    ///   - timestamp: Timestamp in milliseconds.
    ///   - previousHash: Hash of previous entry.
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
```

### Step 4: Create Pure Integrity Functions

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/IntegrityFunctions.swift`

```swift
import CryptoKit
import Foundation

// MARK: - Canonical JSON Encoding

/// Encodes content to canonical JSON bytes for consistent checksums.
///
/// Canonical JSON requirements:
/// - Sorted keys (lexicographic Unicode order)
/// - Compact format (no whitespace)
/// - UTF-8 encoding
/// - No trailing newlines
///
/// - Parameter content: The content to encode.
/// - Returns: Canonical JSON as UTF-8 bytes.
/// - Throws: `IntegrityError.jsonError` if encoding fails.
public func toCanonicalJSON<T: Encodable>(_ content: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    do {
        return try encoder.encode(content)
    } catch {
        throw IntegrityError.jsonError(error)
    }
}

// MARK: - Checksum Calculation

/// Calculates SHA-256 checksum of data.
///
/// - Parameter data: The data to hash.
/// - Returns: Lowercase hex-encoded checksum string.
public func calculateChecksum(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.compactMap { String(format: "%02x", $0) }.joined()
}

/// Calculates SHA-256 checksum of content via canonical JSON.
///
/// - Parameter content: The content to hash.
/// - Returns: Lowercase hex-encoded checksum string.
/// - Throws: `IntegrityError.jsonError` if encoding fails.
public func calculateChecksum<T: Encodable>(_ content: T) throws -> String {
    let data = try toCanonicalJSON(content)
    return calculateChecksum(data)
}

// MARK: - Envelope Creation

/// Creates an integrity envelope for content.
///
/// The envelope includes a SHA-256 checksum and content length
/// that can be verified on read.
///
/// - Parameter content: The content to wrap.
/// - Returns: An integrity envelope containing the content.
/// - Throws: `IntegrityError.jsonError` if encoding fails.
public func createIntegrityEnvelope<T: Codable & Sendable>(
    _ content: T
) throws -> IntegrityEnvelope<T> {
    let canonicalData = try toCanonicalJSON(content)
    let checksum = calculateChecksum(canonicalData)

    let metadata = IntegrityMetadata(
        checksum: checksum,
        contentLength: canonicalData.count
    )

    return IntegrityEnvelope(integrity: metadata, content: content)
}

// MARK: - Verification

/// Verifies an integrity envelope and extracts the content.
///
/// Performs the following checks:
/// 1. Algorithm is supported (sha256)
/// 2. Content checksum matches
/// 3. Content length matches
///
/// - Parameter envelope: The envelope to verify.
/// - Returns: The verified content.
/// - Throws: `IntegrityError` if verification fails.
public func verifyAndExtract<T: Codable & Sendable>(
    _ envelope: IntegrityEnvelope<T>
) throws -> T {
    // Verify algorithm
    guard envelope.integrity.algorithm == SyncConstants.integrityAlgorithm else {
        throw IntegrityError.unsupportedAlgorithm(envelope.integrity.algorithm)
    }

    // Compute actual values
    let canonicalData = try toCanonicalJSON(envelope.content)
    let actualChecksum = calculateChecksum(canonicalData)

    // Verify checksum
    guard actualChecksum == envelope.integrity.checksum else {
        throw IntegrityError.checksumMismatch(
            expected: envelope.integrity.checksum,
            actual: actualChecksum
        )
    }

    // Verify length
    guard canonicalData.count == envelope.integrity.contentLength else {
        throw IntegrityError.lengthMismatch(
            expected: envelope.integrity.contentLength,
            actual: canonicalData.count
        )
    }

    return envelope.content
}

/// Verifies integrity envelope from raw JSON data.
///
/// - Parameter data: Raw JSON data containing an integrity envelope.
/// - Returns: The verified and decoded content.
/// - Throws: `IntegrityError` if verification fails.
public func verifyAndExtract<T: Codable & Sendable>(
    from data: Data
) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let envelope: IntegrityEnvelope<T>
    do {
        envelope = try decoder.decode(IntegrityEnvelope<T>.self, from: data)
    } catch {
        throw IntegrityError.jsonError(error)
    }

    return try verifyAndExtract(envelope)
}

// MARK: - Chain Verification

/// Verifies that a change correctly references the previous change.
///
/// - Parameters:
///   - change: The change to verify.
///   - previousChange: The previous change (nil for first change).
/// - Returns: True if the chain link is valid.
/// - Throws: `IntegrityError.chainBroken` if verification fails.
public func verifyChainLink<T: Codable & Sendable>(
    change: ChangeLogEntry<T>,
    previousChange: ChangeLogEntry<T>?
) throws -> Bool {
    if change.sequence == 1 {
        // First change should have no previous hash
        guard change.previousHash == nil else {
            throw IntegrityError.chainBroken(
                sequence: change.sequence,
                expected: "nil",
                actual: change.previousHash ?? "nil"
            )
        }
        return true
    }

    guard let previous = previousChange else {
        throw IntegrityError.chainBroken(
            sequence: change.sequence,
            expected: "previous change",
            actual: "nil"
        )
    }

    let expectedHash = try calculateChecksum(previous)

    guard change.previousHash == expectedHash else {
        throw IntegrityError.chainBroken(
            sequence: change.sequence,
            expected: expectedHash,
            actual: change.previousHash ?? "nil"
        )
    }

    return true
}

/// Verifies the integrity of a sequence of changes.
///
/// - Parameter changes: Changes in sequence order.
/// - Returns: True if the entire chain is valid.
/// - Throws: `IntegrityError.chainBroken` if verification fails.
public func verifyChangeChain<T: Codable & Sendable>(
    _ changes: [ChangeLogEntry<T>]
) throws -> Bool {
    guard !changes.isEmpty else { return true }

    // Verify first change
    _ = try verifyChainLink(change: changes[0], previousChange: nil)

    // Verify subsequent changes
    for i in 1..<changes.count {
        _ = try verifyChainLink(change: changes[i], previousChange: changes[i - 1])
    }

    return true
}

// MARK: - Manifest Checksum

/// Computes a combined checksum over file entries in a manifest.
///
/// - Parameter files: File entries with checksums.
/// - Returns: Combined checksum of all file checksums.
public func computeManifestChecksum(
    _ files: [ManifestFileEntry]
) -> String {
    let sortedFiles = files.sorted { $0.sequence < $1.sequence }
    let combined = sortedFiles.map(\.checksum).joined()
    return calculateChecksum(Data(combined.utf8))
}

// MARK: - Supporting Types

/// Entry in a device manifest listing a change file.
public struct ManifestFileEntry: Codable, Sendable, Equatable {
    /// Sequence number of the change.
    public let sequence: Int

    /// Filename of the change file.
    public let filename: String

    /// SHA-256 checksum of the file.
    public let checksum: String

    /// File size in bytes.
    public let size: Int

    /// Timestamp in milliseconds.
    public let timestamp: Int64

    /// Creates a manifest file entry.
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
```

### Step 5: Create File Naming Utilities

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/SyncFileNaming.swift`

```swift
import Foundation

// MARK: - File Naming

/// Utilities for sync file naming conventions.
///
/// File format: `{sequence}_{timestamp}_{operation}.json`
/// Example: `000142_1705772400000_session_upsert.json`
public enum SyncFileNaming {
    /// Generates a change file name.
    ///
    /// - Parameters:
    ///   - sequence: The sequence number.
    ///   - timestamp: Timestamp in milliseconds.
    ///   - entity: Entity type.
    ///   - operation: Operation type.
    /// - Returns: The formatted filename.
    public static func changeFileName(
        sequence: Int,
        timestamp: Int64,
        entity: SyncEntityType,
        operation: SyncOperationType
    ) -> String {
        let paddedSequence = String(
            format: "%0\(SyncConstants.sequenceDigits)d",
            sequence
        )
        return "\(paddedSequence)_\(timestamp)_\(entity.rawValue)_\(operation.rawValue).\(SyncConstants.syncFileExtension)"
    }

    /// Parses a change file name.
    ///
    /// - Parameter filename: The filename to parse.
    /// - Returns: Parsed components, or nil if invalid.
    public static func parseChangeFileName(
        _ filename: String
    ) -> ChangeFileComponents? {
        // Remove extension
        let baseName: String
        if filename.hasSuffix(".\(SyncConstants.syncFileExtension)") {
            baseName = String(filename.dropLast(SyncConstants.syncFileExtension.count + 1))
        } else {
            return nil
        }

        let parts = baseName.split(separator: "_")
        guard parts.count >= 4 else { return nil }

        guard let sequence = Int(parts[0]),
              let timestamp = Int64(parts[1]),
              let entity = SyncEntityType(rawValue: String(parts[2])),
              let operation = SyncOperationType(rawValue: String(parts[3]))
        else { return nil }

        return ChangeFileComponents(
            sequence: sequence,
            timestamp: timestamp,
            entity: entity,
            operation: operation
        )
    }

    /// Generates a device file name.
    ///
    /// - Parameter deviceId: The device identifier.
    /// - Returns: The device config filename.
    public static func deviceFileName(deviceId: String) -> String {
        "\(deviceId).\(SyncConstants.syncFileExtension)"
    }

    /// Generates a snapshot file name.
    ///
    /// - Parameters:
    ///   - timestamp: ISO8601 timestamp string.
    ///   - deviceId: Device that created the snapshot.
    /// - Returns: The snapshot filename.
    public static func snapshotFileName(
        timestamp: String,
        deviceId: String
    ) -> String {
        "\(timestamp)_\(deviceId).\(SyncConstants.syncFileExtension).gz"
    }

    /// Generates the path for a change file.
    ///
    /// - Parameters:
    ///   - deviceId: Device identifier.
    ///   - filename: Change file name.
    /// - Returns: Full relative path from sync root.
    public static func changeFilePath(
        deviceId: String,
        filename: String
    ) -> String {
        "\(SyncConstants.changesDirectory)/\(deviceId)/\(filename)"
    }

    /// Generates the path for a device config file.
    ///
    /// - Parameter deviceId: Device identifier.
    /// - Returns: Full relative path from sync root.
    public static func deviceFilePath(deviceId: String) -> String {
        "\(SyncConstants.devicesDirectory)/\(deviceFileName(deviceId: deviceId))"
    }
}

// MARK: - Parsed Components

/// Parsed components from a change file name.
public struct ChangeFileComponents: Sendable, Equatable {
    /// Sequence number.
    public let sequence: Int

    /// Timestamp in milliseconds.
    public let timestamp: Int64

    /// Entity type.
    public let entity: SyncEntityType

    /// Operation type.
    public let operation: SyncOperationType
}
```

### Step 6: Create Test Vectors

**File**: `Packages/BioMedLit/Tests/BioMedLitTests/SyncIntegrityTests.swift`

```swift
import XCTest
@testable import BioMedLit

final class SyncIntegrityTests: XCTestCase {

    // MARK: - Canonical JSON Tests

    /// Test that canonical JSON produces consistent output.
    func testCanonicalJSONSortedKeys() throws {
        struct TestContent: Codable, Sendable {
            let z: Int
            let a: String
            let m: [Int]
        }

        let content = TestContent(z: 1, a: "hello", m: [3, 2, 1])
        let data = try toCanonicalJSON(content)
        let jsonString = String(data: data, encoding: .utf8)!

        // Keys must be sorted: a, m, z
        XCTAssertTrue(jsonString.contains("\"a\":\"hello\""))
        XCTAssertTrue(jsonString.contains("\"m\":[3,2,1]"))
        XCTAssertTrue(jsonString.contains("\"z\":1"))

        // Verify order (a before m before z)
        let aIndex = jsonString.range(of: "\"a\"")!.lowerBound
        let mIndex = jsonString.range(of: "\"m\"")!.lowerBound
        let zIndex = jsonString.range(of: "\"z\"")!.lowerBound

        XCTAssertLessThan(aIndex, mIndex)
        XCTAssertLessThan(mIndex, zIndex)
    }

    /// Test that identical content produces identical checksums.
    func testChecksumConsistency() throws {
        struct TestContent: Codable, Sendable {
            let name: String
            let value: Int
        }

        let content1 = TestContent(name: "test", value: 42)
        let content2 = TestContent(name: "test", value: 42)

        let checksum1 = try calculateChecksum(content1)
        let checksum2 = try calculateChecksum(content2)

        XCTAssertEqual(checksum1, checksum2)
    }

    /// Test that different content produces different checksums.
    func testChecksumDifference() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let content1 = TestContent(value: 1)
        let content2 = TestContent(value: 2)

        let checksum1 = try calculateChecksum(content1)
        let checksum2 = try calculateChecksum(content2)

        XCTAssertNotEqual(checksum1, checksum2)
    }

    // MARK: - Integrity Envelope Tests

    /// Test creating and verifying an integrity envelope.
    func testIntegrityEnvelopeRoundTrip() throws {
        struct TestContent: Codable, Sendable, Equatable {
            let id: String
            let data: String
        }

        let original = TestContent(id: "test-123", data: "some data")
        let envelope = try createIntegrityEnvelope(original)
        let extracted = try verifyAndExtract(envelope)

        XCTAssertEqual(original, extracted)
    }

    /// Test that tampered content fails verification.
    func testIntegrityEnvelopeTamperDetection() throws {
        struct TestContent: Codable, Sendable {
            var value: Int
        }

        let original = TestContent(value: 42)
        var envelope = try createIntegrityEnvelope(original)

        // Tamper with the content
        let tamperedContent = TestContent(value: 99)
        envelope = IntegrityEnvelope(
            integrity: envelope.integrity,
            content: tamperedContent
        )

        XCTAssertThrowsError(try verifyAndExtract(envelope)) { error in
            guard case IntegrityError.checksumMismatch = error else {
                XCTFail("Expected checksumMismatch error")
                return
            }
        }
    }

    /// Test verification from raw JSON data.
    func testVerifyFromRawData() throws {
        struct TestContent: Codable, Sendable, Equatable {
            let name: String
        }

        let original = TestContent(name: "test")
        let envelope = try createIntegrityEnvelope(original)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(envelope)

        let extracted: TestContent = try verifyAndExtract(from: data)
        XCTAssertEqual(original, extracted)
    }

    // MARK: - Vector Clock Tests

    func testVectorClockIncrement() {
        var clock = VectorClock()

        let seq1 = clock.increment(for: "device-a")
        XCTAssertEqual(seq1, 1)

        let seq2 = clock.increment(for: "device-a")
        XCTAssertEqual(seq2, 2)

        let seq3 = clock.increment(for: "device-b")
        XCTAssertEqual(seq3, 1)
    }

    func testVectorClockMerge() {
        var clock1 = VectorClock(clocks: ["a": 5, "b": 3])
        let clock2 = VectorClock(clocks: ["a": 3, "b": 7, "c": 2])

        clock1.merge(with: clock2)

        XCTAssertEqual(clock1.sequence(for: "a"), 5) // max(5, 3)
        XCTAssertEqual(clock1.sequence(for: "b"), 7) // max(3, 7)
        XCTAssertEqual(clock1.sequence(for: "c"), 2) // max(0, 2)
    }

    func testVectorClockHappenedBefore() {
        let clock1 = VectorClock(clocks: ["a": 1, "b": 2])
        let clock2 = VectorClock(clocks: ["a": 2, "b": 3])
        let clock3 = VectorClock(clocks: ["a": 2, "b": 1])

        XCTAssertTrue(clock1.happenedBefore(clock2))
        XCTAssertFalse(clock2.happenedBefore(clock1))
        XCTAssertFalse(clock1.happenedBefore(clock3)) // concurrent
        XCTAssertTrue(clock1.isConcurrent(with: clock3))
    }

    // MARK: - Chain Verification Tests

    func testVerifyChainLink() throws {
        struct SimpleData: Codable, Sendable {
            let value: String
        }

        let operation1 = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "first"),
            vectorClock: VectorClock(clocks: ["dev": 1])
        )

        let change1 = ChangeLogEntry(
            deviceId: "dev",
            sequence: 1,
            timestamp: 1000,
            previousHash: nil,
            operation: operation1
        )

        // First change should verify with nil previous
        XCTAssertTrue(try verifyChainLink(change: change1, previousChange: nil))

        let hash1 = try calculateChecksum(change1)

        let operation2 = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "second"),
            vectorClock: VectorClock(clocks: ["dev": 2])
        )

        let change2 = ChangeLogEntry(
            deviceId: "dev",
            sequence: 2,
            timestamp: 2000,
            previousHash: hash1,
            operation: operation2
        )

        // Second change should verify with first as previous
        XCTAssertTrue(try verifyChainLink(change: change2, previousChange: change1))
    }

    // MARK: - File Naming Tests

    func testChangeFileName() {
        let filename = SyncFileNaming.changeFileName(
            sequence: 42,
            timestamp: 1705772400000,
            entity: .session,
            operation: .upsert
        )

        XCTAssertEqual(filename, "000042_1705772400000_session_upsert.json")
    }

    func testParseChangeFileName() {
        let components = SyncFileNaming.parseChangeFileName(
            "000142_1705772400000_document_delete.json"
        )

        XCTAssertNotNil(components)
        XCTAssertEqual(components?.sequence, 142)
        XCTAssertEqual(components?.timestamp, 1705772400000)
        XCTAssertEqual(components?.entity, .document)
        XCTAssertEqual(components?.operation, .delete)
    }

    func testParseInvalidFileName() {
        XCTAssertNil(SyncFileNaming.parseChangeFileName("invalid.json"))
        XCTAssertNil(SyncFileNaming.parseChangeFileName("000001_abc_session_upsert.json"))
    }
}
```

## Files to Create

| File | Description |
|------|-------------|
| `Sync/SyncConstants.swift` | All sync-related constants |
| `Sync/IntegrityError.swift` | Error types for integrity failures |
| `Sync/IntegrityModels.swift` | Data models for envelopes, clocks, operations |
| `Sync/IntegrityFunctions.swift` | Pure functions for checksums and verification |
| `Sync/SyncFileNaming.swift` | File naming utilities |
| `Tests/SyncIntegrityTests.swift` | Unit tests for all integrity code |

## Package.swift Update

Add the new Sync directory to the BioMedLit package:

```swift
// No changes needed - Swift Package Manager automatically includes
// all .swift files in Sources/BioMedLit/
```

## Acceptance Criteria

1. **All tests pass**: `swift test` succeeds
2. **Checksum consistency**: Same content always produces same checksum
3. **Cross-platform compatibility**: Checksums match Python reference implementation
4. **Tamper detection**: Modified content fails verification
5. **Chain verification**: Broken chains are detected
6. **No magic numbers**: All constants in `SyncConstants`
7. **Full documentation**: All public APIs have doc comments

## Cross-Platform Verification

Create a reference test vector that must produce identical checksums on all platforms:

```json
{
  "testVector": {
    "z": 1,
    "a": {"nested": true},
    "m": [3, 2, 1]
  },
  "expectedCanonical": "{\"a\":{\"nested\":true},\"m\":[3,2,1],\"z\":1}",
  "expectedChecksum": "..." // Calculate and document
}
```

## Dependencies

- **CryptoKit**: For SHA-256 (iOS 13+, macOS 10.15+)
- **Foundation**: For JSON encoding

## Next Phase

Phase 2 will implement change tracking and persistence, building on these foundations.
