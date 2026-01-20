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

import CryptoKit
import Foundation

// MARK: - Canonical JSON Encoding

/// Encodes content to canonical JSON bytes for consistent checksums.
///
/// Canonical JSON ensures that the same content always produces the same
/// byte representation, which is essential for reliable checksums.
///
/// Canonical JSON requirements:
/// - Sorted keys (lexicographic Unicode order)
/// - Compact format (no whitespace)
/// - UTF-8 encoding
/// - No trailing newlines
///
/// - Parameter content: The content to encode.
/// - Returns: Canonical JSON as UTF-8 bytes.
/// - Throws: `IntegrityError.jsonError` if encoding fails.
public func toCanonicalJSON<T: Encodable>(_ content: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    do {
        return try encoder.encode(content)
    } catch {
        throw IntegrityError.jsonError(error)
    }
}

// MARK: - Checksum Calculation

/// Calculates SHA-256 checksum of raw data.
///
/// Uses Apple's CryptoKit for secure, hardware-accelerated hashing.
///
/// - Parameter data: The data to hash.
/// - Returns: Lowercase hex-encoded checksum string (64 characters).
public func calculateChecksum(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.compactMap { String(format: "%02x", $0) }.joined()
}

/// Calculates SHA-256 checksum of content via canonical JSON.
///
/// First serializes the content to canonical JSON, then computes the hash.
/// This ensures consistent checksums regardless of in-memory representation.
///
/// - Parameter content: The content to hash.
/// - Returns: Lowercase hex-encoded checksum string (64 characters).
/// - Throws: `IntegrityError.jsonError` if encoding fails.
public func calculateChecksum<T: Encodable>(_ content: T) throws -> String {
    let data = try toCanonicalJSON(content)
    return calculateChecksum(data)
}

// MARK: - Envelope Creation

/// Creates an integrity envelope for content.
///
/// The envelope includes a SHA-256 checksum and content length that can be
/// verified when the data is read back. This is the primary way to create
/// sync files.
///
/// Example:
/// ```swift
/// let session = FactCheckSession(...)
/// let envelope = try createIntegrityEnvelope(session)
/// let data = try JSONEncoder().encode(envelope)
/// // Write data to file
/// ```
///
/// - Parameter content: The content to wrap.
/// - Returns: An integrity envelope containing the content.
/// - Throws: `IntegrityError.jsonError` if encoding fails.
public func createIntegrityEnvelope<T: Codable & Sendable>(
    _ content: T
) throws -> IntegrityEnvelope<T> {
    let canonicalData = try toCanonicalJSON(content)
    let checksum = calculateChecksum(canonicalData)

    let metadata = IntegrityMetadata(
        checksum: checksum,
        contentLength: canonicalData.count
    )

    return IntegrityEnvelope(integrity: metadata, content: content)
}

// MARK: - Verification

/// Verifies an integrity envelope and extracts the content.
///
/// Performs the following checks:
/// 1. Algorithm is supported (sha256)
/// 2. Content checksum matches stored checksum
/// 3. Content length matches stored length
///
/// If all checks pass, returns the content. Otherwise throws an error
/// indicating what verification failed.
///
/// - Parameter envelope: The envelope to verify.
/// - Returns: The verified content.
/// - Throws: `IntegrityError` if verification fails.
public func verifyAndExtract<T: Codable & Sendable>(
    _ envelope: IntegrityEnvelope<T>
) throws -> T {
    // Verify algorithm is supported
    guard envelope.integrity.algorithm == SyncConstants.integrityAlgorithm else {
        throw IntegrityError.unsupportedAlgorithm(envelope.integrity.algorithm)
    }

    // Compute actual values from content
    let canonicalData = try toCanonicalJSON(envelope.content)
    let actualChecksum = calculateChecksum(canonicalData)

    // Verify checksum matches
    guard actualChecksum == envelope.integrity.checksum else {
        throw IntegrityError.checksumMismatch(
            expected: envelope.integrity.checksum,
            actual: actualChecksum
        )
    }

    // Verify length matches
    guard canonicalData.count == envelope.integrity.contentLength else {
        throw IntegrityError.lengthMismatch(
            expected: envelope.integrity.contentLength,
            actual: canonicalData.count
        )
    }

    return envelope.content
}

/// Verifies integrity envelope from raw JSON data.
///
/// Convenience overload that decodes the envelope from raw bytes and then
/// verifies it. Use this when reading files from disk or network.
///
/// - Parameter data: Raw JSON data containing an integrity envelope.
/// - Returns: The verified and decoded content.
/// - Throws: `IntegrityError` if verification or decoding fails.
public func verifyAndExtract<T: Codable & Sendable>(
    from data: Data
) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let envelope: IntegrityEnvelope<T>
    do {
        envelope = try decoder.decode(IntegrityEnvelope<T>.self, from: data)
    } catch {
        throw IntegrityError.jsonError(error)
    }

    return try verifyAndExtract(envelope)
}

