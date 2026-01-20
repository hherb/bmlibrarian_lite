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

// MARK: - Workspace Configuration

/// Workspace-level configuration stored in workspace.json.
///
/// The workspace configuration defines the sync format and encryption
/// settings for all devices in the workspace. It's created when the
/// first device initializes the sync folder.
///
/// All devices in the workspace must be compatible with the schema version.
public struct WorkspaceConfig: Codable, Sendable, Equatable {
    /// Configuration format version.
    ///
    /// Allows for future changes to the workspace config format.
    public let version: Int

    /// Sync schema version for data files.
    ///
    /// All change files must use this schema version.
    public let schemaVersion: Int

    /// Minimum schema version required to read this workspace.
    ///
    /// Devices with older versions should prompt for an update.
    public let minCompatibleVersion: Int

    /// When the workspace was created.
    public let createdAt: Date

    /// Encryption mode for sync data.
    ///
    /// Currently supports `.none` or `.aes256gcm`.
    public let encryption: EncryptionMode

    /// Creates workspace configuration.
    ///
    /// - Parameters:
    ///   - version: Configuration format version. Defaults to 1.
    ///   - schemaVersion: Data schema version. Defaults to current.
    ///   - minCompatibleVersion: Minimum readable version. Defaults to current.
    ///   - createdAt: Creation timestamp. Defaults to now.
    ///   - encryption: Encryption mode. Defaults to none.
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

// MARK: - Encryption Mode

/// Encryption mode for sync data.
///
/// When encryption is enabled, all sync file contents (not filenames)
/// are encrypted before writing and decrypted after reading.
public enum EncryptionMode: String, Codable, Sendable {
    /// No encryption (default).
    case none

    /// AES-256-GCM encryption with per-user key.
    case aes256gcm = "aes-256-gcm"
}

// MARK: - Device Configuration

/// Device registration stored in devices/{device_id}.json.
///
/// Each device registers itself in the workspace with configuration
/// including sync scope and storage limits. Other devices can read
/// this to discover peers and understand their capabilities.
public struct DeviceConfig: Codable, Sendable, Equatable {
    /// Unique device identifier (UUID).
    ///
    /// Generated once and stored persistently on the device.
    public let deviceId: String

    /// Human-readable device name.
    ///
    /// Typically the device hostname or user-configured name.
    public let name: String

    /// Platform identifier.
    public let platform: SyncPlatform

    /// When device was registered in the workspace.
    public let createdAt: Date

    /// Last time device was seen syncing.
    ///
    /// Updated each time the device syncs successfully.
    public var lastSeen: Date

    /// Sync scope configuration.
    ///
    /// Defines what this device downloads and keeps locally.
    public var syncScope: SyncScope

    /// Creates device configuration.
    ///
    /// - Parameters:
    ///   - deviceId: Unique device identifier (UUID string).
    ///   - name: Human-readable device name.
    ///   - platform: Platform type (ios, macos, etc.).
    ///   - createdAt: Registration timestamp. Defaults to now.
    ///   - lastSeen: Last sync timestamp. Defaults to now.
    ///   - syncScope: Sync configuration. Defaults to full sync.
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
///
/// Different devices have different storage constraints. iOS devices
/// typically use selective or minimal mode, while macOS devices can
/// often sync everything.
public struct SyncScope: Codable, Sendable, Equatable {
    /// Sync mode (full, selective, recent, or minimal).
    public var mode: SyncMode

    /// Session filter (for selective and recent modes).
    public var sessionFilter: SessionFilter?

    /// Maximum local storage in megabytes.
    ///
    /// When exceeded, auto-eviction may occur.
    public var maxLocalStorageMB: Int

    /// Auto-eviction configuration.
    public var autoEviction: AutoEvictionConfig?

    /// Creates sync scope with defaults.
    ///
    /// - Parameters:
    ///   - mode: Sync mode. Defaults to full.
    ///   - sessionFilter: Optional session filter for selective/recent modes.
    ///   - maxLocalStorageMB: Storage limit. Defaults to 500MB.
    ///   - autoEviction: Optional auto-eviction configuration.
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

// MARK: - Session Filter

/// Filter for which sessions to sync.
///
/// Used with selective and recent sync modes to control which
/// sessions are downloaded to the device.
public struct SessionFilter: Codable, Sendable, Equatable {
    /// Filter mode (whitelist or recent).
    public let mode: SessionFilterMode

    /// Session IDs to sync (for whitelist mode).
    public var ids: [String]

    /// Days to keep (for recent mode).
    public var recentDays: Int?

    /// Creates session filter.
    ///
    /// - Parameters:
    ///   - mode: Filter mode (whitelist or recent).
    ///   - ids: Session IDs for whitelist mode.
    ///   - recentDays: Days to keep for recent mode.
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
    /// Only sync explicitly listed session IDs.
    case whitelist

    /// Only sync sessions created/modified in last N days.
    case recent
}

// MARK: - Auto-Eviction Configuration

/// Auto-eviction configuration.
///
/// When enabled, the device automatically removes local session data
/// to stay within storage limits. Evicted sessions remain in the cloud
/// and can be re-fetched on demand.
public struct AutoEvictionConfig: Codable, Sendable, Equatable {
    /// Whether auto-eviction is enabled.
    public var enabled: Bool

