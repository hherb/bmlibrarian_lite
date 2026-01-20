import Foundation

// MARK: - Integrity Errors

/// Errors that can occur during integrity verification of sync data.
///
/// These errors indicate that data may be corrupted, tampered with, or
/// incompatible with the current app version. Each error type provides
/// specific information to help diagnose and potentially recover from the issue.
///
/// ## Error Handling Strategy
/// When an integrity error occurs:
/// 1. Log the error with full details for debugging
/// 2. Quarantine the corrupt file (don't delete it)
/// 3. Attempt recovery (skip, use snapshot, or request resend)
/// 4. Notify the user if recovery fails
///
/// ## Example
/// ```swift
/// do {
///     let content = try verifyAndExtract(envelope)
/// } catch let error as IntegrityError {
///     logger.error("Integrity check failed: \(error.errorDescription ?? "unknown")")
///     quarantineFile(at: path)
/// }
/// ```
public enum IntegrityError: Error, LocalizedError, Sendable {
    /// The integrity envelope wrapper is missing or cannot be parsed.
    ///
    /// This typically indicates the file was not created by our sync system,
    /// was truncated during transfer, or is from an incompatible version.
    case missingEnvelope

    /// The checksum algorithm specified in the envelope is not supported.
    ///
    /// This could happen if the file was created by a newer app version
    /// using a different hash algorithm. The associated value contains
    /// the unsupported algorithm identifier.
    ///
    /// - Parameter algorithm: The algorithm identifier that was not recognized.
    case unsupportedAlgorithm(String)

    /// The computed checksum does not match the expected value.
    ///
    /// This is the primary indicator of data corruption or tampering.
    /// The file contents have been modified since the checksum was calculated.
    ///
    /// - Parameters:
    ///   - expected: The checksum stored in the integrity envelope.
    ///   - actual: The checksum computed from the current file contents.
    case checksumMismatch(expected: String, actual: String)

    /// The content length does not match the expected value.
    ///
    /// This can catch truncation or expansion of data that might
    /// coincidentally produce the same checksum (extremely unlikely
    /// with SHA-256, but provides defense in depth).
    ///
    /// - Parameters:
    ///   - expected: The byte count stored in the integrity envelope.
    ///   - actual: The actual byte count of the content.
    case lengthMismatch(expected: Int, actual: Int)

    /// The chain hash does not match, indicating a gap or tampering.
    ///
    /// Each change in the log references the hash of the previous change.
    /// If this chain is broken, changes may have been lost, reordered,
    /// or tampered with.
    ///
    /// - Parameters:
    ///   - sequence: The sequence number of the change with the broken link.
    ///   - expected: The hash that was expected (from the previous change).
    ///   - actual: The hash that was found in the change's previousHash field.
    case chainBroken(sequence: Int, expected: String, actual: String)

    /// A file listed in the manifest is missing from the device directory.
    ///
    /// This could indicate incomplete sync, file deletion, or corruption
    /// of the manifest itself.
    ///
    /// - Parameter filename: The name of the missing file.
    case missingFile(String)

    /// A file exists in the device directory that is not listed in the manifest.
    ///
    /// This could indicate the manifest is out of date, or files were
    /// added outside the normal sync process.
    ///
    /// - Parameter filename: The name of the unexpected file.
    case unexpectedFile(String)

    /// The schema version is newer than this app version can handle.
    ///
    /// The user needs to update their app to read this data.
    /// We should not attempt to process data we don't understand.
    ///
    /// - Parameters:
    ///   - found: The schema version found in the data.
    ///   - maxSupported: The maximum schema version this app supports.
    case schemaVersionTooNew(found: Int, maxSupported: Int)

    /// JSON encoding or decoding failed.
    ///
    /// The data is not valid JSON or doesn't match the expected structure.
    /// This wraps the underlying error for context.
    ///
    /// - Parameter error: The underlying JSON error.
    case jsonError(Error)

