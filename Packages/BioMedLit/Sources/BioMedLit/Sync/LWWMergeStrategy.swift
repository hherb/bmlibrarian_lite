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

// MARK: - LWW Merge Strategy

/// Last-Write-Wins merge strategy for sync conflicts.
///
/// When the same entity is modified on multiple devices, the change with the
/// latest timestamp wins. This is appropriate for single-user multi-device
/// scenarios where concurrent edits are rare and the "last edit" semantics
/// match user expectations.
///
/// All methods are pure functions with no side effects, making them easy
/// to test and reason about.
///
/// ## Determinism
///
/// To ensure all devices resolve conflicts identically, when timestamps are
/// equal, the device ID is used as a deterministic tiebreaker (lexicographic
/// comparison).
///
/// ## Example Usage
///
/// ```swift
/// let shouldApply = LWWMergeStrategy.shouldApplyRemote(
///     remote: (timestamp: 1705772400000, deviceId: "device-b"),
///     local: (timestamp: 1705772399000, deviceId: "device-a")
/// )
/// // shouldApply == true (remote is later)
/// ```
public struct LWWMergeStrategy: Sendable {

    // MARK: - Change Resolution

    /// Compares two change log entries and returns the winner.
    ///
    /// The winning change is determined by:
    /// 1. Later timestamp wins
    /// 2. If timestamps are equal, higher device ID wins (lexicographic)
    ///
    /// This function is deterministic: given the same inputs, all devices
    /// will compute the same winner.
    ///
    /// - Parameters:
    ///   - local: The local change entry.
    ///   - remote: The remote change entry.
    /// - Returns: The winning change entry (either local or remote).
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

        // Timestamps equal - use device ID as deterministic tiebreaker
        // Higher device ID wins to ensure all devices agree
        if remote.deviceId > local.deviceId {
            return remote
        }
        return local
    }

    // MARK: - Remote Application Decision

    /// Determines if a remote change should be applied over local state.
    ///
    /// Use this when you have a remote change and want to know if it should
    /// replace the local version of the same entity.
    ///
    /// - Parameters:
    ///   - remote: The remote change's timestamp and device ID.
    ///   - local: The local version's timestamp and device ID, or nil if
    ///           the entity doesn't exist locally.
    /// - Returns: True if the remote change should be applied.
    public static func shouldApplyRemote(
        remote: (timestamp: Int64, deviceId: String),
        local: (timestamp: Int64, deviceId: String)?
    ) -> Bool {
        // No local version - always apply remote
        guard let local = local else {
            return true
        }

        // Compare timestamps
        if remote.timestamp > local.timestamp {
            return true
        } else if remote.timestamp == local.timestamp {
            // Tiebreaker: higher device ID wins
            return remote.deviceId > local.deviceId
        }
        return false
    }

    /// Determines if a local change should be sent when a remote version exists.
    ///
    /// This is the inverse of `shouldApplyRemote`: returns true if the local
    /// change would win over the remote version.
    ///
    /// - Parameters:
    ///   - local: The local change's timestamp and device ID.
    ///   - remote: The remote version's timestamp and device ID.
    /// - Returns: True if the local change should be sent/kept.
    public static func shouldKeepLocal(
        local: (timestamp: Int64, deviceId: String),
        remote: (timestamp: Int64, deviceId: String)
    ) -> Bool {
        !shouldApplyRemote(remote: remote, local: local)
    }

    // MARK: - Per-Field Merging

    /// Merges entity data field by field using LWW semantics.
    ///
    /// Each field is tracked separately with its own timestamp. This allows
    /// partial merges where different fields were updated on different
    /// devices concurrently.
    ///
    /// For example, if device A updates "title" and device B updates "notes"
    /// at the same time, both changes can be preserved.
    ///
    /// - Parameters:
    ///   - localTimestamps: Map of field name to last-modified timestamp (local).
    ///   - remoteTimestamps: Map of field name to last-modified timestamp (remote).
    ///   - localData: Local field values.
    ///   - remoteData: Remote field values.
    /// - Returns: Tuple of merged timestamps and merged data.
    public static func mergeFields(
        localTimestamps: [String: Int64],
        remoteTimestamps: [String: Int64],
        localData: [String: Any],
        remoteData: [String: Any]
    ) -> (timestamps: [String: Int64], data: [String: Any]) {
        var resultTimestamps: [String: Int64] = [:]
        var resultData: [String: Any] = [:]

        // Collect all field names from both sides
        let allFields = Set(localTimestamps.keys).union(remoteTimestamps.keys)

        for field in allFields {
            let localTs = localTimestamps[field] ?? 0
            let remoteTs = remoteTimestamps[field] ?? 0

            if remoteTs > localTs {
                // Remote wins for this field
                resultTimestamps[field] = remoteTs
                if let value = remoteData[field] {
                    resultData[field] = value
                }
            } else {
                // Local wins (or equal, prefer local)
                resultTimestamps[field] = localTs
                if let value = localData[field] {
                    resultData[field] = value
                }
            }
        }

        return (resultTimestamps, resultData)
    }

    // MARK: - Delete Handling

    /// Determines the outcome when one side has a delete and the other has data.
    ///
    /// Delete operations are treated as regular updates with LWW semantics:
    /// - If delete timestamp > data timestamp: entity is deleted
    /// - If data timestamp > delete timestamp: data is preserved
    ///
    /// - Parameters:
    ///   - deleteTimestamp: When the delete operation occurred.
    ///   - dataTimestamp: When the data was last modified.
    /// - Returns: True if the delete wins (entity should be deleted).
    public static func deleteWins(
        deleteTimestamp: Int64,
        dataTimestamp: Int64
    ) -> Bool {
        deleteTimestamp >= dataTimestamp
    }
}

