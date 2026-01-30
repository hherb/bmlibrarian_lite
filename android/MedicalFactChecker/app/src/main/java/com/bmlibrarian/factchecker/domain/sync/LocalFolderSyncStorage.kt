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

import android.net.Uri
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Local folder-based sync storage implementation.
 *
 * Works with any user-selected folder, enabling sync via:
 * - Dropbox, Google Drive, iCloud, OneDrive (folder sync)
 * - Syncthing (P2P sync)
 * - Network shares (SMB/NFS)
 * - Local device storage (no sync)
 *
 * All file operations are performed on the IO dispatcher for proper threading.
 * Writes are atomic (write to temp file, then rename) to prevent corruption.
 *
 * @property rootPath Absolute path to the sync root folder
 *
 * @see <a href="doc/cross_platform/sync_protocol.md">Sync Protocol Specification</a>
 */
class LocalFolderSyncStorage(
    private val rootPath: String
) : SyncStorage {

    companion object {
        private const val TAG = "LocalFolderSyncStorage"
        private const val TEMP_FILE_PREFIX = ".tmp_"
    }

    private val rootFile = File(rootPath)

    init {
        require(rootPath.isNotBlank()) { "Root path cannot be blank" }
    }

    /**
     * Resolves a relative path to an absolute File.
     */
    private fun resolvePath(relativePath: String): File {
        val normalizedPath = relativePath.trimStart('/')
        return if (normalizedPath.isEmpty()) {
            rootFile
        } else {
            File(rootFile, normalizedPath)
        }
    }

    override suspend fun listFiles(path: String): List<SyncFileInfo> = withContext(Dispatchers.IO) {
        val dir = resolvePath(path)

        if (!dir.exists()) {
            throw SyncStorageException.DirectoryNotFound(path)
        }

        if (!dir.isDirectory) {
            throw SyncStorageException.DirectoryNotFound("$path is not a directory")
        }

        try {
            dir.listFiles()
                ?.filter { it.isFile && !it.name.startsWith(".") }
                ?.map { file ->
                    SyncFileInfo(
                        name = file.name,
                        path = file.relativeTo(rootFile).path,
                        size = file.length(),
                        modifiedAt = file.lastModified()
                    )
                }
                ?.sortedByDescending { it.modifiedAt }
                ?: emptyList()
        } catch (e: SecurityException) {
            throw SyncStorageException.PermissionDenied(path)
        }
    }

    override suspend fun listDirectories(path: String): List<String> = withContext(Dispatchers.IO) {
        val dir = resolvePath(path)

        if (!dir.exists()) {
            throw SyncStorageException.DirectoryNotFound(path)
        }

        if (!dir.isDirectory) {
            throw SyncStorageException.DirectoryNotFound("$path is not a directory")
        }

        try {
            dir.listFiles()
                ?.filter { it.isDirectory && !it.name.startsWith(".") }
                ?.map { it.name }
                ?.sorted()
                ?: emptyList()
        } catch (e: SecurityException) {
            throw SyncStorageException.PermissionDenied(path)
        }
    }

    override suspend fun readFile(path: String): ByteArray = withContext(Dispatchers.IO) {
        val file = resolvePath(path)

        if (!file.exists()) {
            throw SyncStorageException.FileNotFound(path)
        }

        if (!file.isFile) {
            throw SyncStorageException.FileNotFound("$path is not a file")
        }

        try {
            file.readBytes()
        } catch (e: SecurityException) {
            throw SyncStorageException.PermissionDenied(path)
        } catch (e: IOException) {
            throw SyncStorageException.IOError("Failed to read $path", e)
        }
    }

    override suspend fun writeFile(data: ByteArray, path: String) = withContext(Dispatchers.IO) {
        val file = resolvePath(path)

        try {
            // Ensure parent directories exist
            file.parentFile?.let { parent ->
                if (!parent.exists()) {
                    if (!parent.mkdirs()) {
                        throw SyncStorageException.IOError("Failed to create directory: ${parent.path}")
                    }
                }
            }

            // Atomic write: write to temp file, then rename
            val tempFile = File(file.parentFile, "$TEMP_FILE_PREFIX${file.name}")
            try {
                tempFile.writeBytes(data)

                // Rename temp file to final destination
                if (!tempFile.renameTo(file)) {
                    // Fallback: copy and delete if rename fails (cross-filesystem)
                    tempFile.copyTo(file, overwrite = true)
                    tempFile.delete()
                }

                Log.d(TAG, "Wrote ${data.size} bytes to $path")
            } catch (e: Exception) {
                // Clean up temp file on failure
                tempFile.delete()
                throw e
            }
        } catch (e: SecurityException) {
            throw SyncStorageException.PermissionDenied(path)
        } catch (e: SyncStorageException) {
            throw e
        } catch (e: IOException) {
            throw SyncStorageException.IOError("Failed to write $path", e)
        }
    }

    override suspend fun deleteFile(path: String) = withContext(Dispatchers.IO) {
        val file = resolvePath(path)

        if (!file.exists()) {
            // Idempotent: no error if file doesn't exist
            Log.d(TAG, "Delete ignored (file not found): $path")
            return@withContext
        }

        try {
            if (file.isFile) {
                if (!file.delete()) {
                    throw SyncStorageException.IOError("Failed to delete $path")
                }
                Log.d(TAG, "Deleted file: $path")
            }
        } catch (e: SecurityException) {
            throw SyncStorageException.PermissionDenied(path)
        }
    }

    override suspend fun fileExists(path: String): Boolean = withContext(Dispatchers.IO) {
        val file = resolvePath(path)
        file.exists() && file.isFile
    }

    override suspend fun createDirectory(path: String) = withContext(Dispatchers.IO) {
        val dir = resolvePath(path)

        if (dir.exists()) {
            if (!dir.isDirectory) {
                throw SyncStorageException.IOError("$path exists but is not a directory")
            }
            // Already exists as directory - idempotent success
            return@withContext
        }

        try {
            if (!dir.mkdirs()) {
                throw SyncStorageException.IOError("Failed to create directory: $path")
            }
            Log.d(TAG, "Created directory: $path")
        } catch (e: SecurityException) {
            throw SyncStorageException.PermissionDenied(path)
        }
    }

    override suspend fun quarantineFile(path: String, reason: String): String = withContext(Dispatchers.IO) {
        val file = resolvePath(path)

        if (!file.exists()) {
            throw SyncStorageException.FileNotFound(path)
        }

        try {
            // Create quarantine directory
            val quarantineDir = resolvePath(SyncConstants.QUARANTINE_DIR)
            if (!quarantineDir.exists()) {
                quarantineDir.mkdirs()
            }

            // Generate quarantine filename with timestamp
            val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH-mm-ss", Locale.US)
            val timestamp = dateFormat.format(Date())
            val quarantineName = "${timestamp}_${file.name}"
            val quarantineFile = File(quarantineDir, quarantineName)

            // Move file to quarantine
            if (!file.renameTo(quarantineFile)) {
                file.copyTo(quarantineFile, overwrite = true)
                file.delete()
            }

            val quarantinePath = "${SyncConstants.QUARANTINE_DIR}/$quarantineName"
            Log.w(TAG, "Quarantined $path -> $quarantinePath (reason: $reason)")

            quarantinePath
        } catch (e: SecurityException) {
            throw SyncStorageException.PermissionDenied(path)
        } catch (e: IOException) {
            throw SyncStorageException.IOError("Failed to quarantine $path", e)
        }
    }

    override suspend fun watchForChanges(callback: (String) -> Unit): Closeable {
        // Note: Android doesn't have a built-in recursive file watcher like iOS/macOS.
        // For production, consider using FileObserver (limited) or polling.
        // This implementation provides a manual trigger mechanism.

        val isActive = AtomicBoolean(true)

        Log.d(TAG, "File watching registered for $rootPath")

        return object : Closeable {
            override fun close() {
                isActive.set(false)
                Log.d(TAG, "File watching stopped for $rootPath")
            }
        }
    }

    /**
     * Checks if the sync root folder is accessible.
     *
     * @return true if the folder exists and is readable/writable
     */
    suspend fun isAccessible(): Boolean = withContext(Dispatchers.IO) {
        try {
            rootFile.exists() && rootFile.isDirectory && rootFile.canRead() && rootFile.canWrite()
        } catch (e: SecurityException) {
            false
        }
    }

    /**
     * Gets the total size of all files in the sync folder.
     *
     * @return Total size in bytes
     */
    suspend fun getTotalSize(): Long = withContext(Dispatchers.IO) {
        try {
            rootFile.walkTopDown()
                .filter { it.isFile }
                .sumOf { it.length() }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to calculate total size", e)
            0L
        }
    }

    /**
     * Gets the number of files in the sync folder.
     *
     * @return File count
     */
    suspend fun getFileCount(): Int = withContext(Dispatchers.IO) {
        try {
            rootFile.walkTopDown()
                .filter { it.isFile && !it.name.startsWith(".") }
                .count()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to count files", e)
            0
        }
    }
}

