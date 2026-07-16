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

/// Sync storage backed by a local file system directory.
///
/// This implementation is useful for:
/// - Unit and integration testing
/// - LAN sync via shared network folders
/// - Debugging sync issues locally
/// - Development without cloud dependencies
///
/// Thread Safety: This class is an actor, providing automatic isolation
/// for all mutable state. All methods can be called safely from any context.
///
/// Example:
/// ```swift
/// let storage = try LocalFolderSyncStorage(
///     rootURL: URL(fileURLWithPath: "/path/to/sync")
/// )
/// try await storage.writeFile(data, at: "changes/device1/000001.json")
/// let files = try await storage.listFiles(at: "changes/device1")
/// ```
public actor LocalFolderSyncStorage: SyncStorageProtocol {
    // MARK: - Properties

    /// Root directory for sync files.
    private let rootURL: URL

    /// File manager instance (thread-safe for read operations).
    private let fileManager = FileManager.default

    /// ISO8601 date formatter for quarantine timestamps.
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Initialization

    /// Creates local folder storage.
    ///
    /// Creates the root directory if it doesn't exist.
    ///
    /// - Parameter rootURL: Root directory for sync files.
    /// - Throws: `SyncStorageError.ioError` if directory cannot be created.
    public init(rootURL: URL) throws {
        self.rootURL = rootURL

        // Ensure root exists
        if !FileManager.default.fileExists(atPath: rootURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw SyncStorageError.ioError(
                    "Failed to create sync root: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Private Helpers

    /// Resolves a relative path to a full URL.
    ///
    /// - Parameter path: Relative path from sync root.
    /// - Returns: Absolute URL to the file or directory.
    private func resolve(_ path: String) -> URL {
        // Handle empty path
        if path.isEmpty {
            return rootURL
        }
        return rootURL.appendingPathComponent(path)
    }

    // MARK: - SyncStorageProtocol Implementation

    public func listFiles(at path: String) async throws -> [SyncFileInfo] {
        let url = resolve(path)

        // Check directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SyncStorageError.directoryNotFound(path)
        }

        // Get directory contents
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SyncStorageError.ioError(
                "Failed to list directory: \(error.localizedDescription)"
            )
        }

        // Filter to files only and extract metadata
        return try contents.compactMap { itemURL -> SyncFileInfo? in
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir)

            // Skip directories
            guard !isDir.boolValue else { return nil }

            // Get file attributes
            let resourceValues: URLResourceValues
            do {
                resourceValues = try itemURL.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
            } catch {
                throw SyncStorageError.ioError(
                    "Failed to read file attributes: \(error.localizedDescription)"
                )
            }

            return SyncFileInfo(
                name: itemURL.lastPathComponent,
                path: path.isEmpty ? itemURL.lastPathComponent : path + "/" + itemURL.lastPathComponent,
                size: resourceValues.fileSize ?? 0,
                modifiedAt: resourceValues.contentModificationDate ?? Date()
            )
        }
    }

    public func listDirectories(at path: String) async throws -> [String] {
        let url = resolve(path)

        // Return empty array if directory doesn't exist (not an error)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        // Get directory contents
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SyncStorageError.ioError(
                "Failed to list directory: \(error.localizedDescription)"
            )
        }

        // Filter to directories only
        return contents.compactMap { itemURL -> String? in
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? itemURL.lastPathComponent : nil
        }
    }

    public func readFile(at path: String) async throws -> Data {
        let url = resolve(path)

        guard fileManager.fileExists(atPath: url.path) else {
            throw SyncStorageError.fileNotFound(path)
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw SyncStorageError.ioError(
                "Failed to read file: \(error.localizedDescription)"
            )
        }
    }

    public func writeFile(_ data: Data, at path: String) async throws {
        let url = resolve(path)

        // Ensure parent directory exists
        let parentURL = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            do {
                try fileManager.createDirectory(
                    at: parentURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw SyncStorageError.ioError(
                    "Failed to create parent directory: \(error.localizedDescription)"
                )
            }
        }

        // Write atomically to prevent partial files
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SyncStorageError.ioError(
                "Failed to write file: \(error.localizedDescription)"
            )
        }
    }

    public func deleteFile(at path: String) async throws {
        let url = resolve(path)

        // Silently succeed if file doesn't exist (idempotent)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SyncStorageError.ioError(
                "Failed to delete file: \(error.localizedDescription)"
            )
        }
    }

    public func fileExists(at path: String) async -> Bool {
        // True for files and directories alike, matching the protocol
        // contract and iCloudSyncStorage — sync callers probe change-log
        // directories as well as individual files.
        fileManager.fileExists(atPath: resolve(path).path)
    }

    public func createDirectory(at path: String) async throws {
        let url = resolve(path)

        // Silently succeed if already exists (idempotent)
        if fileManager.fileExists(atPath: url.path) {
            return
        }

        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw SyncStorageError.ioError(
                "Failed to create directory: \(error.localizedDescription)"
            )
        }
    }

    public func quarantineFile(at path: String, reason: String) async throws -> String {
        let sourceURL = resolve(path)

        // Check source exists
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw SyncStorageError.fileNotFound(path)
        }

        // Generate quarantine path with timestamp
        let timestamp = dateFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-") // Windows-safe
        let quarantinePath = "\(SyncConstants.quarantineDirectory)/\(timestamp)_\(sourceURL.lastPathComponent)"
        let quarantineURL = resolve(quarantinePath)

        // Ensure quarantine directory exists
        try await createDirectory(at: SyncConstants.quarantineDirectory)

        // Move file to quarantine
        do {
            try fileManager.moveItem(at: sourceURL, to: quarantineURL)
        } catch {
            throw SyncStorageError.ioError(
                "Failed to quarantine file: \(error.localizedDescription)"
            )
        }

        // Write reason file for analysis
        let reasonPath = quarantinePath + ".reason.txt"
        let reasonContent = """
            Quarantine Reason: \(reason)
            Original Path: \(path)
            Quarantined At: \(Date())
            """
        if let reasonData = reasonContent.data(using: .utf8) {
            try await writeFile(reasonData, at: reasonPath)
        }

        return quarantinePath
    }

    public func watchForChanges(
        _ callback: @escaping @Sendable (String) -> Void
    ) async -> Any {
        // For local folders, use DispatchSource for file monitoring.
        // Note: This is a simplified implementation that monitors the root.
        // A production implementation would use FSEvents on macOS for
        // recursive monitoring.

        let descriptor = open(rootURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Return a no-op token if we can't open the directory
            return NSObject()
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .global(qos: .utility)
        )

        let rootPath = rootURL.path
        source.setEventHandler {
            callback(rootPath)
        }

        source.setCancelHandler {
            close(descriptor)
        }

        source.resume()
        return source
    }

    // MARK: - Additional Convenience Methods

    /// Gets the absolute path to the sync root.
    ///
    /// Useful for debugging and logging.
    public var rootPath: String {
        rootURL.path
    }

    /// Checks if the storage root exists and is accessible.
    ///
    /// - Returns: True if the root directory exists and is readable.
    public func isAccessible() -> Bool {
        fileManager.isReadableFile(atPath: rootURL.path)
    }
}
