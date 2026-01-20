# Phase 2: Change Tracking & Persistence

## Overview

This phase implements the change tracking layer that records local modifications and reads remote changes. All persistence is handled through protocols to allow different storage backends.

**Goal**: Enable tracking of local changes and reading of remote changes with full integrity verification.

**Package Location**: `Packages/BioMedLit/Sources/BioMedLit/Sync/`

## Prerequisites

- Phase 1 complete (integrity functions, models, constants)

## Golden Rules Compliance

- **No magic numbers**: Sequence digits, file extensions from `SyncConstants`
- **Type hints**: Full Swift type annotations
- **Docstrings**: Documentation comments on all public APIs
- **Pure functions**: Transformation functions are side-effect-free
- **Input validation**: All external data verified before processing

## Implementation Steps

### Step 1: Create Sync Storage Protocol

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/SyncStorageProtocol.swift`

This protocol abstracts file operations for different backends (iCloud, local, etc.).

```swift
import Foundation

// MARK: - File Info

/// Information about a file in sync storage.
public struct SyncFileInfo: Sendable, Equatable {
    /// File name (not full path).
    public let name: String

    /// Full path relative to sync root.
    public let path: String

    /// File size in bytes.
    public let size: Int

    /// Last modification date.
    public let modifiedAt: Date

    /// Creates file info.
    public init(name: String, path: String, size: Int, modifiedAt: Date) {
        self.name = name
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

// MARK: - Storage Protocol

/// Protocol for sync file storage operations.
///
/// Implementations provide access to different storage backends:
/// - `LocalFolderSyncStorage` for local directories (testing, LAN sync)
/// - `iCloudSyncStorage` for iCloud Drive
/// - `DropboxSyncStorage` for Dropbox
public protocol SyncStorageProtocol: Sendable {
    /// Lists files in a directory.
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Returns: Array of file info objects.
    /// - Throws: Storage-specific errors.
    func listFiles(at path: String) async throws -> [SyncFileInfo]

    /// Lists subdirectories in a directory.
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Returns: Array of directory names.
    /// - Throws: Storage-specific errors.
    func listDirectories(at path: String) async throws -> [String]

    /// Reads file contents.
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Returns: File data.
    /// - Throws: Storage-specific errors.
    func readFile(at path: String) async throws -> Data

    /// Writes file contents.
    ///
    /// - Parameters:
    ///   - data: Data to write.
    ///   - path: Path relative to sync root.
    /// - Throws: Storage-specific errors.
    func writeFile(_ data: Data, at path: String) async throws

    /// Deletes a file.
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Throws: Storage-specific errors.
    func deleteFile(at path: String) async throws

    /// Checks if a file exists.
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Returns: True if file exists.
    func fileExists(at path: String) async -> Bool

    /// Creates a directory (including parents).
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Throws: Storage-specific errors.
    func createDirectory(at path: String) async throws

    /// Moves a file to quarantine.
    ///
    /// - Parameters:
    ///   - path: Current path relative to sync root.
    ///   - reason: Reason for quarantine.
    /// - Returns: New path in quarantine.
    /// - Throws: Storage-specific errors.
    func quarantineFile(at path: String, reason: String) async throws -> String

    /// Registers for change notifications.
    ///
    /// - Parameter callback: Called when files change.
    /// - Returns: A token to unregister.
    func watchForChanges(_ callback: @escaping @Sendable (String) -> Void) async -> Any
}

// MARK: - Storage Errors

/// Errors from sync storage operations.
public enum SyncStorageError: Error, LocalizedError, Sendable {
    /// File not found.
    case fileNotFound(String)

    /// Directory not found.
    case directoryNotFound(String)

    /// Permission denied.
    case permissionDenied(String)

    /// Storage quota exceeded.
    case quotaExceeded

    /// Network unavailable.
    case networkUnavailable

    /// General I/O error.
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .quotaExceeded:
            return "Storage quota exceeded"
        case .networkUnavailable:
            return "Network unavailable"
        case .ioError(let message):
            return "I/O error: \(message)"
        }
    }
}
```

### Step 2: Create Local Folder Storage Implementation

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/LocalFolderSyncStorage.swift`

