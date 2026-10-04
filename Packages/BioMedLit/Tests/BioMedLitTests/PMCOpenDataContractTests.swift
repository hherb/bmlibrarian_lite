import XCTest
@testable import BioMedLit

/// PMC's open-data bucket helpers against the shared contract (#480).
final class PMCOpenDataContractTests: XCTestCase {
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

    private func contract() throws -> [String: Any] {
        let url = try XCTUnwrap(Self.contractFile, "pmc_open_data.json not found")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testTheNamesAreTheContracts() throws {
        let c = try contract()
        XCTAssertEqual(BioMedLitConstants.pmcOpenDataServiceName, c["service_name"] as? String)
        // Restored in Task 6:
        // XCTAssertEqual(FullTextSource.pmcOpenData.rawValue, c["source"] as? String)
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
}