// MARK: - Merge Result

/// Result of merging local and remote changes for an entity.
///
/// This enum captures all possible outcomes of a merge operation,
/// allowing the caller to handle each case appropriately.
public enum MergeResult<T: Sendable>: Sendable {
    /// Local version wins, no changes needed.
    ///
    /// The local data is already the winning version and should be kept.
    case keepLocal

    /// Remote version wins, apply remote data.
    ///
    /// The associated value contains the remote data to apply.
    case applyRemote(T)

    /// Merged result combining fields from both sides.
    ///
    /// The associated value contains the merged data. This occurs when
    /// using per-field merging and different fields were updated on
    /// different devices.
    case merged(T)

    /// Conflict that requires user resolution.
    ///
    /// This is reserved for future use when we want to show conflicts
    /// to users. Currently, LWW automatically resolves all conflicts.
    case conflict(local: T, remote: T)

    /// The entity should be deleted.
    ///
    /// A delete operation won over any data updates.
    case delete
}

// MARK: - Conflict Info

/// Information about a detected conflict for logging and debugging.
///
/// Even though LWW resolves conflicts automatically, it can be useful
/// to log when conflicts occur for debugging or user notification.
public struct ConflictInfo: Sendable, Equatable {
    /// Entity type that had the conflict.
    public let entityType: SyncEntityType

    /// Entity identifier.
    public let entityId: String

    /// Local change timestamp.
    public let localTimestamp: Int64

    /// Local device ID.
    public let localDeviceId: String

    /// Remote change timestamp.
    public let remoteTimestamp: Int64

    /// Remote device ID.
    public let remoteDeviceId: String

    /// Which side won the conflict.
    public let winner: ConflictWinner

    /// Creates conflict information.
    ///
    /// - Parameters:
    ///   - entityType: Type of the conflicting entity.
    ///   - entityId: Identifier of the conflicting entity.
    ///   - localTimestamp: When the local change occurred.
    ///   - localDeviceId: Device that made the local change.
    ///   - remoteTimestamp: When the remote change occurred.
    ///   - remoteDeviceId: Device that made the remote change.
    ///   - winner: Which side won.
    public init(
        entityType: SyncEntityType,
        entityId: String,
        localTimestamp: Int64,
        localDeviceId: String,
        remoteTimestamp: Int64,
        remoteDeviceId: String,
        winner: ConflictWinner
    ) {
        self.entityType = entityType
        self.entityId = entityId
        self.localTimestamp = localTimestamp
        self.localDeviceId = localDeviceId
        self.remoteTimestamp = remoteTimestamp
        self.remoteDeviceId = remoteDeviceId
        self.winner = winner
    }
}

/// Indicates which side won a conflict.
public enum ConflictWinner: String, Sendable, Codable {
    /// Local change won.
    case local

    /// Remote change won.
    case remote
}
