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

// MARK: - Storage Monitor

/// Monitors local storage usage for sync operations.
///
/// The storage monitor tracks how much storage is being used for synced
/// content and provides recommendations for eviction when limits are exceeded.
/// Storage information is cached to avoid expensive recalculation on every query.
///
/// Thread Safety: This is an actor with isolated state.
///
/// Example:
/// ```swift
/// let monitor = StorageMonitor(delegate: myDelegate)
///
/// // Check storage usage
/// let info = try await monitor.getStorageInfo()
/// print("Using \(info.usedMB) MB")
///
/// // Check if eviction needed
/// if try await monitor.isStorageExceeded(maxMB: 500) {
///     let toFree = try await monitor.getRecommendedEvictionMB(maxMB: 500)
///     print("Need to free \(toFree) MB")
/// }
/// ```
public actor StorageMonitor {
    // MARK: - Properties

    /// Delegate for storage queries.
    private weak var delegate: StorageMonitorDelegate?

    /// Cached storage info.
    private var cachedInfo: StorageInfo?

    /// When cache was last updated.
    private var cacheTime: Date?

    /// Cache duration from constants.
    private let cacheDuration: TimeInterval = SyncConstants.storageCacheDurationSeconds

    // MARK: - Initialization

    /// Creates a storage monitor.
    ///
    /// - Parameter delegate: Delegate for storage queries. The delegate is held
    ///   weakly to prevent retain cycles.
    public init(delegate: StorageMonitorDelegate) {
        self.delegate = delegate
    }

    // MARK: - Storage Queries

    /// Gets current storage info.
    ///
    /// Returns cached info if valid, otherwise queries the delegate.
    /// Cache validity is determined by `SyncConstants.storageCacheDurationSeconds`.
    ///
    /// - Parameter forceRefresh: If true, bypasses the cache and queries fresh data.
    /// - Returns: Current storage information.
    /// - Throws: `StorageError.delegateNotSet` if delegate is nil.
    public func getStorageInfo(forceRefresh: Bool = false) async throws -> StorageInfo {
        // Return cached if valid and not forcing refresh
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
    /// - Returns: True if current usage exceeds the limit.
    /// - Throws: `StorageError.delegateNotSet` if delegate is nil.
    public func isStorageExceeded(maxMB: Int) async throws -> Bool {
        let info = try await getStorageInfo()
        return info.usedMB > maxMB
    }

    /// Gets recommended eviction amount.
    ///
    /// Calculates how many megabytes need to be evicted to bring storage
    /// below the target ratio of the maximum limit. Uses the target ratio
    /// from `SyncConstants.evictionTargetRatio` to prevent immediate
    /// re-triggering of eviction.
    ///
    /// - Parameters:
    ///   - maxMB: Maximum storage in megabytes.
    ///   - targetRatio: Target ratio after eviction (0.0-1.0). Defaults to constant.
    /// - Returns: Megabytes to evict, or 0 if not needed.
    /// - Throws: `StorageError.delegateNotSet` if delegate is nil.
    public func getRecommendedEvictionMB(
        maxMB: Int,
        targetRatio: Double = SyncConstants.evictionTargetRatio
    ) async throws -> Int {
        let info = try await getStorageInfo()

        // No eviction needed if under limit
        if info.usedMB <= maxMB {
            return 0
        }

        // Calculate target (e.g., 90% of max to leave buffer)
        let targetMB = Int(Double(maxMB) * targetRatio)
        return max(0, info.usedMB - targetMB)
    }

    /// Invalidates the cache.
    ///
    /// Call this after storage-modifying operations like eviction
    /// to ensure fresh data on next query.
    public func invalidateCache() {
        cachedInfo = nil
        cacheTime = nil
    }
}

// MARK: - Storage Info

/// Information about storage usage.
///
/// Provides a snapshot of current storage usage including breakdowns
/// by entity type and session. Used for storage management decisions.
public struct StorageInfo: Sendable, Equatable {
    /// Total used storage in megabytes.
    public let usedMB: Int

    /// Storage used by each entity type (sessions, documents, etc.).
    public let byEntity: [SyncEntityType: Int]

    /// Number of sessions with full content.
    public let fullSessionCount: Int

    /// Number of sessions that are stubs (metadata only).
    public let stubSessionCount: Int

    /// Largest sessions sorted by size (for eviction candidates).
    public let largestSessions: [SessionStorageInfo]

    /// Creates storage info.
    ///
    /// - Parameters:
    ///   - usedMB: Total storage used in megabytes.
    ///   - byEntity: Storage breakdown by entity type.
    ///   - fullSessionCount: Number of sessions with full content.
    ///   - stubSessionCount: Number of stub sessions.
    ///   - largestSessions: Largest sessions for eviction consideration.
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

// MARK: - Session Storage Info

/// Storage info for a single session.
///
/// Contains metadata about a session needed for eviction decisions,
/// including size, access patterns, and content information.
public struct SessionStorageInfo: Sendable, Equatable, Identifiable {
    /// Unique session identifier.
    public let id: String

    /// Session title or research claim.
    public let title: String

    /// Storage size in megabytes.
    public let sizeMB: Int

    /// Number of documents in the session.
    public let documentCount: Int

    /// Whether a report has been generated.
    public let hasReport: Bool

    /// When the session was last accessed.
    public let lastAccessedAt: Date

    /// When the session was created.
    public let createdAt: Date

    /// Current sync state (full, stub, evicted, etc.).
    public let syncState: RecordSyncState

    /// Creates session storage info.
    ///
    /// - Parameters:
    ///   - id: Unique session identifier.
    ///   - title: Session title or claim.
    ///   - sizeMB: Storage size in megabytes.
    ///   - documentCount: Number of documents.
    ///   - hasReport: Whether report exists.
    ///   - lastAccessedAt: Last access timestamp.
    ///   - createdAt: Creation timestamp.
    ///   - syncState: Current sync state.
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
///
/// The delegate is responsible for calculating actual storage usage
/// from the underlying database or file system.
///
/// Implementers should:
/// - Calculate storage for all synced entities
/// - Provide session-level breakdown for eviction decisions
/// - Return accurate size estimates
public protocol StorageMonitorDelegate: AnyObject, Sendable {
    /// Calculates current storage info.
    ///
    /// Should aggregate storage across all synced entities and provide
    /// session-level details for eviction planning.
    ///
    /// - Returns: Complete storage information.
    /// - Throws: If storage calculation fails.
    func calculateStorageInfo() async throws -> StorageInfo

    /// Gets storage info for a specific session.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Session storage info, or nil if session not found.
    /// - Throws: If query fails.
    func getSessionStorageInfo(sessionId: String) async throws -> SessionStorageInfo?
}

// MARK: - Storage Errors

/// Errors from storage operations.
///
/// These errors cover failure modes specific to storage monitoring
/// and eviction operations.
public enum StorageError: Error, LocalizedError, Sendable {
    /// Storage delegate not set (likely deallocated).
    case delegateNotSet

    /// Session not found for eviction or fetch.
    case sessionNotFound(String)

    /// Eviction operation failed.
    case evictionFailed(String)

    /// Fetch operation failed.
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
