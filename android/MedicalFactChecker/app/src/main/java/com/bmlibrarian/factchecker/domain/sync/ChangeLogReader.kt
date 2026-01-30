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
import kotlinx.serialization.json.Json

/**
 * Reads and verifies changes from remote devices.
 *
 * Discovers devices in the workspace, reads their change manifests,
 * and provides verified change records for the sync engine to apply.
 *
 * @property storage The sync storage backend
 * @property localDeviceId This device's ID (to exclude from remote reads)
 *
 * @see <a href="doc/cross_platform/sync_protocol.md">Sync Protocol Specification</a>
 */
class ChangeLogReader(
    private val storage: SyncStorage,
    private val localDeviceId: String
) {
    companion object {
        private const val TAG = "ChangeLogReader"
    }

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    /**
     * Discovers all devices in the workspace.
     *
     * @return List of device IDs (excluding local device)
     */
    suspend fun discoverDevices(): List<String> {
        return try {
            val devicesDir = SyncConstants.DEVICES_DIR
            if (!storage.fileExists("$devicesDir/.")) {
                // Check if directory exists by listing files
                try {
                    storage.listFiles(devicesDir)
                } catch (e: SyncStorageException.DirectoryNotFound) {
                    return emptyList()
                }
            }

            storage.listFiles(devicesDir)
                .filter { it.name.endsWith(".json") }
                .map { it.name.removeSuffix(".json") }
                .filter { it != localDeviceId }
                .also { Log.d(TAG, "Discovered ${it.size} remote devices") }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to discover devices", e)
            emptyList()
        }
    }

    /**
     * Reads a device's configuration.
     *
     * @param deviceId The device ID to read
     * @return Device configuration or null if not found
     */
    suspend fun readDeviceConfig(deviceId: String): DeviceConfig? {
        return try {
            val path = "${SyncConstants.DEVICES_DIR}/$deviceId.json"
            val data = storage.readFile(path)
            json.decodeFromString<DeviceConfig>(String(data))
        } catch (e: SyncStorageException.FileNotFound) {
            null
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read device config for $deviceId", e)
            null
        }
    }

    /**
     * Reads a device's change manifest.
     *
     * @param deviceId The device ID
     * @return Manifest or null if not found
     */
    suspend fun readManifest(deviceId: String): ChangeManifest? {
        return try {
            val path = "${SyncConstants.CHANGES_DIR}/$deviceId/${SyncConstants.MANIFEST_FILE}"
            val data = storage.readFile(path)
            json.decodeFromString<ChangeManifest>(String(data))
        } catch (e: SyncStorageException.FileNotFound) {
            null
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read manifest for $deviceId", e)
            null
        }
    }

    /**
     * Gets new changes from a device since a watermark.
     *
     * @param deviceId The device to read from
     * @param sinceSequence Only return changes after this sequence (0 for all)
     * @return List of change file entries to fetch
     */
    suspend fun getNewChanges(deviceId: String, sinceSequence: Long): List<ChangeFileEntry> {
        val manifest = readManifest(deviceId) ?: return emptyList()

        return manifest.files
            .filter { it.sequence > sinceSequence }
            .sortedBy { it.sequence }
            .also {
                if (it.isNotEmpty()) {
                    Log.d(TAG, "Found ${it.size} new changes from $deviceId (since seq=$sinceSequence)")
                }
            }
    }

    /**
     * Reads and verifies a change record.
     *
     * @param deviceId The device that wrote the change
     * @param entry The manifest entry describing the change
     * @return Verified change record, or null if verification failed
     */
    suspend fun readChange(deviceId: String, entry: ChangeFileEntry): ChangeRecord? {
        val path = "${SyncConstants.CHANGES_DIR}/$deviceId/${entry.filename}"

        return try {
            val data = storage.readFile(path)
            val dataString = String(data)

            // Parse record
            val record = json.decodeFromString<ChangeRecord>(dataString)

            // Verify checksum
            val payloadJson = json.encodeToString(ChangePayload.serializer(), record.payload)
            val computedChecksum = ChecksumUtil.computeChecksum(payloadJson)

            if (computedChecksum != record.envelope.checksum) {
                Log.e(TAG, "Checksum mismatch for $path")
                Log.e(TAG, "  Expected: ${record.envelope.checksum}")
                Log.e(TAG, "  Computed: $computedChecksum")

                // Quarantine corrupt file
                storage.quarantineFile(path, "checksum_mismatch")
                return null
            }

            // Verify manifest checksum matches file
            if (entry.checksum != record.envelope.checksum) {
                Log.w(TAG, "Manifest checksum doesn't match file for $path")
                // This could indicate manifest corruption or file tampering
                // We trust the file's self-contained checksum if it verifies
            }

            Log.d(TAG, "Verified change: ${entry.filename}")
            record
        } catch (e: SyncStorageException.FileNotFound) {
            Log.w(TAG, "Change file not found: $path")
            null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read/parse change: $path", e)

            // Quarantine unparseable file
            try {
                storage.quarantineFile(path, "parse_error: ${e.message}")
            } catch (qe: Exception) {
                Log.e(TAG, "Failed to quarantine $path", qe)
            }

            null
        }
    }

    /**
     * Reads all new changes from all remote devices.
     *
     * @param watermarks Map of device ID to last-seen sequence
     * @return List of all new changes, sorted by timestamp
     */
    suspend fun readAllNewChanges(
        watermarks: Map<String, Long>
    ): List<Pair<String, ChangeRecord>> {
        val allChanges = mutableListOf<Pair<String, ChangeRecord>>()

        for (deviceId in discoverDevices()) {
            val watermark = watermarks[deviceId] ?: 0L
            val entries = getNewChanges(deviceId, watermark)

            for (entry in entries) {
                val record = readChange(deviceId, entry)
                if (record != null) {
                    allChanges.add(deviceId to record)
                }
            }
        }

        // Sort by timestamp for consistent ordering
        return allChanges.sortedBy { it.second.payload.timestamp }
    }

    /**
     * Verifies integrity of a device's change chain.
     *
     * Checks that the hash chain is unbroken for the last N changes.
     *
     * @param deviceId The device to verify
     * @param depth Number of changes to verify (default [SyncConstants.DEFAULT_CHAIN_VERIFICATION_DEPTH])
     * @return True if chain is valid
     */
    suspend fun verifyChain(
        deviceId: String,
        depth: Int = SyncConstants.DEFAULT_CHAIN_VERIFICATION_DEPTH
    ): Boolean {
        val manifest = readManifest(deviceId) ?: return true // No manifest = nothing to verify

        val entries = manifest.files
            .sortedByDescending { it.sequence }
            .take(depth)

        var expectedPreviousHash: String? = null

        for (entry in entries.reversed()) {
            val record = readChange(deviceId, entry) ?: return false

            // First in chain can have null previousHash
            if (expectedPreviousHash != null && record.payload.previousHash != expectedPreviousHash) {
                Log.e(TAG, "Chain broken at sequence ${entry.sequence}")
                return false
            }

            expectedPreviousHash = record.envelope.checksum
        }

        Log.d(TAG, "Chain verified for $deviceId (depth=$depth)")
        return true
    }
}
