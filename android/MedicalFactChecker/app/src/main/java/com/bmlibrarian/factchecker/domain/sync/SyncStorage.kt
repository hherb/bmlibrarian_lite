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

import java.io.Closeable

/**
 * Information about a file in sync storage.
 *
 * Provides metadata about a file without reading its contents.
 * Used for efficient directory listing and change discovery.
 *
 * @property name File name (not full path)
 * @property path Full path relative to sync root
 * @property size File size in bytes
 * @property modifiedAt Last modification timestamp (milliseconds since epoch)
 */
data class SyncFileInfo(
    val name: String,
    val path: String,
    val size: Long,
    val modifiedAt: Long
)

/**
 * Protocol for sync file storage operations.
 *
 * This interface abstracts file operations to allow different storage backends:
 * - [LocalFolderSyncStorage] for local directories (any folder-sync provider)
 * - Future: Direct cloud provider integrations if needed
 *
 * All paths are relative to the sync root directory. Implementations handle
 * translating to absolute paths for their specific backend.
 *
 * The design allows users to select ANY folder as their sync root, including:
 * - Local device storage
 * - Dropbox-synced folders
 * - Google Drive-synced folders
 * - iCloud Drive folders (on supported devices)
 * - OneDrive folders
 * - Syncthing folders
 * - Network shares (SMB/NFS)
 *
 * Thread Safety: All methods are suspend functions and implementations should
 * be thread-safe for concurrent access.
 *
 * @see <a href="doc/cross_platform/sync_protocol.md">Sync Protocol Specification</a>
 */
interface SyncStorage {
    /**
     * Lists files in a directory.
     *
     * Returns metadata for all files (not subdirectories) in the specified
     * directory. Hidden files (starting with ".") are excluded.
     *
     * @param path Path relative to sync root
     * @return List of file info objects
     * @throws SyncStorageException.DirectoryNotFound if path doesn't exist
     */
    suspend fun listFiles(path: String): List<SyncFileInfo>

    /**
     * Lists subdirectories in a directory.
     *
     * Returns names of all subdirectories (not files) in the specified
     * directory. Hidden directories are excluded.
     *
     * @param path Path relative to sync root
     * @return List of directory names (not full paths)
     * @throws SyncStorageException.DirectoryNotFound if path doesn't exist
     */
    suspend fun listDirectories(path: String): List<String>

    /**
     * Reads file contents.
     *
     * Returns the complete file contents as raw bytes.
     *
     * @param path Path relative to sync root
     * @return File data as byte array
     * @throws SyncStorageException.FileNotFound if file doesn't exist
     */
    suspend fun readFile(path: String): ByteArray

    /**
     * Writes file contents.
     *
     * Creates or overwrites a file with the specified data.
     * Parent directories are created automatically if needed.
     * Writes are atomic to prevent partial files.
     *
     * @param data Data to write
     * @param path Path relative to sync root
     * @throws SyncStorageException on failure
     */
    suspend fun writeFile(data: ByteArray, path: String)

    /**
     * Deletes a file.
     *
     * Removes the file at the specified path. No error if the file
     * doesn't exist (idempotent).
     *
     * @param path Path relative to sync root
     * @throws SyncStorageException on failure (except missing file)
     */
    suspend fun deleteFile(path: String)

    /**
     * Checks if a file exists.
     *
     * @param path Path relative to sync root
     * @return True if file exists (not directory)
     */
    suspend fun fileExists(path: String): Boolean

    /**
     * Creates a directory (including parents).
     *
     * Creates the directory and any missing parent directories.
     * No error if the directory already exists (idempotent).
     *
     * @param path Path relative to sync root
     * @throws SyncStorageException on failure
     */
    suspend fun createDirectory(path: String)

    /**
     * Moves a file to quarantine.
     *
     * Moves a corrupt or suspicious file to the quarantine directory
     * for later analysis. The file is preserved but removed from
     * normal sync processing.
     *
     * @param path Current path relative to sync root
     * @param reason Reason for quarantine (for logging/analysis)
     * @return New path in quarantine directory
     * @throws SyncStorageException on failure
     */
    suspend fun quarantineFile(path: String, reason: String): String

    /**
     * Registers for change notifications.
     *
     * Returns a token that receives callbacks when files change in the
     * storage. The callback receives the path of the changed file.
     *
     * Note: Implementations may batch or debounce notifications.
     *
     * @param callback Called when files change
     * @return A closeable token to unregister. Keep a strong reference and close when done.
     */
    suspend fun watchForChanges(callback: (String) -> Unit): Closeable
}

/**
 * Errors from sync storage operations.
 *
 * These errors cover common failure modes across all storage backends.
 * Implementations should map backend-specific errors to these types.
 */
sealed class SyncStorageException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** File not found at the specified path. */
    class FileNotFound(val path: String) : SyncStorageException("File not found: $path")

    /** Directory not found at the specified path. */
    class DirectoryNotFound(val path: String) : SyncStorageException("Directory not found: $path")

    /** Permission denied for the operation. */
    class PermissionDenied(val path: String) : SyncStorageException("Permission denied: $path")

    /** Storage quota exceeded (cloud storage). */
    class QuotaExceeded : SyncStorageException("Storage quota exceeded")

    /** Network unavailable (cloud storage). */
    class NetworkUnavailable : SyncStorageException("Network unavailable")

    /** General I/O error with details. */
    class IOError(message: String, cause: Throwable? = null) : SyncStorageException("I/O error: $message", cause)
}
