// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
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

/// Which URL the Unpaywall tier tries, and the PDF a landing page declares,
/// read from the contract all three platforms share (#464):
/// `doc/cross_platform/fulltext_parity/unpaywall_landing_page.json`.
final class UnpaywallLandingPageContractTests: XCTestCase {

    private enum ContractError: Error {
        case notFound(origin: String)
        case malformed(String)
    }

    /// The contract file, read from the repository, never copied into test
    /// resources. The walk stops at the checkout root, as
    /// `AnsweredLookupVerbContractTests.contractFile` does, so a worktree under
    /// the main checkout never reads the main checkout's contract.
    private static let contractFile: URL? = {
        let relative = "doc/cross_platform/fulltext_parity/unpaywall_landing_page.json"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            // `.git` is a directory in a normal checkout and a file in a worktree.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return nil
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// The contract's two tables, as untyped rows.
    ///
    /// Untyped because each `response` is Unpaywall's JSON, which is decoded
    /// here exactly as the service decodes it: re-serialised, then handed to
    /// `JSONDecoder` as ``UnpaywallResponse``.
    private func loadTable(_ name: String) throws -> [[String: Any]] {
        guard let file = Self.contractFile else {
            throw ContractError.notFound(origin: #filePath)
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        guard let contract = object as? [String: Any],
              let rows = contract[name] as? [[String: Any]] else {
            throw ContractError.malformed(name)
        }
        return rows
    }

    /// A row's string field, `nil` for JSON `null`.
    private func string(_ row: [String: Any], _ key: String) -> String? {
        row[key] as? String
    }

    func testEachUnpaywallChoiceRow() throws {
        let rows = try loadTable("unpaywall_choice")
        XCTAssertGreaterThanOrEqual(rows.count, 5, "an empty table would pass vacuously")
        for row in rows {
            let name = string(row, "name") ?? "?"
            let json = try JSONSerialization.data(withJSONObject: row["response"] ?? [:])
            let response = try JSONDecoder().decode(UnpaywallResponse.self, from: json)

            let choice = UnpaywallLandingPage.choose(from: response)

            XCTAssertEqual(choice.pdfURL, string(row, "pdf_url"), name)
            XCTAssertEqual(choice.landingPage, string(row, "landing_page"), name)
        }
    }

    func testEachCitationPDFURLRow() throws {
        let rows = try loadTable("citation_pdf_url")
        XCTAssertGreaterThanOrEqual(rows.count, 10, "an empty table would pass vacuously")
        for row in rows {
            let name = string(row, "name") ?? "?"
            let page = try XCTUnwrap(string(row, "page_url").flatMap(URL.init(string:)), name)
            let html = try XCTUnwrap(string(row, "html"), name)

            let found = UnpaywallLandingPage.citationPDFURL(html: html, pageURL: page)

            XCTAssertEqual(found?.absoluteString, string(row, "expected"), name)
        }
    }
}
