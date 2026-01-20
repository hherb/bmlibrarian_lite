import Foundation

// MARK: - File Naming Utilities

/// Pure functions for sync file naming conventions.
///
/// All sync files follow consistent naming patterns that encode useful metadata
/// in the filename itself. This allows for efficient file discovery and filtering
/// without reading file contents.
///
/// ## File Name Format
/// Change files: `{sequence}_{timestamp}_{entity}_{operation}.json`
/// Example: `000142_1705772400000_session_upsert.json`
///
/// ## Design Rationale
/// - Zero-padded sequence ensures lexicographic sorting matches numeric sorting
/// - Timestamp aids debugging and allows time-based filtering
/// - Entity and operation enable efficient filtering by type
/// - JSON extension indicates the file format
///
/// ## Cross-Platform Compatibility
/// File names use only ASCII characters and avoid special characters that
/// might cause issues on different file systems.
public enum SyncFileNaming {

    // MARK: - Change File Names

    /// Generates a change file name from its components.
    ///
    /// The generated name includes all metadata needed for filtering and sorting
    /// without reading file contents.
    ///
    /// ## Format
    /// `{sequence}_{timestamp}_{entity}_{operation}.json`
    ///
    /// ## Example
    /// ```swift
    /// let name = SyncFileNaming.changeFileName(
    ///     sequence: 42,
    ///     timestamp: 1705772400000,
    ///     entity: .session,
    ///     operation: .upsert
    /// )
    /// // Returns: "000042_1705772400000_session_upsert.json"
    /// ```
    ///
    /// - Parameters:
    ///   - sequence: The change's sequence number (will be zero-padded).
    ///   - timestamp: Timestamp in milliseconds since Unix epoch.
    ///   - entity: The entity type being modified.
    ///   - operation: The operation type (upsert or delete).
    /// - Returns: The formatted filename.
    public static func changeFileName(
        sequence: Int,
        timestamp: Int64,
        entity: SyncEntityType,
        operation: SyncOperationType
    ) -> String {
        let paddedSequence = String(
            format: "%0\(SyncConstants.sequenceDigits)d",
            sequence
        )
        return "\(paddedSequence)_\(timestamp)_\(entity.rawValue)_\(operation.rawValue).\(SyncConstants.syncFileExtension)"
    }

    /// Parses a change file name into its components.
    ///
    /// This is the inverse of `changeFileName`. Returns nil if the filename
    /// doesn't match the expected format.
    ///
    /// ## Example
    /// ```swift
    /// if let components = SyncFileNaming.parseChangeFileName(
    ///     "000142_1705772400000_document_delete.json"
    /// ) {
    ///     print(components.sequence)    // 142
    ///     print(components.entity)      // .document
    ///     print(components.operation)   // .delete
    /// }
    /// ```
    ///
    /// - Parameter filename: The filename to parse.
    /// - Returns: Parsed components, or nil if the filename is invalid.
    public static func parseChangeFileName(
        _ filename: String
    ) -> ChangeFileComponents? {
        // Remove the file extension
        let expectedSuffix = ".\(SyncConstants.syncFileExtension)"
        guard filename.hasSuffix(expectedSuffix) else {
            return nil
        }

        let baseName = String(filename.dropLast(expectedSuffix.count))

        // Split into parts: sequence_timestamp_entity_operation
        let parts = baseName.split(separator: "_")
        guard parts.count >= 4 else {
            return nil
        }

        // Parse each component
        guard let sequence = Int(parts[0]),
              let timestamp = Int64(parts[1]),
              let entity = SyncEntityType(rawValue: String(parts[2])),
              let operation = SyncOperationType(rawValue: String(parts[3]))
        else {
            return nil
        }

        return ChangeFileComponents(
            sequence: sequence,
            timestamp: timestamp,
            entity: entity,
            operation: operation
        )
    }

    // MARK: - Device File Names

    /// Generates a device registration file name.
    ///
    /// Device files are stored in the devices directory and contain
    /// information about registered devices in the workspace.
    ///
    /// ## Example
    /// ```swift
    /// let name = SyncFileNaming.deviceFileName(deviceId: "abc-123-def")
    /// // Returns: "abc-123-def.json"
    /// ```
    ///
    /// - Parameter deviceId: The device's unique identifier.
    /// - Returns: The device config filename.
    public static func deviceFileName(deviceId: String) -> String {
        "\(deviceId).\(SyncConstants.syncFileExtension)"
    }

