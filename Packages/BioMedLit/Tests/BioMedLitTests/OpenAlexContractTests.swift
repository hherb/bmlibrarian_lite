import XCTest
@testable import BioMedLit

/// Loads the shared OpenAlex contract (#480, stage B).
enum OpenAlexContract {
    private static let contractFile: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(
                "doc/cross_platform/fulltext_parity/openalex_locations.json")
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
        let url = try XCTUnwrap(contractFile, "openalex_locations.json not found")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

final class OpenAlexContractTests: XCTestCase {
    private func table(_ name: String) throws -> [[String: Any]] {
        try XCTUnwrap(OpenAlexContract.load()[name] as? [[String: Any]], name)
    }

    func testEveryContractTableIsReadHere() throws {
        XCTAssertEqual(
            Set(try OpenAlexContract.load().keys),
            ["schema_version", "description", "service_name", "pdf_service_name", "source",
             "base_url", "work_url", "pdf_urls", "status"]
        )
    }

    func testTheNamesAreTheContracts() throws {
        let contract = try OpenAlexContract.load()
        XCTAssertEqual(contract["service_name"] as? String, OpenAccessSource.openAlex.serviceName)
        XCTAssertEqual(contract["pdf_service_name"] as? String, OpenAccessSource.openAlexPDF.serviceName)
        XCTAssertEqual(contract["base_url"] as? String, BioMedLitConstants.openAlexBaseURL)
        XCTAssertEqual(BioMedLitConstants.openAlexServiceName, OpenAccessSource.openAlex.serviceName)
    }

    func testEachWorkURLRow() throws {
        let rows = try table("work_url")
        XCTAssertGreaterThanOrEqual(rows.count, 5)
        for row in rows {
            let name = row["name"] as? String ?? "?"
            let url = OpenAlex.workURL(doi: row["doi"] as! String, mailto: row["mailto"] as? String)
            XCTAssertEqual(url?.absoluteString, row["url"] as? String, name)
        }
    }

    func testEachPDFURLsRow() throws {
        let rows = try table("pdf_urls")
        XCTAssertGreaterThanOrEqual(rows.count, 8)
        for row in rows {
            let name = row["name"] as? String ?? "?"
            let work = row["work"] as Any
            if row["malformed"] as? Bool == true {
                XCTAssertThrowsError(try OpenAlex.pdfURLs(fromWorkObject: work), name)
                continue
            }
            let tried = Set(row["tried"] as? [String] ?? [])
            XCTAssertEqual(
                OpenAlex.untried(try OpenAlex.pdfURLs(fromWorkObject: work), tried: tried),
                row["expected"] as? [String],
                name
            )
        }
    }
}
