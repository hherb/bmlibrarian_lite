# Phase 4: Selective Sync & Storage Management

## Overview

This phase implements selective sync capabilities for devices with limited storage. Users can choose which sessions to sync, evict content to free space, and fetch data on-demand.

**Goal**: Enable efficient storage management while maintaining full sync capabilities.

**Package Location**: `Packages/BioMedLit/Sources/BioMedLit/Sync/`

## Prerequisites

- Phase 1-3 complete

## Golden Rules Compliance

- **No magic numbers**: Storage limits, ratios from `SyncConstants`
- **Type hints**: Full Swift type annotations
- **Docstrings**: Documentation comments on all public APIs
- **Pure functions**: Eviction selection is deterministic

## Implementation Steps

### Step 1: Create Storage Monitor

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/StorageMonitor.swift`

```swift
import Foundation

// MARK: - Storage Monitor

/// Monitors local storage usage for sync.
public actor StorageMonitor {
    /// Delegate for storage queries.
    private weak var delegate: StorageMonitorDelegate?

    /// Cached storage info.
    private var cachedInfo: StorageInfo?

    /// When cache was last updated.
    private var cacheTime: Date?

    /// Cache duration in seconds.
    private let cacheDuration: TimeInterval = 60

    /// Creates a storage monitor.
    ///
    /// - Parameter delegate: Delegate for storage queries.
    public init(delegate: StorageMonitorDelegate) {
        self.delegate = delegate
    }

    /// Gets current storage info.
    ///
    /// - Parameter forceRefresh: Bypass cache.
    /// - Returns: Current storage information.
    public func getStorageInfo(forceRefresh: Bool = false) async throws -> StorageInfo {
        // Return cached if valid
        if !forceRefresh,
           let cached = cachedInfo,
           let cacheTime = cacheTime,
           Date().timeIntervalSince(cacheTime) < cacheDuration {
            return cached
        }

        guard let delegate = delegate else {
            throw StorageError.delegateNotSet
        }

        let info = try await delegate.calculateStorageInfo()
        cachedInfo = info
        cacheTime = Date()

        return info
    }

    /// Checks if storage limit is exceeded.
    ///
    /// - Parameter maxMB: Maximum storage in megabytes.
    /// - Returns: True if limit exceeded.
    public func isStorageExceeded(maxMB: Int) async throws -> Bool {
        let info = try await getStorageInfo()
        return info.usedMB > maxMB
    }

    /// Gets recommended eviction amount.
    ///
    /// - Parameters:
    ///   - maxMB: Maximum storage in megabytes.
    ///   - targetRatio: Target ratio after eviction.
    /// - Returns: Megabytes to evict, or 0 if not needed.
    public func getRecommendedEvictionMB(
        maxMB: Int,
        targetRatio: Double = SyncConstants.evictionTargetRatio
    ) async throws -> Int {
        let info = try await getStorageInfo()

        if info.usedMB <= maxMB {
            return 0
        }

        let targetMB = Int(Double(maxMB) * targetRatio)
        return info.usedMB - targetMB
    }

    /// Invalidates the cache.
    public func invalidateCache() {
        cachedInfo = nil
        cacheTime = nil
    }
}

// MARK: - Storage Info

/// Information about storage usage.
public struct StorageInfo: Sendable, Equatable {
    /// Total used storage in megabytes.
    public let usedMB: Int

    /// Storage by entity type.
    public let byEntity: [SyncEntityType: Int]

    /// Number of full sessions.
    public let fullSessionCount: Int

    /// Number of stub sessions.
    public let stubSessionCount: Int

    /// Largest sessions (for eviction candidates).
    public let largestSessions: [SessionStorageInfo]

    /// Creates storage info.
    public init(
        usedMB: Int,
        byEntity: [SyncEntityType: Int] = [:],
        fullSessionCount: Int = 0,
        stubSessionCount: Int = 0,
        largestSessions: [SessionStorageInfo] = []
    ) {
        self.usedMB = usedMB
        self.byEntity = byEntity
        self.fullSessionCount = fullSessionCount
        self.stubSessionCount = stubSessionCount
        self.largestSessions = largestSessions
    }
}

/// Storage info for a single session.
public struct SessionStorageInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let sizeMB: Int
    public let documentCount: Int
    public let hasReport: Bool
    public let lastAccessedAt: Date
    public let createdAt: Date
    public let syncState: RecordSyncState

    public init(
        id: String,
        title: String,
        sizeMB: Int,
        documentCount: Int,
        hasReport: Bool,
        lastAccessedAt: Date,
        createdAt: Date,
        syncState: RecordSyncState
    ) {
        self.id = id
        self.title = title
        self.sizeMB = sizeMB
        self.documentCount = documentCount
        self.hasReport = hasReport
        self.lastAccessedAt = lastAccessedAt
        self.createdAt = createdAt
        self.syncState = syncState
    }
}