    /// Extracts the device ID from a device file name.
    ///
    /// - Parameter filename: The device file name to parse.
    /// - Returns: The device ID, or nil if the filename is invalid.
    public static func parseDeviceFileName(_ filename: String) -> String? {
        let expectedSuffix = ".\(SyncConstants.syncFileExtension)"
        guard filename.hasSuffix(expectedSuffix) else {
            return nil
        }
        return String(filename.dropLast(expectedSuffix.count))
    }

    // MARK: - Snapshot File Names

    /// Generates a snapshot file name.
    ///
    /// Snapshots are compressed full-state dumps used for fast initial sync
    /// and recovery from corruption.
    ///
    /// ## Format
    /// `{timestamp}_{deviceId}.json.gz`
    ///
    /// ## Example
    /// ```swift
    /// let name = SyncFileNaming.snapshotFileName(
    ///     timestamp: "2024-01-20T12-00-00Z",
    ///     deviceId: "device-abc"
    /// )
    /// // Returns: "2024-01-20T12-00-00Z_device-abc.json.gz"
    /// ```
    ///
    /// - Parameters:
    ///   - timestamp: ISO8601-like timestamp string (colons replaced with dashes).
    ///   - deviceId: The device that created the snapshot.
    /// - Returns: The snapshot filename.
    public static func snapshotFileName(
        timestamp: String,
        deviceId: String
    ) -> String {
        "\(timestamp)_\(deviceId).\(SyncConstants.syncFileExtension).gz"
    }

    /// Generates a filesystem-safe ISO8601 timestamp string for snapshot names.
    ///
    /// Standard ISO8601 uses colons which are problematic on some file systems
    /// (especially Windows). This function replaces colons with dashes.
    ///
    /// ## Example
    /// ```swift
    /// let timestamp = SyncFileNaming.snapshotTimestamp(from: Date())
    /// // Returns something like: "2024-01-20T12-00-00Z"
    /// ```
    ///
    /// - Parameter date: The date to format. Defaults to current date.
    /// - Returns: Filesystem-safe timestamp string.
    public static func snapshotTimestamp(from date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let iso = formatter.string(from: date)
        // Replace colons with dashes for filesystem safety
        return iso.replacingOccurrences(of: ":", with: "-")
    }

    // MARK: - Path Generation

    /// Generates the relative path for a change file.
    ///
    /// Paths are relative to the sync root directory.
    ///
    /// ## Example
    /// ```swift
    /// let path = SyncFileNaming.changeFilePath(
    ///     deviceId: "device-abc",
    ///     filename: "000001_1705772400000_session_upsert.json"
    /// )
    /// // Returns: "changes/device-abc/000001_1705772400000_session_upsert.json"
    /// ```
    ///
    /// - Parameters:
    ///   - deviceId: The device identifier.
    ///   - filename: The change file name.
    /// - Returns: Full relative path from sync root.
    public static func changeFilePath(
        deviceId: String,
        filename: String
    ) -> String {
        "\(SyncConstants.changesDirectory)/\(deviceId)/\(filename)"
    }

    /// Generates the relative path for a device config file.
    ///
    /// ## Example
    /// ```swift
    /// let path = SyncFileNaming.deviceFilePath(deviceId: "device-abc")
    /// // Returns: "devices/device-abc.json"
    /// ```
    ///
    /// - Parameter deviceId: The device identifier.
    /// - Returns: Full relative path from sync root.
    public static func deviceFilePath(deviceId: String) -> String {
        "\(SyncConstants.devicesDirectory)/\(deviceFileName(deviceId: deviceId))"
    }

    /// Generates the relative path for a device's changes directory.
    ///
    /// ## Example
    /// ```swift
    /// let path = SyncFileNaming.deviceChangesDirectory(deviceId: "device-abc")
    /// // Returns: "changes/device-abc"
    /// ```
    ///
    /// - Parameter deviceId: The device identifier.
    /// - Returns: Path to the device's changes directory.
    public static func deviceChangesDirectory(deviceId: String) -> String {
        "\(SyncConstants.changesDirectory)/\(deviceId)"
    }

    /// Generates the relative path for a device's manifest file.
    ///
    /// ## Example
    /// ```swift
    /// let path = SyncFileNaming.manifestFilePath(deviceId: "device-abc")
    /// // Returns: "changes/device-abc/manifest.json"
    /// ```
    ///
    /// - Parameter deviceId: The device identifier.
    /// - Returns: Path to the device's manifest file.
    public static func manifestFilePath(deviceId: String) -> String {
        "\(SyncConstants.changesDirectory)/\(deviceId)/\(SyncConstants.manifestFile)"
    }

    /// Generates the relative path for a snapshot file.
    ///
    /// - Parameter filename: The snapshot filename.
    /// - Returns: Full relative path from sync root.
    public static func snapshotFilePath(filename: String) -> String {
        "\(SyncConstants.snapshotsDirectory)/\(filename)"
    }

