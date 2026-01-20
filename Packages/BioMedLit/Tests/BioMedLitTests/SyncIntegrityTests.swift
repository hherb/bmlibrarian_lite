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
            ManifestFileEntry(sequence: 1, filename: "f1", checksum: "aaa", size: 100, timestamp: 1000),
            ManifestFileEntry(sequence: 2, filename: "f2", checksum: "bbb", size: 200, timestamp: 2000)
        ]

        let checksum1 = computeManifestChecksum(files)

        // Same files in different order should produce same checksum
        let reversedFiles = [
            ManifestFileEntry(sequence: 2, filename: "f2", checksum: "bbb", size: 200, timestamp: 2000),
            ManifestFileEntry(sequence: 1, filename: "f1", checksum: "aaa", size: 100, timestamp: 1000)
        ]

        let checksum2 = computeManifestChecksum(reversedFiles)

        XCTAssertEqual(checksum1, checksum2, "Manifest checksum should be order-independent")
    }

    /// Test empty manifest checksum.
    func testEmptyManifestChecksum() {
        let checksum = computeManifestChecksum([])
        XCTAssertFalse(checksum.isEmpty)
    }
}
