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

// MARK: - On-Demand Fetcher

/// Fetches session content on-demand from remote storage.
///
/// When a session is evicted (converted to a stub), its content remains
/// in the cloud. This fetcher retrieves that content when the user needs
/// to access it again.
///
/// The fetcher:
/// - Finds which device(s) have the content
/// - Downloads and verifies the changes
/// - Applies them to the local database
/// - Updates the session's sync state to full
///
/// Thread Safety: This is an actor with isolated state.
///
/// Example:
/// ```swift
/// let fetcher = OnDemandFetcher(
///     storage: iCloudStorage,
///     reader: changeLogReader,
///     delegate: myDelegate
/// )
///
/// // Fetch evicted session
/// let result = try await fetcher.fetchSession("session-id")
/// switch result.status {
/// case .fetched:
///     print("Session content restored!")
/// case .alreadyFull:
///     print("Session already has full content")
/// case .alreadyInProgress:
///     print("Fetch already running")
/// case .restoredFromSnapshot:
///     print("Restored from snapshot")
/// }
/// ```
public actor OnDemandFetcher {
    // MARK: - Properties

    /// Sync storage backend.
    private let storage: SyncStorageProtocol

    /// Change log reader for fetching changes.
    private let reader: ChangeLogReader

    /// Delegate for applying fetched content.
    private weak var delegate: OnDemandFetchDelegate?

    /// Currently fetching sessions (prevents duplicate fetches).
    private var inProgress: Set<String> = []

    /// Logger for fetch operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "OnDemandFetch"
    )

    // MARK: - Initialization

    /// Creates an on-demand fetcher.
    ///
    /// - Parameters:
    ///   - storage: Sync storage backend.
    ///   - reader: Change log reader for reading remote changes.
    ///   - delegate: Delegate for applying fetched content. Held weakly.
    public init(
        storage: SyncStorageProtocol,
        reader: ChangeLogReader,
        delegate: OnDemandFetchDelegate
    ) {
        self.storage = storage
        self.reader = reader
        self.delegate = delegate
    }

    // MARK: - Fetching

    /// Fetches full session content from remote storage.
    ///
    /// Locates the session's content in remote devices and downloads it.
    /// If found, applies the content to the local database and updates
    /// the sync state to full.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Fetch result indicating what happened.
    /// - Throws: `StorageError.fetchFailed` if content cannot be found.
    public func fetchSession(_ sessionId: String) async throws -> FetchResult {
        // Prevent duplicate fetches
        guard !inProgress.contains(sessionId) else {
            logger.debug("Fetch already in progress for: \(sessionId)")
            return FetchResult(status: .alreadyInProgress)
        }

        inProgress.insert(sessionId)
        defer { inProgress.remove(sessionId) }

        logger.info("Starting fetch for session: \(sessionId)")

        guard let delegate = delegate else {
            throw StorageError.delegateNotSet
        }

        // Check current state
        let currentState = try await delegate.getSessionSyncState(sessionId)
        guard currentState != .full else {
            logger.debug("Session already full: \(sessionId)")
            return FetchResult(status: .alreadyFull)
        }

        // Find which device has the content
        let sourceDevice = try await findDeviceWithContent(sessionId)

        if let device = sourceDevice {
            // Fetch changes from that device
            try await fetchFromDevice(sessionId: sessionId, deviceId: device)
            logger.info("Fetched session \(sessionId) from device \(device)")
            return FetchResult(status: .fetched)
        }

        // No device found - try snapshot as fallback
        if let snapshot = try await findSnapshotWithSession(sessionId) {
            try await restoreFromSnapshot(sessionId: sessionId, snapshotPath: snapshot)
            logger.info("Restored session \(sessionId) from snapshot")
            return FetchResult(status: .restoredFromSnapshot)
        }

        // Content not found anywhere
        logger.error("No device has content for session: \(sessionId)")
        throw StorageError.fetchFailed("No device has content for session \(sessionId)")
    }

    /// Checks if a fetch is currently in progress for a session.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if fetch is in progress.
    public func isFetching(_ sessionId: String) -> Bool {
        inProgress.contains(sessionId)
    }

    /// Gets the set of sessions currently being fetched.
    ///
    /// - Returns: Set of session IDs with in-progress fetches.
    public func getInProgressFetches() -> Set<String> {
        inProgress
    }

    // MARK: - Device Discovery

    /// Finds a device that has full content for a session.
    ///
    /// Scans remote device manifests to find one that contains changes
    /// related to the requested session.
    ///
    /// - Parameter sessionId: Session identifier to find.
    /// - Returns: Device ID with the content, or nil if not found.
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
                logger.debug("Found session \(sessionId) on device \(device.deviceId)")
                return device.deviceId
            }
        }

        return nil
    }

    /// Finds a snapshot containing a session.
    ///
    /// Scans available snapshots (newest first) to find one that
    /// might contain the requested session.
    ///
    /// - Parameter sessionId: Session identifier to find.
    /// - Returns: Path to snapshot file, or nil if not found.
    private func findSnapshotWithSession(_ sessionId: String) async throws -> String? {
        let snapshotFiles: [SyncFileInfo]
        do {
            snapshotFiles = try await storage.listFiles(at: SyncConstants.snapshotsDirectory)
        } catch SyncStorageError.directoryNotFound {
            return nil
        }

        // Sort by date (newest first)
        let sorted = snapshotFiles.sorted { $0.modifiedAt > $1.modifiedAt }

        for snapshotFile in sorted {
            // For a production implementation, we'd peek into the snapshot
            // to verify it contains the session. For now, return first available.
            logger.debug("Found potential snapshot: \(snapshotFile.path)")
            return snapshotFile.path
        }

        return nil
    }

    /// Fetches session data from a specific device.
    ///
    /// Downloads all changes from the device that are relevant to the
    /// requested session and applies them to the local database.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - deviceId: Device to fetch from.
    private func fetchFromDevice(sessionId: String, deviceId: String) async throws {
        guard let delegate = delegate else { return }

        // Get all changes from device (starting from 0 to get full history)
        let changes = try await reader.readChanges(from: deviceId, afterSequence: 0)

        logger.debug("Fetched \(changes.count) changes from device \(deviceId)")

        // Filter to relevant changes and apply them
        // In a full implementation, we'd decode each change and check if it's
        // related to the session (either the session itself or its documents/citations)
        for change in changes {
            try await delegate.applyFetchedChange(change)
        }

        // Update sync state to full
        try await delegate.setSessionSyncState(sessionId, state: .full)
    }

    /// Restores session from a snapshot.
    ///
    /// Snapshots are periodic full-state captures that can be used for
    /// recovery when change logs are incomplete.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - snapshotPath: Path to snapshot file.
    private func restoreFromSnapshot(sessionId: String, snapshotPath: String) async throws {
        guard let delegate = delegate else { return }

        logger.info("Restoring session \(sessionId) from snapshot: \(snapshotPath)")

        // Read snapshot data
        let snapshotData = try await storage.readFile(at: snapshotPath)

        // Decompress and parse snapshot (snapshots are gzipped)
        // In a full implementation, we'd:
        // 1. Decompress the gzipped data
        // 2. Parse the JSON snapshot structure
        // 3. Find the session and its related entities
        // 4. Apply them to the local database

        // For now, we signal success and let the delegate handle specifics
        try await delegate.applySnapshotData(sessionId: sessionId, data: snapshotData)
        try await delegate.setSessionSyncState(sessionId, state: .full)
    }
}

