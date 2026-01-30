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

import android.util.Log
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Core sync engine that orchestrates the sync process.
 *
 * Coordinates reading remote changes, applying them via LWW merge,
 * and writing local changes to the sync folder.
 *
 * Thread-safe: Uses mutex to ensure only one sync runs at a time.
 *
 * @property storage The sync storage backend
 * @property deviceConfig This device's configuration
 * @property changeApplier Callback to apply changes to local database
 *
 * @see <a href="doc/cross_platform/sync_protocol.md">Sync Protocol Specification</a>
 */
class SyncEngine(
    private val storage: SyncStorage,
    private val deviceConfig: DeviceConfig,
    private val changeApplier: ChangeApplier
) {
    companion object {
        private const val TAG = "SyncEngine"
    }

    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val syncMutex = Mutex()

    private lateinit var changeLogWriter: ChangeLogWriter
    private lateinit var changeLogReader: ChangeLogReader
    private var syncState: SyncState = SyncState(deviceId = deviceConfig.deviceId)

    private var isInitialized = false

    /**
     * Initializes the sync engine.
     *
     * Sets up the workspace if needed, registers this device, and
     * prepares the change log components.
     */
    suspend fun initialize() = syncMutex.withLock {
        if (isInitialized) return@withLock

        try {
            Log.d(TAG, "Initializing sync engine...")

            // Ensure workspace exists
            ensureWorkspaceExists()

            // Register this device
            registerDevice()

            // Initialize change log components
            changeLogWriter = ChangeLogWriterFactory.create(storage, deviceConfig.deviceId)
            changeLogReader = ChangeLogReader(storage, deviceConfig.deviceId)

            // Load sync state
            loadSyncState()

            isInitialized = true
            Log.d(TAG, "Sync engine initialized")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize sync engine", e)
            throw e
        }
    }

    /**
     * Performs a full sync cycle.
     *
     * 1. Updates device last-seen timestamp
     * 2. Discovers remote devices
     * 3. Reads and applies their changes
     * 4. Saves sync state
     *
     * @return Sync result with statistics
     */
    suspend fun sync(): SyncResult = syncMutex.withLock {
        if (!isInitialized) {
            throw IllegalStateException("SyncEngine not initialized")
        }

        val startTime = System.currentTimeMillis()
        var changesApplied = 0
        val errors = mutableListOf<String>()

        try {
            Log.d(TAG, "Starting sync...")

            // Update our device's last-seen timestamp
            updateDeviceLastSeen()

            // Get all new changes from remote devices
            val newChanges = changeLogReader.readAllNewChanges(syncState.watermarks)

            Log.d(TAG, "Found ${newChanges.size} new changes to process")

            // Apply each change
            for ((remoteDeviceId, record) in newChanges) {
                try {
                    val applied = applyChange(record)
                    if (applied) {
                        changesApplied++
                    }

                    // Update watermark for this device
                    syncState.watermarks[remoteDeviceId] = record.payload.sequence
                } catch (e: Exception) {
                    val error = "Failed to apply change ${record.payload.entityId}: ${e.message}"
                    Log.e(TAG, error, e)
                    errors.add(error)
                }
            }

            // Save sync state
            syncState.lastSyncAt = System.currentTimeMillis()
            saveSyncState()

            val duration = System.currentTimeMillis() - startTime
            Log.d(TAG, "Sync completed in ${duration}ms: $changesApplied changes applied")

            SyncResult(
                success = errors.isEmpty(),
                changesApplied = changesApplied,
                changesUploaded = 0, // Local changes are written immediately, not batched
                errors = errors,
                duration = duration
            )
        } catch (e: Exception) {
            Log.e(TAG, "Sync failed", e)
            SyncResult(
                success = false,
                errors = listOf(e.message ?: "Unknown error"),
                duration = System.currentTimeMillis() - startTime
            )
        }
    }

    /**
     * Records a local entity change.
     *
     * Call this whenever an entity is created or updated locally.
     *
     * @param entityType Type of entity
     * @param entityId Primary key
     * @param entityData JSON-encoded entity data
     */
    suspend fun recordUpsert(
        entityType: SyncEntityType,
        entityId: String,
        entityData: String
    ) {
        if (!isInitialized) {
            Log.w(TAG, "SyncEngine not initialized, skipping recordUpsert")
            return
        }

        changeLogWriter.recordUpsert(entityType, entityId, entityData)
    }

    /**
     * Records a local entity deletion.
     *
     * Call this whenever an entity is deleted locally.
     *
     * @param entityType Type of entity
     * @param entityId Primary key
     */
    suspend fun recordDelete(
        entityType: SyncEntityType,
        entityId: String
    ) {
        if (!isInitialized) {
            Log.w(TAG, "SyncEngine not initialized, skipping recordDelete")
            return
        }

        changeLogWriter.recordDelete(entityType, entityId)
    }

    /**
     * Gets the number of connected devices (excluding this one).
     */
    suspend fun getConnectedDeviceCount(): Int {
        return if (isInitialized) {
            changeLogReader.discoverDevices().size
        } else {
            0
        }
    }

    /**
     * Gets information about all devices in the workspace.
     */
    suspend fun getDevices(): List<DeviceConfig> {
        if (!isInitialized) return emptyList()

        val devices = mutableListOf<DeviceConfig>()

        // Add self
        devices.add(deviceConfig)

        // Add remote devices
        for (deviceId in changeLogReader.discoverDevices()) {
            changeLogReader.readDeviceConfig(deviceId)?.let { devices.add(it) }
        }

        return devices.sortedByDescending { it.lastSeenAt }
    }

    // ==================== Private Helpers ====================

    /**
     * Ensures the workspace structure exists.
     */
    private suspend fun ensureWorkspaceExists() {
        // Check for existing workspace
        val workspacePath = SyncConstants.WORKSPACE_FILE
        if (storage.fileExists(workspacePath)) {
            // Verify compatibility
            val data = storage.readFile(workspacePath)
            val config = json.decodeFromString<WorkspaceConfig>(String(data))

            if (config.minCompatibleVersion > SyncConstants.SCHEMA_VERSION) {
                throw IllegalStateException(
                    "Workspace requires schema version ${config.minCompatibleVersion}, " +
                    "but this app only supports version ${SyncConstants.SCHEMA_VERSION}. " +
                    "Please update the app."
                )
            }

            Log.d(TAG, "Using existing workspace (schema v${config.schemaVersion})")
            return
        }

        // Create new workspace
        Log.d(TAG, "Creating new workspace...")

        val config = WorkspaceConfig()
        val configJson = json.encodeToString(config)
        storage.writeFile(configJson.toByteArray(Charsets.UTF_8), workspacePath)

        // Create directories
        storage.createDirectory(SyncConstants.DEVICES_DIR)
        storage.createDirectory(SyncConstants.CHANGES_DIR)

        Log.d(TAG, "Workspace created")
    }

    /**
     * Registers this device in the workspace.
     */
    private suspend fun registerDevice() {
        val devicePath = "${SyncConstants.DEVICES_DIR}/${deviceConfig.deviceId}.json"
        val configJson = json.encodeToString(deviceConfig)
        storage.writeFile(configJson.toByteArray(Charsets.UTF_8), devicePath)

        Log.d(TAG, "Device registered: ${deviceConfig.deviceName}")
    }

    /**
     * Updates this device's last-seen timestamp.
     */
    private suspend fun updateDeviceLastSeen() {
        val updatedConfig = deviceConfig.copy(lastSeenAt = System.currentTimeMillis())
        val devicePath = "${SyncConstants.DEVICES_DIR}/${deviceConfig.deviceId}.json"
        val configJson = json.encodeToString(updatedConfig)
        storage.writeFile(configJson.toByteArray(Charsets.UTF_8), devicePath)
    }

    /**
     * Loads sync state from local storage.
     */
    private suspend fun loadSyncState() {
        // Sync state is stored locally, not in the sync folder
        // This would typically use SharedPreferences or local database
        // For now, we start fresh each time
        syncState = SyncState(deviceId = deviceConfig.deviceId)
    }

    /**
     * Saves sync state to local storage.
     */
    private suspend fun saveSyncState() {
        // Would save to SharedPreferences or local database
        // Implementation depends on integration with existing storage
    }

    /**
     * Applies a remote change using LWW merge.
     *
     * @return true if the change was applied
     */
    private suspend fun applyChange(record: ChangeRecord): Boolean {
        val payload = record.payload
        val remoteVersion = payload.toVersion()

        // Get local version if exists
        val localVersion = changeApplier.getEntityVersion(
            payload.entityType,
            payload.entityId
        )

        return when (payload.operation) {
            SyncOperation.DELETE -> {
                if (LWWMergeStrategy.shouldApplyDelete(remoteVersion, localVersion?.toVersion())) {
                    changeApplier.applyDelete(payload.entityType, payload.entityId)
                    Log.d(TAG, "Applied delete: ${payload.entityType}/${payload.entityId}")
                    true
                } else {
                    Log.d(TAG, "Skipped delete (LWW): ${payload.entityType}/${payload.entityId}")
                    false
                }
            }

            SyncOperation.UPSERT -> {
                if (LWWMergeStrategy.shouldApplyRemote(remoteVersion, localVersion?.toVersion())) {
                    changeApplier.applyUpsert(
                        payload.entityType,
                        payload.entityId,
                        payload.data ?: throw IllegalStateException("Upsert missing data"),
                        EntityVersion(
                            entityId = payload.entityId,
                            entityType = payload.entityType,
                            timestamp = payload.timestamp,
                            deviceId = payload.deviceId
                        )
                    )
                    Log.d(TAG, "Applied upsert: ${payload.entityType}/${payload.entityId}")
                    true
                } else {
                    Log.d(TAG, "Skipped upsert (LWW): ${payload.entityType}/${payload.entityId}")
                    false
                }
            }
        }
    }
}

/**
 * Interface for applying sync changes to the local database.
 *
 * Implement this to connect the sync engine to your data layer.
 */
interface ChangeApplier {
    /**
     * Gets the current version of an entity.
     *
     * @return EntityVersion or null if entity doesn't exist
     */
    suspend fun getEntityVersion(entityType: SyncEntityType, entityId: String): EntityVersion?

    /**
     * Applies an upsert (create or update) to the local database.
     *
     * @param entityType Type of entity
     * @param entityId Primary key
     * @param data JSON-encoded entity data
     * @param version Version information to store
     */
    suspend fun applyUpsert(
        entityType: SyncEntityType,
        entityId: String,
        data: String,
        version: EntityVersion
    )

    /**
     * Applies a delete to the local database.
     *
     * @param entityType Type of entity
     * @param entityId Primary key
     */
    suspend fun applyDelete(entityType: SyncEntityType, entityId: String)
}
