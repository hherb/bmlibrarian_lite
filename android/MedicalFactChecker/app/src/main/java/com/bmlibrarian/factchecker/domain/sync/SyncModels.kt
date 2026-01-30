/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

package com.bmlibrarian.factchecker.domain.sync

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Sync protocol constants and directory structure.
 *
 * Defines the folder layout and file naming conventions used by the
 * cross-platform sync protocol.
 *
 * @see <a href="doc/cross_platform/sync_protocol.md">Sync Protocol Specification</a>
 */
object SyncConstants {
    /** Current schema version. */
    const val SCHEMA_VERSION = 1

    /** Minimum compatible schema version. */
    const val MIN_COMPATIBLE_VERSION = 1

    /** Workspace configuration filename. */
    const val WORKSPACE_FILE = "workspace.json"

    /** Devices directory name. */
    const val DEVICES_DIR = "devices"

    /** Changes directory name. */
    const val CHANGES_DIR = "changes"

    /** Quarantine directory name (hidden). */
    const val QUARANTINE_DIR = ".quarantine"

    /** Manifest filename within each device's changes directory. */
    const val MANIFEST_FILE = "manifest.json"

    /** Default checksum algorithm. */
    const val CHECKSUM_ALGORITHM = "sha256"

    /** Integrity envelope version. */
    const val ENVELOPE_VERSION = 1

    /** Sequence number padding width for filenames. */
    const val SEQUENCE_PADDING_WIDTH = 6

    /** Default chain verification depth. */
    const val DEFAULT_CHAIN_VERIFICATION_DEPTH = 100

    /** Default sync folder path for Android. */
    const val DEFAULT_SYNC_FOLDER_PATH = "/storage/emulated/0/BMLibrarian"

    // Time constants for UI formatting
    /** One minute in milliseconds. */
    const val ONE_MINUTE_MS = 60_000L

    /** One hour in milliseconds. */
    const val ONE_HOUR_MS = 3_600_000L

    /** One day in milliseconds. */
    const val ONE_DAY_MS = 86_400_000L
}

/**
 * Sync mode determining what data is synchronized.
 */
@Serializable
enum class SyncMode {
    /** Sync all sessions and documents. */
    @SerialName("full")
    FULL,

    /** Sync only selected sessions. */
    @SerialName("selective")
    SELECTIVE,

    /** Sync only recent sessions (last N days). */
    @SerialName("recent")
    RECENT,

    /** Sync minimal data (sessions without full documents). */
    @SerialName("minimal")
    MINIMAL
}

/**
 * Platform identifier for device registration.
 */
@Serializable
enum class SyncPlatform {
    @SerialName("ios")
    IOS,

    @SerialName("macos")
    MACOS,

    @SerialName("android")
    ANDROID,

    @SerialName("desktop")
    DESKTOP
}

/**
 * Entity types that can be synchronized.
 */
@Serializable
enum class SyncEntityType {
    @SerialName("session")
    SESSION,

    @SerialName("document")
    DOCUMENT,

    @SerialName("citation")
    CITATION,

    @SerialName("report")
    REPORT,

    @SerialName("usage")
    USAGE,

    @SerialName("settings")
    SETTINGS
}

/**
 * Sync operations.
 */
@Serializable
enum class SyncOperation {
    @SerialName("upsert")
    UPSERT,

    @SerialName("delete")
    DELETE
}

/**
 * Workspace configuration stored at sync root.
 *
 * Created on first sync initialization. All devices share this file.
 *
 * @property schemaVersion Current schema version
 * @property minCompatibleVersion Minimum version that can read this workspace
 * @property createdAt Unix timestamp milliseconds when workspace was created
 * @property encryptionMode Encryption mode ("none" or "aes-256-gcm")
 */
@Serializable
data class WorkspaceConfig(
    val schemaVersion: Int = SyncConstants.SCHEMA_VERSION,
    val minCompatibleVersion: Int = SyncConstants.MIN_COMPATIBLE_VERSION,
    val createdAt: Long = System.currentTimeMillis(),
    val encryptionMode: String = "none"
)

/**
 * Sync scope configuration for a device.
 *
 * @property mode Sync mode determining what data is synchronized
 * @property maxStorageMB Optional storage limit in megabytes
 */
@Serializable
data class SyncScope(
    val mode: SyncMode = SyncMode.FULL,
    val maxStorageMB: Int? = null
)

/**
 * Device configuration stored in devices directory.
 *
 * Each device registers itself on first sync.
 *
 * @property deviceId Unique UUID for this device
 * @property deviceName Human-readable device name
 * @property platform Platform identifier
 * @property appVersion App version for compatibility checks
 * @property lastSeenAt Last sync timestamp (milliseconds)
 * @property syncScope Sync configuration for this device
 */
@Serializable
data class DeviceConfig(
    val deviceId: String,
    val deviceName: String,
    val platform: SyncPlatform,
    val appVersion: String,
    val lastSeenAt: Long = System.currentTimeMillis(),
    val syncScope: SyncScope = SyncScope()
)

/**
 * Change manifest for a device.
 *
 * Index of all change files from a device. Updated after each change file write.
 *
 * @property deviceId Device that owns this manifest
 * @property lastSequence Highest sequence number written
 * @property files List of change file entries
 */