// MARK: - Storage Monitor Delegate

/// Delegate protocol for storage queries.
public protocol StorageMonitorDelegate: AnyObject, Sendable {
    /// Calculates current storage info.
    func calculateStorageInfo() async throws -> StorageInfo

    /// Gets storage info for a specific session.
    func getSessionStorageInfo(sessionId: String) async throws -> SessionStorageInfo?
}

// MARK: - Storage Errors

/// Errors from storage operations.
public enum StorageError: Error, LocalizedError, Sendable {
    case delegateNotSet
    case sessionNotFound(String)
    case evictionFailed(String)
    case fetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .delegateNotSet:
            return "Storage delegate not set"
        case .sessionNotFound(let id):
            return "Session not found: \(id)"
        case .evictionFailed(let reason):
            return "Eviction failed: \(reason)"
        case .fetchFailed(let reason):
            return "Fetch failed: \(reason)"
        }
    }
}
```

### Step 2: Create Session Eviction Manager

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/SessionEvictionManager.swift`

```swift
import Foundation

// MARK: - Session Eviction Manager

/// Manages eviction of session content to free storage.
public actor SessionEvictionManager {
    /// Storage monitor.
    private let storageMonitor: StorageMonitor

    /// Delegate for eviction operations.
    private weak var delegate: SessionEvictionDelegate?

    /// Pinned session IDs (never evict).
    private var pinnedSessions: Set<String> = []

    /// Creates an eviction manager.
    ///
    /// - Parameters:
    ///   - storageMonitor: Storage monitor.
    ///   - delegate: Delegate for eviction operations.
    public init(
        storageMonitor: StorageMonitor,
        delegate: SessionEvictionDelegate
    ) {
        self.storageMonitor = storageMonitor
        self.delegate = delegate
    }

    /// Pins a session (prevents eviction).
    ///
    /// - Parameter sessionId: Session identifier.
    public func pinSession(_ sessionId: String) {
        pinnedSessions.insert(sessionId)
    }

    /// Unpins a session.
    ///
    /// - Parameter sessionId: Session identifier.
    public func unpinSession(_ sessionId: String) {
        pinnedSessions.remove(sessionId)
    }

    /// Checks if a session is pinned.
    ///
    /// - Parameter sessionId: Session identifier.
    public func isPinned(_ sessionId: String) -> Bool {
        pinnedSessions.contains(sessionId)
    }

    /// Evicts a specific session's content.
    ///
    /// Converts the session to a stub, keeping metadata but removing
    /// documents, citations, and full-text content.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Megabytes freed.
    public func evictSession(_ sessionId: String) async throws -> Int {
        guard !pinnedSessions.contains(sessionId) else {
            throw StorageError.evictionFailed("Session is pinned")
        }

        guard let delegate = delegate else {
            throw StorageError.delegateNotSet
        }

        let freed = try await delegate.evictSessionContent(sessionId)

        // Invalidate storage cache
        await storageMonitor.invalidateCache()

        return freed
    }

    /// Auto-evicts sessions to meet storage target.
    ///
    /// - Parameters:
    ///   - maxMB: Maximum storage in megabytes.
    ///   - strategy: Eviction strategy.
    ///   - minKeep: Minimum sessions to keep.
    /// - Returns: Eviction result.
    public func autoEvict(
        maxMB: Int,
        strategy: EvictionStrategy = .lru,
        minKeep: Int = SyncConstants.defaultMinSessionsToKeep
    ) async throws -> EvictionResult {
        let info = try await storageMonitor.getStorageInfo(forceRefresh: true)

        // Check if eviction needed
        guard info.usedMB > maxMB else {
            return EvictionResult(sessionsEvicted: 0, mbFreed: 0)
        }

        let targetMB = Int(Double(maxMB) * SyncConstants.evictionTargetRatio)
        let toFree = info.usedMB - targetMB

        // Get candidates sorted by strategy
        let candidates = selectEvictionCandidates(
            from: info.largestSessions,
            strategy: strategy,
            minKeep: minKeep
        )

        var totalFreed = 0
        var sessionsEvicted = 0

        for candidate in candidates {
            guard totalFreed < toFree else { break }
            guard !pinnedSessions.contains(candidate.id) else { continue }

            do {
                let freed = try await evictSession(candidate.id)
                totalFreed += freed
                sessionsEvicted += 1
            } catch {
                // Log but continue with other sessions
                continue
            }
        }

        return EvictionResult(
            sessionsEvicted: sessionsEvicted,
            mbFreed: totalFreed
        )
    }

    /// Selects eviction candidates based on strategy.
    ///
    /// This is a pure function for deterministic selection.
    ///
    /// - Parameters:
    ///   - sessions: Available sessions.
    ///   - strategy: Eviction strategy.
    ///   - minKeep: Minimum to keep.
    /// - Returns: Sorted candidates (first = evict first).
    public func selectEvictionCandidates(
        from sessions: [SessionStorageInfo],
        strategy: EvictionStrategy,
        minKeep: Int
    ) -> [SessionStorageInfo] {
        // Filter out stubs and local-only
        var candidates = sessions.filter { session in
            session.syncState == .full
        }

        // Sort by strategy
        switch strategy {
        case .lru:
            candidates.sort { $0.lastAccessedAt < $1.lastAccessedAt }
        case .largest:
            candidates.sort { $0.sizeMB > $1.sizeMB }
        case .oldest:
            candidates.sort { $0.createdAt < $1.createdAt }
        case .noReport:
            // Sessions without reports first, then by last accessed
            candidates.sort { session1, session2 in
                if session1.hasReport != session2.hasReport {
                    return !session1.hasReport
                }
                return session1.lastAccessedAt < session2.lastAccessedAt
            }
        }

        // Keep minimum number
        if candidates.count > minKeep {
            return Array(candidates.dropLast(minKeep))
        }

        return []
    }
}

// MARK: - Session Eviction Delegate

/// Delegate protocol for session eviction operations.
public protocol SessionEvictionDelegate: AnyObject, Sendable {
    /// Evicts content for a session.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Megabytes freed.
    func evictSessionContent(_ sessionId: String) async throws -> Int

    /// Creates a stub for a session.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - stub: Stub data to save.
    func saveSessionStub(_ sessionId: String, stub: SessionStub) async throws
}

// MARK: - Eviction Result

/// Result of an eviction operation.
public struct EvictionResult: Sendable, Equatable {
    /// Number of sessions evicted.
    public let sessionsEvicted: Int

    /// Total megabytes freed.
    public let mbFreed: Int
}

// MARK: - Session Stub

/// Minimal metadata for an evicted session.
public struct SessionStub: Codable, Sendable, Equatable {
    /// Session identifier.
    public let id: String

    /// Research claim/question.
    public let claim: String

    /// When session was created.
    public let createdAt: Date

    /// Number of documents (before eviction).
    public let documentCount: Int

    /// Number of citations (before eviction).
    public let citationCount: Int

    /// Whether report was generated.
    public let hasReport: Bool

    /// Original content size in bytes.
    public let contentSizeBytes: Int

    /// When content was evicted.
    public let evictedAt: Date

    /// Creates a session stub.
    public init(
        id: String,
        claim: String,
        createdAt: Date,
        documentCount: Int,
        citationCount: Int,
        hasReport: Bool,
        contentSizeBytes: Int,
        evictedAt: Date = Date()
    ) {
        self.id = id
        self.claim = claim
        self.createdAt = createdAt
        self.documentCount = documentCount
        self.citationCount = citationCount
        self.hasReport = hasReport
        self.contentSizeBytes = contentSizeBytes
        self.evictedAt = evictedAt
    }
}
```