```swift
import Foundation

/// Sync storage backed by a local file system directory.
///
/// Useful for:
/// - Unit testing
/// - LAN sync via shared folders
/// - Debugging sync issues
public actor LocalFolderSyncStorage: SyncStorageProtocol {
    /// Root directory for sync files.
    private let rootURL: URL

    /// File manager instance.
    private let fileManager = FileManager.default

    /// Creates local folder storage.
    ///
    /// - Parameter rootURL: Root directory for sync files.
    /// - Throws: If directory cannot be created.
    public init(rootURL: URL) throws {
        self.rootURL = rootURL

        // Ensure root exists
        if !FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
        }
    }

    /// Resolves a relative path to a full URL.
    private func resolve(_ path: String) -> URL {
        rootURL.appendingPathComponent(path)
    }

    public func listFiles(at path: String) async throws -> [SyncFileInfo] {
        let url = resolve(path)

        guard fileManager.fileExists(atPath: url.path) else {
            throw SyncStorageError.directoryNotFound(path)
        }

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return try contents.compactMap { itemURL -> SyncFileInfo? in
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)

            guard !isDirectory.boolValue else { return nil }

            let resourceValues = try itemURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )

            return SyncFileInfo(
                name: itemURL.lastPathComponent,
                path: path + "/" + itemURL.lastPathComponent,
                size: resourceValues.fileSize ?? 0,
                modifiedAt: resourceValues.contentModificationDate ?? Date()
            )
        }
    }

    public func listDirectories(at path: String) async throws -> [String] {
        let url = resolve(path)

        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return contents.compactMap { itemURL -> String? in
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? itemURL.lastPathComponent : nil
        }
    }

    public func readFile(at path: String) async throws -> Data {
        let url = resolve(path)

        guard fileManager.fileExists(atPath: url.path) else {
            throw SyncStorageError.fileNotFound(path)
        }

        return try Data(contentsOf: url)
    }

    public func writeFile(_ data: Data, at path: String) async throws {
        let url = resolve(path)

        // Ensure parent directory exists
        let parentURL = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
        }

        try data.write(to: url, options: .atomic)
    }

    public func deleteFile(at path: String) async throws {
        let url = resolve(path)

        guard fileManager.fileExists(atPath: url.path) else {
            throw SyncStorageError.fileNotFound(path)
        }

        try fileManager.removeItem(at: url)
    }

    public func fileExists(at path: String) async -> Bool {
        fileManager.fileExists(atPath: resolve(path).path)
    }

    public func createDirectory(at path: String) async throws {
        let url = resolve(path)
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    public func quarantineFile(at path: String, reason: String) async throws -> String {
        let sourceURL = resolve(path)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let quarantinePath = "\(SyncConstants.quarantineDirectory)/\(timestamp)_\(sourceURL.lastPathComponent)"
        let quarantineURL = resolve(quarantinePath)

        // Ensure quarantine directory exists
        try await createDirectory(at: SyncConstants.quarantineDirectory)

        // Move file
        try fileManager.moveItem(at: sourceURL, to: quarantineURL)

        // Write reason file
        let reasonPath = quarantinePath + ".reason.txt"
        try reason.data(using: .utf8)?.write(to: resolve(reasonPath))

        return quarantinePath
    }

    public func watchForChanges(
        _ callback: @escaping @Sendable (String) -> Void
    ) async -> Any {
        // For local folders, use DispatchSource for file monitoring
        // This is a simplified implementation
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: open(rootURL.path, O_EVTONLY),
            eventMask: .write,
            queue: .global()
        )

        source.setEventHandler {
            callback(self.rootURL.path)
        }

        source.resume()
        return source
    }
}
```

