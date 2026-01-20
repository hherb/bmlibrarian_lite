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

// MARK: - Sync Constants

/// Constants for the sync module.
///
/// All magic numbers and strings are centralized here per golden rules.
/// This ensures consistency across the codebase and makes it easy to
/// adjust values without hunting through multiple files.
public enum SyncConstants {
    // MARK: - Integrity

    /// Current integrity envelope version.
    /// Increment when envelope format changes.
    public static let integrityVersion = 1

    /// Hash algorithm identifier used for checksums.
    /// Using SHA-256 for strong collision resistance.
    public static let integrityAlgorithm = "sha256"

    /// Current schema version for sync data.
    /// Increment when data format changes.
    public static let schemaVersion = 1

    /// Minimum schema version that can be read.
    /// Allows for backwards-compatible reads.
    public static let minCompatibleSchemaVersion = 1

    // MARK: - File Naming

    /// Number of digits for sequence numbers (zero-padded).
    /// Six digits allows for up to 999,999 changes per device.
    public static let sequenceDigits = 6

    /// File extension for sync files.
    public static let syncFileExtension = "json"

    // MARK: - Directory Names

    /// Root sync directory name in cloud storage.
    public static let syncRootDirectory = "BMLibrarian"

    /// Subdirectory for device registration files.
    public static let devicesDirectory = "devices"

    /// Subdirectory for change log files.
    public static let changesDirectory = "changes"

    /// Subdirectory for periodic snapshots.
    public static let snapshotsDirectory = "snapshots"

    /// Subdirectory for quarantined corrupt files.
    /// Prefixed with dot to be hidden on Unix systems.
    public static let quarantineDirectory = ".quarantine"

    // MARK: - File Names

    /// Workspace metadata file name.
    public static let workspaceFile = "workspace.json"

    /// Per-device manifest file name.
    public static let manifestFile = "manifest.json"

    /// Per-device cursor file name for tracking sync position.
    public static let cursorFile = "cursor.json"

    // MARK: - Verification

    /// Hours between full integrity verification passes.
    public static let fullVerifyIntervalHours = 24

    /// Number of recent changes to verify for chain integrity.
    /// Verifying the last N changes catches most corruption.
    public static let chainVerifyDepth = 100

    /// Maximum retry attempts for resending corrupt data.
    public static let maxResendAttempts = 3

    // MARK: - Storage Management

    /// Default maximum local storage in megabytes.
    public static let defaultMaxStorageMB = 500

    /// Target ratio when evicting (evict until at this fraction of max).
    /// For example, 0.9 means evict until storage is at 90% of max.
    public static let evictionTargetRatio = 0.9

    /// Minimum sessions to keep during auto-eviction.
    /// Prevents evicting everything on low-storage devices.
    public static let defaultMinSessionsToKeep = 5

    /// Default days before auto-eviction of old sessions.
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
    /// Prevents rapid-fire syncs when many changes happen quickly.
    public static let changeDebounceIntervalSeconds: TimeInterval = 1.0

    /// Minimum interval between background syncs in seconds.
    /// 15 minutes balances battery life and freshness.
    public static let backgroundSyncIntervalSeconds: TimeInterval = 15 * 60
}

// MARK: - Sync Mode

/// Sync mode determines what data a device downloads.
///
/// Different devices have different storage constraints and usage patterns.
/// These modes allow tailoring sync behavior appropriately.
public enum SyncMode: String, Codable, Sendable {
    /// Sync all data (default for desktops with ample storage).
    case full

    /// Only sync whitelisted sessions (user-selected).
    case selective

    /// Only sync sessions from last N days (auto-managed).
    case recent

    /// Only sync metadata, fetch content on-demand (minimal storage).
    case minimal
}

// MARK: - Record Sync State

/// Tracks the sync state of an individual record on a device.
///
/// This enables selective sync where some records may be stubs
/// that can be fetched on-demand.
public enum RecordSyncState: String, Codable, Sendable {
    /// Complete record with all content available locally.
    case full

    /// Metadata only, content available on-demand from cloud.
    case stub

    /// Was full, now stub (freed local storage via eviction).
    case evicted

    /// Exists only on this device, not yet synced to cloud.
    case localOnly

    /// Deleted locally, still exists in cloud.
    case deletedLocal
}

// MARK: - Sync Operation Type

/// Types of operations that can be recorded in the change log.
public enum SyncOperationType: String, Codable, Sendable {
    /// Insert or update an entity.
    case upsert

    /// Delete an entity.
    case delete
}

// MARK: - Sync Entity Type

/// Entity types that can be synced between devices.
///
/// Each entity type has its own handling during sync,
/// particularly for conflict resolution.
public enum SyncEntityType: String, Codable, Sendable {
    /// Fact-check session (research question and settings).
    case session

    /// Literature document (article metadata and content).
    case document

    /// Extracted citation from a document.
    case citation

    /// Generated report for a session.
    case report

    /// Usage tracking record.
    case usageRecord

    /// User settings and preferences.
    case settings
}

// MARK: - Sync Platform

/// Platform identifiers for device registration.
public enum SyncPlatform: String, Codable, Sendable {
    /// iOS mobile app.
    case ios

    /// macOS desktop app.
    case macos

    /// Android mobile app.
    case android

    /// Python desktop application.
    case desktop
}
