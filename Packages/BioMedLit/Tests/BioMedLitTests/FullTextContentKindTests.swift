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

/// The kind is a *persisted* contract shared with bmlib, whose `ContentKind`
/// uses these exact four strings. Pinned against literals in both directions
/// for the reason `FullTextDegradation`'s raw values are: a compiler-derived
/// case name is a detail a rename changes silently, and a test that
/// round-trips through `init(rawValue:)` agrees with the rename.
final class FullTextContentKindTests: XCTestCase {
    func testTheRawValuesArePinned() {
        XCTAssertEqual(FullTextContentKind.fulltext.rawValue, "fulltext")
        XCTAssertEqual(FullTextContentKind.abstract.rawValue, "abstract")
        XCTAssertEqual(FullTextContentKind.extracted.rawValue, "extracted")
        XCTAssertEqual(FullTextContentKind.none.rawValue, "none")
    }

    func testTheRawValuesDecode() {
        XCTAssertEqual(FullTextContentKind(rawValue: "fulltext"), .fulltext)
        XCTAssertEqual(FullTextContentKind(rawValue: "abstract"), .abstract)
        XCTAssertEqual(FullTextContentKind(rawValue: "extracted"), .extracted)
        // `.none` here would be read as `Optional<FullTextContentKind>.none`
        // (nil), not the `.none` case, because the left side is already
        // optional — the ambiguity the type's own doc comment warns about.
        // Spelled out explicitly rather than worked around any other way.
        XCTAssertEqual(FullTextContentKind(rawValue: "none"), FullTextContentKind.none)
    }

    /// A member added later must be given a raw value deliberately, not
    /// inherited from its case name.
    func testTheMemberSetIsPinned() {
        XCTAssertEqual(FullTextContentKind.allCases.count, 4)
    }

    /// The default keeps every existing producer compiling and honest: a
    /// result built without saying what it holds claims nothing.
    func testAResultDefaultsToNoKindAndNoExtraction() {
        let result = FullTextResult(content: .doi(webURL: URL(string: "https://doi.org/10.1/x")!))
        XCTAssertEqual(result.contentKind, .none)
        XCTAssertNil(result.extractedText)
        XCTAssertNil(result.localPDFPath)
    }

    /// Europe PMC content carrying a body is the ordinary success, and the one
    /// case where a kind and a parse coexist.
    func testEuropePMCContentCanCarryTheFulltextKind() {
        let result = FullTextResult(
            content: .europePMC(html: "<p>body</p>", markdown: "body"),
            contentKind: .fulltext
        )
        XCTAssertEqual(result.contentKind, .fulltext)
    }

    /// The three facts a PDF tier produces travel together.
    func testAPDFResultCarriesItsTextAndItsPath() {
        let result = FullTextResult(
            content: .unpaywall(pdfURL: URL(string: "https://example.org/a.pdf")!),
            contentKind: .extracted,
            extractedText: "recovered prose",
            localPDFPath: "/tmp/a.pdf"
        )
        XCTAssertEqual(result.extractedText, "recovered prose")
        XCTAssertEqual(result.localPDFPath, "/tmp/a.pdf")
        XCTAssertEqual(result.pdfURL?.absoluteString, "https://example.org/a.pdf")
    }
}
