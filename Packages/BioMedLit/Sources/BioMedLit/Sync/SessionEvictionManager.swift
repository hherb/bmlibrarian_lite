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

// MARK: - Session Eviction Manager

/// Manages eviction of session content to free storage.
///
/// When devices have limited storage, sessions can be evicted to free space.
/// Evicted sessions become "stubs" that retain metadata but have their content
/// removed. The content remains available in the cloud for on-demand fetching.
///
/// Supports multiple eviction strategies:
/// - LRU (Least Recently Used): Evict sessions that haven't been accessed recently
/// - Largest: Evict biggest sessions first for quick space recovery
/// - Oldest: Evict sessions by creation date
/// - No Report: Prioritize evicting sessions without generated reports
///
/// Thread Safety: This is an actor with isolated state.
///
/// Example:
/// ```swift
/// let manager = SessionEvictionManager(
///     storageMonitor: monitor,
///     delegate: myDelegate
/// )
///
/// // Pin important sessions
/// await manager.pinSession("important-session-id")
///
/// // Manual eviction
/// let freed = try await manager.evictSession("old-session-id")
///
/// // Auto-eviction when storage exceeded
/// let result = try await manager.autoEvict(maxMB: 500, strategy: .lru)
/// print("Evicted \(result.sessionsEvicted) sessions, freed \(result.mbFreed) MB")
/// ```
public actor SessionEvictionManager {
    // MARK: - Properties

    /// Storage monitor for checking usage.
    private let storageMonitor: StorageMonitor

    /// Delegate for eviction operations.
    private weak var delegate: SessionEvictionDelegate?

    /// Pinned session IDs (never evicted).
    private var pinnedSessions: Set<String> = []

    /// Logger for eviction operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "SessionEviction"
    )

    // MARK: - Initialization

    /// Creates an eviction manager.
    ///
    /// - Parameters:
    ///   - storageMonitor: Monitor for storage queries.
    ///   - delegate: Delegate for performing eviction. Held weakly.
    public init(
        storageMonitor: StorageMonitor,
        delegate: SessionEvictionDelegate
    ) {
        self.storageMonitor = storageMonitor
        self.delegate = delegate
    }

    // MARK: - Pinning

    /// Pins a session to prevent eviction.
    ///
    /// Pinned sessions are never evicted, even during auto-eviction.
    /// Use this for sessions the user is actively working on.
    ///
    /// - Parameter sessionId: Session identifier to pin.
    public func pinSession(_ sessionId: String) {
        pinnedSessions.insert(sessionId)
        logger.debug("Pinned session: \(sessionId)")
    }

    /// Unpins a session to allow eviction.
    ///
    /// - Parameter sessionId: Session identifier to unpin.
    public func unpinSession(_ sessionId: String) {
        pinnedSessions.remove(sessionId)
        logger.debug("Unpinned session: \(sessionId)")
    }

    /// Checks if a session is pinned.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if the session is pinned.
    public func isPinned(_ sessionId: String) -> Bool {
        pinnedSessions.contains(sessionId)
    }

    /// Gets all pinned session IDs.
    ///
    /// - Returns: Set of pinned session identifiers.
    public func getPinnedSessions() -> Set<String> {
        pinnedSessions
    }

    // MARK: - Manual Eviction

    /// Evicts a specific session's content.
    ///
    /// Converts the session to a stub, keeping metadata but removing
    /// documents, citations, and full-text content. The content remains
    /// in the cloud and can be fetched on-demand later.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Megabytes freed by the eviction.
    /// - Throws: `StorageError.evictionFailed` if session is pinned or eviction fails.
    public func evictSession(_ sessionId: String) async throws -> Int {
        // Check if pinned
        guard !pinnedSessions.contains(sessionId) else {
            logger.warning("Cannot evict pinned session: \(sessionId)")
            throw StorageError.evictionFailed("Session is pinned: \(sessionId)")
        }

        guard let delegate = delegate else {
            throw StorageError.delegateNotSet
        }

        logger.info("Evicting session: \(sessionId)")

        let freed = try await delegate.evictSessionContent(sessionId)

        // Invalidate storage cache since we freed space
        await storageMonitor.invalidateCache()

        logger.info("Evicted session \(sessionId), freed \(freed) MB")

        return freed
    }

    // MARK: - Auto-Eviction

    /// Auto-evicts sessions to meet storage target.
    ///
    /// Evicts sessions according to the specified strategy until storage
    /// usage drops below the target (maxMB * evictionTargetRatio).
    ///
    /// Respects:
    /// - Pinned sessions (never evicted)
    /// - Minimum session count (keeps at least minKeep sessions)
    /// - The specified eviction strategy for ordering
    ///
    /// - Parameters:
    ///   - maxMB: Maximum storage in megabytes.
    ///   - strategy: Strategy for selecting eviction order.
    ///   - minKeep: Minimum sessions to keep regardless of storage pressure.
    /// - Returns: Eviction result with count and freed space.
    /// - Throws: `StorageError` if eviction operations fail.
    public func autoEvict(
        maxMB: Int,
        strategy: EvictionStrategy = .lru,
        minKeep: Int = SyncConstants.defaultMinSessionsToKeep
    ) async throws -> EvictionResult {
        let info = try await storageMonitor.getStorageInfo(forceRefresh: true)

        // Check if eviction needed
        guard info.usedMB > maxMB else {
            logger.debug("Auto-eviction not needed: \(info.usedMB) MB <= \(maxMB) MB")
            return EvictionResult(sessionsEvicted: 0, mbFreed: 0)
        }

        // Calculate target (leave buffer to prevent immediate re-trigger)
        let targetMB = Int(Double(maxMB) * SyncConstants.evictionTargetRatio)
        let toFree = info.usedMB - targetMB

        logger.info("Auto-eviction starting: need to free \(toFree) MB")

        // Get candidates sorted by strategy
        let candidates = selectEvictionCandidates(
            from: info.largestSessions,
            strategy: strategy,
            minKeep: minKeep
        )

        var totalFreed = 0
        var sessionsEvicted = 0

        for candidate in candidates {
            // Stop if we've freed enough
            guard totalFreed < toFree else { break }

            // Skip pinned sessions
            guard !pinnedSessions.contains(candidate.id) else {
                logger.debug("Skipping pinned session: \(candidate.id)")
                continue
            }

            do {
                let freed = try await evictSession(candidate.id)
                totalFreed += freed
                sessionsEvicted += 1
            } catch {
                // Log but continue with other sessions
                logger.error("Failed to evict session \(candidate.id): \(error.localizedDescription)")
                continue
            }
        }

        logger.info("Auto-eviction complete: evicted \(sessionsEvicted) sessions, freed \(totalFreed) MB")

        return EvictionResult(
            sessionsEvicted: sessionsEvicted,
            mbFreed: totalFreed
        )
    }

    // MARK: - Candidate Selection

    /// Selects eviction candidates based on strategy.
    ///
    /// Convenience wrapper around the pure `selectEvictionCandidates` function.
    /// Allows calling the selection logic from actor context.
    ///
    /// - Parameters:
    ///   - sessions: Available sessions to consider.
    ///   - strategy: Eviction strategy determining sort order.
    ///   - minKeep: Minimum sessions to keep (protects most recent).
    /// - Returns: Sorted candidates where first item should be evicted first.
    public func selectEvictionCandidates(
        from sessions: [SessionStorageInfo],
        strategy: EvictionStrategy,
        minKeep: Int
    ) -> [SessionStorageInfo] {
        BioMedLit.selectEvictionCandidates(
            from: sessions,
            strategy: strategy,
            minKeep: minKeep
        )
    }
}

