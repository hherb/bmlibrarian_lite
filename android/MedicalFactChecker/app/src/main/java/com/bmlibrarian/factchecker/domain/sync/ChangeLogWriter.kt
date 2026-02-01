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
 * Writes local changes to the sync folder.
 *
 * Records entity changes as append-only change files with integrity envelopes.
 * Maintains a manifest file for efficient change discovery by other devices.
 *
 * Thread-safe: Uses mutex to serialize write operations.
 *
 * @property storage The sync storage backend
 * @property deviceId This device's unique identifier
 *
 * @see <a href="doc/cross_platform/sync_protocol.md">Sync Protocol Specification</a>
 */
class ChangeLogWriter(
    private val storage: SyncStorage,
    private val deviceId: String
) {
    companion object {
        private const val TAG = "ChangeLogWriter"
    }

    private val json = Json {
        prettyPrint = false
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val writeMutex = Mutex()
    private var currentSequence: Long = 0
    private var lastChangeHash: String? = null
    private val vectorClock: MutableMap<String, Long> = mutableMapOf()

    /**
     * Initializes the change log writer.
     *
     * Reads existing manifest to determine current sequence number.
     * Must be called before recording any changes.
     */
    suspend fun initialize() = writeMutex.withLock {
        try {
            // Ensure changes directory exists
            val changesDir = "${SyncConstants.CHANGES_DIR}/$deviceId"
            storage.createDirectory(changesDir)

            // Read existing manifest if present
            val manifestPath = "$changesDir/${SyncConstants.MANIFEST_FILE}"
            if (storage.fileExists(manifestPath)) {
                val manifestData = storage.readFile(manifestPath)
                val manifest = json.decodeFromString<ChangeManifest>(String(manifestData))
                currentSequence = manifest.lastSequence

                // Get hash of last change for chain verification
                if (manifest.files.isNotEmpty()) {
                    val lastFile = manifest.files.maxByOrNull { it.sequence }
                    lastChangeHash = lastFile?.checksum
                }

                Log.d(TAG, "Initialized with sequence=$currentSequence")
            } else {
                currentSequence = 0
                lastChangeHash = null
                Log.d(TAG, "Initialized fresh (no existing manifest)")
            }

            // Initialize vector clock with our device
            vectorClock[deviceId] = currentSequence
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize", e)
            throw e
        }
    }

    /**
     * Records an entity upsert (create or update).
     *
     * @param entityType Type of entity
     * @param entityId Primary key of entity
     * @param entityData JSON-encoded entity data
     * @return The sequence number of the recorded change
     */
    suspend fun recordUpsert(
        entityType: SyncEntityType,
        entityId: String,
        entityData: String
    ): Long = recordChange(entityType, entityId, SyncOperation.UPSERT, entityData)

    /**
     * Records an entity deletion.
     *
     * @param entityType Type of entity
     * @param entityId Primary key of entity
     * @return The sequence number of the recorded change
     */
    suspend fun recordDelete(
        entityType: SyncEntityType,
        entityId: String
    ): Long = recordChange(entityType, entityId, SyncOperation.DELETE, null)

    /**
     * Records a change to the sync folder.
     */
    private suspend fun recordChange(
        entityType: SyncEntityType,
        entityId: String,
        operation: SyncOperation,
        entityData: String?
    ): Long = writeMutex.withLock {
        val timestamp = System.currentTimeMillis()
        val sequence = ++currentSequence

        // Update vector clock
        vectorClock[deviceId] = sequence

        // Create payload
        val payload = ChangePayload(
            sequence = sequence,
            deviceId = deviceId,
            timestamp = timestamp,
            entityType = entityType,
            operation = operation,
            entityId = entityId,
            previousHash = lastChangeHash,
            vectorClock = vectorClock.toMap(),
            data = entityData
        )

        // Serialize and compute checksum
        val payloadJson = json.encodeToString(payload)
        val checksum = ChecksumUtil.computeChecksum(payloadJson)

        // Create envelope
        val envelope = IntegrityEnvelope(checksum = checksum)
        val record = ChangeRecord(envelope = envelope, payload = payload)

        // Generate filename
        val filename = formatFilename(sequence, timestamp, entityType, operation)
        val changesDir = "${SyncConstants.CHANGES_DIR}/$deviceId"
        val filePath = "$changesDir/$filename"

        // Write change file
        val recordJson = json.encodeToString(record)
        storage.writeFile(recordJson.toByteArray(Charsets.UTF_8), filePath)

        // Update manifest
        updateManifest(sequence, filename, checksum, recordJson.length.toLong())

        // Update last hash for chain
        lastChangeHash = checksum

        Log.d(TAG, "Recorded $operation for $entityType:$entityId (seq=$sequence)")

        sequence
    }

    /**
     * Updates the manifest file with a new change entry.
     */
    private suspend fun updateManifest(
        sequence: Long,
        filename: String,
        checksum: String,
        size: Long
    ) {
        val changesDir = "${SyncConstants.CHANGES_DIR}/$deviceId"
        val manifestPath = "$changesDir/${SyncConstants.MANIFEST_FILE}"

        // Read existing manifest or create new
        val manifest = if (storage.fileExists(manifestPath)) {
            val data = storage.readFile(manifestPath)
            json.decodeFromString<ChangeManifest>(String(data))
        } else {
            ChangeManifest(deviceId = deviceId)
        }

        // Add new entry
        val newEntry = ChangeFileEntry(
            sequence = sequence,
            filename = filename,
            checksum = checksum,
            size = size
        )

        val updatedManifest = manifest.copy(
            lastSequence = sequence,
            files = manifest.files + newEntry
        )

        // Write updated manifest
        val manifestJson = json.encodeToString(updatedManifest)
        storage.writeFile(manifestJson.toByteArray(Charsets.UTF_8), manifestPath)
    }

    /**
     * Formats a change filename.
     *
     * Format: {sequence:06d}-{timestamp}-{entityType}-{operation}.json
     */
    private fun formatFilename(
        sequence: Long,
        timestamp: Long,
        entityType: SyncEntityType,
        operation: SyncOperation
    ): String {
        val seqStr = sequence.toString().padStart(SyncConstants.SEQUENCE_PADDING_WIDTH, '0')
        val entityStr = entityType.name.lowercase()
        val opStr = operation.name.lowercase()
        return "$seqStr-$timestamp-$entityStr-$opStr.json"
    }

    /**
     * Gets the current sequence number.
     */
    fun getCurrentSequence(): Long = currentSequence

    /**
     * Gets the current vector clock.
     */
    fun getVectorClock(): Map<String, Long> = vectorClock.toMap()
}

/**
 * Factory for creating ChangeLogWriter instances.
 */
object ChangeLogWriterFactory {
    /**
     * Creates and initializes a ChangeLogWriter.
     *
     * @param storage The sync storage backend
     * @param deviceId This device's unique identifier
     * @return Initialized writer ready for use
     */
    suspend fun create(storage: SyncStorage, deviceId: String): ChangeLogWriter {
        val writer = ChangeLogWriter(storage, deviceId)
        writer.initialize()
        return writer
    }
}