    /// A human-readable description of the error suitable for logging.
    ///
    /// These descriptions are designed to be informative for debugging
    /// while not exposing sensitive data. Checksums are truncated for brevity.
    public var errorDescription: String? {
        switch self {
        case .missingEnvelope:
            return "Missing or malformed integrity envelope"

        case .unsupportedAlgorithm(let algorithm):
            return "Unsupported checksum algorithm: \(algorithm)"

        case .checksumMismatch(let expected, let actual):
            // Truncate checksums for readability in logs
            let expectedPrefix = String(expected.prefix(16))
            let actualPrefix = String(actual.prefix(16))
            return "Checksum mismatch: expected \(expectedPrefix)..., got \(actualPrefix)..."

        case .lengthMismatch(let expected, let actual):
            return "Content length mismatch: expected \(expected) bytes, got \(actual) bytes"

        case .chainBroken(let sequence, let expected, let actual):
            let expectedPrefix = String(expected.prefix(16))
            let actualPrefix = String(actual.prefix(16))
            return "Chain broken at sequence \(sequence): expected \(expectedPrefix)..., got \(actualPrefix)..."

        case .missingFile(let filename):
            return "Missing file listed in manifest: \(filename)"

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
/// When integrity verification fails, we attempt various recovery strategies.
/// This enum represents the outcome of those attempts, allowing the caller
/// to take appropriate action.
///
/// ## Recovery Strategies (in order of preference)
/// 1. Skip - If the data is non-critical, skip it and continue
/// 2. Rebuild from snapshot - Restore state from a known-good snapshot
/// 3. Request resend - Ask the source device to resend the data
/// 4. Fail - No recovery possible, user notification required
public enum RecoveryResult: Sendable {
    /// The corrupt file was skipped because it was non-critical.
    ///
    /// The sync can continue without this data. For example, a single
    /// document's full text might be skipped while keeping the metadata.
    case skipped

    /// State was rebuilt from a snapshot.
    ///
    /// A previous full-state snapshot was used to restore data.
    /// Some recent changes may be lost, but the system is consistent.
    ///
    /// - Parameter snapshotId: Identifier of the snapshot used for recovery.
    case rebuiltFromSnapshot(snapshotId: String)

    /// A resend request has been queued for the source device.
    ///
    /// The source device will be asked to resend the corrupt data.
    /// The caller should retry later after the resend completes.
    case pendingResend

    /// Recovery failed and user notification is required.
    ///
    /// None of the automatic recovery strategies worked. The user
    /// should be informed and may need to take manual action.
    ///
    /// - Parameter reason: A user-friendly explanation of why recovery failed.
    case failed(reason: String)
}

// MARK: - Sync Storage Errors

/// Errors that can occur during sync storage operations.
///
/// These errors relate to reading from or writing to the sync storage
/// (local folder or iCloud), as opposed to data integrity issues.
public enum SyncStorageError: Error, LocalizedError, Sendable {
    /// The sync root directory could not be accessed or created.
    ///
    /// This might indicate a permissions issue or iCloud being unavailable.
    ///
    /// - Parameter path: The path that could not be accessed.
    case rootDirectoryUnavailable(path: String)

    /// A file could not be read from storage.
    ///
    /// - Parameters:
    ///   - path: The path of the file that could not be read.
    ///   - underlying: The underlying file system error, if available.
    case readFailed(path: String, underlying: Error?)

    /// A file could not be written to storage.
    ///
    /// - Parameters:
    ///   - path: The path where the write was attempted.
    ///   - underlying: The underlying file system error, if available.
    case writeFailed(path: String, underlying: Error?)

    /// A file could not be deleted from storage.
    ///
    /// - Parameters:
    ///   - path: The path of the file that could not be deleted.
    ///   - underlying: The underlying file system error, if available.
    case deleteFailed(path: String, underlying: Error?)

    /// A directory listing could not be performed.
    ///
    /// - Parameters:
    ///   - path: The directory path that could not be listed.
    ///   - underlying: The underlying file system error, if available.
    case listingFailed(path: String, underlying: Error?)

    /// The operation timed out waiting for iCloud.
    ///
    /// The file may not be downloaded yet or iCloud may be unavailable.
    ///
    /// - Parameter path: The path of the file that timed out.
    case iCloudTimeout(path: String)

    /// The device is not registered in the workspace.
    ///
    /// The device must be registered before it can sync.
    ///
    /// - Parameter deviceId: The unregistered device identifier.
    case deviceNotRegistered(deviceId: String)

    /// The workspace has not been initialized.
    ///
    /// The workspace must be created before syncing can begin.
    case workspaceNotInitialized

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .rootDirectoryUnavailable(let path):
            return "Sync directory unavailable: \(path)"

        case .readFailed(let path, let underlying):
            let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
            return "Failed to read file: \(path)\(detail)"

        case .writeFailed(let path, let underlying):
            let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
            return "Failed to write file: \(path)\(detail)"

        case .deleteFailed(let path, let underlying):
            let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
            return "Failed to delete file: \(path)\(detail)"

        case .listingFailed(let path, let underlying):
            let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
            return "Failed to list directory: \(path)\(detail)"

        case .iCloudTimeout(let path):
            return "Timeout waiting for iCloud download: \(path)"

        case .deviceNotRegistered(let deviceId):
            return "Device not registered: \(deviceId)"

        case .workspaceNotInitialized:
            return "Sync workspace has not been initialized"
        }
    }
}
