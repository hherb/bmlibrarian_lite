import CryptoKit
import Foundation

// MARK: - Canonical JSON Encoding

/// Encodes content to canonical JSON bytes for consistent checksums across platforms.
///
/// Canonical JSON ensures that identical content always produces identical bytes,
/// which is essential for checksum consistency. This implementation follows these rules:
/// - Keys are sorted in lexicographic (Unicode) order
/// - No unnecessary whitespace (compact format)
/// - UTF-8 encoding
/// - No trailing newlines
/// - Forward slashes are not escaped
///
/// ## Cross-Platform Compatibility
/// This function must produce identical output to equivalent implementations
/// in Python, Kotlin, and other platforms to ensure checksums match.
///
/// ## Example
/// ```swift
/// struct MyData: Codable {
///     let name: String
///     let value: Int
/// }
/// let data = MyData(name: "test", value: 42)
/// let json = try toCanonicalJSON(data)
/// // Produces: {"name":"test","value":42}
/// ```
///
/// - Parameter content: The content to encode to JSON.
/// - Returns: Canonical JSON as UTF-8 bytes.
/// - Throws: `IntegrityError.jsonError` if encoding fails.
public func toCanonicalJSON<T: Encodable>(_ content: T) throws -> Data {
    let encoder = JSONEncoder()
    // sortedKeys ensures consistent key ordering
    // withoutEscapingSlashes avoids unnecessary escaping
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    do {
        return try encoder.encode(content)
    } catch {
        throw IntegrityError.jsonError(error)
    }
}

// MARK: - Checksum Calculation

/// Calculates the SHA-256 checksum of raw data.
///
/// This is a pure function that computes the cryptographic hash of the input data.
/// SHA-256 provides strong collision resistance, making it extremely unlikely
/// that two different inputs will produce the same hash.
///
/// ## Output Format
/// The result is a 64-character lowercase hexadecimal string representing
/// the 256-bit (32-byte) hash.
///
/// ## Example
/// ```swift
/// let data = "Hello, World!".data(using: .utf8)!
/// let checksum = calculateChecksum(data)
/// // checksum is a 64-character hex string
/// ```
///
/// - Parameter data: The data to hash.
/// - Returns: Lowercase hex-encoded SHA-256 checksum (64 characters).
public func calculateChecksum(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.compactMap { String(format: "%02x", $0) }.joined()
}

/// Calculates the SHA-256 checksum of content by first encoding to canonical JSON.
///
/// This is a convenience function that combines JSON encoding and hashing.
/// The content is first serialized to canonical JSON, then hashed.
///
/// ## Example
/// ```swift
/// struct MyData: Codable {
///     let value: Int
/// }
/// let checksum = try calculateChecksum(MyData(value: 42))
/// ```
///
/// - Parameter content: The content to hash.
/// - Returns: Lowercase hex-encoded SHA-256 checksum.
/// - Throws: `IntegrityError.jsonError` if JSON encoding fails.
public func calculateChecksum<T: Encodable>(_ content: T) throws -> String {
    let data = try toCanonicalJSON(content)
    return calculateChecksum(data)
}

// MARK: - Envelope Creation

/// Creates an integrity envelope wrapping the given content.
///
/// The envelope includes a SHA-256 checksum and content length that can be
/// verified when the envelope is later read. This is the primary function
/// for preparing content to be written to sync files.
///
/// ## How It Works
/// 1. Serialize the content to canonical JSON
/// 2. Compute the SHA-256 hash of the JSON bytes
/// 3. Record the byte length
/// 4. Wrap everything in an IntegrityEnvelope
///
/// ## Example
/// ```swift
/// let myData = SessionData(id: "123", name: "My Session")
/// let envelope = try createIntegrityEnvelope(myData)
/// // Now encode the envelope to JSON and write to file
/// ```
///
/// - Parameter content: The content to wrap with integrity metadata.
/// - Returns: An integrity envelope containing the content and verification data.
/// - Throws: `IntegrityError.jsonError` if JSON encoding fails.
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

// MARK: - Envelope Verification

/// Verifies an integrity envelope and extracts the content if valid.
///
/// This function performs multiple verification checks to ensure the content
/// has not been corrupted or tampered with:
/// 1. Algorithm check: Ensures we support the hash algorithm used
/// 2. Checksum verification: Computes the hash and compares to stored value
/// 3. Length verification: Ensures content length matches expected value
///
/// ## When to Use
/// Call this function whenever reading content from a sync file. It ensures
/// the data is intact before using it.
///
/// ## Example
/// ```swift
/// let envelope = // ... read from file ...
/// do {
///     let content = try verifyAndExtract(envelope)
///     // Use the verified content
/// } catch IntegrityError.checksumMismatch(let expected, let actual) {
///     // Handle corruption
/// }
/// ```
///
/// - Parameter envelope: The envelope to verify.
/// - Returns: The verified content.
/// - Throws: `IntegrityError` if any verification check fails.
public func verifyAndExtract<T: Codable & Sendable>(
    _ envelope: IntegrityEnvelope<T>
) throws -> T {
    // Verify we support the algorithm
    guard envelope.integrity.algorithm == SyncConstants.integrityAlgorithm else {
        throw IntegrityError.unsupportedAlgorithm(envelope.integrity.algorithm)
    }

    // Compute actual checksum and length
    let canonicalData = try toCanonicalJSON(envelope.content)
    let actualChecksum = calculateChecksum(canonicalData)

    // Verify checksum matches
    guard actualChecksum == envelope.integrity.checksum else {
        throw IntegrityError.checksumMismatch(
            expected: envelope.integrity.checksum,
            actual: actualChecksum
        )
    }

    // Verify length matches (defense in depth)
    guard canonicalData.count == envelope.integrity.contentLength else {
        throw IntegrityError.lengthMismatch(
            expected: envelope.integrity.contentLength,
            actual: canonicalData.count
        )
    }

    return envelope.content
}

