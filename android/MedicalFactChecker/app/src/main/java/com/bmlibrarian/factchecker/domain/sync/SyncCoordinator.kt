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

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * High-level sync coordinator for the app.
 *
 * This is the main entry point for sync functionality. It manages:
 * - Sync configuration (folder selection)
 * - Sync state (connected devices, last sync time)
 * - Triggering sync operations
 * - Recording local changes
 *
 * The coordinator exposes a [StateFlow] of [SyncUiState] for UI binding.
 *
 * Usage:
 * ```kotlin
 * // Configure sync with a folder
 * syncCoordinator.configureSyncFolder("/path/to/sync/folder")
 *
 * // Trigger sync
 * val result = syncCoordinator.sync()
 *
 * // Record a change
 * syncCoordinator.recordSessionChange(session)
 * ```
 *
 * @see <a href="doc/cross_platform/sync_protocol.md">Sync Protocol Specification</a>
 */
@Singleton
class SyncCoordinator @Inject constructor(
    private val context: Context
) {
    companion object {
        private const val TAG = "SyncCoordinator"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val stateManager = SyncStateManager(context)

    private val _uiState = MutableStateFlow(SyncUiState())
    val uiState: StateFlow<SyncUiState> = _uiState.asStateFlow()

    private var syncEngine: SyncEngine? = null
    private var storage: LocalFolderSyncStorage? = null
    private var changeApplier: ChangeApplier? = null

    /**
     * Initializes the sync coordinator.
     *
     * Call this on app startup to restore previous sync configuration.
     *
     * @param appVersion Current app version for device registration
     * @param applier Callback implementation for applying changes
     */
    suspend fun initialize(appVersion: String, applier: ChangeApplier) {
        this.changeApplier = applier

        val folderPath = stateManager.getSyncFolderPath()
        val syncEnabled = stateManager.isSyncEnabled()

        if (folderPath != null && syncEnabled) {
            try {
                initializeSyncEngine(folderPath, appVersion)
                Log.d(TAG, "Sync coordinator initialized with folder: $folderPath")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize sync", e)
                _uiState.value = SyncUiState(
                    status = SyncStatus.ERROR,
                    syncFolderPath = folderPath,
                    errorMessage = e.message
                )
            }
        } else {
            _uiState.value = SyncUiState(status = SyncStatus.NOT_CONFIGURED)
        }
    }

    /**
     * Configures sync with a folder path.
     *
     * @param folderPath Absolute path to the sync folder
     * @param appVersion Current app version
     * @return true if configuration succeeded
     */
    suspend fun configureSyncFolder(folderPath: String, appVersion: String): Boolean {
        return try {
            // Validate and create storage
            val newStorage = LocalFolderSyncStorageFactory.create(folderPath)

            // Check accessibility
            if (!newStorage.isAccessible()) {
                throw SyncStorageException.PermissionDenied(folderPath)
            }

            // Save configuration
            stateManager.setSyncFolderPath(folderPath)
            stateManager.setSyncEnabled(true)

            // Initialize engine
            initializeSyncEngine(folderPath, appVersion)

            Log.d(TAG, "Sync configured with folder: $folderPath")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure sync folder", e)
            _uiState.value = _uiState.value.copy(
                status = SyncStatus.ERROR,
                errorMessage = e.message
            )
            false
        }
    }

    /**
     * Disables sync and clears configuration.
     */
    suspend fun disableSync() {
        stateManager.setSyncEnabled(false)
        stateManager.setSyncFolderPath(null)

        syncEngine = null
        storage = null

        _uiState.value = SyncUiState(status = SyncStatus.NOT_CONFIGURED)

        Log.d(TAG, "Sync disabled")
    }

    /**
     * Triggers a sync operation.
     *
     * @return Sync result with statistics
     */
    suspend fun sync(): SyncResult {
        val engine = syncEngine ?: return SyncResult(
            success = false,
            errors = listOf("Sync not configured")
        )

        _uiState.value = _uiState.value.copy(status = SyncStatus.SYNCING)

        return try {
            val result = engine.sync()

            val connectedDevices = engine.getConnectedDeviceCount()

            _uiState.value = _uiState.value.copy(
                status = if (result.success) SyncStatus.IDLE else SyncStatus.ERROR,
                lastSyncAt = System.currentTimeMillis(),
                connectedDevices = connectedDevices,
                errorMessage = if (result.errors.isNotEmpty()) result.errors.first() else null
            )

            result
        } catch (e: Exception) {
            Log.e(TAG, "Sync failed", e)

            _uiState.value = _uiState.value.copy(
                status = SyncStatus.ERROR,
                errorMessage = e.message
            )

            SyncResult(
                success = false,
                errors = listOf(e.message ?: "Unknown error")
            )
        }
    }

    /**
     * Records a session change for sync.
     *
     * @param sessionId Session's unique ID
     * @param sessionJson JSON-encoded session data
     */
    suspend fun recordSessionUpsert(sessionId: String, sessionJson: String) {
        syncEngine?.recordUpsert(SyncEntityType.SESSION, sessionId, sessionJson)
    }

    /**
     * Records a session deletion for sync.
     */
    suspend fun recordSessionDelete(sessionId: String) {
        syncEngine?.recordDelete(SyncEntityType.SESSION, sessionId)
    }

    /**
     * Records a document change for sync.
     */
    suspend fun recordDocumentUpsert(documentId: String, documentJson: String) {
        syncEngine?.recordUpsert(SyncEntityType.DOCUMENT, documentId, documentJson)
    }

    /**
     * Records a document deletion for sync.
     */
    suspend fun recordDocumentDelete(documentId: String) {
        syncEngine?.recordDelete(SyncEntityType.DOCUMENT, documentId)
    }

    /**
     * Records a citation change for sync.
     */
    suspend fun recordCitationUpsert(citationId: String, citationJson: String) {
        syncEngine?.recordUpsert(SyncEntityType.CITATION, citationId, citationJson)
    }

    /**
     * Records a report change for sync.
     */
    suspend fun recordReportUpsert(reportId: String, reportJson: String) {
        syncEngine?.recordUpsert(SyncEntityType.REPORT, reportId, reportJson)
    }

    /**
     * Gets information about all connected devices.
     */
    suspend fun getConnectedDevices(): List<DeviceConfig> {
        return syncEngine?.getDevices() ?: emptyList()
    }

    /**
     * Gets the current device's name.
     */
    suspend fun getDeviceName(): String {
        return stateManager.getDeviceName()
    }

    /**
     * Sets the current device's name.
     */
    suspend fun setDeviceName(name: String) {
        stateManager.setDeviceName(name)
    }

    /**
     * Checks if a folder path is valid for sync.
     */
    suspend fun validateFolder(folderPath: String): FolderValidationResult {
        return try {
            val testStorage = LocalFolderSyncStorageFactory.create(folderPath)

            if (!testStorage.isAccessible()) {
                return FolderValidationResult.PermissionDenied
            }

            // Check if workspace already exists
            val hasWorkspace = testStorage.fileExists(SyncConstants.WORKSPACE_FILE)

            if (hasWorkspace) {
                FolderValidationResult.ExistingWorkspace
            } else {
                FolderValidationResult.Valid
            }
        } catch (e: SyncStorageException.PermissionDenied) {
            FolderValidationResult.PermissionDenied
        } catch (e: Exception) {
            FolderValidationResult.Invalid(e.message ?: "Unknown error")
        }
    }

    // ==================== Private Helpers ====================

    private suspend fun initializeSyncEngine(folderPath: String, appVersion: String) {
        val applier = changeApplier ?: throw IllegalStateException("ChangeApplier not set")

        storage = LocalFolderSyncStorageFactory.create(folderPath)
        val deviceConfig = stateManager.createDeviceConfig(appVersion)

        syncEngine = SyncEngine(storage!!, deviceConfig, applier).also {
            it.initialize()
        }

        val connectedDevices = syncEngine!!.getConnectedDeviceCount()

        _uiState.value = SyncUiState(
            status = SyncStatus.IDLE,
            syncFolderPath = folderPath,
            connectedDevices = connectedDevices,
            lastSyncAt = stateManager.loadSyncState().lastSyncAt
        )
    }
}

/**
 * Result of folder validation.
 */
sealed class FolderValidationResult {
    /** Folder is valid and empty (new workspace will be created). */
    object Valid : FolderValidationResult()

    /** Folder contains an existing BMLibrarian workspace. */
    object ExistingWorkspace : FolderValidationResult()

    /** Folder is not accessible (permission denied). */
    object PermissionDenied : FolderValidationResult()

    /** Folder is invalid for another reason. */
    data class Invalid(val reason: String) : FolderValidationResult()
}