    /// Generates the relative path for the quarantine directory.
    ///
    /// - Returns: Path to the quarantine directory.
    public static func quarantineDirectory() -> String {
        SyncConstants.quarantineDirectory
    }

    /// Generates a quarantine file path for a corrupt file.
    ///
    /// The quarantine path preserves the original filename with a timestamp
    /// to avoid collisions.
    ///
    /// - Parameters:
    ///   - originalPath: The original path of the corrupt file.
    ///   - timestamp: When the file was quarantined. Defaults to now.
    /// - Returns: Path in the quarantine directory.
    public static func quarantineFilePath(
        originalPath: String,
        timestamp: Date = Date()
    ) -> String {
        let timestampStr = snapshotTimestamp(from: timestamp)
        let filename = (originalPath as NSString).lastPathComponent
        return "\(SyncConstants.quarantineDirectory)/\(timestampStr)_\(filename)"
    }

    // MARK: - Filtering Helpers

    /// Filters change filenames to only those matching a specific entity type.
    ///
    /// This is useful for processing only certain types of changes without
    /// reading file contents.
    ///
    /// ## Example
    /// ```swift
    /// let filenames = ["000001_..._session_upsert.json", "000002_..._document_upsert.json"]
    /// let sessionFiles = SyncFileNaming.filterByEntity(filenames, entity: .session)
    /// // Returns only the session file
    /// ```
    ///
    /// - Parameters:
    ///   - filenames: Array of change filenames.
    ///   - entity: The entity type to filter for.
    /// - Returns: Filenames matching the entity type.
    public static func filterByEntity(
        _ filenames: [String],
        entity: SyncEntityType
    ) -> [String] {
        filenames.filter { filename in
            guard let components = parseChangeFileName(filename) else {
                return false
            }
            return components.entity == entity
        }
    }

    /// Filters change filenames to only those matching a specific operation type.
    ///
    /// - Parameters:
    ///   - filenames: Array of change filenames.
    ///   - operation: The operation type to filter for.
    /// - Returns: Filenames matching the operation type.
    public static func filterByOperation(
        _ filenames: [String],
        operation: SyncOperationType
    ) -> [String] {
        filenames.filter { filename in
            guard let components = parseChangeFileName(filename) else {
                return false
            }
            return components.operation == operation
        }
    }

    /// Filters change filenames to only those after a specific sequence number.
    ///
    /// This is useful for incremental sync - fetching only changes after
    /// the last processed sequence.
    ///
    /// - Parameters:
    ///   - filenames: Array of change filenames.
    ///   - sequence: Minimum sequence number (exclusive).
    /// - Returns: Filenames with sequence > the given value.
    public static func filterAfterSequence(
        _ filenames: [String],
        sequence: Int
    ) -> [String] {
        filenames.filter { filename in
            guard let components = parseChangeFileName(filename) else {
                return false
            }
            return components.sequence > sequence
        }
    }

    /// Sorts change filenames by sequence number.
    ///
    /// Because filenames use zero-padded sequences, lexicographic sorting
    /// produces the same result. However, this function explicitly parses
    /// and sorts by numeric value for clarity and correctness.
    ///
    /// - Parameter filenames: Array of change filenames.
    /// - Returns: Filenames sorted by sequence (ascending).
    public static func sortBySequence(_ filenames: [String]) -> [String] {
        filenames.sorted { a, b in
            let seqA = parseChangeFileName(a)?.sequence ?? 0
            let seqB = parseChangeFileName(b)?.sequence ?? 0
            return seqA < seqB
        }
    }
}

// MARK: - Parsed Components

/// Components extracted from a change file name.
///
/// This struct is returned by `parseChangeFileName` and contains all the
/// metadata encoded in the filename.
public struct ChangeFileComponents: Sendable, Equatable {
    /// The sequence number of the change.
    ///
    /// Monotonically increasing per device, starting at 1.
    public let sequence: Int

    /// Timestamp when the change was created, in milliseconds since Unix epoch.
    public let timestamp: Int64

    /// The type of entity that was modified.
    public let entity: SyncEntityType

    /// The type of operation (upsert or delete).
    public let operation: SyncOperationType

    /// Creates change file components.
    ///
    /// - Parameters:
    ///   - sequence: The sequence number.
    ///   - timestamp: Timestamp in milliseconds.
    ///   - entity: Entity type.
    ///   - operation: Operation type.
    public init(
        sequence: Int,
        timestamp: Int64,
        entity: SyncEntityType,
        operation: SyncOperationType
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.entity = entity
        self.operation = operation
    }
}
