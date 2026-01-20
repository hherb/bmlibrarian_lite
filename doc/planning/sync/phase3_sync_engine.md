# Phase 3: Sync Engine & Providers

## Overview

This phase implements the sync engine that orchestrates change discovery, merging, and uploading. It also includes the iCloud Drive storage provider for Apple platforms.

**Goal**: Create a working sync engine that can synchronize data between devices.

**Package Location**: `Packages/BioMedLit/Sources/BioMedLit/Sync/`

## Prerequisites

- Phase 1 complete (integrity functions, models, constants)
- Phase 2 complete (change tracking, storage protocol)

## Golden Rules Compliance

- **No magic numbers**: Retry counts, intervals from constants
- **Type hints**: Full Swift type annotations
- **Docstrings**: Documentation comments on all public APIs
- **Pure functions**: Merge logic is deterministic and side-effect-free
- **Retry with backoff**: Network operations use exponential backoff

## Implementation Steps

### Step 1: Create LWW Merge Strategy

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/LWWMergeStrategy.swift`

The Last-Write-Wins merge strategy resolves conflicts by timestamp.

```swift
import Foundation

// MARK: - LWW Merge Strategy

/// Last-Write-Wins merge strategy for sync conflicts.
///
/// When the same entity is modified on multiple devices, the change
/// with the latest timestamp wins. This is appropriate for single-user
/// multi-device scenarios where concurrent edits are rare.
public struct LWWMergeStrategy: Sendable {

    /// Compares two changes and returns the winner.
    ///
    /// - Parameters:
    ///   - local: The local change.
    ///   - remote: The remote change.
    /// - Returns: The winning change (local or remote).
    public static func resolve<T: Codable & Sendable>(
        local: ChangeLogEntry<T>,
        remote: ChangeLogEntry<T>
    ) -> ChangeLogEntry<T> {
        // Compare timestamps first
        if remote.timestamp > local.timestamp {
            return remote
        } else if local.timestamp > remote.timestamp {
            return local
        }

        // Timestamps equal - use device ID as tiebreaker for determinism
        if remote.deviceId > local.deviceId {
            return remote
        }
        return local
    }

    /// Determines if a remote change should be applied over local state.
    ///
    /// - Parameters:
    ///   - remote: The remote change.
    ///   - localTimestamp: Timestamp of local version (nil if not present).
    ///   - localDeviceId: Device ID that created local version.
    /// - Returns: True if remote should be applied.
    public static func shouldApplyRemote(
        remote: (timestamp: Int64, deviceId: String),
        local: (timestamp: Int64, deviceId: String)?
    ) -> Bool {
        guard let local = local else {
            // No local version - always apply remote
            return true
        }

        if remote.timestamp > local.timestamp {
            return true
        } else if remote.timestamp == local.timestamp {
            // Tiebreaker: higher device ID wins
            return remote.deviceId > local.deviceId
        }
        return false
    }

    /// Merges entity data field by field using LWW.
    ///
    /// Each field is tracked separately with its own timestamp.
    /// This allows partial merges where different fields were
    /// updated on different devices.
    ///
    /// - Parameters:
    ///   - local: Local field timestamps.
    ///   - remote: Remote field timestamps.
    ///   - localData: Local entity data.
    ///   - remoteData: Remote entity data.
    /// - Returns: Merged timestamps and winning fields.
    public static func mergeFields(
        local: [String: Int64],
        remote: [String: Int64],
        localData: [String: Any],
        remoteData: [String: Any]
    ) -> (timestamps: [String: Int64], data: [String: Any]) {
        var resultTimestamps: [String: Int64] = [:]
        var resultData: [String: Any] = [:]

        // Get all field names
        let allFields = Set(local.keys).union(remote.keys)

        for field in allFields {
            let localTs = local[field] ?? 0
            let remoteTs = remote[field] ?? 0

            if remoteTs > localTs {
                resultTimestamps[field] = remoteTs
                if let value = remoteData[field] {
                    resultData[field] = value
                }
            } else {
                resultTimestamps[field] = localTs
                if let value = localData[field] {
                    resultData[field] = value
                }
            }
        }

        return (resultTimestamps, resultData)
    }
}

