import Foundation

// MARK: - Sync Constants

/// Constants for the sync module.
///
/// All magic numbers and configuration values are centralized here per golden rules.
/// This ensures consistency across the codebase and makes it easy to adjust
/// settings without searching through multiple files.
///
/// ## Usage
/// ```swift
/// let version = SyncConstants.integrityVersion
/// let timeout = SyncConstants.iCloudDownloadTimeoutSeconds
/// ```
public enum SyncConstants {
    // MARK: - Integrity

    /// Current integrity envelope version.
    ///
    /// Increment this when the envelope format changes in a breaking way.
    /// Older versions can still be read if within the compatible range.
    public static let integrityVersion = 1

    /// Hash algorithm identifier used for checksums.
    ///
    /// We use SHA-256 which provides a good balance of security and performance.
    /// This string is stored in integrity envelopes for forward compatibility.
    public static let integrityAlgorithm = "sha256"

    /// Current schema version for sync data structures.
    ///
    /// Increment when adding new fields or changing data formats.
    /// Used to detect incompatible data from newer app versions.
    public static let schemaVersion = 1

    /// Minimum schema version that can be read by this version of the app.
    ///
    /// If we encounter data with a schema version below this, we cannot
    /// safely process it and should inform the user.
    public static let minCompatibleSchemaVersion = 1

    // MARK: - File Naming

    /// Number of digits for sequence numbers (zero-padded).
    ///
    /// Using 6 digits supports up to 999,999 changes per device,
    /// which is sufficient for typical usage patterns.
    /// Zero-padding ensures lexicographic sorting matches numeric sorting.
    public static let sequenceDigits = 6

    /// File extension for sync files.
    ///
    /// JSON is human-readable and widely supported across platforms.
    public static let syncFileExtension = "json"

    // MARK: - Directory Names

    /// Root sync directory name in iCloud Drive.
    ///
    /// All sync data is stored under this directory to keep it organized
    /// and separate from other app data.
    public static let syncRootDirectory = "BMLibrarian"

    /// Subdirectory for device registration files.
    ///
    /// Each device creates a file here when it joins the sync workspace.
    public static let devicesDirectory = "devices"

    /// Subdirectory for change log files.
    ///
    /// Each device has its own subdirectory containing its change files.
    public static let changesDirectory = "changes"

    /// Subdirectory for periodic full-state snapshots.
    ///
    /// Snapshots allow faster sync for new devices and recovery from corruption.
    public static let snapshotsDirectory = "snapshots"

    /// Subdirectory for quarantined corrupt files.
    ///
    /// Files that fail integrity checks are moved here for analysis
    /// rather than being deleted. The dot prefix hides it from casual browsing.
    public static let quarantineDirectory = ".quarantine"

    // MARK: - File Names

    /// Workspace metadata file name.
    ///
    /// Contains workspace-wide settings and configuration.
    public static let workspaceFile = "workspace.json"

    /// Per-device manifest file name.
    ///
    /// Lists all change files with their checksums for integrity verification.
    public static let manifestFile = "manifest.json"

    /// Per-device cursor file name.
    ///
    /// Tracks sync progress so devices know where to resume from.
    public static let cursorFile = "cursor.json"

    // MARK: - Verification

    /// Hours between full integrity verification runs.
    ///
    /// Full verification is expensive, so we only do it periodically.
    /// Individual files are verified on read.
    public static let fullVerifyIntervalHours = 24

    /// Number of recent changes to verify for chain integrity.
    ///
    /// We verify the chain hash linking for this many recent changes
    /// to detect tampering or corruption without checking all history.
    public static let chainVerifyDepth = 100

    /// Maximum retry attempts for requesting resend of corrupt data.
    ///
    /// If a file fails integrity checks, we can request the source device
    /// to resend it. This limits how many times we retry before giving up.
    public static let maxResendAttempts = 3

    // MARK: - Storage Management

    /// Default maximum local storage in megabytes.
    ///
    /// Used for selective sync to limit how much data is kept locally.
    /// Users can adjust this in settings.
    public static let defaultMaxStorageMB = 500

    /// Target storage ratio when evicting data.
    ///
    /// When storage exceeds the max, we evict until reaching this ratio
    /// of the maximum. This provides headroom before the next eviction.
    public static let evictionTargetRatio = 0.9

    /// Minimum number of sessions to keep during auto-eviction.
    ///
    /// Ensures users always have some data available even when storage
    /// is constrained. The most recently used sessions are preserved.
    public static let defaultMinSessionsToKeep = 5

    /// Default number of days before a session is eligible for auto-eviction.
    ///
    /// Sessions not accessed within this period may be evicted to free space.
    public static let defaultAutoEvictDays = 90

    // MARK: - Sync Scope

    /// Default sync mode for new devices.
    ///
    /// Full sync is the safest default as it ensures all data is available.
    /// Users can switch to selective or minimal sync for constrained devices.
    public static let defaultSyncMode = SyncMode.full

