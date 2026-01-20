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

// MARK: - File Naming

/// Utilities for sync file naming conventions.
///
/// All sync files follow consistent naming patterns that encode metadata
/// directly in the filename. This enables efficient discovery and sorting
/// without parsing file contents.
///
/// Change file format: `{sequence}_{timestamp}_{entity}_{operation}.json`
/// Example: `000142_1705772400000_session_upsert.json`
///
/// This naming scheme allows:
/// - Sorting files by sequence with simple string comparison
/// - Quick filtering by entity type or operation
/// - Recovery of metadata even if file contents are corrupt
public enum SyncFileNaming {
    // MARK: - Change File Names

    /// Generates a change file name.
    ///
    /// The filename encodes all key metadata for the change, enabling
    /// efficient discovery and sorting without reading file contents.
    ///
    /// - Parameters:
    ///   - sequence: The sequence number (zero-padded to 6 digits).
    ///   - timestamp: Timestamp in milliseconds since Unix epoch.
    ///   - entity: Entity type being modified.
    ///   - operation: Operation type (upsert or delete).
    /// - Returns: The formatted filename (e.g., "000042_1705772400000_session_upsert.json").
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
    /// This is the inverse of `changeFileName(sequence:timestamp:entity:operation:)`.
    /// Returns nil if the filename doesn't match the expected format.
    ///
    /// - Parameter filename: The filename to parse (with or without path).
    /// - Returns: Parsed components, or nil if invalid format.
    public static func parseChangeFileName(
        _ filename: String
    ) -> ChangeFileComponents? {
        // Extract just the filename if a path was provided
        let name = URL(fileURLWithPath: filename).lastPathComponent

        // Remove extension
        let baseName: String
        let expectedSuffix = ".\(SyncConstants.syncFileExtension)"
        if name.hasSuffix(expectedSuffix) {
            baseName = String(name.dropLast(expectedSuffix.count))
        } else {
            return nil
        }

        // Split into components: sequence_timestamp_entity_operation
        let parts = baseName.split(separator: "_")
        guard parts.count >= 4 else { return nil }

        // Parse each component
        guard let sequence = Int(parts[0]) else { return nil }
        guard let timestamp = Int64(parts[1]) else { return nil }
        guard let entity = SyncEntityType(rawValue: String(parts[2])) else { return nil }
        guard let operation = SyncOperationType(rawValue: String(parts[3])) else { return nil }

        return ChangeFileComponents(
            sequence: sequence,
            timestamp: timestamp,
            entity: entity,
            operation: operation
        )
    }

    // MARK: - Device File Names

    /// Generates a device configuration file name.
    ///
    /// - Parameter deviceId: The unique device identifier (UUID).
    /// - Returns: The device config filename (e.g., "abc123-def456.json").
    public static func deviceFileName(deviceId: String) -> String {
        "\(deviceId).\(SyncConstants.syncFileExtension)"
    }

    // MARK: - Snapshot File Names

    /// Generates a snapshot file name.
    ///
    /// Snapshots are periodic full-state captures that enable recovery
    /// from chain breaks without replaying all history.
    ///
    /// - Parameters:
    ///   - timestamp: ISO8601 timestamp string.
    ///   - deviceId: Device that created the snapshot.
    /// - Returns: The snapshot filename (e.g., "2024-01-20T15:30:00Z_abc123.json.gz").
    public static func snapshotFileName(
        timestamp: String,
        deviceId: String
    ) -> String {
        "\(timestamp)_\(deviceId).\(SyncConstants.syncFileExtension).gz"
    }

    // MARK: - Path Generation

    /// Generates the full relative path for a change file.
    ///
    /// - Parameters:
    ///   - deviceId: Device identifier.
    ///   - filename: Change file name.
    /// - Returns: Full relative path from sync root (e.g., "changes/abc123/000001_...json").
    public static func changeFilePath(
        deviceId: String,
        filename: String
    ) -> String {
        "\(SyncConstants.changesDirectory)/\(deviceId)/\(filename)"
    }

    /// Generates the full relative path for a device config file.
    ///
    /// - Parameter deviceId: Device identifier.
    /// - Returns: Full relative path from sync root (e.g., "devices/abc123.json").
    public static func deviceFilePath(deviceId: String) -> String {
        "\(SyncConstants.devicesDirectory)/\(deviceFileName(deviceId: deviceId))"
    }

    /// Generates the path for a device's change directory.
    ///
    /// - Parameter deviceId: Device identifier.
    /// - Returns: Path to device's change directory (e.g., "changes/abc123").
    public static func deviceChangesDirectory(deviceId: String) -> String {
        "\(SyncConstants.changesDirectory)/\(deviceId)"
    }

    /// Generates the path for a device's manifest file.
    ///
    /// - Parameter deviceId: Device identifier.
    /// - Returns: Path to device's manifest (e.g., "changes/abc123/manifest.json").
    public static func manifestPath(deviceId: String) -> String {
        "\(SyncConstants.changesDirectory)/\(deviceId)/\(SyncConstants.manifestFile)"
    }
}

// MARK: - Parsed Components

/// Parsed components from a change file name.
///
/// This struct holds the metadata extracted from a change file name,
/// enabling processing without reading the file contents.
public struct ChangeFileComponents: Sendable, Equatable {
    /// Sequence number (monotonically increasing per device).
    public let sequence: Int

    /// Timestamp in milliseconds since Unix epoch.
    public let timestamp: Int64

    /// Entity type that was modified.
    public let entity: SyncEntityType

    /// Operation type (upsert or delete).
    public let operation: SyncOperationType

    /// Creates parsed file components.
    ///
    /// - Parameters:
    ///   - sequence: Sequence number.
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