// MARK: - Pure Functions

/// Selects eviction candidates based on strategy.
///
/// This is a pure function that deterministically sorts sessions
/// for eviction based on the specified strategy. Sessions that are
/// already stubs or evicted are filtered out.
///
/// The function is side-effect free and can be used for:
/// - Testing eviction logic in isolation
/// - Previewing what would be evicted
/// - Reusing the logic in different contexts
///
/// - Parameters:
///   - sessions: Available sessions to consider.
///   - strategy: Eviction strategy determining sort order.
///   - minKeep: Minimum sessions to keep (protects most recent).
/// - Returns: Sorted candidates where first item should be evicted first.
public func selectEvictionCandidates(
    from sessions: [SessionStorageInfo],
    strategy: EvictionStrategy,
    minKeep: Int
) -> [SessionStorageInfo] {
    // Filter to only full sessions (stubs/evicted already have no content)
    var candidates = sessions.filter { session in
        session.syncState == .full
    }

    // Sort by strategy
    switch strategy {
    case .lru:
        // Least recently accessed first (oldest access = evict first)
        candidates.sort { $0.lastAccessedAt < $1.lastAccessedAt }

    case .largest:
        // Largest sessions first (most space recovery)
        candidates.sort { $0.sizeMB > $1.sizeMB }

    case .oldest:
        // Oldest by creation date
        candidates.sort { $0.createdAt < $1.createdAt }

    case .noReport:
        // Sessions without reports first, then by last accessed
        candidates.sort { session1, session2 in
            // First sort by hasReport (false before true)
            if session1.hasReport != session2.hasReport {
                return !session1.hasReport
            }
            // Then by last accessed (older first)
            return session1.lastAccessedAt < session2.lastAccessedAt
        }
    }

    // Protect the most recent sessions (keep at least minKeep)
    if candidates.count > minKeep {
        // Remove the last minKeep items (most valuable by sort order)
        return Array(candidates.dropLast(minKeep))
    }

    // Not enough candidates to meet minKeep - don't evict any
    return []
}

