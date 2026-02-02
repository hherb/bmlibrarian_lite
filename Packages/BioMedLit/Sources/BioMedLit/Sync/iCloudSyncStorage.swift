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
import os.log

// MARK: - iCloud Sync Storage

/// Sync storage backed by iCloud Drive.
///
/// Uses the ubiquitous container for cross-device synchronization between
/// Apple devices. Files are automatically synced by iOS/macOS when the
/// device has network connectivity.
///
/// ## Requirements
///
/// - iCloud Drive entitlement in the app
/// - Container identifier configured in entitlements
/// - User must be signed into iCloud
///
/// ## File Coordination
///
/// All file operations use NSFileCoordinator to ensure proper handling
/// of iCloud file states (downloading, uploading, conflicts).
///
/// ## Example Usage
///
/// ```swift
/// guard iCloudSyncStorage.isAvailable() else {
///     throw SyncStorageError.networkUnavailable
/// }
/// let storage = try iCloudSyncStorage()
/// ```
public actor iCloudSyncStorage: SyncStorageProtocol {

    // MARK: - Properties

    /// URL of the iCloud container with sync root appended.
    private let containerURL: URL

    /// File manager for file operations.
    private let fileManager = FileManager.default

    /// File coordinator for iCloud-safe file operations.
    private let coordinator = NSFileCoordinator()

    /// Logger for iCloud operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "iCloudSyncStorage"
    )

    // MARK: - Initialization

    /// Creates iCloud Drive storage.
    ///
    /// Locates the ubiquitous container and creates the sync root directory
    /// if it doesn't exist.
    ///
    /// - Parameter containerIdentifier: iCloud container identifier.
    ///   Pass nil to use the first available container.
    /// - Throws: `SyncStorageError.networkUnavailable` if iCloud is not available.
    public init(containerIdentifier: String? = nil) throws {
        guard let ubiquityURL = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else {
            throw SyncStorageError.networkUnavailable
        }

        self.containerURL = ubiquityURL.appendingPathComponent(
            SyncConstants.syncRootDirectory,
            isDirectory: true
        )

        // Ensure sync root directory exists
        if !FileManager.default.fileExists(atPath: containerURL.path) {
            try FileManager.default.createDirectory(
                at: containerURL,
                withIntermediateDirectories: true
            )
        }

        logger.info("iCloud storage initialized at: \(self.containerURL.path)")
    }

    // MARK: - Path Resolution

    /// Resolves a relative path to a full iCloud URL.
    ///
    /// - Parameter path: Path relative to the sync root.
    /// - Returns: Full URL in the iCloud container.
    private func resolve(_ path: String) -> URL {
        if path.isEmpty {
            return containerURL
        }
        return containerURL.appendingPathComponent(path)
    }

    // MARK: - SyncStorageProtocol Implementation

    public func listFiles(at path: String) async throws -> [SyncFileInfo] {
        let url = resolve(path)

        return try await withCheckedThrowingContinuation { continuation in
            var coordinatorError: NSError?

            coordinator.coordinate(
                readingItemAt: url,
                options: [],
                error: &coordinatorError
            ) { coordinatedURL in
                do {
                    guard fileManager.fileExists(atPath: coordinatedURL.path) else {
                        continuation.resume(throwing: SyncStorageError.directoryNotFound(path))
                        return
                    }

                    let contents = try fileManager.contentsOfDirectory(
                        at: coordinatedURL,
                        includingPropertiesForKeys: [
                            .fileSizeKey,
                            .contentModificationDateKey,
                            .isDirectoryKey
                        ],
                        options: [.skipsHiddenFiles]
                    )

                    let files = try contents.compactMap { itemURL -> SyncFileInfo? in
                        let resourceValues = try itemURL.resourceValues(
                            forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
                        )

                        // Skip directories
                        if resourceValues.isDirectory == true {
                            return nil
                        }

                        let relativePath = path.isEmpty
                            ? itemURL.lastPathComponent
                            : "\(path)/\(itemURL.lastPathComponent)"

                        return SyncFileInfo(
                            name: itemURL.lastPathComponent,
                            path: relativePath,
                            size: resourceValues.fileSize ?? 0,
                            modifiedAt: resourceValues.contentModificationDate ?? Date()
                        )
                    }

                    continuation.resume(returning: files)
                } catch {
                    continuation.resume(
                        throwing: SyncStorageError.ioError(error.localizedDescription)
                    )
                }
            }

            if let error = coordinatorError {
                continuation.resume(
                    throwing: SyncStorageError.ioError(error.localizedDescription)
                )
            }
        }
    }

    public func listDirectories(at path: String) async throws -> [String] {
        let url = resolve(path)

        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        return try await withCheckedThrowingContinuation { continuation in
            var coordinatorError: NSError?

            coordinator.coordinate(
                readingItemAt: url,
                options: [],
                error: &coordinatorError
            ) { coordinatedURL in
                do {
                    let contents = try fileManager.contentsOfDirectory(
                        at: coordinatedURL,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )

                    let directories = try contents.compactMap { itemURL -> String? in
                        let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
                        return resourceValues.isDirectory == true ? itemURL.lastPathComponent : nil
                    }

                    continuation.resume(returning: directories)
                } catch {
                    continuation.resume(
                        throwing: SyncStorageError.ioError(error.localizedDescription)
                    )
                }
            }

            if let error = coordinatorError {
                continuation.resume(
                    throwing: SyncStorageError.ioError(error.localizedDescription)
                )
            }
        }
    }

    public func readFile(at path: String) async throws -> Data {
        let url = resolve(path)

        // Start downloading if file is not locally available
        try startDownloadingIfNeeded(at: url)

        // Wait for download to complete
        try await waitForDownload(at: url)

        return try await withCheckedThrowingContinuation { continuation in
            var coordinatorError: NSError?

            coordinator.coordinate(
                readingItemAt: url,
                options: [],
                error: &coordinatorError
            ) { coordinatedURL in
                do {
                    let data = try Data(contentsOf: coordinatedURL)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: SyncStorageError.fileNotFound(path))
                }
            }

            if let error = coordinatorError {
                continuation.resume(
                    throwing: SyncStorageError.ioError(error.localizedDescription)
                )
            }
        }
    }

    public func writeFile(_ data: Data, at path: String) async throws {
        let url = resolve(path)

        // Ensure parent directory exists
        let parentURL = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var coordinatorError: NSError?

            coordinator.coordinate(
                writingItemAt: url,
                options: .forReplacing,
                error: &coordinatorError
            ) { coordinatedURL in
                do {
                    try data.write(to: coordinatedURL, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(
                        throwing: SyncStorageError.ioError(error.localizedDescription)
                    )
                }
            }

            if let error = coordinatorError {
                continuation.resume(
                    throwing: SyncStorageError.ioError(error.localizedDescription)
                )
            }
        }
    }

    public func deleteFile(at path: String) async throws {
        let url = resolve(path)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var coordinatorError: NSError?

            coordinator.coordinate(
                writingItemAt: url,
                options: .forDeleting,
                error: &coordinatorError
            ) { coordinatedURL in
                do {
                    try fileManager.removeItem(at: coordinatedURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: SyncStorageError.fileNotFound(path))
                }
            }

            if let error = coordinatorError {
                continuation.resume(
                    throwing: SyncStorageError.ioError(error.localizedDescription)
                )
            }
        }
    }

    public func fileExists(at path: String) async -> Bool {
        fileManager.fileExists(atPath: resolve(path).path)
    }

    public func createDirectory(at path: String) async throws {
        let url = resolve(path)
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    public func quarantineFile(at path: String, reason: String) async throws -> String {
        let sourceURL = resolve(path)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeName = sourceURL.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let quarantinePath = "\(SyncConstants.quarantineDirectory)/\(timestamp)_\(safeName)"
        let quarantineURL = resolve(quarantinePath)

        // Ensure quarantine directory exists
        try await createDirectory(at: SyncConstants.quarantineDirectory)

        // Move file to quarantine
        try fileManager.moveItem(at: sourceURL, to: quarantineURL)

        // Write reason file
        let reasonPath = "\(quarantinePath).reason.txt"
        let reasonURL = resolve(reasonPath)
        try reason.data(using: .utf8)?.write(to: reasonURL)

        logger.info("Quarantined file: \(path) -> \(quarantinePath), reason: \(reason)")

        return quarantinePath
    }

    public func watchForChanges(
        _ callback: @escaping @Sendable (String) -> Void
    ) async -> Any {
        // Use NSMetadataQuery to watch for iCloud changes
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)

        // Observe query updates
        let observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [containerPath = containerURL.path] _ in
            callback(containerPath)
        }

        query.start()

        logger.info("Started watching for iCloud changes")

        // Return both query and observer so they can be cleaned up
        return (query, observer) as Any
    }

    // MARK: - iCloud-Specific Methods

    /// Triggers download of a file if it's not locally available.
    ///
    /// - Parameter url: URL of the file to download.
    private func startDownloadingIfNeeded(at url: URL) throws {
        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            // File might already be downloaded or doesn't need download
            logger.debug("Could not start download for \(url.path): \(error.localizedDescription)")
        }
    }

    /// Waits for a file to finish downloading from iCloud.
    ///
    /// - Parameter url: URL of the file to wait for.
    /// - Throws: `SyncStorageError.ioError` if download times out.
    private func waitForDownload(at url: URL) async throws {
        let timeoutSeconds = SyncConstants.iCloudDownloadTimeoutSeconds

        for _ in 0..<timeoutSeconds {
            do {
                let resourceValues = try url.resourceValues(
                    forKeys: [.ubiquitousItemDownloadingStatusKey]
                )

                if resourceValues.ubiquitousItemDownloadingStatus == .current {
                    return
                }
            } catch {
                // Resource values might not be available, check if file exists
                if fileManager.fileExists(atPath: url.path) {
                    return
                }
            }

            // Wait before checking again
            try await Task.sleep(nanoseconds: BioMedLitConstants.iCloudPollingIntervalNanoseconds)
        }

        // Timeout - check if file exists anyway
        if !fileManager.fileExists(atPath: url.path) {
            throw SyncStorageError.ioError(
                "Download timeout after \(timeoutSeconds) seconds for: \(url.lastPathComponent)"
            )
        }
    }

    // MARK: - Static Methods

    /// Checks if iCloud is available on this device.
    ///
    /// - Returns: True if the user is signed into iCloud and it's enabled.
    public static func isAvailable() -> Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Gets the current iCloud account identifier.
    ///
    /// Can be used to detect account changes.
    ///
    /// - Returns: Opaque token representing the iCloud account, or nil.
    public static func currentAccountToken() -> (NSCoding & NSCopying & NSObjectProtocol)? {
        FileManager.default.ubiquityIdentityToken
    }
}

// MARK: - iCloud Account Observer

/// Observes changes to the iCloud account status.
///
/// Use this to detect when the user signs in/out of iCloud or switches accounts.
public final class iCloudAccountObserver: Sendable {

    /// Callback type for account changes.
    public typealias AccountChangeCallback = @Sendable () -> Void

    /// The callback to invoke when account changes.
    private let callback: AccountChangeCallback

    /// Notification observer token.
    private let observer: NSObjectProtocol

    /// Creates an iCloud account observer.
    ///
    /// - Parameter callback: Called when the iCloud account changes.
    public init(callback: @escaping AccountChangeCallback) {
        self.callback = callback
        self.observer = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            callback()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
    }
}
