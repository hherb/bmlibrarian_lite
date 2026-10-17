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

/// Loads the shared Europe PMC free-PDF contract (bmlib#79).
enum EuropePMCFreePDFContract {
    private static let contractFile: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(
                "doc/cross_platform/fulltext_parity/europepmc_free_pdf.json")
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
        let url = try XCTUnwrap(contractFile, "europepmc_free_pdf.json not found")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

/// Tests for the Europe PMC free-PDF availability allow-list.
///
/// Mirrors bmlib issue #79: `availability == "Free"` alone rejects the
/// `Open access` / `OA` entries that are 95.7% of the free PDFs Europe PMC
/// offers, both of which are the same `?pdf=render` URL on the same host.
///
/// The cases are the shared contract
/// `doc/cross_platform/fulltext_parity/europepmc_free_pdf.json`, which Python
/// and Android read too: add a row there, not a test here.
final class EuropePMCFreePDFTests: XCTestCase {

    func testEveryContractKeyIsReadHere() throws {
        XCTAssertEqual(
            Set(try EuropePMCFreePDFContract.load().keys),
            ["schema_version", "description", "source", "free_codes", "free_labels",
             "known_unavailable_codes", "cases"]
        )
    }

    func testTheConstantsAreTheContracts() throws {
        let contract = try EuropePMCFreePDFContract.load()
        XCTAssertEqual(
            BioMedLitConstants.europePMCFreePDFAvailabilityCodes,
            Set(try XCTUnwrap(contract["free_codes"] as? [String])))
        XCTAssertEqual(
            BioMedLitConstants.europePMCFreePDFAvailabilityLabels,
            Set(try XCTUnwrap(contract["free_labels"] as? [String])))
        XCTAssertEqual(
            BioMedLitConstants.europePMCKnownUnavailablePDFCodes,
            Set(try XCTUnwrap(contract["known_unavailable_codes"] as? [String])))
    }

    /// Each case builds the result the search response would carry: no
    /// `fullTextUrlList` at all when the case's `fullTextUrl` is null.
    func testEachContractCase() throws {
        let cases = try XCTUnwrap(EuropePMCFreePDFContract.load()["cases"] as? [[String: Any]])
        // An emptied table would pass the loop vacuously.
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for entry in cases {
            let name = entry["name"] as? String ?? "?"
            var object: [String: Any] = ["id": "1", "pmid": "1"]
            if !(entry["fullTextUrl"] is NSNull), let entries = entry["fullTextUrl"] {
                object["fullTextUrlList"] = ["fullTextUrl": entries]
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            let result = try JSONDecoder().decode(EuropePMCResult.self, from: data)

            XCTAssertEqual(
                EuropePMCService.extractFreePDFURL(from: result),
                entry["expected_url"] as? String,
                name
            )
        }
    }
}