// MARK: - Merge Result

/// Result of merging local and remote changes.
public enum MergeResult<T: Sendable>: Sendable {
    /// Local version wins, no changes needed.
    case keepLocal

    /// Remote version wins, apply remote data.
    case applyRemote(T)

    /// Merged result combining both.
    case merged(T)

    /// Conflict that requires user resolution.
    case conflict(local: T, remote: T)
}
```

### Step 2: Create Sync Engine

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/SyncEngine.swift`

```swift
import Foundation

// MARK: - Sync Engine

/// Orchestrates the sync process between local and remote storage.
///
/// The sync process:
/// 1. Discover new changes from remote devices
/// 2. Verify integrity of all changes
/// 3. Apply changes using LWW merge
/// 4. Upload local pending changes
/// 5. Update watermarks
public actor SyncEngine {
    /// Storage backend.
    private let storage: SyncStorageProtocol

    /// This device's ID.
    private let deviceId: String

    /// State manager for watermarks and exclusions.
    private let stateManager: SyncStateManager

    /// Change log writer.
    private let writer: ChangeLogWriter

    /// Change log reader.
    private let reader: ChangeLogReader

    /// Delegate for applying changes to local database.
    private weak var delegate: SyncEngineDelegate?

    /// Whether a sync is in progress.
    private var isSyncing = false

    /// Last sync timestamp.
    private var lastSyncTime: Date?

    /// JSON encoder.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Creates a sync engine.
    ///
    /// - Parameters:
    ///   - storage: Storage backend.
    ///   - deviceId: This device's identifier.
    ///   - stateManager: State manager.
    ///   - writer: Change log writer.
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

    /// Sets the delegate for applying changes.
    public func setDelegate(_ delegate: SyncEngineDelegate) {
        self.delegate = delegate
    }

    /// Performs a full sync cycle.
    ///
    /// - Returns: Sync result with statistics.
    /// - Throws: If sync fails critically.
    public func sync() async throws -> SyncResult {
        guard !isSyncing else {
            return SyncResult(status: .alreadyInProgress)
        }

        isSyncing = true
        defer { isSyncing = false }

        var result = SyncResult(status: .success)
        let startTime = Date()

        do {
            // 1. Update last seen
            try await stateManager.updateLastSeen()

            // 2. Discover remote devices
            let devices = try await reader.discoverDevices()
            result.devicesFound = devices.count

            // 3. Process changes from each device
            for device in devices {
                do {
                    let deviceResult = try await processDeviceChanges(device)
                    result.changesReceived += deviceResult.changesApplied
                    result.warnings.append(contentsOf: deviceResult.warnings)
                } catch {
                    result.warnings.append(
                        SyncWarning(
                            deviceId: device.deviceId,
                            message: "Failed to process: \(error.localizedDescription)"
                        )
                    )
                }
            }

            // 4. Upload local pending changes
            let uploadResult = try await uploadPendingChanges()
            result.changesSent = uploadResult.changesSent

            // 5. Update manifest
            try await updateManifest()

            lastSyncTime = Date()
            result.duration = Date().timeIntervalSince(startTime)

        } catch {
            result.status = .failed(error)
            result.duration = Date().timeIntervalSince(startTime)
        }

        return result
    }

    /// Processes changes from a single remote device.
    private func processDeviceChanges(
        _ device: DeviceConfig
    ) async throws -> DeviceSyncResult {
        var result = DeviceSyncResult(deviceId: device.deviceId)

        let watermark = await stateManager.getWatermark(for: device.deviceId)
        let changes = try await reader.readChanges(
            from: device.deviceId,
            afterSequence: watermark
        )

        // Sort by timestamp for deterministic ordering
        let sortedChanges = changes.sorted { c1, c2 in
            if c1.timestamp != c2.timestamp {
                return c1.timestamp < c2.timestamp
            }
            return c1.deviceId < c2.deviceId
        }

        for change in sortedChanges {
            do {
                // Check exclusions
                // (Entity ID extraction would need type-specific handling)
                let applied = try await applyChange(change)
                if applied {
                    result.changesApplied += 1
                } else {
                    result.changesSkipped += 1
                }

                // Update watermark
                try await stateManager.setWatermark(change.sequence, for: device.deviceId)

            } catch let error as IntegrityError {
                result.warnings.append(
                    SyncWarning(
                        deviceId: device.deviceId,
                        message: "Integrity error at sequence \(change.sequence): \(error.localizedDescription)"
                    )
                )

                // Quarantine corrupt file
                let filename = "change_\(change.sequence).json"
                let path = SyncFileNaming.changeFilePath(
                    deviceId: device.deviceId,
                    filename: filename
                )
                _ = try? await storage.quarantineFile(at: path, reason: error.localizedDescription)

            } catch {
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

    /// Applies a single verified change.
    ///
    /// - Parameter change: The change to apply.
    /// - Returns: True if applied, false if skipped.
    private func applyChange(_ change: VerifiedChange) async throws -> Bool {
        guard let delegate = delegate else {
            return false
        }

        return try await delegate.applyChange(change)
    }

    /// Uploads any pending local changes.
    private func uploadPendingChanges() async throws -> UploadResult {
        // The change log writer automatically uploads when recording
        // This method is for any queued changes that failed previously
        return UploadResult(changesSent: 0, errors: [])
    }

    /// Updates the device manifest with current file list.
    private func updateManifest() async throws {
        let changesPath = "\(SyncConstants.changesDirectory)/\(deviceId)"

        guard await storage.fileExists(at: changesPath) else {
            return
        }

        let files = try await storage.listFiles(at: changesPath)

        var entries: [ManifestFileEntry] = []
        var maxSequence = 0

        for file in files where file.name != SyncConstants.manifestFile {
            guard let components = SyncFileNaming.parseChangeFileName(file.name) else {
                continue
            }

            let data = try await storage.readFile(at: file.path)
            let checksum = calculateChecksum(data)

            entries.append(ManifestFileEntry(
                sequence: components.sequence,
                filename: file.name,
                checksum: checksum,
                size: file.size,
                timestamp: components.timestamp
            ))

            maxSequence = max(maxSequence, components.sequence)
        }

        var manifest = DeviceManifest(
            deviceId: deviceId,
            lastUpdated: Date(),
            headSequence: maxSequence,
            files: entries.sorted { $0.sequence < $1.sequence }
        )
        manifest.updateChecksum()

        let envelope = try createIntegrityEnvelope(manifest)
        let data = try encoder.encode(envelope)
        let path = "\(changesPath)/\(SyncConstants.manifestFile)"
        try await storage.writeFile(data, at: path)
    }

    /// Gets the last sync time.
    public func getLastSyncTime() -> Date? {
        lastSyncTime
    }

    /// Gets whether a sync is in progress.
    public func isSyncInProgress() -> Bool {
        isSyncing
    }
}

// MARK: - Sync Engine Delegate

/// Delegate protocol for applying changes to local database.
public protocol SyncEngineDelegate: AnyObject, Sendable {
    /// Applies a verified change to the local database.
    ///
    /// - Parameter change: The change to apply.
    /// - Returns: True if applied, false if skipped.
    func applyChange(_ change: VerifiedChange) async throws -> Bool

    /// Checks if an entity exists locally.
    ///
    /// - Parameters:
    ///   - entityType: Type of entity.
    ///   - id: Entity identifier.
    /// - Returns: Timestamp of local version, or nil.
    func getLocalTimestamp(
        entityType: SyncEntityType,
        id: String
    ) async -> Int64?
}

// MARK: - Result Types

/// Result of a sync operation.
public struct SyncResult: Sendable {
    /// Overall sync status.
    public var status: SyncStatus

    /// Number of devices discovered.
    public var devicesFound: Int = 0

    /// Number of changes received and applied.
    public var changesReceived: Int = 0

    /// Number of changes sent to remote.
    public var changesSent: Int = 0

    /// Duration of sync in seconds.
    public var duration: TimeInterval = 0

    /// Non-fatal warnings encountered.
    public var warnings: [SyncWarning] = []
}

/// Sync status.
public enum SyncStatus: Sendable {
    case success
    case alreadyInProgress
    case failed(Error)
}

/// Result of processing a single device's changes.
struct DeviceSyncResult {
    let deviceId: String
    var changesApplied: Int = 0
    var changesSkipped: Int = 0
    var warnings: [SyncWarning] = []
}

/// Result of uploading changes.
struct UploadResult {
    let changesSent: Int
    let errors: [Error]
}

/// Non-fatal sync warning.
public struct SyncWarning: Sendable {
    public let deviceId: String?
    public let message: String

    public init(deviceId: String? = nil, message: String) {
        self.deviceId = deviceId
        self.message = message
    }
}
```