### Step 3: Create On-Demand Fetcher

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/OnDemandFetcher.swift`

```swift
import Foundation

// MARK: - On-Demand Fetcher

/// Fetches session content on-demand from remote storage.
public actor OnDemandFetcher {
    /// Sync storage.
    private let storage: SyncStorageProtocol

    /// Change log reader.
    private let reader: ChangeLogReader

    /// Delegate for applying fetched content.
    private weak var delegate: OnDemandFetchDelegate?

    /// Currently fetching sessions (to prevent duplicates).
    private var inProgress: Set<String> = []

    /// Creates an on-demand fetcher.
    ///
    /// - Parameters:
    ///   - storage: Sync storage.
    ///   - reader: Change log reader.
    ///   - delegate: Delegate for applying content.
    public init(
        storage: SyncStorageProtocol,
        reader: ChangeLogReader,
        delegate: OnDemandFetchDelegate
    ) {
        self.storage = storage
        self.reader = reader
        self.delegate = delegate
    }

    /// Fetches full session content.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Fetch result.
    public func fetchSession(_ sessionId: String) async throws -> FetchResult {
        guard !inProgress.contains(sessionId) else {
            return FetchResult(status: .alreadyInProgress)
        }

        inProgress.insert(sessionId)
        defer { inProgress.remove(sessionId) }

        guard let delegate = delegate else {
            throw StorageError.delegateNotSet
        }

        // Check current state
        let currentState = try await delegate.getSessionSyncState(sessionId)
        guard currentState != .full else {
            return FetchResult(status: .alreadyFull)
        }

        // Find which device has the content
        let sourceDevice = try await findDeviceWithContent(sessionId)

        guard let device = sourceDevice else {
            // Try snapshot as fallback
            if let snapshot = try await findSnapshotWithSession(sessionId) {
                try await restoreFromSnapshot(sessionId: sessionId, snapshot: snapshot)
                return FetchResult(status: .restoredFromSnapshot)
            }
            throw StorageError.fetchFailed("No device has content for session \(sessionId)")
        }

        // Fetch changes from that device
        try await fetchFromDevice(sessionId: sessionId, deviceId: device)

        return FetchResult(status: .fetched)
    }

    /// Finds a device that has full content for a session.
    private func findDeviceWithContent(_ sessionId: String) async throws -> String? {
        let devices = try await reader.discoverDevices()

        for device in devices {
            // Check device's manifest for session-related changes
            guard let manifest = try await reader.readManifest(for: device.deviceId) else {
                continue
            }

            // Look for session create/upsert in files
            let hasSession = manifest.files.contains { file in
                file.filename.contains(sessionId) ||
                (file.filename.contains("session") && file.filename.contains("upsert"))
            }

            if hasSession {
                return device.deviceId
            }
        }

        return nil
    }

    /// Finds a snapshot containing a session.
    private func findSnapshotWithSession(_ sessionId: String) async throws -> String? {
        let snapshotFiles = try await storage.listFiles(at: SyncConstants.snapshotsDirectory)

        // Sort by date (newest first)
        let sorted = snapshotFiles.sorted { $0.modifiedAt > $1.modifiedAt }

        for snapshotFile in sorted {
            // Would need to peek into snapshot to check if session is there
            // For now, return first available
            return snapshotFile.path
        }

        return nil
    }

    /// Fetches session data from a specific device.
    private func fetchFromDevice(sessionId: String, deviceId: String) async throws {
        guard let delegate = delegate else { return }

        // Get all changes from device
        let changes = try await reader.readChanges(from: deviceId, afterSequence: 0)

        // Filter to relevant changes
        for change in changes {
            // Would need type-specific decoding
            // For session: decode and check ID
            // For documents: decode and check session ID
            try await delegate.applyFetchedChange(change)
        }

        // Update sync state
        try await delegate.setSessionSyncState(sessionId, state: .full)
    }

    /// Restores session from snapshot.
    private func restoreFromSnapshot(sessionId: String, snapshot: String) async throws {
        // Decompress and parse snapshot
        // Extract session and related entities
        // Apply to local database
    }

    /// Checks if a fetch is in progress.
    public func isFetching(_ sessionId: String) -> Bool {
        inProgress.contains(sessionId)
    }
}