    // MARK: - Timing

    /// Maximum seconds to wait for iCloud file download.
    ///
    /// If a file isn't downloaded within this time, we consider it failed
    /// and may retry or fall back to cached data.
    public static let iCloudDownloadTimeoutSeconds = 30

    /// Cache duration for storage usage information in seconds.
    ///
    /// Storage info is cached to avoid expensive recalculation on every access.
    public static let storageCacheDurationSeconds: TimeInterval = 60

    /// Debounce interval for change observation in seconds.
    ///
    /// Multiple rapid changes are batched together before writing to the
    /// change log to avoid excessive file operations.
    public static let changeDebounceIntervalSeconds: TimeInterval = 1.0

    /// Minimum interval between background syncs in seconds.
    ///
    /// Prevents excessive syncing that would drain battery. Background sync
    /// won't run more often than this interval (15 minutes).
    public static let backgroundSyncIntervalSeconds: TimeInterval = 15 * 60
}

// MARK: - Sync Mode

/// Sync mode determines what data a device downloads from the cloud.
///
/// Different devices have different storage constraints and usage patterns.
/// This enum allows users to choose the appropriate sync behavior.
///
/// ## Modes
/// - `full`: Downloads all sessions and documents. Best for desktops with ample storage.
/// - `selective`: Only downloads user-whitelisted sessions. Best for curated workflows.
/// - `recent`: Only downloads sessions from the last N days. Auto-cleanup for active users.
/// - `minimal`: Only downloads metadata; content fetched on-demand. Best for phones.
public enum SyncMode: String, Codable, Sendable {
    /// Sync all data from all devices.
    ///
    /// This is the default mode for desktop machines with sufficient storage.
    /// All sessions, documents, and reports are downloaded.
    case full

    /// Only sync sessions that are explicitly whitelisted.
    ///
    /// Users manually select which sessions to sync to this device.
    /// Good for focusing on specific projects.
    case selective

    /// Only sync sessions from the last N days.
    ///
    /// Automatically removes older sessions to manage storage.
    /// The number of days is configurable separately.
    case recent

    /// Only sync metadata; fetch full content on-demand.
    ///
    /// Minimizes storage usage by only downloading session titles
    /// and document metadata. Full content is fetched when accessed.
    case minimal
}

// MARK: - Record Sync State

/// Tracks the sync state of individual records on a device.
///
/// Records can exist in different states depending on sync mode,
/// storage constraints, and user actions.
public enum RecordSyncState: String, Codable, Sendable {
    /// Complete record with all content available locally.
    ///
    /// The record is fully synced and can be accessed offline.
    case full

    /// Metadata only; content available on-demand from cloud.
    ///
    /// Used in minimal sync mode or when content has been evicted.
    case stub

    /// Was previously full, now evicted to save storage.
    ///
    /// The record existed locally but was removed to free space.
    /// Can be fetched again on-demand.
    case evicted

    /// Exists only on this device, not yet synced to cloud.
    ///
    /// New local records start in this state until sync completes.
    case localOnly

    /// Deleted locally but still exists in cloud.
    ///
    /// Used during sync to track deletions that need to be propagated.
    case deletedLocal
}

// MARK: - Sync Operation Type

/// Types of operations that can be recorded in the change log.
///
/// We use a simple upsert/delete model rather than separate create/update
/// to simplify conflict resolution and reduce edge cases.
public enum SyncOperationType: String, Codable, Sendable {
    /// Insert or update a record.
    ///
    /// If the record doesn't exist, it's created. If it exists, it's updated.
    /// The full record data is included with the operation.
    case upsert

    /// Delete a record.
    ///
    /// Marks the record as deleted. The deletion propagates to all devices.
    /// Only the record ID is needed; no data payload is included.
    case delete
}

// MARK: - Sync Entity Type

/// Entity types that can be synchronized across devices.
///
/// Each entity type has its own merge behavior and conflict resolution rules.
/// New entity types can be added as the app evolves.
public enum SyncEntityType: String, Codable, Sendable {
    /// A fact-checking session containing documents and results.
    case session

    /// A document (paper, article) associated with a session.
    case document

    /// A citation extracted from a document.
    case citation

    /// A generated report for a session.
    case report

    /// Usage tracking records for analytics and billing.
    case usageRecord

    /// User settings and preferences.
    case settings
}

// MARK: - Sync Platform

/// Platform identifiers for device registration.
///
/// Used to track which platform a device is running on, which can inform
/// sync decisions (e.g., different default modes for phones vs desktops).
public enum SyncPlatform: String, Codable, Sendable {
    /// iPhone or iPad running iOS/iPadOS.
    case ios

    /// Mac running macOS.
    case macos

    /// Android phone or tablet.
    case android

    /// Desktop app (Python/PySide6).
    case desktop
}