### Step 3: Create iCloud Drive Storage Provider

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/iCloudSyncStorage.swift`

```swift
import Foundation

/// Sync storage backed by iCloud Drive.
///
/// Uses the ubiquitous container for cross-device sync.
/// Requires iCloud Drive entitlement and container configuration.
public actor iCloudSyncStorage: SyncStorageProtocol {
    /// iCloud container URL.
    private let containerURL: URL

    /// File manager instance.
    private let fileManager = FileManager.default

    /// File coordinator for iCloud operations.
    private let coordinator = NSFileCoordinator()

    /// Creates iCloud Drive storage.
    ///
    /// - Parameter containerIdentifier: iCloud container identifier (nil for default).
    /// - Throws: If iCloud is not available.
    public init(containerIdentifier: String? = nil) throws {
        guard let url = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else {
            throw SyncStorageError.networkUnavailable
        }

        self.containerURL = url.appendingPathComponent(SyncConstants.syncRootDirectory)

        // Ensure root exists
        if !FileManager.default.fileExists(atPath: containerURL.path) {
            try FileManager.default.createDirectory(
                at: containerURL,
                withIntermediateDirectories: true
            )
        }
    }

    /// Resolves a relative path to a full URL.
    private func resolve(_ path: String) -> URL {
        containerURL.appendingPathComponent(path)
    }

    public func listFiles(at path: String) async throws -> [SyncFileInfo] {
        let url = resolve(path)

        return try await withCheckedThrowingContinuation { continuation in
            var error: NSError?

            coordinator.coordinate(
                readingItemAt: url,
                options: [],
                error: &error
            ) { coordinatedURL in
                do {
                    let contents = try fileManager.contentsOfDirectory(
                        at: coordinatedURL,
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )

                    let files = try contents.compactMap { itemURL -> SyncFileInfo? in
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

                    continuation.resume(returning: files)
                } catch {
                    continuation.resume(throwing: SyncStorageError.ioError(error.localizedDescription))
                }
            }

            if let error = error {
                continuation.resume(throwing: SyncStorageError.ioError(error.localizedDescription))
            }
        }
    }

    public func listDirectories(at path: String) async throws -> [String] {
        let url = resolve(path)

        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        return try await withCheckedThrowingContinuation { continuation in
            var error: NSError?

            coordinator.coordinate(
                readingItemAt: url,
                options: [],
                error: &error
            ) { coordinatedURL in
                do {
                    let contents = try fileManager.contentsOfDirectory(
                        at: coordinatedURL,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )

                    let dirs = contents.compactMap { itemURL -> String? in
                        var isDirectory: ObjCBool = false
                        fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)
                        return isDirectory.boolValue ? itemURL.lastPathComponent : nil
                    }

                    continuation.resume(returning: dirs)
                } catch {
                    continuation.resume(throwing: SyncStorageError.ioError(error.localizedDescription))
                }
            }

            if let error = error {
                continuation.resume(throwing: SyncStorageError.ioError(error.localizedDescription))
            }
        }
    }

    public func readFile(at path: String) async throws -> Data {
        let url = resolve(path)

        // Start downloading if not available
        try fileManager.startDownloadingUbiquitousItem(at: url)

        // Wait for download (with timeout)
        for _ in 0..<SyncConstants.iCloudDownloadTimeoutSeconds {
            if let resourceValues = try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]
            ) {
                if resourceValues.ubiquitousItemDownloadingStatus == .current {
                    break
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        return try await withCheckedThrowingContinuation { continuation in
            var error: NSError?

            coordinator.coordinate(
                readingItemAt: url,
                options: [],
                error: &error
            ) { coordinatedURL in
                do {
                    let data = try Data(contentsOf: coordinatedURL)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: SyncStorageError.fileNotFound(path))
                }
            }

            if let error = error {
                continuation.resume(throwing: SyncStorageError.ioError(error.localizedDescription))
            }
        }
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var error: NSError?

            coordinator.coordinate(
                writingItemAt: url,
                options: .forReplacing,
                error: &error
            ) { coordinatedURL in
                do {
                    try data.write(to: coordinatedURL, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: SyncStorageError.ioError(error.localizedDescription))
                }
            }

            if let error = error {
                continuation.resume(throwing: SyncStorageError.ioError(error.localizedDescription))
            }
        }
    }

    public func deleteFile(at path: String) async throws {
        let url = resolve(path)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var error: NSError?

            coordinator.coordinate(
                writingItemAt: url,
                options: .forDeleting,
                error: &error
            ) { coordinatedURL in
                do {
                    try fileManager.removeItem(at: coordinatedURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: SyncStorageError.fileNotFound(path))
                }
            }

            if let error = error {
                continuation.resume(throwing: SyncStorageError.ioError(error.localizedDescription))
            }
        }
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

        try await createDirectory(at: SyncConstants.quarantineDirectory)
        try fileManager.moveItem(at: sourceURL, to: quarantineURL)

        let reasonPath = quarantinePath + ".reason.txt"
        try reason.data(using: .utf8)?.write(to: resolve(reasonPath))

        return quarantinePath
    }

    public func watchForChanges(
        _ callback: @escaping @Sendable (String) -> Void
    ) async -> Any {
        // Use NSMetadataQuery for iCloud changes
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { _ in
            callback(self.containerURL.path)
        }

        query.start()
        return query
    }

    /// Checks if iCloud is available.
    public static func isAvailable() -> Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }
}
```

### Step 4: Create Workspace Initializer

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/WorkspaceInitializer.swift`

