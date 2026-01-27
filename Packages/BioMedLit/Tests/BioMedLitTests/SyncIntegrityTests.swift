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

import XCTest
@testable import BioMedLit

/// Tests for Phase 1 sync integrity functionality.
final class SyncIntegrityTests: XCTestCase {

    // MARK: - Canonical JSON Tests

    /// Test that canonical JSON produces consistent output with sorted keys.
    func testCanonicalJSONSortedKeys() throws {
        struct TestContent: Codable, Sendable {
            let z: Int
            let a: String
            let m: [Int]
        }

        let content = TestContent(z: 1, a: "hello", m: [3, 2, 1])
        let data = try toCanonicalJSON(content)
        let jsonString = String(data: data, encoding: .utf8)!

        // Keys must be sorted alphabetically
        XCTAssertTrue(jsonString.contains("\"a\":\"hello\""))
        XCTAssertTrue(jsonString.contains("\"m\":[3,2,1]"))
        XCTAssertTrue(jsonString.contains("\"z\":1"))

        // Verify order: a before m before z
        let aIndex = jsonString.range(of: "\"a\"")!.lowerBound
        let mIndex = jsonString.range(of: "\"m\"")!.lowerBound
        let zIndex = jsonString.range(of: "\"z\"")!.lowerBound

        XCTAssertLessThan(aIndex, mIndex)
        XCTAssertLessThan(mIndex, zIndex)
    }

    /// Test that canonical JSON is compact (no whitespace).
    func testCanonicalJSONCompact() throws {
        struct TestContent: Codable, Sendable {
            let name: String
            let value: Int
        }

        let content = TestContent(name: "test", value: 42)
        let data = try toCanonicalJSON(content)
        let jsonString = String(data: data, encoding: .utf8)!

        // Should not contain newlines or indentation
        XCTAssertFalse(jsonString.contains("\n"))
        XCTAssertFalse(jsonString.contains("  "))
    }

    // MARK: - Checksum Tests

    /// Test that identical content produces identical checksums.
    func testChecksumConsistency() throws {
        struct TestContent: Codable, Sendable {
            let name: String
            let value: Int
        }

        let content1 = TestContent(name: "test", value: 42)
        let content2 = TestContent(name: "test", value: 42)

        let checksum1 = try calculateChecksum(content1)
        let checksum2 = try calculateChecksum(content2)

        XCTAssertEqual(checksum1, checksum2)
    }

    /// Test that different content produces different checksums.
    func testChecksumDifference() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let content1 = TestContent(value: 1)
        let content2 = TestContent(value: 2)

        let checksum1 = try calculateChecksum(content1)
        let checksum2 = try calculateChecksum(content2)