### Step 3: Create Workspace Configuration Models

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/WorkspaceModels.swift`

```swift
import Foundation

// MARK: - Workspace Configuration

/// Workspace-level configuration stored in workspace.json.
public struct WorkspaceConfig: Codable, Sendable, Equatable {
    /// Configuration format version.
    public let version: Int

    /// Sync schema version.
    public let schemaVersion: Int

    /// Minimum schema version required to read this workspace.
    public let minCompatibleVersion: Int

    /// When the workspace was created.
    public let createdAt: Date

    /// Encryption mode (none or aes-256-gcm).
    public let encryption: EncryptionMode

    /// Creates workspace configuration.
    public init(
        version: Int = 1,
        schemaVersion: Int = SyncConstants.schemaVersion,
        minCompatibleVersion: Int = SyncConstants.minCompatibleSchemaVersion,
        createdAt: Date = Date(),
        encryption: EncryptionMode = .none
    ) {
        self.version = version
        self.schemaVersion = schemaVersion
        self.minCompatibleVersion = minCompatibleVersion
        self.createdAt = createdAt
        self.encryption = encryption
    }
}

/// Encryption mode for sync data.
public enum EncryptionMode: String, Codable, Sendable {
    case none
    case aes256gcm = "aes-256-gcm"
}

// MARK: - Device Configuration

/// Device registration stored in devices/{device_id}.json.
public struct DeviceConfig: Codable, Sendable, Equatable {
    /// Unique device identifier (UUID).
    public let deviceId: String

    /// Human-readable device name.
    public let name: String

    /// Platform identifier.
    public let platform: SyncPlatform

    /// When device was registered.
    public let createdAt: Date

    /// Last time device was seen syncing.
    public var lastSeen: Date

    /// Sync scope configuration.
    public var syncScope: SyncScope

    /// Creates device configuration.
    public init(
        deviceId: String,
        name: String,
        platform: SyncPlatform,
        createdAt: Date = Date(),
        lastSeen: Date = Date(),
        syncScope: SyncScope = SyncScope()
    ) {
        self.deviceId = deviceId
        self.name = name
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeen = lastSeen
        self.syncScope = syncScope
    }
}

// MARK: - Sync Scope

/// Configuration for what a device syncs.
public struct SyncScope: Codable, Sendable, Equatable {
    /// Sync mode.
    public var mode: SyncMode

    /// Session filter (for selective mode).
    public var sessionFilter: SessionFilter?

    /// Maximum local storage in MB.
    public var maxLocalStorageMB: Int

    /// Auto-eviction configuration.
    public var autoEviction: AutoEvictionConfig?

    /// Creates sync scope with defaults.
    public init(
        mode: SyncMode = SyncConstants.defaultSyncMode,
        sessionFilter: SessionFilter? = nil,
        maxLocalStorageMB: Int = SyncConstants.defaultMaxStorageMB,
        autoEviction: AutoEvictionConfig? = nil
    ) {
        self.mode = mode
        self.sessionFilter = sessionFilter
        self.maxLocalStorageMB = maxLocalStorageMB
        self.autoEviction = autoEviction
    }
}

/// Filter for which sessions to sync.
public struct SessionFilter: Codable, Sendable, Equatable {
    /// Filter mode.
    public let mode: SessionFilterMode

    /// Session IDs (for whitelist mode).
    public var ids: [String]

    /// Days to keep (for recent mode).
    public var recentDays: Int?

    /// Creates session filter.
    public init(
        mode: SessionFilterMode,
        ids: [String] = [],
        recentDays: Int? = nil
    ) {
        self.mode = mode
        self.ids = ids
        self.recentDays = recentDays
    }
}

/// Session filter mode.
public enum SessionFilterMode: String, Codable, Sendable {
    case whitelist
    case recent
}

