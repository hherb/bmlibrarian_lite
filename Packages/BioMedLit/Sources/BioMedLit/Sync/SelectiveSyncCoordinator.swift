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

import Combine
import Foundation
import os.log

// MARK: - Selective Sync Coordinator

/// Coordinates selective sync operations.
///
/// Provides a unified, high-level API for managing sync scope, storage limits,
/// session eviction, and on-demand fetching. This is the primary interface
/// for UI code to interact with selective sync features.
///
/// Thread Safety: Uses `@MainActor` for UI binding compatibility.
/// Internal components are actors for safe concurrent access.
///
/// Example:
/// ```swift
/// let coordinator = SelectiveSyncCoordinator()
/// await coordinator.initialize(
///     scopeManager: scopeManager,
///     evictionManager: evictionManager,
///     fetcher: fetcher,
///     storageMonitor: monitor
/// )
///
/// // Observe state changes
/// coordinator.$storageInfo
///     .sink { info in
///         updateStorageUI(info)
///     }
///
/// // Change sync mode
/// await coordinator.setSyncMode(.selective)
///
/// // Add session to sync
/// await coordinator.addSession("session-id")
///
/// // Fetch evicted content
/// await coordinator.fetchSession("evicted-session-id")
/// ```
@MainActor
public final class SelectiveSyncCoordinator: ObservableObject {
    // MARK: - Published State

    /// Current storage info (nil until first refresh).
    @Published public private(set) var storageInfo: StorageInfo?

    /// Sessions available for syncing (from all devices).
    @Published public private(set) var availableSessions: [SessionSyncInfo] = []

    /// Sessions present on this device.
    @Published public private(set) var localSessions: [SessionSyncInfo] = []

    /// Whether a fetch operation is in progress.
    @Published public private(set) var isFetching: Bool = false

    /// Current sync mode.
    @Published public private(set) var syncMode: SyncMode = .full

    /// Storage limit in megabytes.
    @Published public private(set) var storageLimit: Int = SyncConstants.defaultMaxStorageMB

    /// Whether auto-eviction is enabled.
    @Published public private(set) var autoEvictionEnabled: Bool = false

    /// Last error encountered (for UI display).
    @Published public private(set) var lastError: Error?

    // MARK: - Private Properties

    /// Scope manager for configuration.
    private var scopeManager: SyncScopeManager?

    /// Eviction manager for freeing storage.
    private var evictionManager: SessionEvictionManager?

    /// On-demand fetcher for retrieving content.
    private var fetcher: OnDemandFetcher?

    /// Storage monitor for usage tracking.
    private var storageMonitor: StorageMonitor?