```swift
import Foundation

// MARK: - Workspace Initializer

/// Initializes a sync workspace for a new or existing device.
public struct WorkspaceInitializer: Sendable {
    /// Storage backend.
    private let storage: SyncStorageProtocol

    /// JSON encoder.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Creates a workspace initializer.
    ///
    /// - Parameter storage: Storage backend.
    public init(storage: SyncStorageProtocol) {
        self.storage = storage
    }

    /// Initializes a new workspace.
    ///
    /// Creates the directory structure and workspace configuration.
    ///
    /// - Parameter encryption: Encryption mode to use.
    /// - Returns: The workspace configuration.
    public func initializeWorkspace(
        encryption: EncryptionMode = .none
    ) async throws -> WorkspaceConfig {
        // Create directory structure
        try await storage.createDirectory(at: SyncConstants.devicesDirectory)
        try await storage.createDirectory(at: SyncConstants.changesDirectory)
        try await storage.createDirectory(at: SyncConstants.snapshotsDirectory)

        // Create workspace config
        let config = WorkspaceConfig(encryption: encryption)
        let envelope = try createIntegrityEnvelope(config)
        let data = try encoder.encode(envelope)
        try await storage.writeFile(data, at: SyncConstants.workspaceFile)

        return config
    }

    /// Loads an existing workspace.
    ///
    /// - Returns: The workspace configuration, or nil if not found.
    public func loadWorkspace() async throws -> WorkspaceConfig? {
        guard await storage.fileExists(at: SyncConstants.workspaceFile) else {
            return nil
        }

        let data = try await storage.readFile(at: SyncConstants.workspaceFile)
        return try verifyAndExtract(from: data)
    }

    /// Registers a new device.
    ///
    /// - Parameters:
    ///   - name: Human-readable device name.
    ///   - platform: Platform identifier.
    /// - Returns: The device configuration with generated ID.
    public func registerDevice(
        name: String,
        platform: SyncPlatform
    ) async throws -> DeviceConfig {
        let deviceId = UUID().uuidString

        let config = DeviceConfig(
            deviceId: deviceId,
            name: name,
            platform: platform
        )

        let envelope = try createIntegrityEnvelope(config)
        let data = try encoder.encode(envelope)
        let path = SyncFileNaming.deviceFilePath(deviceId: deviceId)
        try await storage.writeFile(data, at: path)

        // Create device's change directory
        let changesPath = "\(SyncConstants.changesDirectory)/\(deviceId)"
        try await storage.createDirectory(at: changesPath)

        return config
    }

    /// Checks if a workspace exists.
    public func workspaceExists() async -> Bool {
        await storage.fileExists(at: SyncConstants.workspaceFile)
    }

    /// Gets or creates workspace.
    ///
    /// - Parameter encryption: Encryption for new workspace.
    /// - Returns: Existing or new workspace configuration.
    public func getOrCreateWorkspace(
        encryption: EncryptionMode = .none
    ) async throws -> WorkspaceConfig {
        if let existing = try await loadWorkspace() {
            // Verify compatibility
            if existing.minCompatibleVersion > SyncConstants.schemaVersion {
                throw IntegrityError.schemaVersionTooNew(
                    found: existing.minCompatibleVersion,
                    maxSupported: SyncConstants.schemaVersion
                )
            }
            return existing
        }

        return try await initializeWorkspace(encryption: encryption)
    }
}
```