/// Auto-eviction configuration.
public struct AutoEvictionConfig: Codable, Sendable, Equatable {
    /// Whether auto-eviction is enabled.
    public var enabled: Bool

    /// Eviction strategy.
    public var strategy: EvictionStrategy

    /// Minimum sessions to keep.
    public var keepMinimumSessions: Int

    /// Session IDs that are never evicted.
    public var neverEvict: [String]

    /// Evict sessions older than this many days.
    public var evictOlderThanDays: Int?

    /// Creates auto-eviction config.
    public init(
        enabled: Bool = false,
        strategy: EvictionStrategy = .lru,
        keepMinimumSessions: Int = SyncConstants.defaultMinSessionsToKeep,
        neverEvict: [String] = [],
        evictOlderThanDays: Int? = nil
    ) {
        self.enabled = enabled
        self.strategy = strategy
        self.keepMinimumSessions = keepMinimumSessions
        self.neverEvict = neverEvict
        self.evictOlderThanDays = evictOlderThanDays
    }
}

/// Strategy for auto-eviction.
public enum EvictionStrategy: String, Codable, Sendable {
    /// Least recently used.
    case lru

    /// Largest sessions first.
    case largest

    /// Oldest by creation date.
    case oldest

    /// Sessions without reports first.
    case noReport
}

// MARK: - Device Manifest

/// Manifest of all change files for a device.
public struct DeviceManifest: Codable, Sendable, Equatable {
    /// Device that owns this manifest.
    public let deviceId: String

    /// When manifest was last updated.
    public var lastUpdated: Date

    /// Highest sequence number.
    public var headSequence: Int

    /// List of change files.
    public var files: [ManifestFileEntry]

    /// Combined checksum of all file checksums.
    public var manifestChecksum: String

    /// Creates device manifest.
    public init(
        deviceId: String,
        lastUpdated: Date = Date(),
        headSequence: Int = 0,
        files: [ManifestFileEntry] = []
    ) {
        self.deviceId = deviceId
        self.lastUpdated = lastUpdated
        self.headSequence = headSequence
        self.files = files
        self.manifestChecksum = computeManifestChecksum(files)
    }

    /// Updates the manifest checksum after modifying files.
    public mutating func updateChecksum() {
        manifestChecksum = computeManifestChecksum(files)
    }
}

// MARK: - Watermarks

/// Tracks how far we've processed each device's changes.
public struct SyncWatermarks: Codable, Sendable, Equatable {
    /// Map of device ID to last processed sequence.
    public var watermarks: [String: Int]

    /// Creates empty watermarks.
    public init() {
        self.watermarks = [:]
    }

    /// Gets watermark for a device.
    public func watermark(for deviceId: String) -> Int {
        watermarks[deviceId] ?? 0
    }

    /// Updates watermark for a device.
    public mutating func setWatermark(_ sequence: Int, for deviceId: String) {
        watermarks[deviceId] = sequence
    }
}

// MARK: - Local Exclusions

/// Records of entities excluded from sync on this device.
public struct LocalExclusions: Codable, Sendable, Equatable {
    /// Excluded session IDs with reasons.
    public var sessions: [String: ExclusionReason]

    /// Creates empty exclusions.
    public init() {
        self.sessions = [:]
    }

    /// Checks if a session is excluded.
    public func isExcluded(_ sessionId: String) -> Bool {
        sessions[sessionId] != nil
    }

    /// Adds an exclusion.
    public mutating func exclude(_ sessionId: String, reason: ExclusionReason) {
        sessions[sessionId] = reason
    }

    /// Removes an exclusion.
    public mutating func include(_ sessionId: String) {
        sessions.removeValue(forKey: sessionId)
    }
}

/// Reason for local exclusion.
public enum ExclusionReason: String, Codable, Sendable {
    case userDeletedLocal
    case userRemovedFromScope
    case autoEvicted
}
```

### Step 4: Create Change Log Writer

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/ChangeLogWriter.swift`