// MARK: - Chain Verification

/// Verifies that a change correctly references the previous change.
///
/// Change log entries form a hash chain where each entry includes the hash
/// of the previous entry. This enables detection of:
/// - Missing entries (gaps in the chain)
/// - Modified historical entries (tampering)
///
/// - Parameters:
///   - change: The change to verify.
///   - previousChange: The previous change (nil for first change).
/// - Returns: True if the chain link is valid.
/// - Throws: `IntegrityError.chainBroken` if verification fails.
public func verifyChainLink<T: Codable & Sendable>(
    change: ChangeLogEntry<T>,
    previousChange: ChangeLogEntry<T>?
) throws -> Bool {
    if change.sequence == 1 {
        // First change should have no previous hash
        guard change.previousHash == nil else {
            throw IntegrityError.chainBroken(
                sequence: change.sequence,
                expected: "nil",
                actual: change.previousHash ?? "nil"
            )
        }
        return true
    }

    // Non-first change must have a previous change to verify against
    guard let previous = previousChange else {
        throw IntegrityError.chainBroken(
            sequence: change.sequence,
            expected: "previous change",
            actual: "nil"
        )
    }

    // Compute expected hash from previous change
    let expectedHash = try calculateChecksum(previous)

    // Verify the stored previous hash matches
    guard change.previousHash == expectedHash else {
        throw IntegrityError.chainBroken(
            sequence: change.sequence,
            expected: expectedHash,
            actual: change.previousHash ?? "nil"
        )
    }

    return true
}

/// Verifies the integrity of a sequence of changes.
///
/// Validates that all entries in the sequence form a valid hash chain.
/// Entries must be provided in sequence order.
///
/// - Parameter changes: Changes in sequence order.
/// - Returns: True if the entire chain is valid.
/// - Throws: `IntegrityError.chainBroken` if verification fails.
public func verifyChangeChain<T: Codable & Sendable>(
    _ changes: [ChangeLogEntry<T>]
) throws -> Bool {
    guard !changes.isEmpty else { return true }

    // Verify first change (should have nil previousHash)
    _ = try verifyChainLink(change: changes[0], previousChange: nil)

    // Verify each subsequent change against its predecessor
    for index in 1..<changes.count {
        _ = try verifyChainLink(
            change: changes[index],
            previousChange: changes[index - 1]
        )
    }

    return true
}

// MARK: - Manifest Checksum

/// Computes a combined checksum over file entries in a manifest.
///
/// The manifest checksum is computed by concatenating all individual file
/// checksums (in sequence order) and hashing the result. This provides a
/// single value that changes if any file changes.
///
/// - Parameter files: File entries with checksums.
/// - Returns: Combined checksum of all file checksums.
public func computeManifestChecksum(
    _ files: [ManifestFileEntry]
) -> String {
    // Sort by sequence to ensure consistent ordering
    let sortedFiles = files.sorted { $0.sequence < $1.sequence }

    // Concatenate all checksums
    let combined = sortedFiles.map(\.checksum).joined()

    // Hash the combined string
    return calculateChecksum(Data(combined.utf8))
}

// MARK: - Supporting Types

/// Entry in a device manifest listing a change file.
///
/// The manifest provides an index of all change files from a device,
/// enabling efficient discovery of new changes without scanning the
/// entire directory.
public struct ManifestFileEntry: Codable, Sendable, Equatable {
    /// Sequence number of the change.
    public let sequence: Int

    /// Filename of the change file.
    public let filename: String

    /// SHA-256 checksum of the file contents (the envelope).
    public let checksum: String

    /// SHA-256 checksum of the change entry (for chain linking).
    ///
    /// This is the hash used in the `previousHash` field of the next change.
    /// It's computed from the ChangeLogEntry content, not the file.
    public let entryChecksum: String

    /// File size in bytes.
    public let size: Int

    /// Timestamp in milliseconds since Unix epoch.
    public let timestamp: Int64

    /// Creates a manifest file entry.
    ///
    /// - Parameters:
    ///   - sequence: Sequence number of the change.
    ///   - filename: Change file name.
    ///   - checksum: SHA-256 checksum of file contents.
    ///   - entryChecksum: SHA-256 checksum of the change entry for chain linking.
    ///   - size: File size in bytes.
    ///   - timestamp: Timestamp in milliseconds.
    public init(
        sequence: Int,
        filename: String,
        checksum: String,
        entryChecksum: String,
        size: Int,
        timestamp: Int64
    ) {
        self.sequence = sequence
        self.filename = filename
        self.checksum = checksum
        self.entryChecksum = entryChecksum
        self.size = size
        self.timestamp = timestamp
    }
}
