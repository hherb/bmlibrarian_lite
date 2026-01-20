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

// MARK: - Integrity Errors

/// Errors that occur during integrity verification of sync data.
///
/// These errors indicate potential data corruption, tampering, or version
/// incompatibility. All integrity errors should be logged and may trigger
/// recovery procedures such as re-fetching from source or rebuilding from
/// snapshots.
public enum IntegrityError: Error, LocalizedError, Sendable {
    /// The integrity envelope is missing or malformed.
    ///
    /// This indicates the file was not created by a sync-aware writer
    /// or was corrupted during transmission.
    case missingEnvelope

    /// The checksum algorithm specified is not supported.
    ///
    /// - Parameter algorithm: The unsupported algorithm identifier.
    ///
    /// Currently only "sha256" is supported. This error may occur when
    /// reading data from a newer version of the app.
    case unsupportedAlgorithm(String)

    /// The computed checksum does not match the expected value.
    ///
    /// - Parameters:
    ///   - expected: The checksum value stored in the integrity metadata.
    ///   - actual: The checksum computed from the content.
    ///
    /// This is the primary indicator of data corruption or tampering.
    case checksumMismatch(expected: String, actual: String)

    /// The content length does not match the expected value.
    ///
    /// - Parameters:
    ///   - expected: The length stored in the integrity metadata.
    ///   - actual: The actual length of the content.
    ///
    /// This provides an additional layer of verification beyond checksums.
    case lengthMismatch(expected: Int, actual: Int)

    /// The chain hash does not match, indicating a gap or tampering.
    ///
    /// - Parameters:
    ///   - sequence: The sequence number where the break was detected.
    ///   - expected: The expected hash of the previous change.
    ///   - actual: The actual hash found.
    ///
    /// Change logs form a hash chain for tamper detection. A broken chain
    /// indicates missing changes or modification of historical data.
    case chainBroken(sequence: Int, expected: String, actual: String)

    /// A file listed in the manifest is missing from storage.
    ///
    /// - Parameter filename: The missing file name.
    ///
    /// This may occur during partial sync or if files were deleted externally.
    case missingFile(String)

    /// A file exists that is not listed in the manifest.
    ///
    /// - Parameter filename: The unexpected file name.
    ///
    /// This may indicate external modification of the sync folder.
    case unexpectedFile(String)

    /// The schema version is newer than this app supports.
    ///
    /// - Parameters:
    ///   - found: The schema version in the data.
    ///   - maxSupported: The maximum version this app can read.
    ///
    /// The user should update the app to read newer data.
    case schemaVersionTooNew(found: Int, maxSupported: Int)

    /// JSON encoding or decoding failed.
    ///
    /// - Parameter error: The underlying JSON error.
    ///
    /// This wraps encoding/decoding errors with a sync-specific type.
    case jsonError(Error)

    public var errorDescription: String? {
        switch self {
        case .missingEnvelope:
            return "Missing integrity envelope - file may be corrupted or not a sync file"

        case .unsupportedAlgorithm(let algorithm):
            return "Unsupported checksum algorithm: \(algorithm). Please update the app."

        case .checksumMismatch(let expected, let actual):
            let expectedPrefix = String(expected.prefix(16))
            let actualPrefix = String(actual.prefix(16))
            return "Checksum mismatch: expected \(expectedPrefix)..., got \(actualPrefix)..."

        case .lengthMismatch(let expected, let actual):
            return "Content length mismatch: expected \(expected) bytes, got \(actual) bytes"

        case .chainBroken(let sequence, let expected, let actual):
            let expectedPrefix = String(expected.prefix(16))
            let actualPrefix = String(actual.prefix(16))
            return "Change chain broken at sequence \(sequence): expected \(expectedPrefix)..., got \(actualPrefix)..."

        case .missingFile(let filename):
            return "Missing file from manifest: \(filename)"

        case .unexpectedFile(let filename):
            return "Unexpected file not in manifest: \(filename)"

        case .schemaVersionTooNew(let found, let maxSupported):
            return "Schema version \(found) not supported (max: \(maxSupported)). Please update the app."

        case .jsonError(let error):
            return "JSON error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Recovery Result

/// Result of attempting to recover from data corruption.
///
/// When integrity verification fails, the sync system attempts automatic
/// recovery. This enum represents the possible outcomes.
public enum RecoveryResult: Sendable {
    /// File was skipped because it's non-critical.
    ///
    /// The file was not essential and sync can continue without it.
    case skipped

    /// State was successfully rebuilt from a snapshot.
    ///
    /// - Parameter snapshotId: Identifier of the snapshot used.
    ///
    /// Periodic snapshots allow recovery from chain breaks.
    case rebuiltFromSnapshot(snapshotId: String)

    /// Requested the source device to resend the data.
    ///
    /// The corrupt data was flagged and a resend was requested.
    /// Check back after some time for the fresh data.
    case pendingResend

    /// Recovery failed and user notification is required.
    ///
    /// - Parameter reason: Human-readable explanation.
    ///
    /// Manual intervention may be needed to resolve the issue.
    case failed(reason: String)
}