// MARK: - On-Demand Fetch Delegate

/// Delegate for applying fetched content.
public protocol OnDemandFetchDelegate: AnyObject, Sendable {
    /// Gets sync state for a session.
    func getSessionSyncState(_ sessionId: String) async throws -> RecordSyncState

    /// Sets sync state for a session.
    func setSessionSyncState(_ sessionId: String, state: RecordSyncState) async throws

    /// Applies a fetched change.
    func applyFetchedChange(_ change: VerifiedChange) async throws
}

// MARK: - Fetch Result

/// Result of an on-demand fetch.
public struct FetchResult: Sendable, Equatable {
    /// Fetch status.
    public let status: FetchStatus
}

/// Status of a fetch operation.
public enum FetchStatus: Sendable, Equatable {
    case fetched
    case alreadyFull
    case alreadyInProgress
    case restoredFromSnapshot
}
```

### Step 4: Create Sync Scope Manager

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/SyncScopeManager.swift`

```swift
import Foundation

// MARK: - Sync Scope Manager

/// Manages sync scope configuration for a device.
public actor SyncScopeManager {
    /// Storage backend.
    private let storage: SyncStorageProtocol

    /// Device configuration.
    private var deviceConfig: DeviceConfig

    /// Local exclusions.
    private var exclusions: LocalExclusions

    /// JSON encoder.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Creates a sync scope manager.
    ///
    /// - Parameters:
    ///   - storage: Storage backend.
    ///   - deviceConfig: Device configuration.
    public init(storage: SyncStorageProtocol, deviceConfig: DeviceConfig) {
        self.storage = storage
        self.deviceConfig = deviceConfig
        self.exclusions = LocalExclusions()
    }

    /// Gets the current sync mode.
    public func getSyncMode() -> SyncMode {
        deviceConfig.syncScope.mode
    }

    /// Sets the sync mode.
    ///
    /// - Parameter mode: New sync mode.
    public func setSyncMode(_ mode: SyncMode) async throws {
        deviceConfig.syncScope.mode = mode
        try await saveDeviceConfig()
    }

    /// Gets the session filter.
    public func getSessionFilter() -> SessionFilter? {
        deviceConfig.syncScope.sessionFilter
    }

    /// Adds a session to the whitelist.
    ///
    /// - Parameter sessionId: Session identifier.
    public func addToWhitelist(_ sessionId: String) async throws {
        if deviceConfig.syncScope.sessionFilter == nil {
            deviceConfig.syncScope.sessionFilter = SessionFilter(mode: .whitelist)
        }
        deviceConfig.syncScope.sessionFilter?.ids.append(sessionId)
        try await saveDeviceConfig()
    }

    /// Removes a session from the whitelist.
    ///
    /// - Parameter sessionId: Session identifier.
    public func removeFromWhitelist(_ sessionId: String) async throws {
        deviceConfig.syncScope.sessionFilter?.ids.removeAll { $0 == sessionId }
        try await saveDeviceConfig()
    }

    /// Checks if a session is in scope for syncing.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if session should be synced.
    public func isInScope(_ sessionId: String) -> Bool {
        // Check exclusions first
        if exclusions.isExcluded(sessionId) {
            return false
        }

        switch deviceConfig.syncScope.mode {
        case .full:
            return true

        case .selective:
            guard let filter = deviceConfig.syncScope.sessionFilter else {
                return true // No filter = include all
            }
            return filter.ids.contains(sessionId)

        case .recent:
            // Would need session creation date
            // For now, return true
            return true

        case .minimal:
            // Only sync stubs
            return false
        }
    }

    /// Excludes a session locally (without affecting cloud).
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - reason: Reason for exclusion.
    public func excludeLocally(_ sessionId: String, reason: ExclusionReason) {
        exclusions.exclude(sessionId, reason: reason)
    }

    /// Includes a previously excluded session.
    ///
    /// - Parameter sessionId: Session identifier.
    public func includeLocally(_ sessionId: String) {
        exclusions.include(sessionId)
    }

    /// Gets all local exclusions.
    public func getExclusions() -> LocalExclusions {
        exclusions
    }

    /// Sets the maximum local storage.
    ///
    /// - Parameter maxMB: Maximum storage in megabytes.
    public func setMaxLocalStorage(_ maxMB: Int) async throws {
        deviceConfig.syncScope.maxLocalStorageMB = maxMB
        try await saveDeviceConfig()
    }

    /// Gets the maximum local storage.
    public func getMaxLocalStorage() -> Int {
        deviceConfig.syncScope.maxLocalStorageMB
    }

    /// Configures auto-eviction.
    ///
    /// - Parameter config: Auto-eviction configuration.
    public func setAutoEviction(_ config: AutoEvictionConfig) async throws {
        deviceConfig.syncScope.autoEviction = config
        try await saveDeviceConfig()
    }

    /// Gets auto-eviction configuration.
    public func getAutoEviction() -> AutoEvictionConfig? {
        deviceConfig.syncScope.autoEviction
    }

    /// Saves the device configuration to storage.
    private func saveDeviceConfig() async throws {
        let envelope = try createIntegrityEnvelope(deviceConfig)
        let data = try encoder.encode(envelope)
        let path = SyncFileNaming.deviceFilePath(deviceId: deviceConfig.deviceId)
        try await storage.writeFile(data, at: path)
    }
}
```