/// Verifies integrity and extracts content from raw JSON data.
///
/// This convenience function handles both JSON decoding and verification
/// in a single call. Use this when reading directly from file data.
///
/// ## Example
/// ```swift
/// let fileData = try Data(contentsOf: fileURL)
/// let content: MyData = try verifyAndExtract(from: fileData)
/// ```
///
/// - Parameter data: Raw JSON data containing an integrity envelope.
/// - Returns: The verified and decoded content.
/// - Throws: `IntegrityError` if decoding or verification fails.
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

/// Verifies that a change correctly references the previous change in the chain.
///
/// Each change (except the first) must contain the SHA-256 hash of the previous
/// change. This creates a hash chain that detects missing or tampered entries.
///
/// ## Chain Rules
/// - First change (sequence 1): previousHash must be nil
/// - Subsequent changes: previousHash must equal hash of previous change
///
/// ## Example
/// ```swift
/// let isValid = try verifyChainLink(change: change2, previousChange: change1)
/// ```
///
/// - Parameters:
///   - change: The change entry to verify.
///   - previousChange: The previous change entry (nil for first change).
/// - Returns: True if the chain link is valid.
/// - Throws: `IntegrityError.chainBroken` if the chain link is invalid.
public func verifyChainLink<T: Codable & Sendable>(
    change: ChangeLogEntry<T>,
    previousChange: ChangeLogEntry<T>?
) throws -> Bool {
    if change.sequence == 1 {
        // First change must have no previous hash
        guard change.previousHash == nil else {
            throw IntegrityError.chainBroken(
                sequence: change.sequence,
                expected: "nil",
                actual: change.previousHash ?? "nil"
            )
        }
        return true
    }

    // Non-first changes must reference the previous change
    guard let previous = previousChange else {
        throw IntegrityError.chainBroken(
            sequence: change.sequence,
            expected: "previous change",
            actual: "nil"
        )
    }

    let expectedHash = try calculateChecksum(previous)

    guard change.previousHash == expectedHash else {
        throw IntegrityError.chainBroken(
            sequence: change.sequence,
            expected: expectedHash,
            actual: change.previousHash ?? "nil"
        )
    }

    return true
}

/// Verifies the integrity of an entire sequence of changes.
///
/// This function checks that all changes in a sequence form a valid hash chain.
/// It's useful for verifying a batch of changes received from another device.
///
/// ## Performance
/// This function is O(n) where n is the number of changes, as it must
/// compute the hash of each change. For large change logs, consider
/// verifying only recent changes using `SyncConstants.chainVerifyDepth`.
///
/// ## Example
/// ```swift
/// let changes = [change1, change2, change3]
/// let isValid = try verifyChangeChain(changes)
/// ```
///
/// - Parameter changes: Changes in sequence order (must be sorted by sequence).
/// - Returns: True if the entire chain is valid.
/// - Throws: `IntegrityError.chainBroken` if any chain link is invalid.
public func verifyChangeChain<T: Codable & Sendable>(
    _ changes: [ChangeLogEntry<T>]
) throws -> Bool {
    guard !changes.isEmpty else { return true }

    // Verify first change has no previous hash
    _ = try verifyChainLink(change: changes[0], previousChange: nil)

    // Verify each subsequent change links to its predecessor
    for i in 1..<changes.count {
        _ = try verifyChainLink(change: changes[i], previousChange: changes[i - 1])
    }

    return true
}

// MARK: - Manifest Checksum

/// Computes a combined checksum over all files in a manifest.
///
/// This allows quick comparison of manifests: if two manifests have the same
/// combined checksum, their file lists are identical. This is much faster
/// than comparing individual file entries.
///
/// ## Algorithm
/// 1. Sort files by sequence number
/// 2. Concatenate all file checksums
/// 3. Compute SHA-256 of the concatenated string
///
/// - Parameter files: File entries from a manifest.
/// - Returns: Combined checksum of all file checksums.
public func computeManifestChecksum(
    _ files: [ManifestFileEntry]
) -> String {
    let sortedFiles = files.sorted { $0.sequence < $1.sequence }
    let combined = sortedFiles.map(\.checksum).joined()
    return calculateChecksum(Data(combined.utf8))
}

// MARK: - Utility Functions

/// Creates a timestamp in milliseconds since Unix epoch.
///
/// This is the standard timestamp format used throughout the sync system.
/// Using milliseconds provides sufficient precision for ordering without
/// the complexity of nanoseconds.
///
/// - Parameter date: The date to convert. Defaults to current date/time.
/// - Returns: Milliseconds since January 1, 1970 00:00:00 UTC.
public func syncTimestamp(from date: Date = Date()) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
}

/// Converts a sync timestamp back to a Date.
///
/// - Parameter timestamp: Milliseconds since Unix epoch.
/// - Returns: The corresponding Date.
public func dateFromSyncTimestamp(_ timestamp: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
}
