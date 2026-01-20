import XCTest
@testable import BioMedLit

/// Tests for the sync integrity module (Phase 1).
///
/// These tests verify:
/// - Canonical JSON produces consistent, sorted output
/// - Checksums are consistent and detect changes
/// - Integrity envelopes can be created and verified
/// - Tampered data is detected
/// - Vector clocks track causality correctly
/// - Chain verification detects broken links
/// - File naming follows conventions and parses correctly
final class SyncIntegrityTests: XCTestCase {

    // MARK: - Canonical JSON Tests

    /// Tests that canonical JSON produces sorted keys.
    ///
    /// This is essential for cross-platform checksum consistency.
    /// Keys must be sorted in lexicographic (Unicode) order.
    func testCanonicalJSONSortedKeys() throws {
        struct TestContent: Codable, Sendable {
            let z: Int
            let a: String
            let m: [Int]
        }

        let content = TestContent(z: 1, a: "hello", m: [3, 2, 1])
        let data = try toCanonicalJSON(content)
        let jsonString = String(data: data, encoding: .utf8)!

        // Keys must be sorted: a, m, z
        XCTAssertTrue(jsonString.contains("\"a\":\"hello\""))
        XCTAssertTrue(jsonString.contains("\"m\":[3,2,1]"))
        XCTAssertTrue(jsonString.contains("\"z\":1"))

        // Verify order (a before m before z)
        let aIndex = jsonString.range(of: "\"a\"")!.lowerBound
        let mIndex = jsonString.range(of: "\"m\"")!.lowerBound
        let zIndex = jsonString.range(of: "\"z\"")!.lowerBound

        XCTAssertLessThan(aIndex, mIndex, "Key 'a' should come before 'm'")
        XCTAssertLessThan(mIndex, zIndex, "Key 'm' should come before 'z'")
    }

    /// Tests that canonical JSON is compact (no whitespace).
    func testCanonicalJSONCompact() throws {
        struct TestContent: Codable, Sendable {
            let name: String
            let value: Int
        }

        let content = TestContent(name: "test", value: 42)
        let data = try toCanonicalJSON(content)
        let jsonString = String(data: data, encoding: .utf8)!

        // Should be compact - no spaces after colons or commas
        XCTAssertFalse(jsonString.contains(": "), "Should not have space after colon")
        XCTAssertFalse(jsonString.contains(", "), "Should not have space after comma")
        XCTAssertFalse(jsonString.contains("\n"), "Should not have newlines")
    }

    /// Tests that nested objects also have sorted keys.
    func testCanonicalJSONNestedSorting() throws {
        struct Nested: Codable, Sendable {
            let z: Int
            let a: Int
        }
        struct Outer: Codable, Sendable {
            let nested: Nested
        }

        let content = Outer(nested: Nested(z: 2, a: 1))
        let data = try toCanonicalJSON(content)
        let jsonString = String(data: data, encoding: .utf8)!

        // The nested object should also have sorted keys
        XCTAssertTrue(jsonString.contains("{\"a\":1,\"z\":2}"), "Nested keys should be sorted")
    }

    // MARK: - Checksum Tests

    /// Tests that identical content produces identical checksums.
    func testChecksumConsistency() throws {
        struct TestContent: Codable, Sendable {
            let name: String
            let value: Int
        }

        let content1 = TestContent(name: "test", value: 42)
        let content2 = TestContent(name: "test", value: 42)

        let checksum1 = try calculateChecksum(content1)
        let checksum2 = try calculateChecksum(content2)

        XCTAssertEqual(checksum1, checksum2, "Identical content should produce identical checksums")
    }

    /// Tests that different content produces different checksums.
    func testChecksumDifference() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let content1 = TestContent(value: 1)
        let content2 = TestContent(value: 2)

        let checksum1 = try calculateChecksum(content1)
        let checksum2 = try calculateChecksum(content2)