    /// Logger for coordinator operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "SelectiveSync"
    )

    // MARK: - Initialization

    /// Creates a selective sync coordinator.
    ///
    /// Call `initialize(...)` to set up the required components.
    public init() {}

    /// Initializes with required components.
    ///
    /// Must be called before using other methods. Sets up all internal
    /// components and loads initial state.
    ///
    /// - Parameters:
    ///   - scopeManager: Sync scope manager for configuration.
    ///   - evictionManager: Session eviction manager.
    ///   - fetcher: On-demand fetcher for retrieving content.
    ///   - storageMonitor: Storage monitor for usage tracking.
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

        logger.info("Selective sync coordinator initialized")

        // Load initial state
        await refresh()
    }

    // MARK: - State Refresh

    /// Refreshes all state from underlying components.
    ///
    /// Updates storage info, sync mode, and other published properties.
    /// Call after operations that may have changed the state.
    public func refresh() async {
        guard let scopeManager = scopeManager,
              let storageMonitor = storageMonitor else {
            logger.warning("Cannot refresh: components not initialized")
            return
        }

        do {
            // Update storage info with fresh data
            storageInfo = try await storageMonitor.getStorageInfo(forceRefresh: true)

            // Update sync mode
            syncMode = await scopeManager.getSyncMode()

            // Update storage limit
            storageLimit = await scopeManager.getMaxLocalStorage()

            // Update auto-eviction status
            autoEvictionEnabled = await scopeManager.isAutoEvictionEnabled()

            // Clear any previous error on success
            lastError = nil

            logger.debug("State refreshed: \(self.storageInfo?.usedMB ?? 0) MB used")
        } catch {
            lastError = error
            logger.error("Failed to refresh: \(error.localizedDescription)")
        }
    }

    // MARK: - Sync Mode

    /// Changes the sync mode.
    ///
    /// - Parameter mode: New sync mode (full, selective, recent, minimal).
    public func setSyncMode(_ mode: SyncMode) async {
        guard let scopeManager = scopeManager else {
            logger.warning("Cannot set sync mode: not initialized")
            return
        }

        do {
            try await scopeManager.setSyncMode(mode)
            syncMode = mode
            lastError = nil
            logger.info("Sync mode changed to: \(mode.rawValue)")
        } catch {
            lastError = error
            logger.error("Failed to set sync mode: \(error.localizedDescription)")
        }
    }

    // MARK: - Storage Limits

    /// Sets the storage limit.
    ///
    /// If the new limit is lower than current usage, triggers auto-eviction
    /// if enabled.
    ///
    /// - Parameter limitMB: New storage limit in megabytes.
    public func setStorageLimit(_ limitMB: Int) async {
        guard let scopeManager = scopeManager else {
            logger.warning("Cannot set storage limit: not initialized")
            return
        }

        do {
            try await scopeManager.setMaxLocalStorage(limitMB)
            storageLimit = limitMB
            lastError = nil

            // Check if eviction needed with new limit
            await checkAndAutoEvict()

            logger.info("Storage limit set to: \(limitMB) MB")
        } catch {
            lastError = error
            logger.error("Failed to set storage limit: \(error.localizedDescription)")
        }
    }

    // MARK: - Session Management

    /// Adds a session to sync scope.
    ///
    /// For selective mode, adds to whitelist. If the session is a stub,
    /// automatically fetches its content.
    ///
    /// - Parameter sessionId: Session identifier to add.
    public func addSession(_ sessionId: String) async {
        guard let scopeManager = scopeManager else {
            logger.warning("Cannot add session: not initialized")
            return
        }

        do {
            try await scopeManager.addToWhitelist(sessionId)
            lastError = nil

            // Fetch content if not present locally
            await fetchSession(sessionId)

            logger.info("Added session to scope: \(sessionId)")
        } catch {
            lastError = error
            logger.error("Failed to add session: \(error.localizedDescription)")
        }
    }

    /// Removes a session from sync scope.
    ///
    /// Optionally deletes local content as well.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier to remove.
    ///   - deleteLocal: If true, also evicts local content.
    public func removeSession(_ sessionId: String, deleteLocal: Bool = false) async {
        guard let scopeManager = scopeManager else {
            logger.warning("Cannot remove session: not initialized")
            return
        }

        do {
            try await scopeManager.removeFromWhitelist(sessionId)
            lastError = nil

            if deleteLocal {
                await evictSession(sessionId)
            }

            logger.info("Removed session from scope: \(sessionId)")
        } catch {
            lastError = error
            logger.error("Failed to remove session: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetching

    /// Fetches a session's content on-demand.
    ///
    /// Downloads content from the cloud for an evicted or stub session.
    /// Updates `isFetching` during the operation.
    ///
    /// - Parameter sessionId: Session identifier to fetch.
    public func fetchSession(_ sessionId: String) async {
        guard let fetcher = fetcher else {
            logger.warning("Cannot fetch: not initialized")
            return
        }

        isFetching = true
        defer { isFetching = false }

        do {
            let result = try await fetcher.fetchSession(sessionId)
            lastError = nil
            logger.info("Fetch result for \(sessionId): \(String(describing: result.status))")

            // Refresh to update UI
            await refresh()
        } catch {
            lastError = error
            logger.error("Failed to fetch session: \(error.localizedDescription)")
        }
    }

    /// Checks if a fetch is in progress for a session.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if fetch is in progress.
    public func isFetchingSession(_ sessionId: String) async -> Bool {
        guard let fetcher = fetcher else { return false }
        return await fetcher.isFetching(sessionId)
    }

    // MARK: - Eviction

    /// Evicts a session's content to free storage.
    ///
    /// Converts the session to a stub. Content remains in the cloud
    /// for later fetching.
    ///
    /// - Parameter sessionId: Session identifier to evict.
    public func evictSession(_ sessionId: String) async {
        guard let evictionManager = evictionManager else {
            logger.warning("Cannot evict: not initialized")
            return
        }

        do {
            let freed = try await evictionManager.evictSession(sessionId)
            lastError = nil
            logger.info("Evicted session \(sessionId), freed \(freed) MB")

            // Refresh to update UI
            await refresh()
        } catch {
            lastError = error
            logger.error("Failed to evict session: \(error.localizedDescription)")
        }
    }

    // MARK: - Pinning

    /// Pins a session to prevent eviction.
    ///
    /// Pinned sessions are never auto-evicted, even under storage pressure.
    ///
    /// - Parameter sessionId: Session identifier to pin.
    public func pinSession(_ sessionId: String) async {
        guard let evictionManager = evictionManager else {
            logger.warning("Cannot pin: not initialized")
            return
        }
        await evictionManager.pinSession(sessionId)
        logger.info("Pinned session: \(sessionId)")
    }

    /// Unpins a session to allow eviction.
    ///
    /// - Parameter sessionId: Session identifier to unpin.
    public func unpinSession(_ sessionId: String) async {
        guard let evictionManager = evictionManager else {
            logger.warning("Cannot unpin: not initialized")
            return
        }
        await evictionManager.unpinSession(sessionId)
        logger.info("Unpinned session: \(sessionId)")
    }

    /// Checks if a session is pinned.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if session is pinned.
    public func isSessionPinned(_ sessionId: String) async -> Bool {
        guard let evictionManager = evictionManager else { return false }
        return await evictionManager.isPinned(sessionId)
    }

    // MARK: - Auto-Eviction

    /// Triggers auto-eviction if needed.
    ///
    /// Called automatically when storage limit changes. Can also be
    /// called manually to force a check.
    public func checkAndAutoEvict() async {
        guard let evictionManager = evictionManager,
              let scopeManager = scopeManager else {
            return
        }

        let config = await scopeManager.getAutoEviction()
        guard config?.enabled == true else {
            logger.debug("Auto-eviction disabled, skipping check")
            return
        }

        do {
            let result = try await evictionManager.autoEvict(
                maxMB: storageLimit,
                strategy: config?.strategy ?? .lru,
                minKeep: config?.keepMinimumSessions ?? SyncConstants.defaultMinSessionsToKeep
            )

            if result.sessionsEvicted > 0 {
                lastError = nil
                logger.info("Auto-evicted \(result.sessionsEvicted) sessions, freed \(result.mbFreed) MB")
                await refresh()
            }
        } catch {
            lastError = error
            logger.error("Auto-eviction failed: \(error.localizedDescription)")
        }
    }

    /// Configures auto-eviction.
    ///
    /// - Parameter config: Auto-eviction configuration, or nil to disable.
    public func setAutoEviction(_ config: AutoEvictionConfig?) async {
        guard let scopeManager = scopeManager else {
            logger.warning("Cannot configure auto-eviction: not initialized")
            return
        }

        do {
            try await scopeManager.setAutoEviction(config)
            autoEvictionEnabled = config?.enabled ?? false
            lastError = nil
            logger.info("Auto-eviction \(config?.enabled ?? false ? "enabled" : "disabled")")
        } catch {
            lastError = error
            logger.error("Failed to configure auto-eviction: \(error.localizedDescription)")
        }
    }

    // MARK: - Local-Only Deletion

    /// Deletes a session locally only (keeps in cloud).
    ///
    /// The session is excluded from future syncs and its content is evicted.
    /// Other devices are unaffected.
    ///
    /// - Parameter sessionId: Session identifier to delete locally.
    public func deleteLocalOnly(_ sessionId: String) async {
        guard let scopeManager = scopeManager,
              let evictionManager = evictionManager else {
            logger.warning("Cannot delete locally: not initialized")
            return
        }

        do {
            // Exclude from future syncs
            await scopeManager.excludeLocally(sessionId, reason: .userDeletedLocal)

            // Evict content
            _ = try await evictionManager.evictSession(sessionId)

            lastError = nil
            logger.info("Deleted session locally: \(sessionId)")
            await refresh()
        } catch {
            lastError = error
            logger.error("Failed to delete locally: \(error.localizedDescription)")
        }
    }

    // MARK: - Exclusion Management

    /// Excludes a session from sync on this device.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier to exclude.
    ///   - reason: Reason for exclusion.
    public func excludeSession(_ sessionId: String, reason: ExclusionReason) async {
        guard let scopeManager = scopeManager else {
            logger.warning("Cannot exclude: not initialized")
            return
        }
        await scopeManager.excludeLocally(sessionId, reason: reason)
        logger.info("Excluded session: \(sessionId)")
    }

    /// Includes a previously excluded session.
    ///
    /// - Parameter sessionId: Session identifier to include.
    public func includeSession(_ sessionId: String) async {
        guard let scopeManager = scopeManager else {
            logger.warning("Cannot include: not initialized")
            return
        }
        await scopeManager.includeLocally(sessionId)
        logger.info("Included session: \(sessionId)")
    }

    /// Checks if a session is excluded locally.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if session is excluded.
    public func isSessionExcluded(_ sessionId: String) async -> Bool {
        guard let scopeManager = scopeManager else { return false }
        return await scopeManager.isExcluded(sessionId)
    }
}

// MARK: - Session Sync Info

/// Information about a session's sync status.
///
/// Used for displaying session lists in the UI with sync-relevant metadata.
public struct SessionSyncInfo: Identifiable, Sendable, Equatable {
    /// Unique session identifier.
    public let id: String

    /// Session title or research claim.
    public let title: String

    /// Number of documents in the session.
    public let documentCount: Int

    /// Whether a report has been generated.
    public let hasReport: Bool

    /// Current sync state (full, stub, evicted, etc.).
    public let syncState: RecordSyncState

    /// Storage size in megabytes.
    public let sizeMB: Int

    /// Whether the session is pinned (protected from eviction).
    public let isPinned: Bool

    /// When the session was last accessed.
    public let lastAccessedAt: Date

    /// Creates session sync info.
    ///
    /// - Parameters:
    ///   - id: Unique session identifier.
    ///   - title: Session title or claim.
    ///   - documentCount: Number of documents.
    ///   - hasReport: Whether report exists.
    ///   - syncState: Current sync state.
    ///   - sizeMB: Storage size in megabytes.
    ///   - isPinned: Whether session is pinned.
    ///   - lastAccessedAt: Last access timestamp.
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