### Step 5: Create Selective Sync Coordinator

**File**: `Packages/BioMedLit/Sources/BioMedLit/Sync/SelectiveSyncCoordinator.swift`

```swift
import Foundation
import os.log

// MARK: - Selective Sync Coordinator

/// Coordinates selective sync operations.
///
/// Provides a unified API for managing sync scope, storage, and eviction.
@MainActor
public final class SelectiveSyncCoordinator: ObservableObject {
    /// Current storage info.
    @Published public private(set) var storageInfo: StorageInfo?

    /// Sessions available for syncing.
    @Published public private(set) var availableSessions: [SessionSyncInfo] = []

    /// Sessions on this device.
    @Published public private(set) var localSessions: [SessionSyncInfo] = []

    /// Whether a fetch is in progress.
    @Published public private(set) var isFetching: Bool = false

    /// Current sync mode.
    @Published public private(set) var syncMode: SyncMode = .full

    /// Storage limit in MB.
    @Published public private(set) var storageLimit: Int = SyncConstants.defaultMaxStorageMB

    /// Scope manager.
    private var scopeManager: SyncScopeManager?

    /// Eviction manager.
    private var evictionManager: SessionEvictionManager?

    /// On-demand fetcher.
    private var fetcher: OnDemandFetcher?

    /// Storage monitor.
    private var storageMonitor: StorageMonitor?

    /// Logger.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "SelectiveSync"
    )

    /// Creates a selective sync coordinator.
    public init() {}

    /// Initializes with required components.
    ///
    /// - Parameters:
    ///   - scopeManager: Sync scope manager.
    ///   - evictionManager: Session eviction manager.
    ///   - fetcher: On-demand fetcher.
    ///   - storageMonitor: Storage monitor.
    public func initialize(
        scopeManager: SyncScopeManager,
        evictionManager: SessionEvictionManager,
        fetcher: OnDemandFetcher,
        storageMonitor: StorageMonitor
    ) async {
        self.scopeManager = scopeManager
        self.evictionManager = evictionManager
        self.fetcher = fetcher
        self.storageMonitor = storageMonitor

        // Load initial state
        await refresh()
    }

    /// Refreshes all state.
    public func refresh() async {
        guard let scopeManager = scopeManager,
              let storageMonitor = storageMonitor else {
            return
        }

        do {
            // Update storage info
            storageInfo = try await storageMonitor.getStorageInfo(forceRefresh: true)

            // Update sync mode
            syncMode = await scopeManager.getSyncMode()

            // Update storage limit
            storageLimit = await scopeManager.getMaxLocalStorage()

        } catch {
            logger.error("Failed to refresh: \(error.localizedDescription)")
        }
    }

    /// Changes the sync mode.
    ///
    /// - Parameter mode: New sync mode.
    public func setSyncMode(_ mode: SyncMode) async {
        guard let scopeManager = scopeManager else { return }

        do {
            try await scopeManager.setSyncMode(mode)
            syncMode = mode
            logger.info("Sync mode changed to: \(mode.rawValue)")
        } catch {
            logger.error("Failed to set sync mode: \(error.localizedDescription)")
        }
    }

    /// Sets the storage limit.
    ///
    /// - Parameter limitMB: New limit in megabytes.
    public func setStorageLimit(_ limitMB: Int) async {
        guard let scopeManager = scopeManager else { return }

        do {
            try await scopeManager.setMaxLocalStorage(limitMB)
            storageLimit = limitMB

            // Check if eviction needed
            await checkAndAutoEvict()

            logger.info("Storage limit set to: \(limitMB) MB")
        } catch {
            logger.error("Failed to set storage limit: \(error.localizedDescription)")
        }
    }

    /// Adds a session to sync scope.
    ///
    /// - Parameter sessionId: Session identifier.
    public func addSession(_ sessionId: String) async {
        guard let scopeManager = scopeManager else { return }

        do {
            try await scopeManager.addToWhitelist(sessionId)

            // Fetch content if not present
            await fetchSession(sessionId)

            logger.info("Added session to scope: \(sessionId)")
        } catch {
            logger.error("Failed to add session: \(error.localizedDescription)")
        }
    }

    /// Removes a session from sync scope.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - deleteLocal: Also delete local content.
    public func removeSession(_ sessionId: String, deleteLocal: Bool = false) async {
        guard let scopeManager = scopeManager else { return }

        do {
            try await scopeManager.removeFromWhitelist(sessionId)

            if deleteLocal {
                await evictSession(sessionId)
            }

            logger.info("Removed session from scope: \(sessionId)")
        } catch {
            logger.error("Failed to remove session: \(error.localizedDescription)")
        }
    }

    /// Fetches a session's content on-demand.
    ///
    /// - Parameter sessionId: Session identifier.
    public func fetchSession(_ sessionId: String) async {
        guard let fetcher = fetcher else { return }

        isFetching = true
        defer { isFetching = false }

        do {
            let result = try await fetcher.fetchSession(sessionId)
            logger.info("Fetch result for \(sessionId): \(String(describing: result.status))")

            await refresh()
        } catch {
            logger.error("Failed to fetch session: \(error.localizedDescription)")
        }
    }

    /// Evicts a session's content.
    ///
    /// - Parameter sessionId: Session identifier.
    public func evictSession(_ sessionId: String) async {
        guard let evictionManager = evictionManager else { return }

        do {
            let freed = try await evictionManager.evictSession(sessionId)
            logger.info("Evicted session \(sessionId), freed \(freed) MB")

            await refresh()
        } catch {
            logger.error("Failed to evict session: \(error.localizedDescription)")
        }
    }

    /// Pins a session (prevents eviction).
    ///
    /// - Parameter sessionId: Session identifier.
    public func pinSession(_ sessionId: String) async {
        guard let evictionManager = evictionManager else { return }
        await evictionManager.pinSession(sessionId)
    }

    /// Unpins a session.
    ///
    /// - Parameter sessionId: Session identifier.
    public func unpinSession(_ sessionId: String) async {
        guard let evictionManager = evictionManager else { return }
        await evictionManager.unpinSession(sessionId)
    }

    /// Triggers auto-eviction if needed.
    public func checkAndAutoEvict() async {
        guard let evictionManager = evictionManager,
              let scopeManager = scopeManager else {
            return
        }

        let config = await scopeManager.getAutoEviction()
        guard config?.enabled == true else { return }

        do {
            let result = try await evictionManager.autoEvict(
                maxMB: storageLimit,
                strategy: config?.strategy ?? .lru,
                minKeep: config?.keepMinimumSessions ?? SyncConstants.defaultMinSessionsToKeep
            )

            if result.sessionsEvicted > 0 {
                logger.info("Auto-evicted \(result.sessionsEvicted) sessions, freed \(result.mbFreed) MB")
                await refresh()
            }
        } catch {
            logger.error("Auto-eviction failed: \(error.localizedDescription)")
        }
    }

    /// Deletes a session locally only (keeps in cloud).
    ///
    /// - Parameter sessionId: Session identifier.
    public func deleteLocalOnly(_ sessionId: String) async {
        guard let scopeManager = scopeManager,
              let evictionManager = evictionManager else {
            return
        }

        do {
            // Exclude from future syncs
            await scopeManager.excludeLocally(sessionId, reason: .userDeletedLocal)

            // Evict content
            _ = try await evictionManager.evictSession(sessionId)

            logger.info("Deleted session locally: \(sessionId)")
            await refresh()
        } catch {
            logger.error("Failed to delete locally: \(error.localizedDescription)")
        }
    }
}

// MARK: - Session Sync Info

/// Information about a session's sync status.
public struct SessionSyncInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let documentCount: Int
    public let hasReport: Bool
    public let syncState: RecordSyncState
    public let sizeMB: Int
    public let isPinned: Bool
    public let lastAccessedAt: Date

    public init(
        id: String,
        title: String,
        documentCount: Int,
        hasReport: Bool,
        syncState: RecordSyncState,
        sizeMB: Int,
        isPinned: Bool,
        lastAccessedAt: Date
    ) {
        self.id = id
        self.title = title
        self.documentCount = documentCount
        self.hasReport = hasReport
        self.syncState = syncState
        self.sizeMB = sizeMB
        self.isPinned = isPinned
        self.lastAccessedAt = lastAccessedAt
    }
}
```