@Serializable
data class ChangeManifest(
    val deviceId: String,
    val lastSequence: Long = 0,
    val files: List<ChangeFileEntry> = emptyList()
)

/**
 * Entry in a change manifest.
 *
 * @property sequence Sequence number of the change
 * @property filename Name of the change file
 * @property checksum SHA-256 checksum of the file
 * @property size File size in bytes
 */
@Serializable
data class ChangeFileEntry(
    val sequence: Long,
    val filename: String,
    val checksum: String,
    val size: Long
)

/**
 * Integrity envelope wrapping all sync files.
 *
 * @property version Envelope format version
 * @property algorithm Checksum algorithm used
 * @property checksum SHA-256 checksum of the payload
 */
@Serializable
data class IntegrityEnvelope(
    val version: Int = SyncConstants.ENVELOPE_VERSION,
    val algorithm: String = SyncConstants.CHECKSUM_ALGORITHM,
    val checksum: String
)

/**
 * Change record payload.
 *
 * @property sequence Monotonic sequence per device
 * @property deviceId Originating device
 * @property timestamp When change was recorded (milliseconds)
 * @property entityType Type of entity changed
 * @property operation Upsert or delete
 * @property entityId Primary key of entity
 * @property previousHash Hash of previous change (for chain verification)
 * @property vectorClock Causality tracking across devices
 * @property data Entity data (null for delete)
 */
@Serializable
data class ChangePayload(
    val sequence: Long,
    val deviceId: String,
    val timestamp: Long,
    val entityType: SyncEntityType,
    val operation: SyncOperation,
    val entityId: String,
    val previousHash: String? = null,
    val vectorClock: Map<String, Long> = emptyMap(),
    val data: String? = null  // JSON-encoded entity data
)

/**
 * Complete change record with envelope.
 *
 * @property envelope Integrity verification data
 * @property payload The actual change data
 */
@Serializable
data class ChangeRecord(
    val envelope: IntegrityEnvelope,
    val payload: ChangePayload
)

/**
 * Local sync state persisted on device.
 *
 * Tracks watermarks and configuration that survives app restarts.
 *
 * @property deviceId This device's unique ID
 * @property watermarks Map of remote device ID to last-seen sequence number
 * @property lastSyncAt Timestamp of last successful sync
 * @property localExclusions Session IDs excluded from sync on this device
 */
@Serializable
data class SyncState(
    val deviceId: String,
    val watermarks: Map<String, Long> = emptyMap(),
    val lastSyncAt: Long? = null,
    val localExclusions: Set<String> = emptySet()
) {
    /**
     * Creates a copy with an updated watermark.
     */
    fun withWatermark(remoteDeviceId: String, sequence: Long): SyncState {
        return copy(watermarks = watermarks + (remoteDeviceId to sequence))
    }

    /**
     * Creates a copy with updated last sync timestamp.
     */
    fun withLastSyncAt(timestamp: Long): SyncState {
        return copy(lastSyncAt = timestamp)
    }
}

/**
 * Result of a sync operation.
 *
 * @property success Whether sync completed successfully
 * @property changesApplied Number of remote changes applied
 * @property changesUploaded Number of local changes uploaded
 * @property errors List of non-fatal errors encountered
 * @property duration Sync duration in milliseconds
 */
data class SyncResult(
    val success: Boolean,
    val changesApplied: Int = 0,
    val changesUploaded: Int = 0,
    val errors: List<String> = emptyList(),
    val duration: Long = 0
)

/**
 * Sync status for UI display.
 */
enum class SyncStatus {
    /** Sync not configured (no folder selected). */
    NOT_CONFIGURED,

    /** Idle, waiting for next sync. */
    IDLE,

    /** Currently syncing. */
    SYNCING,

    /** Last sync had errors. */
    ERROR,

    /** Sync folder not accessible. */
    FOLDER_UNAVAILABLE
}

/**
 * Observable sync state for UI binding.
 *
 * @property status Current sync status
 * @property lastSyncAt Timestamp of last successful sync
 * @property syncFolderPath Configured sync folder path (null if not configured)
 * @property errorMessage Most recent error message (null if no error)
 * @property connectedDevices Number of other devices in workspace
 */
data class SyncUiState(
    val status: SyncStatus = SyncStatus.NOT_CONFIGURED,
    val lastSyncAt: Long? = null,
    val syncFolderPath: String? = null,
    val errorMessage: String? = null,
    val connectedDevices: Int = 0
)

/**
 * Utility object for computing checksums.
 *
 * Provides SHA-256 checksum computation used for integrity verification
 * throughout the sync protocol.
 */
object ChecksumUtil {
    /**
     * Computes SHA-256 checksum of data.
     *
     * @param data The string data to checksum
     * @return Checksum string prefixed with algorithm (e.g., "sha256:abc123...")
     */
    fun computeChecksum(data: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(data.toByteArray(Charsets.UTF_8))
        return "${SyncConstants.CHECKSUM_ALGORITHM}:" + hash.joinToString("") { "%02x".format(it) }
    }
}
