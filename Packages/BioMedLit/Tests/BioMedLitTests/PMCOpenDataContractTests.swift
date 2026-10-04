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
        for row in try XCTUnwrap(contract()["latest_metadata_key"] as? [[String: Any]]) {
            let name = row["name"] as? String ?? "?"
            let listing = Data((row["listing"] as? String ?? "").utf8)
            let pmcid = row["pmcid"] as? String ?? ""
            if row["error"] != nil {
                XCTAssertThrowsError(
                    try PMCOpenData.latestMetadataKey(listing: listing, pmcid: pmcid), name)
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
        for row in try XCTUnwrap(contract()["record"] as? [[String: Any]]) {
            let name = row["name"] as? String ?? "?"
            let metadata = try JSONSerialization.data(withJSONObject: row["metadata"] as Any)
            let record = try PMCOpenDataRecord(metadata: metadata)
            XCTAssertEqual(record.xmlURL?.absoluteString, row["xml_url"] as? String, name)
            XCTAssertEqual(record.isOpenAccess, row["is_open_access"] as? Bool, name)
            XCTAssertEqual(record.isManuscript, row["is_manuscript"] as? Bool, name)
            XCTAssertEqual(record.licenseCode, row["license_code"] as? String, name)
        }
    }

    func testARecordThatIsNotAnObjectIsRefused() {
        XCTAssertThrowsError(try PMCOpenDataRecord(metadata: Data("[]".utf8)))
        XCTAssertThrowsError(try PMCOpenDataRecord(metadata: Data("not json".utf8)))
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