// MARK: - Session Eviction Delegate

/// Delegate protocol for session eviction operations.
///
/// The delegate is responsible for actually removing content from
/// the database and creating stubs. Implementations should:
/// - Remove documents, citations, and full-text from the session
/// - Create a stub with session metadata for later fetching
/// - Return accurate freed space calculations
public protocol SessionEvictionDelegate: AnyObject, Sendable {
    /// Evicts content for a session.
    ///
    /// Should remove all content (documents, citations, full-text) but
    /// preserve the session metadata so it can be fetched later.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Megabytes freed by the eviction.
    /// - Throws: `StorageError` if eviction fails.
    func evictSessionContent(_ sessionId: String) async throws -> Int

    /// Creates a stub for a session.
    ///
    /// Called during eviction to save minimal metadata about the session
    /// for display and later fetching.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - stub: Stub data to save.
    /// - Throws: If stub creation fails.
    func saveSessionStub(_ sessionId: String, stub: SessionStub) async throws
}

// MARK: - Eviction Result

/// Result of an eviction operation.
///
/// Returned by auto-eviction to report what was accomplished.
public struct EvictionResult: Sendable, Equatable {
    /// Number of sessions evicted.
    public let sessionsEvicted: Int

    /// Total megabytes freed.
    public let mbFreed: Int

    /// Creates an eviction result.
    ///
    /// - Parameters:
    ///   - sessionsEvicted: Number of sessions evicted.
    ///   - mbFreed: Total megabytes freed.
    public init(sessionsEvicted: Int, mbFreed: Int) {
        self.sessionsEvicted = sessionsEvicted
        self.mbFreed = mbFreed
    }
}

// MARK: - Session Stub

/// Minimal metadata for an evicted session.
///
/// When a session is evicted, this stub preserves essential information
/// for display and allows the session to be fetched on-demand later.
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
    ///
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - claim: Research claim or question.
    ///   - createdAt: Original creation date.
    ///   - documentCount: Number of documents before eviction.
    ///   - citationCount: Number of citations before eviction.
    ///   - hasReport: Whether a report was generated.
    ///   - contentSizeBytes: Original content size.
    ///   - evictedAt: When eviction occurred. Defaults to now.
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