### Step 6: Create Tests

**File**: `Packages/BioMedLit/Tests/BioMedLitTests/SelectiveSyncTests.swift`

```swift
import XCTest
@testable import BioMedLit

final class SelectiveSyncTests: XCTestCase {

    // MARK: - Eviction Candidate Selection Tests

    func testEvictionCandidateLRU() async {
        let manager = SessionEvictionManager(
            storageMonitor: MockStorageMonitor(),
            delegate: MockEvictionDelegate()
        )

        let sessions = [
            makeSession(id: "1", lastAccessed: Date(timeIntervalSinceNow: -3600)), // oldest
            makeSession(id: "2", lastAccessed: Date(timeIntervalSinceNow: -1800)),
            makeSession(id: "3", lastAccessed: Date())  // newest
        ]

        let candidates = await manager.selectEvictionCandidates(
            from: sessions,
            strategy: .lru,
            minKeep: 1
        )

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.first?.id, "1") // Oldest accessed first
    }

    func testEvictionCandidateLargest() async {
        let manager = SessionEvictionManager(
            storageMonitor: MockStorageMonitor(),
            delegate: MockEvictionDelegate()
        )

        let sessions = [
            makeSession(id: "1", sizeMB: 100),
            makeSession(id: "2", sizeMB: 500), // largest
            makeSession(id: "3", sizeMB: 200)
        ]

        let candidates = await manager.selectEvictionCandidates(
            from: sessions,
            strategy: .largest,
            minKeep: 1
        )

        XCTAssertEqual(candidates.first?.id, "2") // Largest first
    }

    func testEvictionCandidateNoReport() async {
        let manager = SessionEvictionManager(
            storageMonitor: MockStorageMonitor(),
            delegate: MockEvictionDelegate()
        )

        let sessions = [
            makeSession(id: "1", hasReport: true),
            makeSession(id: "2", hasReport: false), // no report
            makeSession(id: "3", hasReport: true)
        ]

        let candidates = await manager.selectEvictionCandidates(
            from: sessions,
            strategy: .noReport,
            minKeep: 1
        )

        XCTAssertEqual(candidates.first?.id, "2") // No report first
    }

    func testEvictionRespectsMinKeep() async {
        let manager = SessionEvictionManager(
            storageMonitor: MockStorageMonitor(),
            delegate: MockEvictionDelegate()
        )

        let sessions = [
            makeSession(id: "1"),
            makeSession(id: "2"),
            makeSession(id: "3")
        ]

        let candidates = await manager.selectEvictionCandidates(
            from: sessions,
            strategy: .lru,
            minKeep: 3
        )

        XCTAssertTrue(candidates.isEmpty) // All kept
    }

    func testPinnedSessionNotEvicted() async {
        let manager = SessionEvictionManager(
            storageMonitor: MockStorageMonitor(),
            delegate: MockEvictionDelegate()
        )

        await manager.pinSession("session-1")

        XCTAssertTrue(await manager.isPinned("session-1"))
        XCTAssertFalse(await manager.isPinned("session-2"))
    }

    // MARK: - Sync Scope Tests

    func testSyncScopeWhitelist() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = try LocalFolderSyncStorage(rootURL: tempDir)
        let deviceConfig = DeviceConfig(
            deviceId: "test",
            name: "Test",
            platform: .ios,
            syncScope: SyncScope(
                mode: .selective,
                sessionFilter: SessionFilter(mode: .whitelist, ids: ["session-1"])
            )
        )

        let manager = SyncScopeManager(storage: storage, deviceConfig: deviceConfig)

        XCTAssertTrue(await manager.isInScope("session-1"))
        XCTAssertFalse(await manager.isInScope("session-2"))
    }

    func testLocalExclusion() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = try LocalFolderSyncStorage(rootURL: tempDir)
        let deviceConfig = DeviceConfig(
            deviceId: "test",
            name: "Test",
            platform: .ios
        )

        let manager = SyncScopeManager(storage: storage, deviceConfig: deviceConfig)

        // Initially in scope
        XCTAssertTrue(await manager.isInScope("session-1"))

        // Exclude
        await manager.excludeLocally("session-1", reason: .userDeletedLocal)

        // Now out of scope
        XCTAssertFalse(await manager.isInScope("session-1"))

        // Include again
        await manager.includeLocally("session-1")

        // Back in scope
        XCTAssertTrue(await manager.isInScope("session-1"))
    }

    // MARK: - Helpers

    private func makeSession(
        id: String,
        sizeMB: Int = 100,
        hasReport: Bool = true,
        lastAccessed: Date = Date()
    ) -> SessionStorageInfo {
        SessionStorageInfo(
            id: id,
            title: "Session \(id)",
            sizeMB: sizeMB,
            documentCount: 10,
            hasReport: hasReport,
            lastAccessedAt: lastAccessed,
            createdAt: Date(timeIntervalSinceNow: -86400),
            syncState: .full
        )
    }
}

// MARK: - Mocks

final class MockStorageMonitor: StorageMonitor {
    init() {
        super.init(delegate: MockStorageDelegate())
    }
}

final class MockStorageDelegate: StorageMonitorDelegate {
    func calculateStorageInfo() async throws -> StorageInfo {
        StorageInfo(usedMB: 100)
    }

    func getSessionStorageInfo(sessionId: String) async throws -> SessionStorageInfo? {
        nil
    }
}

final class MockEvictionDelegate: SessionEvictionDelegate {
    func evictSessionContent(_ sessionId: String) async throws -> Int {
        100
    }

    func saveSessionStub(_ sessionId: String, stub: SessionStub) async throws {}
}
```

## Files to Create

| File | Description |
|------|-------------|
| `Sync/StorageMonitor.swift` | Monitors storage usage |
| `Sync/SessionEvictionManager.swift` | Manages session eviction |
| `Sync/OnDemandFetcher.swift` | Fetches content on-demand |
| `Sync/SyncScopeManager.swift` | Manages sync scope |
| `Sync/SelectiveSyncCoordinator.swift` | High-level selective sync API |
| `Tests/SelectiveSyncTests.swift` | Unit tests |

## Acceptance Criteria

1. **Eviction strategies work**: LRU, largest, oldest, noReport
2. **Pinning prevents eviction**: Pinned sessions not evicted
3. **Sync scope filtering**: Only in-scope sessions synced
4. **Local exclusions work**: Excluded sessions skipped
5. **On-demand fetch works**: Can fetch evicted content
6. **Auto-eviction respects limits**: Stays under storage limit
7. **All tests pass**: `swift test` succeeds

## Dependencies

- Phase 1-3 complete

## Next Phase

Phase 5 will implement platform-specific integration (iOS/macOS apps).