/**
 * Factory for creating LocalFolderSyncStorage instances.
 *
 * Validates the folder path and checks accessibility before creating storage.
 */
object LocalFolderSyncStorageFactory {
    /**
     * Creates a LocalFolderSyncStorage for the given path.
     *
     * @param path Absolute path to the sync folder
     * @return Storage instance
     * @throws IllegalArgumentException if path is invalid
     * @throws SyncStorageException.PermissionDenied if folder is not accessible
     */
    suspend fun create(path: String): LocalFolderSyncStorage = withContext(Dispatchers.IO) {
        val file = File(path)

        if (!file.exists()) {
            // Try to create the folder
            if (!file.mkdirs()) {
                throw SyncStorageException.IOError("Cannot create sync folder: $path")
            }
        }

        if (!file.isDirectory) {
            throw IllegalArgumentException("Path is not a directory: $path")
        }

        if (!file.canRead() || !file.canWrite()) {
            throw SyncStorageException.PermissionDenied(path)
        }

        LocalFolderSyncStorage(path)
    }

    /**
     * Creates a LocalFolderSyncStorage from a content URI.
     *
     * For use with Storage Access Framework (SAF) document trees.
     * Note: SAF URIs require special handling - this is a placeholder for
     * future implementation using DocumentFile API.
     *
     * @param uri Content URI from SAF folder picker
     * @return Storage instance
     */
    fun createFromUri(uri: Uri): LocalFolderSyncStorage {
        // For SAF URIs, we need to use DocumentFile API instead of java.io.File.
        // This is a placeholder - full SAF support would require a separate
        // DocumentFileSyncStorage implementation.
        throw UnsupportedOperationException(
            "SAF URI support not yet implemented. Use a direct file path instead."
        )
    }
}