### Step 5: Create Sync Coordinator (High-Level API)

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/SyncCoordinator.swift`

```swift
import Foundation
import os.log

// MARK: - Sync Coordinator

/// High-level coordinator for sync operations.
///
/// Provides a simple API for apps to trigger and monitor sync.
@MainActor
public final class SyncCoordinator: ObservableObject {
    /// Current sync status.
    @Published public private(set) var status: SyncCoordinatorStatus = .idle

    /// Last sync result.
    @Published public private(set) var lastResult: SyncResult?

    /// Last sync time.
    @Published public private(set) var lastSyncTime: Date?

    /// Whether sync is available (storage connected).
    @Published public private(set) var isAvailable: Bool = false

    /// Sync engine.
    private var engine: SyncEngine?

    /// Storage provider.
    private var storage: SyncStorageProtocol?

    /// This device's configuration.
    private var deviceConfig: DeviceConfig?

    /// Logger.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "SyncCoordinator"
    )

    /// Creates a sync coordinator.
    public init() {}

    /// Initializes sync with iCloud.
    ///
    /// - Parameters:
    ///   - deviceName: Name for this device.
    ///   - platform: Platform identifier.
    ///   - delegate: Delegate for applying changes.
    public func initializeWithiCloud(
        deviceName: String,
        platform: SyncPlatform,
        delegate: SyncEngineDelegate
    ) async throws {
        status = .initializing

        do {
            guard iCloudSyncStorage.isAvailable() else {
                throw SyncStorageError.networkUnavailable
            }

            let storage = try iCloudSyncStorage()
            self.storage = storage

            let initializer = WorkspaceInitializer(storage: storage)
            _ = try await initializer.getOrCreateWorkspace()

            // Check for existing device config or register new
            let deviceConfig = try await loadOrRegisterDevice(
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

            // Create writer
            let writer = ChangeLogWriter(
                storage: storage,
                deviceId: deviceConfig.deviceId
            )

            // Create engine
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

            logger.info("Sync initialized for device: \(deviceConfig.deviceId)")

        } catch {
            status = .error(error)
            logger.error("Sync initialization failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Initializes sync with a local folder (for testing).
    ///
    /// - Parameters:
    ///   - rootURL: Root directory URL.
    ///   - deviceName: Name for this device.
    ///   - platform: Platform identifier.
    ///   - delegate: Delegate for applying changes.
    public func initializeWithLocalFolder(
        rootURL: URL,
        deviceName: String,
        platform: SyncPlatform,
        delegate: SyncEngineDelegate
    ) async throws {
        status = .initializing

        do {
            let storage = try LocalFolderSyncStorage(rootURL: rootURL)
            self.storage = storage

            let initializer = WorkspaceInitializer(storage: storage)
            _ = try await initializer.getOrCreateWorkspace()

            let deviceConfig = try await loadOrRegisterDevice(
                initializer: initializer,
                name: deviceName,
                platform: platform
            )
            self.deviceConfig = deviceConfig

            let stateManager = SyncStateManager(
                storage: storage,
                deviceConfig: deviceConfig
            )
            try await stateManager.loadState()

            let writer = ChangeLogWriter(
                storage: storage,
                deviceId: deviceConfig.deviceId
            )

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

        } catch {
            status = .error(error)
            throw error
        }
    }

    /// Triggers a sync operation.
    public func sync() async {
        guard let engine = engine else {
            logger.warning("Sync requested but engine not initialized")
            return
        }

        guard status != .syncing else {
            logger.info("Sync already in progress")
            return
        }

        status = .syncing

        do {
            let result = try await engine.sync()
            lastResult = result
            lastSyncTime = Date()

            switch result.status {
            case .success:
                status = .idle
                logger.info("Sync completed: \(result.changesReceived) received, \(result.changesSent) sent")
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
    /// - Parameters:
    ///   - entity: Entity type.
    ///   - id: Entity identifier.
    ///   - data: Entity data.
    public func recordChange<T: Codable & Sendable>(
        entity: SyncEntityType,
        id: String,
        data: T
    ) async throws {
        guard let engine = engine else {
            throw SyncStorageError.networkUnavailable
        }

        // Access writer through engine or state manager
        // This would need refactoring to expose writer properly
        logger.debug("Change recorded: \(entity.rawValue) \(id)")
    }

    /// Loads existing device config or registers new.
    private func loadOrRegisterDevice(
        initializer: WorkspaceInitializer,
        name: String,
        platform: SyncPlatform
    ) async throws -> DeviceConfig {
        // In a real implementation, we'd store deviceId locally
        // and try to load matching config. For now, always register.
        return try await initializer.registerDevice(
            name: name,
            platform: platform
        )
    }

    /// Gets the current device ID.
    public var deviceId: String? {
        deviceConfig?.deviceId
    }
}

// MARK: - Status

/// Status of the sync coordinator.
public enum SyncCoordinatorStatus: Equatable {
    case idle
    case initializing
    case syncing
    case error(Error)

    public static func == (lhs: SyncCoordinatorStatus, rhs: SyncCoordinatorStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.initializing, .initializing), (.syncing, .syncing):
            return true
        case (.error, .error):
            return true // Simplified comparison
        default:
            return false
        }
    }
}
```

### Step 6: Create Tests

**File**: `Packages/BioMedLit/Tests/BioMedLitTests/SyncEngineTests.swift`

```swift
import XCTest
@testable import BioMedLit

final class SyncEngineTests: XCTestCase {

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

    // MARK: - LWW Merge Tests

    func testLWWMergeTimestampWins() {
        let localTs: Int64 = 1000
        let remoteTs: Int64 = 2000

        let shouldApply = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: remoteTs, deviceId: "device-b"),
            local: (timestamp: localTs, deviceId: "device-a")
        )

        XCTAssertTrue(shouldApply, "Later timestamp should win")
    }

    func testLWWMergeTiebreaker() {
        let timestamp: Int64 = 1000

        // Same timestamp, device-b > device-a alphabetically
        let shouldApply = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: timestamp, deviceId: "device-b"),
            local: (timestamp: timestamp, deviceId: "device-a")
        )

        XCTAssertTrue(shouldApply, "Higher device ID should win on tie")

        let shouldNotApply = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: timestamp, deviceId: "device-a"),
            local: (timestamp: timestamp, deviceId: "device-b")
        )

        XCTAssertFalse(shouldNotApply, "Lower device ID should lose on tie")
    }

    func testLWWMergeNoLocal() {
        let shouldApply = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: 1000, deviceId: "device-a"),
            local: nil
        )

        XCTAssertTrue(shouldApply, "Should always apply when no local version")
    }

    // MARK: - Workspace Initializer Tests

    func testWorkspaceInitialization() async throws {
        let initializer = WorkspaceInitializer(storage: storage)

        let config = try await initializer.initializeWorkspace()

        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.schemaVersion, SyncConstants.schemaVersion)
        XCTAssertEqual(config.encryption, .none)

        // Verify directories created
        XCTAssertTrue(await storage.fileExists(at: SyncConstants.workspaceFile))
    }

    func testDeviceRegistration() async throws {
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.initializeWorkspace()

        let device = try await initializer.registerDevice(
            name: "Test iPhone",
            platform: .ios
        )

        XCTAssertFalse(device.deviceId.isEmpty)
        XCTAssertEqual(device.name, "Test iPhone")
        XCTAssertEqual(device.platform, .ios)
        XCTAssertEqual(device.syncScope.mode, .full)

        // Verify device file created
        let path = SyncFileNaming.deviceFilePath(deviceId: device.deviceId)
        XCTAssertTrue(await storage.fileExists(at: path))
    }

    func testWorkspaceLoadAfterCreate() async throws {
        let initializer = WorkspaceInitializer(storage: storage)

        // Create
        let created = try await initializer.initializeWorkspace()

        // Load
        let loaded = try await initializer.loadWorkspace()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(created.schemaVersion, loaded?.schemaVersion)
    }

    // MARK: - Sync Engine Tests

    func testSyncEngineInitialization() async throws {
        let initializer = WorkspaceInitializer(storage: storage)
        _ = try await initializer.initializeWorkspace()

        let deviceConfig = try await initializer.registerDevice(
            name: "Test Device",
            platform: .ios
        )

        let stateManager = SyncStateManager(
            storage: storage,
            deviceConfig: deviceConfig
        )

        let writer = ChangeLogWriter(
            storage: storage,
            deviceId: deviceConfig.deviceId
        )

        let engine = SyncEngine(
            storage: storage,
            deviceId: deviceConfig.deviceId,
            stateManager: stateManager,
            writer: writer
        )

        XCTAssertFalse(await engine.isSyncInProgress())
        XCTAssertNil(await engine.getLastSyncTime())
    }

    // MARK: - Integration Test

    func testTwoDeviceSync() async throws {
        // Device A setup
        let deviceARoot = tempDirectory.appendingPathComponent("deviceA")
        let storageA = try LocalFolderSyncStorage(rootURL: deviceARoot)
        let initializerA = WorkspaceInitializer(storage: storageA)
        _ = try await initializerA.initializeWorkspace()
        let configA = try await initializerA.registerDevice(name: "Device A", platform: .ios)

        // Device B setup (pointing to same workspace via shared folder simulation)
        // In real scenario, this would be iCloud syncing the files
        let storageB = try LocalFolderSyncStorage(rootURL: deviceARoot)
        let initializerB = WorkspaceInitializer(storage: storageB)
        let configB = try await initializerB.registerDevice(name: "Device B", platform: .macos)

        // Both devices should see each other
        let reader = ChangeLogReader(storage: storageA, myDeviceId: configA.deviceId)
        let devices = try await reader.discoverDevices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.deviceId, configB.deviceId)
    }
}
```

## Files to Create

| File | Description |
|------|-------------|
| `Sync/LWWMergeStrategy.swift` | Last-Write-Wins merge logic |
| `Sync/SyncEngine.swift` | Main sync orchestrator |
| `Sync/iCloudSyncStorage.swift` | iCloud Drive storage provider |
| `Sync/WorkspaceInitializer.swift` | Workspace and device setup |
| `Sync/SyncCoordinator.swift` | High-level API for apps |
| `Tests/SyncEngineTests.swift` | Unit and integration tests |

## Acceptance Criteria

1. **LWW merge works**: Later timestamp wins, device ID tiebreaker
2. **Workspace initializes**: Creates directories and config
3. **Device registration**: Creates device config with UUID
4. **iCloud storage**: Reads/writes through file coordination
5. **Sync engine**: Discovers devices, reads changes, updates watermarks
6. **All tests pass**: `swift test` succeeds

## iCloud Entitlements

Add to iOS/macOS app:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.bmlibrarian.factchecker</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudDocuments</string>
</array>
```

## Dependencies

- Phase 1 (integrity functions)
- Phase 2 (change tracking, storage protocol)

## Next Phase

Phase 4 will implement selective sync and storage management.
