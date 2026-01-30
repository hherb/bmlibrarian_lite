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
import android.content.SharedPreferences
import android.os.Build
import android.provider.Settings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * Manages device-local sync state persistence.
 *
 * Stores sync configuration and watermarks locally (not in sync folder)
 * so they persist across app restarts.
 *
 * @property context Android context for SharedPreferences access
 *
 * @see <a href="doc/cross_platform/sync_protocol.md">Sync Protocol Specification</a>
 */
class SyncStateManager(
    private val context: Context
) {
    companion object {
        private const val PREFS_NAME = "sync_state"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_SYNC_FOLDER_PATH = "sync_folder_path"
        private const val KEY_SYNC_STATE = "sync_state"
        private const val KEY_SYNC_ENABLED = "sync_enabled"
    }

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val prefs: SharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private val mutex = Mutex()

    /**
     * Gets or creates device ID without acquiring mutex.
     *
     * Internal helper to avoid deadlock when called from within mutex-holding context.
     * Must be called from within Dispatchers.IO context.
     */
    private fun getOrCreateDeviceIdInternal(): String {
        return prefs.getString(KEY_DEVICE_ID, null) ?: run {
            val newId = UUID.randomUUID().toString()
            prefs.edit().putString(KEY_DEVICE_ID, newId).apply()
            newId
        }
    }

    /**
     * Gets or generates device name without acquiring mutex.
     *
     * Internal helper to avoid deadlock when called from within mutex-holding context.
     * Must be called from within Dispatchers.IO context.
     */
    private fun getDeviceNameInternal(): String {
        return prefs.getString(KEY_DEVICE_NAME, null) ?: run {
            val name = generateDeviceName()
            prefs.edit().putString(KEY_DEVICE_NAME, name).apply()
            name
        }
    }

    /**
     * Gets or creates a unique device ID for this installation.
     *
     * The device ID is a UUID that remains constant for the lifetime
     * of the app installation. It's regenerated if the app is reinstalled.
     */
    suspend fun getOrCreateDeviceId(): String = mutex.withLock {
        withContext(Dispatchers.IO) {
            getOrCreateDeviceIdInternal()
        }
    }

    /**
     * Gets or generates a human-readable device name.
     *
     * Uses the device manufacturer and model, or Android ID as fallback.
     */
    suspend fun getDeviceName(): String = mutex.withLock {
        withContext(Dispatchers.IO) {
            getDeviceNameInternal()
        }
    }

    /**
     * Sets a custom device name.
     */
    suspend fun setDeviceName(name: String) = mutex.withLock {
        withContext(Dispatchers.IO) {
            prefs.edit().putString(KEY_DEVICE_NAME, name).apply()
        }
    }

    /**
     * Gets the configured sync folder path.
     *
     * @return Path to sync folder, or null if not configured
     */
    suspend fun getSyncFolderPath(): String? = mutex.withLock {
        withContext(Dispatchers.IO) {
            prefs.getString(KEY_SYNC_FOLDER_PATH, null)
        }
    }

    /**
     * Sets the sync folder path.
     *
     * @param path Absolute path to sync folder, or null to disable sync
     */
    suspend fun setSyncFolderPath(path: String?) = mutex.withLock {
        withContext(Dispatchers.IO) {
            if (path != null) {
                prefs.edit().putString(KEY_SYNC_FOLDER_PATH, path).apply()
            } else {
                prefs.edit().remove(KEY_SYNC_FOLDER_PATH).apply()
            }
        }
    }

    /**
     * Gets whether sync is enabled.
     */
    suspend fun isSyncEnabled(): Boolean = mutex.withLock {
        withContext(Dispatchers.IO) {
            prefs.getBoolean(KEY_SYNC_ENABLED, false)
        }
    }

    /**
     * Sets whether sync is enabled.
     */
    suspend fun setSyncEnabled(enabled: Boolean) = mutex.withLock {
        withContext(Dispatchers.IO) {
            prefs.edit().putBoolean(KEY_SYNC_ENABLED, enabled).apply()
        }
    }

    /**
     * Loads the sync state.
     *
     * @return Sync state or a fresh state if none exists
     */
    suspend fun loadSyncState(): SyncState = mutex.withLock {
        withContext(Dispatchers.IO) {
            val stateJson = prefs.getString(KEY_SYNC_STATE, null)
            if (stateJson != null) {
                try {
                    json.decodeFromString<SyncState>(stateJson)
                } catch (e: Exception) {
                    // Corrupted state, start fresh - use internal helper to avoid deadlock
                    SyncState(deviceId = getOrCreateDeviceIdInternal())
                }
            } else {
                // No state yet - use internal helper to avoid deadlock
                SyncState(deviceId = getOrCreateDeviceIdInternal())
            }
        }
    }

    /**
     * Saves the sync state.
     */
    suspend fun saveSyncState(state: SyncState) = mutex.withLock {
        withContext(Dispatchers.IO) {
            val stateJson = json.encodeToString(state)
            prefs.edit().putString(KEY_SYNC_STATE, stateJson).apply()
        }
    }

    /**
     * Clears all sync state and configuration.
     *
     * Call this when user wants to disconnect from sync entirely.
     * Does NOT delete device ID.
     */
    suspend fun clearSyncData() = mutex.withLock {
        withContext(Dispatchers.IO) {
            val deviceId = prefs.getString(KEY_DEVICE_ID, null)
            prefs.edit()
                .clear()
                .putString(KEY_DEVICE_ID, deviceId) // Preserve device ID
                .apply()
        }
    }

    /**
     * Generates a human-readable device name.
     */
    private fun generateDeviceName(): String {
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        val model = Build.MODEL

        // If model already contains manufacturer name, just use model
        return if (model.startsWith(manufacturer, ignoreCase = true)) {
            model
        } else {
            "$manufacturer $model"
        }
    }

    /**
     * Creates a DeviceConfig for this device.
     *
     * @param appVersion Current app version string
     * @return Device configuration for sync registration
     */
    suspend fun createDeviceConfig(appVersion: String): DeviceConfig = mutex.withLock {
        withContext(Dispatchers.IO) {
            DeviceConfig(
                deviceId = getOrCreateDeviceIdInternal(),
                deviceName = getDeviceNameInternal(),
                platform = SyncPlatform.ANDROID,
                appVersion = appVersion
            )
        }
    }
}
