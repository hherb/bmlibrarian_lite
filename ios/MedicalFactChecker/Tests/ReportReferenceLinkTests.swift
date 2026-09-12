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
@testable import MedicalFactChecker

/// The URL a tapped report reference travels in, and back.
///
/// SwiftUI's `Text` hands a tap back only as a URL, so what a reference points
/// at is written into one by the renderer and read out again by the report
/// view. Those were two hand-written halves in different files: one built the
/// query by string interpolation, and two views parsed it separately.
final class ReportReferenceLinkTests: XCTestCase {

    /// A document's identity survives the round trip.
    func testADocumentIdentityRoundTrips() throws {
        let link = ReportReferenceLink.documentIdentity("8A1D4C22-0000-4000-8000-000000000001")

        let url = try XCTUnwrap(link.url)

        XCTAssertEqual(ReportReferenceLink(url: url), link)
    }

    /// Citation text carrying an ampersand survives the round trip.
    ///
    /// The query was built by interpolating text encoded with
    /// `.urlQueryAllowed`, which leaves `&` alone. `[Smith & Jones, 2016]`
    /// therefore produced `value=Smith%20&%20Jones,%202016`, the `&` ended the
    /// value, and the lookup searched for `"Smith "`: a tap that did nothing.
    func testCitationTextCarryingAnAmpersandRoundTrips() throws {
        let link = ReportReferenceLink.citationText("Smith & Jones, 2016")

        let url = try XCTUnwrap(link.url)

        XCTAssertEqual(ReportReferenceLink(url: url), link)
    }

    /// The other characters a query gives meaning to survive as well.
    func testCitationTextCarryingQuerySyntaxRoundTrips() throws {
        let link = ReportReferenceLink.citationText("O'Brien + Lee = 50% #2, 2016")

        let url = try XCTUnwrap(link.url)

        XCTAssertEqual(ReportReferenceLink(url: url), link)
    }

    /// An ordinary link is not mistaken for a reference.
    ///
    /// The report view receives every tapped URL it did not hand to the system,
    /// so a web address shaped like our query must not open a document sheet.
    func testAnOrdinaryURLIsNotAReference() throws {
        let url = try XCTUnwrap(URL(string: "https://example.org/lookup?type=id&value=abc"))

        XCTAssertNil(ReportReferenceLink(url: url))
    }

    /// A reference URL naming no lookup kind this build knows is refused.
    func testAnUnknownLookupKindIsRefused() throws {
        let url = try XCTUnwrap(URL(string: "docref://lookup?type=pmid&value=889149"))

        XCTAssertNil(ReportReferenceLink(url: url))
    }

    /// A reference URL with nothing to look up is refused.
    func testAReferenceWithNoValueIsRefused() throws {
        let url = try XCTUnwrap(URL(string: "docref://lookup?type=id"))

        XCTAssertNil(ReportReferenceLink(url: url))
    }
}