        XCTAssertNotEqual(checksum1, checksum2, "Different content should produce different checksums")
    }

    /// Tests that checksum is 64 hex characters (SHA-256).
    func testChecksumFormat() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let checksum = try calculateChecksum(TestContent(value: 42))

        XCTAssertEqual(checksum.count, 64, "SHA-256 checksum should be 64 hex characters")
        XCTAssertTrue(checksum.allSatisfy { $0.isHexDigit }, "Checksum should be hex")
        XCTAssertEqual(checksum, checksum.lowercased(), "Checksum should be lowercase")
    }

    /// Tests raw data checksum.
    func testRawDataChecksum() {
        let data = "Hello, World!".data(using: .utf8)!
        let checksum = calculateChecksum(data)

        XCTAssertEqual(checksum.count, 64)
        // Known SHA-256 hash of "Hello, World!"
        XCTAssertEqual(checksum, "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f")
    }

    // MARK: - Integrity Envelope Tests

    /// Tests creating and verifying an integrity envelope (round trip).
    func testIntegrityEnvelopeRoundTrip() throws {
        struct TestContent: Codable, Sendable, Equatable {
            let id: String
            let data: String
        }

        let original = TestContent(id: "test-123", data: "some data")
        let envelope = try createIntegrityEnvelope(original)
        let extracted = try verifyAndExtract(envelope)

        XCTAssertEqual(original, extracted, "Round-trip should preserve content")
    }

    /// Tests that tampered content fails verification.
    func testIntegrityEnvelopeTamperDetection() throws {
        struct TestContent: Codable, Sendable {
            var value: Int
        }

        let original = TestContent(value: 42)
        let envelope = try createIntegrityEnvelope(original)

        // Tamper with the content by creating a new envelope with wrong integrity
        let tamperedContent = TestContent(value: 99)
        let tamperedEnvelope = IntegrityEnvelope(
            integrity: envelope.integrity,  // Keep original checksum
            content: tamperedContent        // But change content
        )

        XCTAssertThrowsError(try verifyAndExtract(tamperedEnvelope)) { error in
            guard case IntegrityError.checksumMismatch = error else {
                XCTFail("Expected checksumMismatch error, got \(error)")
                return
            }
        }
    }

    /// Tests verification from raw JSON data.
    func testVerifyFromRawData() throws {
        struct TestContent: Codable, Sendable, Equatable {
            let name: String
        }

        let original = TestContent(name: "test")
        let envelope = try createIntegrityEnvelope(original)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(envelope)

        let extracted: TestContent = try verifyAndExtract(from: data)
        XCTAssertEqual(original, extracted)
    }

    /// Tests that unsupported algorithm is rejected.
    func testUnsupportedAlgorithm() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let content = TestContent(value: 42)
        let metadata = IntegrityMetadata(
            algorithm: "md5",  // Unsupported
            checksum: "fake",
            contentLength: 10
        )
        let envelope = IntegrityEnvelope(integrity: metadata, content: content)

        XCTAssertThrowsError(try verifyAndExtract(envelope)) { error in
            guard case IntegrityError.unsupportedAlgorithm(let algo) = error else {
                XCTFail("Expected unsupportedAlgorithm error, got \(error)")
                return
            }
            XCTAssertEqual(algo, "md5")
        }
    }

    /// Tests that length mismatch is detected.
    func testLengthMismatch() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let content = TestContent(value: 42)
        let canonicalData = try toCanonicalJSON(content)
        let checksum = calculateChecksum(canonicalData)

        // Create metadata with wrong length
        let metadata = IntegrityMetadata(
            checksum: checksum,
            contentLength: canonicalData.count + 100  // Wrong length
        )
        let envelope = IntegrityEnvelope(integrity: metadata, content: content)

        XCTAssertThrowsError(try verifyAndExtract(envelope)) { error in
            guard case IntegrityError.lengthMismatch = error else {
                XCTFail("Expected lengthMismatch error, got \(error)")
                return
            }
        }
    }

    // MARK: - Vector Clock Tests

    /// Tests incrementing a vector clock.
    func testVectorClockIncrement() {
        var clock = VectorClock()

        let seq1 = clock.increment(for: "device-a")
        XCTAssertEqual(seq1, 1)

        let seq2 = clock.increment(for: "device-a")
        XCTAssertEqual(seq2, 2)

        let seq3 = clock.increment(for: "device-b")
        XCTAssertEqual(seq3, 1)

        XCTAssertEqual(clock.sequence(for: "device-a"), 2)
        XCTAssertEqual(clock.sequence(for: "device-b"), 1)
        XCTAssertEqual(clock.sequence(for: "device-c"), 0)  // Not in clock
    }

    /// Tests merging vector clocks (takes max).
    func testVectorClockMerge() {
        var clock1 = VectorClock(clocks: ["a": 5, "b": 3])
        let clock2 = VectorClock(clocks: ["a": 3, "b": 7, "c": 2])

        clock1.merge(with: clock2)

        XCTAssertEqual(clock1.sequence(for: "a"), 5)  // max(5, 3)
        XCTAssertEqual(clock1.sequence(for: "b"), 7)  // max(3, 7)
        XCTAssertEqual(clock1.sequence(for: "c"), 2)  // max(0, 2)
    }

    /// Tests happened-before relationship.
    func testVectorClockHappenedBefore() {
        let clock1 = VectorClock(clocks: ["a": 1, "b": 2])
        let clock2 = VectorClock(clocks: ["a": 2, "b": 3])

        XCTAssertTrue(clock1.happenedBefore(clock2), "clock1 should happen before clock2")
        XCTAssertFalse(clock2.happenedBefore(clock1), "clock2 should not happen before clock1")
    }

    /// Tests concurrent clocks (neither happened before the other).
    func testVectorClockConcurrent() {
        let clock1 = VectorClock(clocks: ["a": 2, "b": 1])
        let clock2 = VectorClock(clocks: ["a": 1, "b": 2])

        XCTAssertFalse(clock1.happenedBefore(clock2))
        XCTAssertFalse(clock2.happenedBefore(clock1))
        XCTAssertTrue(clock1.isConcurrent(with: clock2))
    }

    /// Tests that equal clocks are not concurrent.
    func testVectorClockEqualNotConcurrent() {
        let clock1 = VectorClock(clocks: ["a": 1, "b": 2])
        let clock2 = VectorClock(clocks: ["a": 1, "b": 2])

        XCTAssertFalse(clock1.isConcurrent(with: clock2), "Equal clocks should not be concurrent")
        XCTAssertEqual(clock1, clock2)
    }

    // MARK: - Chain Verification Tests

    /// Tests verifying a valid chain link.
    func testVerifyChainLink() throws {
        struct SimpleData: Codable, Sendable {
            let value: String
        }

        let operation1 = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "first"),
            vectorClock: VectorClock(clocks: ["dev": 1])
        )

        let change1 = ChangeLogEntry(
            deviceId: "dev",
            sequence: 1,
            timestamp: 1000,
            previousHash: nil,
            operation: operation1
        )

        // First change should verify with nil previous
        XCTAssertTrue(try verifyChainLink(change: change1, previousChange: nil))

        let hash1 = try calculateChecksum(change1)

        let operation2 = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "second"),
            vectorClock: VectorClock(clocks: ["dev": 2])
        )

        let change2 = ChangeLogEntry(
            deviceId: "dev",
            sequence: 2,
            timestamp: 2000,
            previousHash: hash1,
            operation: operation2
        )

        // Second change should verify with first as previous
        XCTAssertTrue(try verifyChainLink(change: change2, previousChange: change1))
    }

    /// Tests that broken chain is detected.
    func testBrokenChainDetection() throws {
        struct SimpleData: Codable, Sendable {
            let value: String
        }

        let operation = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "test"),
            vectorClock: VectorClock(clocks: ["dev": 2])
        )

        let change = ChangeLogEntry(
            deviceId: "dev",
            sequence: 2,
            timestamp: 2000,
            previousHash: "wrong_hash",  // Intentionally wrong
            operation: operation
        )

        let previousOperation = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "previous"),
            vectorClock: VectorClock(clocks: ["dev": 1])
        )

        let previousChange = ChangeLogEntry(
            deviceId: "dev",
            sequence: 1,
            timestamp: 1000,
            previousHash: nil,
            operation: previousOperation
        )

        XCTAssertThrowsError(try verifyChainLink(change: change, previousChange: previousChange)) { error in
            guard case IntegrityError.chainBroken = error else {
                XCTFail("Expected chainBroken error, got \(error)")
                return
            }
        }
    }

    /// Tests that first change with previousHash fails.
    func testFirstChangeWithHashFails() throws {
        struct SimpleData: Codable, Sendable {
            let value: String
        }

        let operation = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "test"),
            vectorClock: VectorClock(clocks: ["dev": 1])
        )

        let change = ChangeLogEntry(
            deviceId: "dev",
            sequence: 1,  // First change
            timestamp: 1000,
            previousHash: "should_be_nil",  // Wrong - should be nil
            operation: operation
        )

        XCTAssertThrowsError(try verifyChainLink(change: change, previousChange: nil)) { error in
            guard case IntegrityError.chainBroken = error else {
                XCTFail("Expected chainBroken error, got \(error)")
                return
            }
        }
    }

    /// Tests verifying an entire chain of changes.
    func testVerifyChangeChain() throws {
        struct SimpleData: Codable, Sendable {
            let value: Int
        }

        var changes: [ChangeLogEntry<SimpleData>] = []
        var previousHash: String? = nil

        for i in 1...5 {
            let operation = SyncOperation(
                type: .upsert,
                entity: .session,
                id: "123",
                data: SimpleData(value: i),
                vectorClock: VectorClock(clocks: ["dev": i])
            )

            let change = ChangeLogEntry(
                deviceId: "dev",
                sequence: i,
                timestamp: Int64(i * 1000),
                previousHash: previousHash,
                operation: operation
            )

            changes.append(change)
            previousHash = try calculateChecksum(change)
        }

        XCTAssertTrue(try verifyChangeChain(changes))
    }

    // MARK: - File Naming Tests

    /// Tests generating a change file name.
    func testChangeFileName() {
        let filename = SyncFileNaming.changeFileName(
            sequence: 42,
            timestamp: 1705772400000,
            entity: .session,
            operation: .upsert
        )

        XCTAssertEqual(filename, "000042_1705772400000_session_upsert.json")
    }

    /// Tests zero-padding for different sequence numbers.
    func testChangeFileNamePadding() {
        let name1 = SyncFileNaming.changeFileName(
            sequence: 1,
            timestamp: 1000,
            entity: .session,
            operation: .upsert
        )
        XCTAssertTrue(name1.hasPrefix("000001_"))

        let name2 = SyncFileNaming.changeFileName(
            sequence: 999999,
            timestamp: 1000,
            entity: .session,
            operation: .upsert
        )
        XCTAssertTrue(name2.hasPrefix("999999_"))
    }

    /// Tests parsing a valid change file name.
    func testParseChangeFileName() {
        let components = SyncFileNaming.parseChangeFileName(
            "000142_1705772400000_document_delete.json"
        )

        XCTAssertNotNil(components)
        XCTAssertEqual(components?.sequence, 142)
        XCTAssertEqual(components?.timestamp, 1705772400000)
        XCTAssertEqual(components?.entity, .document)
        XCTAssertEqual(components?.operation, .delete)
    }

    /// Tests parsing invalid file names returns nil.
    func testParseInvalidFileName() {
        XCTAssertNil(SyncFileNaming.parseChangeFileName("invalid.json"))
        XCTAssertNil(SyncFileNaming.parseChangeFileName("000001_abc_session_upsert.json"))
        XCTAssertNil(SyncFileNaming.parseChangeFileName("000001_1000_unknown_upsert.json"))
        XCTAssertNil(SyncFileNaming.parseChangeFileName("000001_1000_session_unknown.json"))
        XCTAssertNil(SyncFileNaming.parseChangeFileName("not_a_change_file.txt"))
    }

    /// Tests device file name generation.
    func testDeviceFileName() {
        let filename = SyncFileNaming.deviceFileName(deviceId: "abc-123-def")
        XCTAssertEqual(filename, "abc-123-def.json")
    }

    /// Tests device file name parsing.
    func testParseDeviceFileName() {
        let deviceId = SyncFileNaming.parseDeviceFileName("abc-123-def.json")
        XCTAssertEqual(deviceId, "abc-123-def")

        XCTAssertNil(SyncFileNaming.parseDeviceFileName("invalid.txt"))
    }

    /// Tests path generation for change files.
    func testChangeFilePath() {
        let path = SyncFileNaming.changeFilePath(
            deviceId: "device-abc",
            filename: "000001_1000_session_upsert.json"
        )
        XCTAssertEqual(path, "changes/device-abc/000001_1000_session_upsert.json")
    }

    /// Tests path generation for device files.
    func testDeviceFilePath() {
        let path = SyncFileNaming.deviceFilePath(deviceId: "device-abc")
        XCTAssertEqual(path, "devices/device-abc.json")
    }

    /// Tests manifest file path generation.
    func testManifestFilePath() {
        let path = SyncFileNaming.manifestFilePath(deviceId: "device-abc")
        XCTAssertEqual(path, "changes/device-abc/manifest.json")
    }

    /// Tests filtering by entity type.
    func testFilterByEntity() {
        let filenames = [
            "000001_1000_session_upsert.json",
            "000002_1000_document_upsert.json",
            "000003_1000_session_delete.json",
            "000004_1000_citation_upsert.json"
        ]

        let sessionFiles = SyncFileNaming.filterByEntity(filenames, entity: .session)
        XCTAssertEqual(sessionFiles.count, 2)
        XCTAssertTrue(sessionFiles.contains("000001_1000_session_upsert.json"))
        XCTAssertTrue(sessionFiles.contains("000003_1000_session_delete.json"))
    }

    /// Tests filtering by operation type.
    func testFilterByOperation() {
        let filenames = [
            "000001_1000_session_upsert.json",
            "000002_1000_document_delete.json",
            "000003_1000_session_delete.json"
        ]

        let deleteFiles = SyncFileNaming.filterByOperation(filenames, operation: .delete)
        XCTAssertEqual(deleteFiles.count, 2)
    }

    /// Tests filtering after a sequence number.
    func testFilterAfterSequence() {
        let filenames = [
            "000001_1000_session_upsert.json",
            "000002_1000_session_upsert.json",
            "000003_1000_session_upsert.json",
            "000004_1000_session_upsert.json"
        ]

        let after2 = SyncFileNaming.filterAfterSequence(filenames, sequence: 2)
        XCTAssertEqual(after2.count, 2)
        XCTAssertTrue(after2.contains("000003_1000_session_upsert.json"))
        XCTAssertTrue(after2.contains("000004_1000_session_upsert.json"))
    }

    /// Tests sorting by sequence.
    func testSortBySequence() {
        let filenames = [
            "000003_1000_session_upsert.json",
            "000001_1000_session_upsert.json",
            "000004_1000_session_upsert.json",
            "000002_1000_session_upsert.json"
        ]

        let sorted = SyncFileNaming.sortBySequence(filenames)

        XCTAssertEqual(sorted[0], "000001_1000_session_upsert.json")
        XCTAssertEqual(sorted[1], "000002_1000_session_upsert.json")
        XCTAssertEqual(sorted[2], "000003_1000_session_upsert.json")
        XCTAssertEqual(sorted[3], "000004_1000_session_upsert.json")
    }

    // MARK: - Manifest Checksum Tests

    /// Tests computing manifest checksum.
    func testComputeManifestChecksum() {
        let files = [
            ManifestFileEntry(sequence: 1, filename: "a.json", checksum: "abc", size: 100, timestamp: 1000),
            ManifestFileEntry(sequence: 2, filename: "b.json", checksum: "def", size: 200, timestamp: 2000)
        ]

        let checksum1 = computeManifestChecksum(files)

        // Same files in different order should produce same checksum (sorted by sequence)
        let filesReversed = [
            ManifestFileEntry(sequence: 2, filename: "b.json", checksum: "def", size: 200, timestamp: 2000),
            ManifestFileEntry(sequence: 1, filename: "a.json", checksum: "abc", size: 100, timestamp: 1000)
        ]

        let checksum2 = computeManifestChecksum(filesReversed)

        XCTAssertEqual(checksum1, checksum2, "Order should not affect manifest checksum")
    }

    // MARK: - Timestamp Tests

    /// Tests sync timestamp conversion.
    func testSyncTimestamp() {
        let date = Date(timeIntervalSince1970: 1705772400)  // 2024-01-20 15:00:00 UTC
        let timestamp = syncTimestamp(from: date)
        XCTAssertEqual(timestamp, 1705772400000)

        let convertedBack = dateFromSyncTimestamp(timestamp)
        XCTAssertEqual(convertedBack.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Error Description Tests

    /// Tests that all integrity errors have descriptions.
    func testIntegrityErrorDescriptions() {
        let errors: [IntegrityError] = [
            .missingEnvelope,
            .unsupportedAlgorithm("md5"),
            .checksumMismatch(expected: "abc123", actual: "def456"),
            .lengthMismatch(expected: 100, actual: 200),
            .chainBroken(sequence: 5, expected: "abc", actual: "def"),
            .missingFile("test.json"),
            .unexpectedFile("extra.json"),
            .schemaVersionTooNew(found: 99, maxSupported: 1),
            .jsonError(NSError(domain: "test", code: 1))
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description should not be empty")
        }
    }

    /// Tests that storage errors have descriptions.
    func testSyncStorageErrorDescriptions() {
        let errors: [SyncStorageError] = [
            .rootDirectoryUnavailable(path: "/test"),
            .readFailed(path: "/test", underlying: nil),
            .writeFailed(path: "/test", underlying: NSError(domain: "test", code: 1)),
            .deleteFailed(path: "/test", underlying: nil),
            .listingFailed(path: "/test", underlying: nil),
            .iCloudTimeout(path: "/test"),
            .deviceNotRegistered(deviceId: "test"),
            .workspaceNotInitialized
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
        }
    }
}
