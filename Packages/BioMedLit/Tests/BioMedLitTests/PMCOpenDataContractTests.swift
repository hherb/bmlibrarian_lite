import XCTest
@testable import BioMedLit

/// Reads `doc/cross_platform/fulltext_parity/pmc_open_data.json`, shared by
/// the contract tests and the chain's status-table test.
enum PMCOpenDataContract {
    private static let contractFile: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(
                "doc/cross_platform/fulltext_parity/pmc_open_data.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return nil
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { return nil }
            directory = parent
        }
    }()

    static func load() throws -> [String: Any] {
        let url = try XCTUnwrap(contractFile, "pmc_open_data.json not found")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

/// PMC's open-data bucket helpers against the shared contract (#480).
final class PMCOpenDataContractTests: XCTestCase {
    private func contract() throws -> [String: Any] { try PMCOpenDataContract.load() }

    func testTheNamesAreTheContracts() throws {
        let c = try contract()
        XCTAssertEqual(BioMedLitConstants.pmcOpenDataServiceName, c["service_name"] as? String)
        XCTAssertEqual(FullTextSource.pmcOpenData.rawValue, c["source"] as? String)
        XCTAssertEqual(BioMedLitConstants.pmcOpenDataBaseURL, c["base_url"] as? String)
    }

    func testLatestMetadataKey() throws {
        let rows = try XCTUnwrap(contract()["latest_metadata_key"] as? [[String: Any]])
        XCTAssertTrue(rows.contains { $0["error"] != nil }, "control: the error form is run")
        for row in rows {
            let name = row["name"] as? String ?? "?"
            let listing = Data((row["listing"] as? String ?? "").utf8)
            let pmcid = row["pmcid"] as? String ?? ""
            if let error = row["error"] {
                XCTAssertEqual(error as? String, Self.malformed, name)
                XCTAssertThrowsError(
                    try PMCOpenData.latestMetadataKey(listing: listing, pmcid: pmcid), name
                ) { XCTAssertTrue($0 is PMCOpenData.UnreadableAnswer, "\(name): \($0)") }
            } else {
                XCTAssertEqual(
                    try PMCOpenData.latestMetadataKey(listing: listing, pmcid: pmcid),
                    row["key"] as? String, name)
            }
        }
    }

    func testHTTPSURL() throws {
        for row in try XCTUnwrap(contract()["https_url"] as? [[String: Any]]) {
            XCTAssertEqual(
                PMCOpenData.httpsURL(row["s3_url"] as? String ?? "")?.absoluteString,
                row["https_url"] as? String, row["name"] as? String ?? "?")
        }
    }

    func testRecord() throws {
        let rows = try XCTUnwrap(contract()["record"] as? [[String: Any]])
        XCTAssertTrue(rows.contains { $0["error"] != nil }, "control: the error form is run")
        for row in rows {
            let name = row["name"] as? String ?? "?"
            let metadata = try JSONSerialization.data(withJSONObject: row["metadata"] as Any)
            if let error = row["error"] {
                XCTAssertEqual(error as? String, Self.malformed, name)
                XCTAssertThrowsError(try PMCOpenDataRecord(metadata: metadata), name) {
                    XCTAssertEqual($0 as? PMCOpenData.UnreadableAnswer, .unreadableXMLURL, name)
                }
                continue
            }
            let record = try PMCOpenDataRecord(metadata: metadata)
            XCTAssertEqual(record.xmlURL?.absoluteString, row["xml_url"] as? String, name)
            XCTAssertEqual(record.isOpenAccess, row["is_open_access"] as? Bool, name)
            XCTAssertEqual(record.isManuscript, row["is_manuscript"] as? Bool, name)
            XCTAssertEqual(record.licenseCode, row["license_code"] as? String, name)
        }
    }

    func testARecordThatIsNotAnObjectIsRefused() {
        for body in ["[]", "not json"] {
            XCTAssertThrowsError(try PMCOpenDataRecord(metadata: Data(body.utf8)), body) {
                XCTAssertEqual($0 as? PMCOpenData.UnreadableAnswer, .notARecord, body)
            }
        }
    }

    /// A missing `xml_url` and a JSON `null` both name no XML; the record is
    /// read, not refused. The control for the contract's malformed rows.
    func testAMissingOrNullXMLURLNamesNoXML() throws {
        for body in [#"{"pmcid": "PMC7"}"#, #"{"pmcid": "PMC7", "xml_url": null}"#] {
            XCTAssertNil(try PMCOpenDataRecord(metadata: Data(body.utf8)).xmlURL, body)
        }
    }

    /// Bytes that are not UTF-8, in a body that is otherwise readable.
    private static let latin1Byte: UInt8 = 0xE9

    func testStrictUTF8() {
        XCTAssertEqual(PMCOpenData.strictUTF8(Data("Müller – β".utf8)), "Müller – β")
        XCTAssertEqual(PMCOpenData.strictUTF8(Data()), "")
        XCTAssertNil(PMCOpenData.strictUTF8(Data([0x61, Self.latin1Byte, 0x62])))
        // A truncated multi-byte sequence.
        XCTAssertNil(PMCOpenData.strictUTF8(Data("β".utf8).prefix(1)))
    }

    /// A listing that declares Latin-1 is still read as UTF-8: the bytes are
    /// not UTF-8, so it is unreadable, whatever the declaration says.
    func testAListingThatIsNotUTF8IsUnreadable() {
        var listing = Data("""
            <?xml version="1.0" encoding="ISO-8859-1"?>\
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
            <Contents><Key>metadata/PMC1.1.json</Key></Contents><Name>
            """.utf8)
        listing.append(Self.latin1Byte)
        listing.append(Data("</Name></ListBucketResult>".utf8))
        XCTAssertThrowsError(try PMCOpenData.latestMetadataKey(listing: listing, pmcid: "PMC1")) {
            XCTAssertEqual($0 as? PMCOpenData.UnreadableAnswer, .notUTF8)
        }
    }

    func testARecordThatIsNotUTF8IsUnreadable() {
        var record = Data(#"{"license_code": ""#.utf8)
        record.append(Self.latin1Byte)
        record.append(Data(#"", "xml_url": "s3://pmc-oa-opendata/PMC1.1/PMC1.1.xml"}"#.utf8))
        XCTAssertThrowsError(try PMCOpenDataRecord(metadata: record)) {
            XCTAssertEqual($0 as? PMCOpenData.UnreadableAnswer, .notUTF8)
        }
    }

    /// A key under the prefix that does not end in `.json` is unreadable,
    /// and refuses the listing when nothing else is readable.
    func testAKeyUnderThePrefixWithAnotherSuffixIsUnreadable() throws {
        let listing = Data("""
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
            <Contents><Key>metadata/PMC1.1.xml</Key></Contents></ListBucketResult>
            """.utf8)
        XCTAssertThrowsError(try PMCOpenData.latestMetadataKey(listing: listing, pmcid: "PMC1")) {
            XCTAssertEqual($0 as? PMCOpenData.UnreadableAnswer, .noReadableVersion)
        }
    }

    /// A combining mark after the prefix's `.` joins it in one `Character`;
    /// the key is still under the prefix, byte for byte, and unreadable.
    func testACombiningMarkAfterThePrefixIsUnreadableNotIgnored() throws {
        let listing = Data("""
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
            <Contents><Key>metadata/PMC1.\u{0301}1.json</Key></Contents></ListBucketResult>
            """.utf8)
        XCTAssertThrowsError(try PMCOpenData.latestMetadataKey(listing: listing, pmcid: "PMC1")) {
            XCTAssertEqual($0 as? PMCOpenData.UnreadableAnswer, .noReadableVersion)
        }
    }

    /// Equal versions: the key that sorts last, as Python's `max` over
    /// `(version, key)` picks it.
    func testEqualVersionsGoToTheKeyThatSortsLast() throws {
        let listing = Data("""
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
            <Contents><Key>metadata/PMC1.2.json</Key></Contents>\
            <Contents><Key>metadata/PMC1.0002.json</Key></Contents>\
            <Contents><Key>metadata/PMC1.0.json</Key></Contents></ListBucketResult>
            """.utf8)
        XCTAssertEqual(try PMCOpenData.latestMetadataKey(listing: listing, pmcid: "PMC1"),
                       "metadata/PMC1.2.json")
    }

    /// A prefixed root in the S3 namespace is the same element, as Python's
    /// namespace-qualified tag test reads it; only the namespace is required.
    func testAPrefixedS3RootIsAListing() throws {
        let listing = Data("""
            <s3:ListBucketResult xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">\
            <s3:Contents><s3:Key>metadata/PMC1.2.json</s3:Key></s3:Contents>\
            <s3:Contents><s3:Key>metadata/PMC1.1.json</s3:Key></s3:Contents></s3:ListBucketResult>
            """.utf8)
        XCTAssertEqual(try PMCOpenData.latestMetadataKey(listing: listing, pmcid: "PMC1"),
                       "metadata/PMC1.2.json")
    }

    /// A `Key` outside the S3 namespace is not one the listing names.
    func testAKeyInAnotherNamespaceIsIgnored() throws {
        let listing = Data("""
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
            <Contents><Key xmlns="urn:other">metadata/PMC1.9.json</Key></Contents>\
            <Contents><Key>metadata/PMC1.1.json</Key></Contents></ListBucketResult>
            """.utf8)
        XCTAssertEqual(try PMCOpenData.latestMetadataKey(listing: listing, pmcid: "PMC1"),
                       "metadata/PMC1.1.json")
    }

    func testNotEstablishedSentences() throws {
        let rows = try XCTUnwrap(contract()["not_established_sentence"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let failureObject = try XCTUnwrap(row["failure"] as? [String: Any])
            let kind = try XCTUnwrap(RequestFailureKind(rawValue: failureObject["kind"] as? String ?? ""))
            let failure = try Self.failure(kind: kind, statusCode: failureObject["status_code"] as? Int)
            XCTAssertEqual(
                FullTextError.notEstablishedSentence(service: row["service"] as? String ?? "",
                                                     failure: failure),
                row["sentence"] as? String)
        }
    }

    /// The two errors that use the sentence name their own service.
    func testTheErrorsUseTheSentence() {
        XCTAssertEqual(
            FullTextError.pmcOpenDataNotEstablished(.timeout).errorDescription,
            FullTextError.notEstablishedSentence(
                service: BioMedLitConstants.pmcOpenDataServiceName, failure: .timeout))
        XCTAssertEqual(
            FullTextError.absenceNotEstablished(.httpStatus(404)).errorDescription,
            FullTextError.notEstablishedSentence(service: "Europe PMC", failure: .httpStatus(404)))
    }

    /// The contract's spelling of an answer we cannot read.
    private static let malformed = "malformed"

    private static func failure(kind: RequestFailureKind, statusCode: Int?) throws -> RequestFailure {
        switch kind {
        case .httpStatus: return .httpStatus(try XCTUnwrap(statusCode))
        case .timeout: return .timeout
        case .connection: return .connection
        case .serviceError: return .serviceError
        case .malformedResponse: return .malformedResponse
        case .incompleteResponse: return .incompleteResponse
        case .requestFailed: return .requestFailed
        case .redirectRefused: return .redirectRefused(statusCode: statusCode)
        }
    }
}