        XCTAssertNotEqual(checksum1, checksum2)
    }

    /// Test that checksum is a valid SHA-256 hex string.
    func testChecksumFormat() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let content = TestContent(value: 123)
        let checksum = try calculateChecksum(content)

        // SHA-256 produces 64 hex characters
        XCTAssertEqual(checksum.count, 64)

        // All characters should be valid hex
        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        for char in checksum.unicodeScalars {
            XCTAssertTrue(hexCharacters.contains(char))
        }
    }

    // MARK: - Integrity Envelope Tests

    /// Test creating and verifying an integrity envelope.
    func testIntegrityEnvelopeRoundTrip() throws {
        struct TestContent: Codable, Sendable, Equatable {
            let id: String
            let data: String
        }

        let original = TestContent(id: "test-123", data: "some data")
        let envelope = try createIntegrityEnvelope(original)
        let extracted = try verifyAndExtract(envelope)

        XCTAssertEqual(original, extracted)
    }

    /// Test that envelope contains correct metadata.
    func testIntegrityEnvelopeMetadata() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let content = TestContent(value: 42)
        let envelope = try createIntegrityEnvelope(content)

        XCTAssertEqual(envelope.integrity.version, SyncConstants.integrityVersion)
        XCTAssertEqual(envelope.integrity.algorithm, SyncConstants.integrityAlgorithm)
        XCTAssertFalse(envelope.integrity.checksum.isEmpty)
        XCTAssertGreaterThan(envelope.integrity.contentLength, 0)
    }

    /// Test that tampered content fails verification.
    func testIntegrityEnvelopeTamperDetection() throws {
        struct TestContent: Codable, Sendable {
            var value: Int
        }

        let original = TestContent(value: 42)
        let envelope = try createIntegrityEnvelope(original)

        // Tamper with the content
        let tamperedContent = TestContent(value: 99)
        let tamperedEnvelope = IntegrityEnvelope(
            integrity: envelope.integrity,
            content: tamperedContent
        )

        XCTAssertThrowsError(try verifyAndExtract(tamperedEnvelope)) { error in
            guard case IntegrityError.checksumMismatch = error else {
                XCTFail("Expected checksumMismatch error, got \(error)")
                return
            }
        }
    }

    /// Test verification from raw JSON data.
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

    /// Test that unsupported algorithm fails verification.
    func testUnsupportedAlgorithmError() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let content = TestContent(value: 42)
        let badMetadata = IntegrityMetadata(
            algorithm: "md5", // Not supported
            checksum: "fake",
            contentLength: 10
        )
        let badEnvelope = IntegrityEnvelope(
            integrity: badMetadata,
            content: content
        )

        XCTAssertThrowsError(try verifyAndExtract(badEnvelope)) { error in
            guard case IntegrityError.unsupportedAlgorithm(let alg) = error else {
                XCTFail("Expected unsupportedAlgorithm error, got \(error)")
                return
            }
            XCTAssertEqual(alg, "md5")
        }
    }

    // MARK: - Vector Clock Tests

    /// Test vector clock increment.
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
        XCTAssertEqual(clock.sequence(for: "device-c"), 0)
    }

    /// Test vector clock merge.
    func testVectorClockMerge() {
        var clock1 = VectorClock(clocks: ["a": 5, "b": 3])
        let clock2 = VectorClock(clocks: ["a": 3, "b": 7, "c": 2])

        clock1.merge(with: clock2)

        XCTAssertEqual(clock1.sequence(for: "a"), 5) // max(5, 3)
        XCTAssertEqual(clock1.sequence(for: "b"), 7) // max(3, 7)
        XCTAssertEqual(clock1.sequence(for: "c"), 2) // max(0, 2)
    }

    /// Test happened-before relationship.
    func testVectorClockHappenedBefore() {
        let clock1 = VectorClock(clocks: ["a": 1, "b": 2])
        let clock2 = VectorClock(clocks: ["a": 2, "b": 3])
        let clock3 = VectorClock(clocks: ["a": 2, "b": 1])

        // clock1 happened before clock2
        XCTAssertTrue(clock1.happenedBefore(clock2))
        XCTAssertFalse(clock2.happenedBefore(clock1))

        // clock1 and clock3 are concurrent
        XCTAssertFalse(clock1.happenedBefore(clock3))
        XCTAssertFalse(clock3.happenedBefore(clock1))
        XCTAssertTrue(clock1.isConcurrent(with: clock3))
    }

    /// Test identical clocks are not concurrent.
    func testVectorClockIdenticalNotConcurrent() {
        let clock1 = VectorClock(clocks: ["a": 1, "b": 2])
        let clock2 = VectorClock(clocks: ["a": 1, "b": 2])

        XCTAssertFalse(clock1.isConcurrent(with: clock2))
        XCTAssertEqual(clock1, clock2)
    }

    // MARK: - Chain Verification Tests

    /// Test verify chain link for first change.
    func testVerifyChainLinkFirst() throws {
        struct SimpleData: Codable, Sendable {
            let value: String
        }

        let operation = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "first"),
            vectorClock: VectorClock(clocks: ["dev": 1])
        )

        let change = ChangeLogEntry(
            deviceId: "dev",
            sequence: 1,
            timestamp: 1000,
            previousHash: nil,
            operation: operation
        )

        // First change should verify with nil previous
        XCTAssertTrue(try verifyChainLink(change: change, previousChange: nil))
    }

    /// Test verify chain link for subsequent change.
    func testVerifyChainLinkSubsequent() throws {
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

    /// Test broken chain detection.
    func testVerifyChainLinkBroken() throws {
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

        let operation2 = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "second"),
            vectorClock: VectorClock(clocks: ["dev": 2])
        )

        // Wrong previous hash
        let change2 = ChangeLogEntry(
            deviceId: "dev",
            sequence: 2,
            timestamp: 2000,
            previousHash: "wrong_hash",
            operation: operation2
        )

        XCTAssertThrowsError(try verifyChainLink(change: change2, previousChange: change1)) { error in
            guard case IntegrityError.chainBroken = error else {
                XCTFail("Expected chainBroken error, got \(error)")
                return
            }
        }
    }

    // MARK: - File Naming Tests

    /// Test change file name generation.
    func testChangeFileName() {
        let filename = SyncFileNaming.changeFileName(
            sequence: 42,
            timestamp: 1705772400000,
            entity: .session,
            operation: .upsert
        )

        XCTAssertEqual(filename, "000042_1705772400000_session_upsert.json")
    }

    /// Test change file name with large sequence.
    func testChangeFileNameLargeSequence() {
        let filename = SyncFileNaming.changeFileName(
            sequence: 999999,
            timestamp: 1705772400000,
            entity: .document,
            operation: .delete
        )

        XCTAssertEqual(filename, "999999_1705772400000_document_delete.json")
    }

    /// Test parse change file name.
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

    /// Test parse invalid file names returns nil.
    func testParseInvalidFileName() {
        XCTAssertNil(SyncFileNaming.parseChangeFileName("invalid.json"))
        XCTAssertNil(SyncFileNaming.parseChangeFileName("000001_abc_session_upsert.json"))
        XCTAssertNil(SyncFileNaming.parseChangeFileName("notjson.txt"))
        XCTAssertNil(SyncFileNaming.parseChangeFileName(""))
    }

    /// Test device file path generation.
    func testDeviceFilePath() {
        let path = SyncFileNaming.deviceFilePath(deviceId: "abc-123")
        XCTAssertEqual(path, "devices/abc-123.json")
    }

    /// Test change file path generation.
    func testChangeFilePath() {
        let path = SyncFileNaming.changeFilePath(
            deviceId: "device-1",
            filename: "000001_123_session_upsert.json"
        )
        XCTAssertEqual(path, "changes/device-1/000001_123_session_upsert.json")
    }

    // MARK: - Manifest Checksum Tests

    /// Test manifest checksum computation.
    func testComputeManifestChecksum() {
        let files = [
            ManifestFileEntry(sequence: 1, filename: "f1", checksum: "aaa", entryChecksum: "eee1", size: 100, timestamp: 1000),
            ManifestFileEntry(sequence: 2, filename: "f2", checksum: "bbb", entryChecksum: "eee2", size: 200, timestamp: 2000)
        ]

        let checksum1 = computeManifestChecksum(files)

        // Same files in different order should produce same checksum
        let reversedFiles = [
            ManifestFileEntry(sequence: 2, filename: "f2", checksum: "bbb", entryChecksum: "eee2", size: 200, timestamp: 2000),
            ManifestFileEntry(sequence: 1, filename: "f1", checksum: "aaa", entryChecksum: "eee1", size: 100, timestamp: 1000)
        ]

        let checksum2 = computeManifestChecksum(reversedFiles)

        XCTAssertEqual(checksum1, checksum2, "Manifest checksum should be order-independent")
    }

    /// Test empty manifest checksum.
    func testEmptyManifestChecksum() {
        let checksum = computeManifestChecksum([])
        XCTAssertFalse(checksum.isEmpty)
    }

    // MARK: - Additional Canonical JSON Tests

    /// Test that nested objects have sorted keys.
    func testCanonicalJSONNestedSorting() throws {
        struct Inner: Codable, Sendable {
            let z: String
            let a: Int
        }
        struct Outer: Codable, Sendable {
            let nested: Inner
            let b: String
        }

        let content = Outer(nested: Inner(z: "last", a: 1), b: "middle")
        let data = try toCanonicalJSON(content)
        let jsonString = String(data: data, encoding: .utf8)!

        // Outer keys should be sorted: b before nested
        let bIndex = jsonString.range(of: "\"b\"")!.lowerBound
        let nestedIndex = jsonString.range(of: "\"nested\"")!.lowerBound
        XCTAssertLessThan(bIndex, nestedIndex)

        // Inner keys should also be sorted: a before z
        let aIndex = jsonString.range(of: "\"a\"")!.lowerBound
        let zIndex = jsonString.range(of: "\"z\"")!.lowerBound
        XCTAssertLessThan(aIndex, zIndex)
    }

    /// Test checksum of raw data.
    func testRawDataChecksum() {
        let data = "Hello, World!".data(using: .utf8)!
        let checksum = calculateChecksum(data)

        // Known SHA-256 of "Hello, World!"
        XCTAssertEqual(checksum, "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f")
    }

    /// Test that length mismatch is detected.
    func testLengthMismatch() throws {
        struct TestContent: Codable, Sendable {
            let value: Int
        }

        let content = TestContent(value: 42)
        let canonicalData = try toCanonicalJSON(content)
        let checksum = calculateChecksum(canonicalData)

        // Create metadata with wrong length
        let badMetadata = IntegrityMetadata(
            checksum: checksum,
            contentLength: canonicalData.count + 100 // Wrong length
        )
        let badEnvelope = IntegrityEnvelope(integrity: badMetadata, content: content)

        XCTAssertThrowsError(try verifyAndExtract(badEnvelope)) { error in
            guard case IntegrityError.lengthMismatch(let expected, let actual) = error else {
                XCTFail("Expected lengthMismatch error, got \(error)")
                return
            }
            XCTAssertEqual(expected, canonicalData.count + 100)
            XCTAssertEqual(actual, canonicalData.count)
        }
    }

    /// Test vector clock concurrent detection.
    func testVectorClockConcurrent() {
        // clock1 has higher 'a', clock2 has higher 'b' - they are concurrent
        let clock1 = VectorClock(clocks: ["a": 2, "b": 1])
        let clock2 = VectorClock(clocks: ["a": 1, "b": 2])

        XCTAssertTrue(clock1.isConcurrent(with: clock2))
        XCTAssertTrue(clock2.isConcurrent(with: clock1))
        XCTAssertFalse(clock1.happenedBefore(clock2))
        XCTAssertFalse(clock2.happenedBefore(clock1))
    }

    /// Test that first change with non-nil previousHash fails.
    func testFirstChangeWithHashFails() throws {
        struct SimpleData: Codable, Sendable {
            let value: String
        }

        let operation = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "first"),
            vectorClock: VectorClock(clocks: ["dev": 1])
        )

        // First change (sequence 1) should NOT have a previous hash
        let badChange = ChangeLogEntry(
            deviceId: "dev",
            sequence: 1,
            timestamp: 1000,
            previousHash: "should_be_nil",
            operation: operation
        )

        XCTAssertThrowsError(try verifyChainLink(change: badChange, previousChange: nil)) { error in
            guard case IntegrityError.chainBroken = error else {
                XCTFail("Expected chainBroken error, got \(error)")
                return
            }
        }
    }

    /// Test verifying a full change chain.
    func testVerifyChangeChain() throws {
        struct SimpleData: Codable, Sendable {
            let value: String
        }

        // Create first change
        let op1 = SyncOperation(
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
            operation: op1
        )

        // Create second change
        let hash1 = try calculateChecksum(change1)
        let op2 = SyncOperation(
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
            operation: op2
        )

        // Create third change
        let hash2 = try calculateChecksum(change2)
        let op3 = SyncOperation(
            type: .upsert,
            entity: .session,
            id: "123",
            data: SimpleData(value: "third"),
            vectorClock: VectorClock(clocks: ["dev": 3])
        )
        let change3 = ChangeLogEntry(
            deviceId: "dev",
            sequence: 3,
            timestamp: 3000,
            previousHash: hash2,
            operation: op3
        )

        // Verify the full chain
        XCTAssertTrue(try verifyChangeChain([change1, change2, change3]))
    }

    // MARK: - Additional File Naming Tests

    /// Test that sequence padding works correctly.
    func testChangeFileNamePadding() {
        // Single digit
        let name1 = SyncFileNaming.changeFileName(
            sequence: 1,
            timestamp: 1000,
            entity: .session,
            operation: .upsert
        )
        XCTAssertTrue(name1.hasPrefix("000001_"))

        // Three digits
        let name2 = SyncFileNaming.changeFileName(
            sequence: 142,
            timestamp: 1000,
            entity: .session,
            operation: .upsert
        )
        XCTAssertTrue(name2.hasPrefix("000142_"))
    }

    /// Test device file name generation.
    func testDeviceFileName() {
        let filename = SyncFileNaming.deviceFileName(deviceId: "abc-123-def")
        XCTAssertEqual(filename, "abc-123-def.json")
    }

    /// Test parsing device file name.
    func testParseDeviceFileName() {
        let deviceId = SyncFileNaming.parseDeviceFileName("abc-123-def.json")
        XCTAssertEqual(deviceId, "abc-123-def")

        // Invalid format
        XCTAssertNil(SyncFileNaming.parseDeviceFileName("abc-123-def.txt"))
        XCTAssertNil(SyncFileNaming.parseDeviceFileName(""))
    }

    /// Test manifest file path generation.
    func testManifestFilePath() {
        let path = SyncFileNaming.manifestPath(deviceId: "device-abc")
        XCTAssertEqual(path, "changes/device-abc/manifest.json")
    }

    // MARK: - Filtering and Sorting Tests

    /// Test filtering files by entity type.
    func testFilterByEntity() {
        let filenames = [
            "000001_1000_session_upsert.json",
            "000002_2000_document_upsert.json",
            "000003_3000_session_delete.json",
            "000004_4000_citation_upsert.json"
        ]

        let sessionFiles = SyncFileNaming.filterByEntity(filenames, entity: .session)
        XCTAssertEqual(sessionFiles.count, 2)
        XCTAssertTrue(sessionFiles.contains("000001_1000_session_upsert.json"))
        XCTAssertTrue(sessionFiles.contains("000003_3000_session_delete.json"))

        let documentFiles = SyncFileNaming.filterByEntity(filenames, entity: .document)
        XCTAssertEqual(documentFiles.count, 1)
        XCTAssertTrue(documentFiles.contains("000002_2000_document_upsert.json"))
    }

    /// Test filtering files by operation type.
    func testFilterByOperation() {
        let filenames = [
            "000001_1000_session_upsert.json",
            "000002_2000_document_delete.json",
            "000003_3000_session_delete.json",
            "000004_4000_citation_upsert.json"
        ]

        let upsertFiles = SyncFileNaming.filterByOperation(filenames, operation: .upsert)
        XCTAssertEqual(upsertFiles.count, 2)
        XCTAssertTrue(upsertFiles.contains("000001_1000_session_upsert.json"))
        XCTAssertTrue(upsertFiles.contains("000004_4000_citation_upsert.json"))

        let deleteFiles = SyncFileNaming.filterByOperation(filenames, operation: .delete)
        XCTAssertEqual(deleteFiles.count, 2)
    }

    /// Test filtering files after a sequence number.
    func testFilterAfterSequence() {
        let filenames = [
            "000001_1000_session_upsert.json",
            "000002_2000_document_upsert.json",
            "000003_3000_session_delete.json",
            "000004_4000_citation_upsert.json"
        ]

        let afterTwo = SyncFileNaming.filterAfterSequence(filenames, sequence: 2)
        XCTAssertEqual(afterTwo.count, 2)
        XCTAssertTrue(afterTwo.contains("000003_3000_session_delete.json"))
        XCTAssertTrue(afterTwo.contains("000004_4000_citation_upsert.json"))

        let afterZero = SyncFileNaming.filterAfterSequence(filenames, sequence: 0)
        XCTAssertEqual(afterZero.count, 4)

        let afterFour = SyncFileNaming.filterAfterSequence(filenames, sequence: 4)
        XCTAssertEqual(afterFour.count, 0)
    }

    /// Test sorting files by sequence number.
    func testSortBySequence() {
        let filenames = [
            "000003_3000_session_delete.json",
            "000001_1000_session_upsert.json",
            "000004_4000_citation_upsert.json",
            "000002_2000_document_upsert.json"
        ]

        let sorted = SyncFileNaming.sortBySequence(filenames)

        XCTAssertEqual(sorted[0], "000001_1000_session_upsert.json")
        XCTAssertEqual(sorted[1], "000002_2000_document_upsert.json")
        XCTAssertEqual(sorted[2], "000003_3000_session_delete.json")
        XCTAssertEqual(sorted[3], "000004_4000_citation_upsert.json")
    }

    // MARK: - Timestamp Utility Tests

    /// Test sync timestamp conversion.
    func testSyncTimestamp() {
        let date = Date(timeIntervalSince1970: 1705772400) // 2024-01-20 15:00:00 UTC
        let timestamp = syncTimestamp(from: date)

        XCTAssertEqual(timestamp, 1705772400000) // milliseconds

        // Round trip
        let roundTrip = dateFromSyncTimestamp(timestamp)
        XCTAssertEqual(roundTrip.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Error Description Tests

    /// Test integrity error descriptions.
    func testIntegrityErrorDescriptions() {
        let missingEnvelope = IntegrityError.missingEnvelope
        XCTAssertNotNil(missingEnvelope.errorDescription)
        XCTAssertFalse(missingEnvelope.errorDescription!.isEmpty)

        let unsupported = IntegrityError.unsupportedAlgorithm("md5")
        XCTAssertTrue(unsupported.errorDescription!.contains("md5"))

        let checksumError = IntegrityError.checksumMismatch(
            expected: "abcd1234567890abcd1234567890abcd",
            actual: "1234abcd567890ab1234abcd567890ab"
        )
        XCTAssertNotNil(checksumError.errorDescription)

        let lengthError = IntegrityError.lengthMismatch(expected: 100, actual: 50)
        XCTAssertTrue(lengthError.errorDescription!.contains("100"))
        XCTAssertTrue(lengthError.errorDescription!.contains("50"))

        let chainError = IntegrityError.chainBroken(sequence: 5, expected: "abc", actual: "xyz")
        XCTAssertTrue(chainError.errorDescription!.contains("5"))

        let missingFile = IntegrityError.missingFile("test.json")
        XCTAssertTrue(missingFile.errorDescription!.contains("test.json"))

        let unexpectedFile = IntegrityError.unexpectedFile("extra.json")
        XCTAssertTrue(unexpectedFile.errorDescription!.contains("extra.json"))

        let versionError = IntegrityError.schemaVersionTooNew(found: 5, maxSupported: 2)
        XCTAssertTrue(versionError.errorDescription!.contains("5"))
        XCTAssertTrue(versionError.errorDescription!.contains("2"))
    }
}