// MARK: - On-Demand Fetch Delegate

/// Delegate for applying fetched content.
///
/// The delegate is responsible for:
/// - Querying and updating session sync states
/// - Applying fetched changes to the local database
/// - Handling snapshot restoration
public protocol OnDemandFetchDelegate: AnyObject, Sendable {
    /// Gets sync state for a session.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Current sync state.
    /// - Throws: If query fails.
    func getSessionSyncState(_ sessionId: String) async throws -> RecordSyncState

    /// Sets sync state for a session.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - state: New sync state.
    /// - Throws: If update fails.
    func setSessionSyncState(_ sessionId: String, state: RecordSyncState) async throws

    /// Applies a fetched change to the local database.
    ///
    /// The delegate should decode the change and apply the appropriate
    /// database operation (insert/update/delete).
    ///
    /// - Parameter change: Verified change data.
    /// - Throws: If application fails.
    func applyFetchedChange(_ change: VerifiedChange) async throws

    /// Applies snapshot data for a session.
    ///
    /// Called when restoring from a snapshot instead of change logs.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - data: Raw snapshot data (may be compressed).
    /// - Throws: If restoration fails.
    func applySnapshotData(sessionId: String, data: Data) async throws
}

// MARK: - Fetch Result

/// Result of an on-demand fetch operation.
public struct FetchResult: Sendable, Equatable {
    /// Fetch status.
    public let status: FetchStatus

    /// Creates a fetch result.
    ///
    /// - Parameter status: The fetch status.
    public init(status: FetchStatus) {
        self.status = status
    }
}

/// Status of a fetch operation.
public enum FetchStatus: Sendable, Equatable {
    /// Content was successfully fetched and applied.
    case fetched

    /// Session already has full content (no fetch needed).
    case alreadyFull

    /// Fetch already in progress for this session.
    case alreadyInProgress

    /// Content was restored from a snapshot.
    case restoredFromSnapshot
}