```swift
import Foundation

// MARK: - Change Log Writer

/// Writes changes to the local change log.
///
/// Thread-safe via actor isolation.
public actor ChangeLogWriter {
    /// Storage backend.
    private let storage: SyncStorageProtocol

    /// This device's ID.
    private let deviceId: String

    /// Current sequence number.
    private var currentSequence: Int

    /// Hash of the last written change.
    private var lastChangeHash: String?

    /// Current vector clock.
    private var vectorClock: VectorClock

    /// JSON encoder configured for sync.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Creates a change log writer.
    ///
    /// - Parameters:
    ///   - storage: Storage backend.
    ///   - deviceId: This device's identifier.
    ///   - initialSequence: Starting sequence number.
    ///   - lastHash: Hash of last change (for chain).
    ///   - vectorClock: Initial vector clock.
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
    }

    /// Records an upsert operation.
    ///
    /// - Parameters:
    ///   - entity: Entity type.
    ///   - id: Entity identifier.
    ///   - data: Entity data.
    /// - Returns: The written change entry.
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
    /// - Parameters:
    ///   - entity: Entity type.
    ///   - id: Entity identifier.
    /// - Returns: The written change entry.
    public func recordDelete<T: Codable & Sendable>(
        entity: SyncEntityType,
        id: String
    ) async throws -> ChangeLogEntry<T> {
        try await recordChange(
            type: .delete,
            entity: entity,
            id: id,
            data: nil
        )
    }

    /// Records a change to the log.
    private func recordChange<T: Codable & Sendable>(
        type: SyncOperationType,
        entity: SyncEntityType,
        id: String,
        data: T?
    ) async throws -> ChangeLogEntry<T> {
        // Increment sequence
        currentSequence += 1
        vectorClock.increment(for: deviceId)

        // Create timestamp
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        // Create operation
        let operation = SyncOperation(
            type: type,
            entity: entity,
            id: id,
            data: data,
            vectorClock: vectorClock
        )

        // Create change entry
        let change = ChangeLogEntry(
            deviceId: deviceId,
            sequence: currentSequence,
            timestamp: timestamp,
            previousHash: lastChangeHash,
            operation: operation
        )

        // Create integrity envelope
        let envelope = try createIntegrityEnvelope(change)

        // Generate filename
        let filename = SyncFileNaming.changeFileName(
            sequence: currentSequence,
            timestamp: timestamp,
            entity: entity,
            operation: type
        )

        // Write to storage
        let path = SyncFileNaming.changeFilePath(deviceId: deviceId, filename: filename)
        let fileData = try encoder.encode(envelope)
        try await storage.writeFile(fileData, at: path)

        // Update chain hash
        lastChangeHash = try calculateChecksum(change)

        return change
    }

    /// Gets the current sequence number.
    public func getCurrentSequence() -> Int {
        currentSequence
    }

    /// Gets the current vector clock.
    public func getVectorClock() -> VectorClock {
        vectorClock
    }

    /// Updates the vector clock after receiving remote changes.
    public func mergeVectorClock(_ remote: VectorClock) {
        vectorClock.merge(with: remote)
    }
}
```

### Step 5: Create Change Log Reader

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/ChangeLogReader.swift`

```swift
import Foundation

// MARK: - Change Log Reader

/// Reads and verifies changes from remote devices.
public struct ChangeLogReader: Sendable {
    /// Storage backend.
    private let storage: SyncStorageProtocol

    /// This device's ID (to skip own changes).
    private let myDeviceId: String

    /// JSON decoder configured for sync.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Creates a change log reader.
    ///
    /// - Parameters:
    ///   - storage: Storage backend.
    ///   - myDeviceId: This device's identifier.
    public init(storage: SyncStorageProtocol, myDeviceId: String) {
        self.storage = storage
        self.myDeviceId = myDeviceId
    }

