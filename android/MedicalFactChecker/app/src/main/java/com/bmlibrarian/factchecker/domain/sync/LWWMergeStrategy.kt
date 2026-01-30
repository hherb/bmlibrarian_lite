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

/**
 * Last-Write-Wins (LWW) merge strategy for conflict resolution.
 *
 * When two devices modify the same entity, LWW determines which version wins:
 * 1. The change with the later timestamp wins
 * 2. If timestamps are equal, the higher device ID wins (lexicographic)
 *
 * This ensures all devices converge to the same state deterministically,
 * without requiring coordination or consensus protocols.
 *
 * Key properties:
 * - Deterministic: All devices make the same decision given the same inputs
 * - Commutative: Order of applying changes doesn't matter
 * - Idempotent: Applying the same change twice has no additional effect
 *
 * @see <a href="doc/cross_platform/sync_protocol.md">Sync Protocol Specification</a>
 */
object LWWMergeStrategy {

    /**
     * Versioned value for merge comparison.
     *
     * @property timestamp When the value was written (milliseconds since epoch)
     * @property deviceId Which device wrote the value
     */
    data class Version(
        val timestamp: Long,
        val deviceId: String
    )

    /**
     * Determines if a remote change should be applied over a local value.
     *
     * @param remote The remote change's version
     * @param local The local value's version (null if entity doesn't exist locally)
     * @return true if the remote change should be applied
     */
    fun shouldApplyRemote(remote: Version, local: Version?): Boolean {
        // If no local version exists, always apply remote
        if (local == null) {
            return true
        }

        // Later timestamp wins
        if (remote.timestamp > local.timestamp) {
            return true
        }

        // Earlier timestamp loses
        if (remote.timestamp < local.timestamp) {
            return false
        }

        // Equal timestamps: use device ID as tiebreaker (lexicographically higher wins)
        // This is arbitrary but deterministic - all devices will make the same choice
        return remote.deviceId > local.deviceId
    }

    /**
     * Merges two versions and returns the winning version.
     *
     * @param a First version
     * @param b Second version
     * @return The winning version
     */
    fun merge(a: Version, b: Version): Version {
        return if (shouldApplyRemote(a, b)) a else b
    }

    /**
     * Determines if a delete should be applied.
     *
     * For deletes, we need to consider:
     * - If entity doesn't exist locally, ignore the delete
     * - If entity exists, apply LWW between delete timestamp and entity's timestamp
     *
     * @param deleteVersion Version of the delete operation
     * @param entityVersion Version of the existing entity (null if doesn't exist)
     * @return true if the delete should be applied
     */
    fun shouldApplyDelete(deleteVersion: Version, entityVersion: Version?): Boolean {
        // Can't delete what doesn't exist
        if (entityVersion == null) {
            return false
        }

        // Apply same LWW logic
        return shouldApplyRemote(deleteVersion, entityVersion)
    }

    /**
     * Merges field-level changes.
     *
     * For entities with independently-updatable fields, each field can be
     * merged separately with its own timestamp.
     *
     * @param T The field value type
     * @param remoteValue The remote field value
     * @param remoteVersion Version of the remote change
     * @param localValue The local field value
     * @param localVersion Version of the local value
     * @return Pair of (winning value, winning version)
     */
    fun <T> mergeField(
        remoteValue: T,
        remoteVersion: Version,
        localValue: T,
        localVersion: Version?
    ): Pair<T, Version> {
        return if (shouldApplyRemote(remoteVersion, localVersion)) {
            remoteValue to remoteVersion
        } else {
            localValue to (localVersion ?: remoteVersion)
        }
    }
}

/**
 * Extension function to create a Version from a ChangePayload.
 */
fun ChangePayload.toVersion(): LWWMergeStrategy.Version {
    return LWWMergeStrategy.Version(
        timestamp = this.timestamp,
        deviceId = this.deviceId
    )
}

/**
 * Tracks per-entity version information for merge decisions.
 *
 * Stored alongside entities in the local database to support LWW merging.
 */
data class EntityVersion(
    /** Entity's unique identifier. */
    val entityId: String,

    /** Entity type. */
    val entityType: SyncEntityType,

    /** Last modification timestamp. */
    val timestamp: Long,

    /** Device that last modified this entity. */
    val deviceId: String,

    /** Whether this entity has been deleted. */
    val isDeleted: Boolean = false
) {
    fun toVersion(): LWWMergeStrategy.Version {
        return LWWMergeStrategy.Version(timestamp, deviceId)
    }
}
