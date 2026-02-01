// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation

// MARK: - File Info

/// Information about a file in sync storage.
///
/// Provides metadata about a file without reading its contents.
/// Used for efficient directory listing and change discovery.
public struct SyncFileInfo: Sendable, Equatable {
    /// File name (not full path).
    public let name: String

    /// Full path relative to sync root.
    public let path: String

    /// File size in bytes.
    public let size: Int

    /// Last modification date.
    public let modifiedAt: Date

    /// Creates file info.
    ///
    /// - Parameters:
    ///   - name: File name without path.
    ///   - path: Full path relative to sync root.
    ///   - size: File size in bytes.
    ///   - modifiedAt: Last modification timestamp.
    public init(name: String, path: String, size: Int, modifiedAt: Date) {
        self.name = name
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

// MARK: - Storage Protocol

/// Protocol for sync file storage operations.
///
/// This protocol abstracts file operations to allow different storage backends:
/// - `LocalFolderSyncStorage` for local directories (testing, LAN sync)
/// - `iCloudSyncStorage` for iCloud Drive (Phase 3)
/// - Future: Dropbox, Google Drive, etc.
///
/// All paths are relative to the sync root directory. Implementations handle
/// translating to absolute paths for their specific backend.
///
/// Thread Safety: All methods are async and implementations should be thread-safe.
/// The `Sendable` requirement ensures safe use across concurrent contexts.
public protocol SyncStorageProtocol: Sendable {
    /// Lists files in a directory.
    ///
    /// Returns metadata for all files (not subdirectories) in the specified
    /// directory. Hidden files (starting with ".") are excluded.
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Returns: Array of file info objects.
    /// - Throws: `SyncStorageError.directoryNotFound` if path doesn't exist.
    func listFiles(at path: String) async throws -> [SyncFileInfo]

    /// Lists subdirectories in a directory.
    ///
    /// Returns names of all subdirectories (not files) in the specified
    /// directory. Hidden directories are excluded.
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Returns: Array of directory names (not full paths).
    /// - Throws: `SyncStorageError.directoryNotFound` if path doesn't exist.
    func listDirectories(at path: String) async throws -> [String]

    /// Reads file contents.
    ///
    /// Returns the complete file contents as raw bytes.
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Returns: File data.
    /// - Throws: `SyncStorageError.fileNotFound` if file doesn't exist.
    func readFile(at path: String) async throws -> Data

    /// Writes file contents.
    ///
    /// Creates or overwrites a file with the specified data.
    /// Parent directories are created automatically if needed.
    /// Writes are atomic to prevent partial files.
    ///
    /// - Parameters:
    ///   - data: Data to write.
    ///   - path: Path relative to sync root.
    /// - Throws: `SyncStorageError` on failure.
    func writeFile(_ data: Data, at path: String) async throws

    /// Deletes a file.
    ///
    /// Removes the file at the specified path. No error if the file
    /// doesn't exist (idempotent).
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Throws: `SyncStorageError` on failure (except missing file).
    func deleteFile(at path: String) async throws

    /// Checks if a file exists.
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Returns: True if file exists (not directory).
    func fileExists(at path: String) async -> Bool

    /// Creates a directory (including parents).
    ///
    /// Creates the directory and any missing parent directories.
    /// No error if the directory already exists (idempotent).
    ///
    /// - Parameter path: Path relative to sync root.
    /// - Throws: `SyncStorageError` on failure.
    func createDirectory(at path: String) async throws

    /// Moves a file to quarantine.
    ///
    /// Moves a corrupt or suspicious file to the quarantine directory
    /// for later analysis. The file is preserved but removed from
    /// normal sync processing.
    ///
    /// - Parameters:
    ///   - path: Current path relative to sync root.
    ///   - reason: Reason for quarantine (for logging/analysis).
    /// - Returns: New path in quarantine directory.
    /// - Throws: `SyncStorageError` on failure.
    func quarantineFile(at path: String, reason: String) async throws -> String

    /// Registers for change notifications.
    ///
    /// Returns a token that receives callbacks when files change in the
    /// storage. The callback receives the path of the changed file.
    ///
    /// Note: Implementations may batch or debounce notifications.
    ///
    /// - Parameter callback: Called when files change.
    /// - Returns: A token to unregister. Keep a strong reference.
    func watchForChanges(
        _ callback: @escaping @Sendable (String) -> Void
    ) async -> Any
}

// MARK: - Storage Errors

/// Errors from sync storage operations.
///
/// These errors cover common failure modes across all storage backends.
/// Implementations should map backend-specific errors to these types.
public enum SyncStorageError: Error, LocalizedError, Sendable {
    /// File not found at the specified path.
    case fileNotFound(String)

    /// Directory not found at the specified path.
    case directoryNotFound(String)

    /// Permission denied for the operation.
    case permissionDenied(String)

    /// Storage quota exceeded (cloud storage).
    case quotaExceeded

    /// Network unavailable (cloud storage).
    case networkUnavailable

    /// General I/O error with details.
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .quotaExceeded:
            return "Storage quota exceeded"
        case .networkUnavailable:
            return "Network unavailable"
        case .ioError(let message):
            return "I/O error: \(message)"
        }
    }
}
