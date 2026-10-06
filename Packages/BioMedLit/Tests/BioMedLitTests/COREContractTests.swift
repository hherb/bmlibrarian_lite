import XCTest
@testable import BioMedLit

/// Loads the shared CORE contract (#480, stage C).
enum COREContract {
    private static let contractFile: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(
                "doc/cross_platform/fulltext_parity/core_fulltext.json")
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
        let url = try XCTUnwrap(contractFile, "core_fulltext.json not found")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

final class COREContractTests: XCTestCase {
    private var contract: [String: Any] = [:]

    override func setUpWithError() throws {
        contract = try COREContract.load()
    }

    private func table(_ name: String, minimum: Int) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(contract[name] as? [[String: Any]], name)
        XCTAssertGreaterThanOrEqual(rows.count, minimum, "\(name) lost rows")
        return rows
    }

    func testEveryContractTableIsReadHere() {
        XCTAssertEqual(Set(contract.keys), [
            "schema_version", "description", "service_name", "source", "source_label",
            "desktop_source_type", "base_url", "min_fulltext_chars",
            "pause_after_consecutive_429", "key_refused_status", "key_refused_reason",
            "search_url", "full_text", "status", "bodies",
        ])
    }

    func testTheNamesAreTheContracts() {
        XCTAssertEqual(contract["service_name"] as? String, BioMedLitConstants.coreServiceName)
        XCTAssertEqual(contract["source"] as? String, OpenAccessSource.core.rawValue)
        XCTAssertEqual(contract["base_url"] as? String, BioMedLitConstants.coreBaseURL)
        XCTAssertEqual(contract["min_fulltext_chars"] as? Int, BioMedLitConstants.coreMinFullTextCharacters)
        XCTAssertEqual(contract["pause_after_consecutive_429"] as? Int, BioMedLitConstants.corePauseAfterConsecutive429)
        XCTAssertEqual(OpenAccessSource.core.serviceName, "CORE")
        XCTAssertEqual(contract["key_refused_status"] as? Int, BioMedLitConstants.coreKeyRefusedStatus)
        XCTAssertEqual(contract["key_refused_reason"] as? String, BioMedLitConstants.coreKeyRefusedReason)
    }

    func testEachSearchURL() throws {
        for row in try table("search_url", minimum: 7) {
            let name = row["name"] as? String ?? "?"
            let doi = try XCTUnwrap(row["doi"] as? String, name)
            let base = row["base_url"] as? String ?? BioMedLitConstants.coreBaseURL
            XCTAssertEqual(CORE.searchURL(doi: doi, baseURL: base)?.absoluteString, row["url"] as? String, name)
        }
    }

    func testEachFullTextRow() throws {
        for row in try table("full_text", minimum: 24) {
            let name = row["name"] as? String ?? "?"
            let doi = try XCTUnwrap(row["doi"] as? String, name)
            let minimum = try XCTUnwrap(row["min_chars"] as? Int, name)
            let answer = try XCTUnwrap(row["answer"], name)
            if row["outcome"] as? String == "malformed" {
                XCTAssertThrowsError(try CORE.fullText(fromAnswerObject: answer, doi: doi, minCharacters: minimum), name)
            } else {
                XCTAssertEqual(
                    try CORE.fullText(fromAnswerObject: answer, doi: doi, minCharacters: minimum),
                    row["text"] as? String, name
                )
            }
        }
    }

    func testEachUnreadableBodyThrows() throws {
        for row in try table("bodies", minimum: 4) {
            let body = Data(try XCTUnwrap(row["body"] as? String).utf8)
            XCTAssertThrowsError(try CORE.fullText(fromAnswer: body, doi: "10.1/x"), row["name"] as? String ?? "?")
        }
    }

    func testABodyThatIsNotUTF8Throws() {
        XCTAssertThrowsError(try CORE.fullText(fromAnswer: Data([0x7B, 0xFF, 0x7D]), doi: "10.1/x"))
    }

    func testCOREIsLastInChainOrder() {
        XCTAssertEqual(OpenAccessShortfall.chainOrder.last, .core)
    }

    func testTwo429sInARowPause() {
        let throttle = CoreThrottle(pauseAfter: 2)
        throttle.record(endedOn: 429)
        XCTAssertFalse(throttle.isPaused)
        throttle.record(endedOn: 429)
        XCTAssertTrue(throttle.isPaused)
    }

    func testA401RefusesTheKeyForGood() {
        let throttle = CoreThrottle(pauseAfter: 2)
        XCTAssertFalse(throttle.isKeyRefused)
        throttle.record(endedOn: BioMedLitConstants.coreKeyRefusedStatus)
        XCTAssertTrue(throttle.isKeyRefused)
        throttle.record(endedOn: 200)
        XCTAssertTrue(throttle.isKeyRefused, "nothing lifts a refused key")
    }

    func testA403RefusesNothing() {
        let throttle = CoreThrottle(pauseAfter: 2)
        throttle.record(endedOn: 403)
        XCTAssertFalse(throttle.isKeyRefused)
    }

    func testA401ResetsThe429Count() {
        let throttle = CoreThrottle(pauseAfter: 2)
        throttle.record(endedOn: 429)
        throttle.record(endedOn: BioMedLitConstants.coreKeyRefusedStatus)
        throttle.record(endedOn: 429)
        XCTAssertFalse(throttle.isPaused)
    }

    func testAnotherEndingResetsTheCount() {
        let throttle = CoreThrottle(pauseAfter: 2)
        throttle.record(endedOn: 429)
        throttle.record(endedOn: 200)
        throttle.record(endedOn: 429)
        XCTAssertFalse(throttle.isPaused)
        throttle.record(endedOn: nil)
        throttle.record(endedOn: 429)
        XCTAssertFalse(throttle.isPaused)
    }
}