    /// Discovers all remote devices.
    ///
    /// - Returns: Array of device configurations.
    public func discoverDevices() async throws -> [DeviceConfig] {
        let deviceDirs = try await storage.listDirectories(
            at: SyncConstants.devicesDirectory
        )

        var devices: [DeviceConfig] = []

        for deviceFile in try await storage.listFiles(at: SyncConstants.devicesDirectory) {
            guard deviceFile.name.hasSuffix(".json") else { continue }

            let data = try await storage.readFile(at: deviceFile.path)
            let config: DeviceConfig = try verifyAndExtract(from: data)

            // Skip self
            if config.deviceId != myDeviceId {
                devices.append(config)
            }
        }

        return devices
    }

    /// Reads the manifest for a device.
    ///
    /// - Parameter deviceId: Device identifier.
    /// - Returns: Device manifest, or nil if not found.
    public func readManifest(for deviceId: String) async throws -> DeviceManifest? {
        let path = "\(SyncConstants.changesDirectory)/\(deviceId)/\(SyncConstants.manifestFile)"

        guard await storage.fileExists(at: path) else {
            return nil
        }

        let data = try await storage.readFile(at: path)
        return try verifyAndExtract(from: data)
    }

    /// Reads changes from a device that are newer than a watermark.
    ///
    /// - Parameters:
    ///   - deviceId: Device identifier.
    ///   - afterSequence: Only return changes after this sequence.
    /// - Returns: Array of verified change data (raw JSON).
    public func readChanges(
        from deviceId: String,
        afterSequence: Int
    ) async throws -> [VerifiedChange] {
        let manifest = try await readManifest(for: deviceId)

        guard let manifest = manifest else {
            return []
        }

        // Filter to new files
        let newFiles = manifest.files.filter { $0.sequence > afterSequence }
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
    /// - Parameters:
    ///   - change: Verified change data.
    /// - Returns: Decoded change entry.
    public func decodeChange<T: Codable & Sendable>(
        _ change: VerifiedChange
    ) throws -> ChangeLogEntry<T> {
        try verifyAndExtract(from: change.data)
    }
}

// MARK: - Verified Change

/// A change that has been verified against the manifest.
public struct VerifiedChange: Sendable {
    /// Source device ID.
    public let deviceId: String

    /// Sequence number.
    public let sequence: Int

    /// Timestamp in milliseconds.
    public let timestamp: Int64

    /// Raw JSON data (integrity verified).
    public let data: Data
}

// MARK: - Change Discovery Result

/// Result of discovering new changes.
public struct ChangeDiscoveryResult: Sendable {
    /// Changes by device, sorted by timestamp.
    public let changes: [VerifiedChange]

    /// Updated watermarks after processing.
    public let newWatermarks: SyncWatermarks

    /// Any errors encountered (non-fatal).
    public let warnings: [ChangeDiscoveryWarning]
}

/// Warning during change discovery.
public struct ChangeDiscoveryWarning: Sendable {
    /// Device that had the issue.
    public let deviceId: String

    /// Description of the warning.
    public let message: String