    /// Strategy for selecting sessions to evict.
    public var strategy: EvictionStrategy

    /// Minimum sessions to keep regardless of storage pressure.
    public var keepMinimumSessions: Int

    /// Session IDs that are never evicted.
    public var neverEvict: [String]

    /// Evict sessions older than this many days (optional).
    public var evictOlderThanDays: Int?

    /// Creates auto-eviction config.
    ///
    /// - Parameters:
    ///   - enabled: Whether auto-eviction is enabled. Defaults to false.
    ///   - strategy: Eviction strategy. Defaults to LRU.
    ///   - keepMinimumSessions: Minimum to keep. Defaults to 5.
    ///   - neverEvict: Session IDs to never evict.
    ///   - evictOlderThanDays: Optional age-based eviction threshold.
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

/// Strategy for auto-eviction when storage is full.
public enum EvictionStrategy: String, Codable, Sendable {
    /// Least recently used (accessed) sessions first.
    case lru

    /// Largest sessions first (quick space recovery).
    case largest

    /// Oldest by creation date.
    case oldest

    /// Sessions without generated reports first.
    case noReport
}

// MARK: - Device Manifest

/// Manifest of all change files for a device.
///
/// Each device maintains a manifest listing all its change files with
/// checksums. This enables efficient discovery of new changes without
/// scanning the entire changes directory.
public struct DeviceManifest: Codable, Sendable, Equatable {
    /// Device that owns this manifest.
    public let deviceId: String

    /// When manifest was last updated.
    public var lastUpdated: Date

    /// Highest sequence number in the manifest.
    public var headSequence: Int

    /// List of change files with metadata.
    public var files: [ManifestFileEntry]

    /// Combined checksum of all file checksums.
    ///
    /// Enables quick verification that the manifest matches the files.
    public var manifestChecksum: String

    /// Creates device manifest.
    ///
    /// - Parameters:
    ///   - deviceId: Device identifier.
    ///   - lastUpdated: Update timestamp. Defaults to now.
    ///   - headSequence: Highest sequence. Defaults to 0.
    ///   - files: File entries. Defaults to empty.
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
    ///
    /// Call this after adding or removing entries from `files`.
    public mutating func updateChecksum() {
        manifestChecksum = computeManifestChecksum(files)
    }

    /// Adds a file entry and updates the checksum.
    ///
    /// - Parameter entry: The file entry to add.
    public mutating func addFile(_ entry: ManifestFileEntry) {
        files.append(entry)
        headSequence = max(headSequence, entry.sequence)
        updateChecksum()
    }
}

// MARK: - Sync Watermarks

/// Tracks how far we've processed each device's changes.
///
/// Watermarks enable incremental sync by recording the last sequence
/// number processed from each remote device.
public struct SyncWatermarks: Codable, Sendable, Equatable {
    /// Map of device ID to last processed sequence.
    public var watermarks: [String: Int]

    /// Creates empty watermarks.
    public init() {
        self.watermarks = [:]
    }

    /// Creates watermarks with initial values.
    ///
    /// - Parameter watermarks: Initial watermark values.
    public init(watermarks: [String: Int]) {
        self.watermarks = watermarks
    }

    /// Gets watermark for a device.
    ///
    /// - Parameter deviceId: Device identifier.
    /// - Returns: Last processed sequence, or 0 if never processed.
    public func watermark(for deviceId: String) -> Int {
        watermarks[deviceId] ?? 0
    }

    /// Updates watermark for a device.
    ///
    /// - Parameters:
    ///   - sequence: New watermark value.
    ///   - deviceId: Device identifier.
    public mutating func setWatermark(_ sequence: Int, for deviceId: String) {
        watermarks[deviceId] = sequence
    }
}

// MARK: - Local Exclusions

/// Records of entities excluded from sync on this device.
///
/// When a user deletes a session locally or removes it from scope,
/// we record an exclusion so it isn't re-synced from the cloud.
public struct LocalExclusions: Codable, Sendable, Equatable {
    /// Excluded session IDs with reasons.
    public var sessions: [String: ExclusionReason]

    /// Creates empty exclusions.
    public init() {
        self.sessions = [:]
    }

    /// Checks if a session is excluded.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if the session is excluded locally.
    public func isExcluded(_ sessionId: String) -> Bool {
        sessions[sessionId] != nil
    }

    /// Gets the exclusion reason for a session.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Exclusion reason, or nil if not excluded.
    public func reason(for sessionId: String) -> ExclusionReason? {
        sessions[sessionId]
    }

    /// Adds an exclusion.
    ///
    /// - Parameters:
    ///   - sessionId: Session to exclude.
    ///   - reason: Reason for exclusion.
    public mutating func exclude(_ sessionId: String, reason: ExclusionReason) {
        sessions[sessionId] = reason
    }

    /// Removes an exclusion.
    ///
    /// - Parameter sessionId: Session to include again.
    public mutating func include(_ sessionId: String) {
        sessions.removeValue(forKey: sessionId)
    }
}

/// Reason for local exclusion.
public enum ExclusionReason: String, Codable, Sendable {
    /// User explicitly deleted the session locally.
    case userDeletedLocal

    /// User removed the session from sync scope.
    case userRemovedFromScope

    /// Session was auto-evicted due to storage pressure.
    case autoEvicted
}