    /// The underlying error, if any.
    public let error: Error?
}
```

### Step 6: Create Sync State Manager

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/SyncStateManager.swift`

```swift
import Foundation

// MARK: - Sync State Manager

/// Manages local sync state (watermarks, exclusions, device config).
///
/// This is the primary interface for tracking sync progress.
public actor SyncStateManager {
    /// Storage backend.
    private let storage: SyncStorageProtocol

    /// This device's configuration.
    private var deviceConfig: DeviceConfig

    /// Watermarks tracking progress per device.
    private var watermarks: SyncWatermarks

    /// Local exclusions.
    private var exclusions: LocalExclusions

    /// Path for local state file.
    private let localStatePath: String

    /// JSON encoder.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Creates a sync state manager.
    ///
    /// - Parameters:
    ///   - storage: Storage backend.
    ///   - deviceConfig: This device's configuration.
    ///   - localStatePath: Path for local state file.
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

    /// Loads state from storage.
    public func loadState() async throws {
        // Load local state if it exists
        if await storage.fileExists(at: localStatePath) {
            let data = try await storage.readFile(at: localStatePath)
            let state: LocalSyncState = try verifyAndExtract(from: data)
            self.watermarks = state.watermarks
            self.exclusions = state.exclusions
        }
    }

    /// Saves state to storage.
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

    /// Gets watermark for a device.
    public func getWatermark(for deviceId: String) -> Int {
        watermarks.watermark(for: deviceId)
    }

    /// Updates watermark for a device.
    public func setWatermark(_ sequence: Int, for deviceId: String) async throws {
        watermarks.setWatermark(sequence, for: deviceId)
        try await saveState()
    }

    /// Checks if a session is excluded.
    public func isExcluded(_ sessionId: String) -> Bool {
        exclusions.isExcluded(sessionId)
    }

    /// Excludes a session locally.
    public func exclude(_ sessionId: String, reason: ExclusionReason) async throws {
        exclusions.exclude(sessionId, reason: reason)
        try await saveState()
    }

    /// Includes a previously excluded session.
    public func include(_ sessionId: String) async throws {
        exclusions.include(sessionId)
        try await saveState()
    }

    /// Gets this device's configuration.
    public func getDeviceConfig() -> DeviceConfig {
        deviceConfig
    }

    /// Updates and uploads device configuration.
    public func updateDeviceConfig(_ config: DeviceConfig) async throws {
        self.deviceConfig = config

        let envelope = try createIntegrityEnvelope(config)
        let data = try encoder.encode(envelope)
        let path = SyncFileNaming.deviceFilePath(deviceId: config.deviceId)
        try await storage.writeFile(data, at: path)
    }

    /// Updates last seen timestamp.
    public func updateLastSeen() async throws {
        var config = deviceConfig
        config.lastSeen = Date()
        try await updateDeviceConfig(config)
    }
}

// MARK: - Local Sync State

/// Local state persisted on device.
struct LocalSyncState: Codable, Sendable {
    let deviceId: String
    let watermarks: SyncWatermarks
    let exclusions: LocalExclusions
    let lastSaved: Date
}
```

### Step 7: Create Tests

**File**: `Packages/BioMedLit/Tests/BioMedLitTests/ChangeTrackingTests.swift`

```swift
import XCTest
@testable import BioMedLit

final class ChangeTrackingTests: XCTestCase {

    var tempDirectory: URL!
    var storage: LocalFolderSyncStorage!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        storage = try LocalFolderSyncStorage(rootURL: tempDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Storage Tests

    func testLocalStorageWriteRead() async throws {
        let testData = "Hello, World!".data(using: .utf8)!
        try await storage.writeFile(testData, at: "test/file.txt")

        let readData = try await storage.readFile(at: "test/file.txt")
        XCTAssertEqual(testData, readData)
    }

    func testLocalStorageListFiles() async throws {
        try await storage.writeFile(Data(), at: "dir/a.txt")
        try await storage.writeFile(Data(), at: "dir/b.txt")
        try await storage.createDirectory(at: "dir/subdir")

        let files = try await storage.listFiles(at: "dir")
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains { $0.name == "a.txt" })
        XCTAssertTrue(files.contains { $0.name == "b.txt" })
    }

    // MARK: - Change Log Writer Tests

    func testChangeLogWriterSequence() async throws {
        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: "test-device"
        )

        struct TestData: Codable, Sendable {
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

        XCTAssertEqual(change1.sequence, 1)
        XCTAssertEqual(change2.sequence, 2)
        XCTAssertNil(change1.previousHash)
        XCTAssertNotNil(change2.previousHash)
    }

    func testChangeLogWriterVectorClock() async throws {
        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: "device-a"
        )

        struct TestData: Codable, Sendable {
            let value: Int
        }

        _ = try await writer.recordUpsert(
            entity: .document,
            id: "doc-1",
            data: TestData(value: 1)
        )

        let clock = await writer.getVectorClock()
        XCTAssertEqual(clock.sequence(for: "device-a"), 1)
    }

    // MARK: - Workspace Models Tests

    func testDeviceConfigSerialization() throws {
        let config = DeviceConfig(
            deviceId: "test-123",
            name: "Test Device",
            platform: .ios,
            syncScope: SyncScope(
                mode: .selective,
                sessionFilter: SessionFilter(mode: .whitelist, ids: ["s1", "s2"])
            )
        )

        let envelope = try createIntegrityEnvelope(config)
        let extracted = try verifyAndExtract(envelope)

        XCTAssertEqual(config.deviceId, extracted.deviceId)
        XCTAssertEqual(config.syncScope.mode, extracted.syncScope.mode)
        XCTAssertEqual(config.syncScope.sessionFilter?.ids, extracted.syncScope.sessionFilter?.ids)
    }

    func testSyncWatermarks() {
        var watermarks = SyncWatermarks()

        XCTAssertEqual(watermarks.watermark(for: "device-a"), 0)

        watermarks.setWatermark(42, for: "device-a")
        XCTAssertEqual(watermarks.watermark(for: "device-a"), 42)

        watermarks.setWatermark(100, for: "device-b")
        XCTAssertEqual(watermarks.watermark(for: "device-b"), 100)
    }

    func testLocalExclusions() {
        var exclusions = LocalExclusions()

        XCTAssertFalse(exclusions.isExcluded("session-1"))

        exclusions.exclude("session-1", reason: .userDeletedLocal)
        XCTAssertTrue(exclusions.isExcluded("session-1"))

        exclusions.include("session-1")
        XCTAssertFalse(exclusions.isExcluded("session-1"))
    }

    // MARK: - File Naming Tests

    func testChangeFileNameGeneration() {
        let filename = SyncFileNaming.changeFileName(
            sequence: 1,
            timestamp: 1705772400000,
            entity: .session,
            operation: .upsert
        )

        XCTAssertEqual(filename, "000001_1705772400000_session_upsert.json")
    }

    func testChangeFileNameParsing() {
        let components = SyncFileNaming.parseChangeFileName(
            "000001_1705772400000_session_upsert.json"
        )

        XCTAssertNotNil(components)
        XCTAssertEqual(components?.sequence, 1)
        XCTAssertEqual(components?.timestamp, 1705772400000)
        XCTAssertEqual(components?.entity, .session)
        XCTAssertEqual(components?.operation, .upsert)
    }
}
```

## Files to Create

| File | Description |
|------|-------------|
| `Sync/SyncStorageProtocol.swift` | Storage abstraction protocol |
| `Sync/LocalFolderSyncStorage.swift` | Local filesystem implementation |
| `Sync/WorkspaceModels.swift` | Workspace and device configuration |
| `Sync/ChangeLogWriter.swift` | Records local changes |
| `Sync/ChangeLogReader.swift` | Reads and verifies remote changes |
| `Sync/SyncStateManager.swift` | Manages local sync state |
| `Tests/ChangeTrackingTests.swift` | Unit tests |

## Acceptance Criteria

1. **Storage abstraction works**: Can write, read, list files
2. **Change log writer**: Correctly increments sequences and chains
3. **Vector clocks**: Track causality across writes
4. **Integrity preserved**: All files use integrity envelopes
5. **Watermarks**: Track progress per device
6. **Exclusions**: Can exclude sessions locally
7. **All tests pass**: `swift test` succeeds

## Dependencies

- Phase 1 (integrity functions and models)

## Next Phase

Phase 3 will implement the sync engine that orchestrates change discovery and merging.
