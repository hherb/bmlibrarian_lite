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

/// Tests for the Europe PMC free-PDF availability allow-list.
///
/// Mirrors bmlib issue #79: `availability == "Free"` alone rejects the
/// `Open access` / `OA` entries that are 95.7% of the free PDFs Europe PMC
/// offers, both of which are the same `?pdf=render` URL on the same host.
final class EuropePMCFreePDFTests: XCTestCase {

    // MARK: - Helpers

    /// Decode a `fullTextUrlList` payload the way the search response does.
    private func decodeResult(fullTextUrlJSON: String) throws -> EuropePMCResult {
        let json = """
        {"id": "1", "pmid": "1", "fullTextUrlList": {"fullTextUrl": \(fullTextUrlJSON)}}
        """
        return try JSONDecoder().decode(EuropePMCResult.self, from: Data(json.utf8))
    }

    private static let renderURL = "https://europepmc.org/articles/PMC1234567?pdf=render"

    // MARK: - Availability code allow-list

    func testOpenAccessPDFIsAccepted() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "pdf", "site": "Europe_PMC", "availability": "Open access",
          "availabilityCode": "OA", "url": "\(Self.renderURL)"}]
        """)

        XCTAssertEqual(EuropePMCService.extractFreePDFURL(from: result), Self.renderURL)
    }

    func testFreePDFIsAccepted() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "pdf", "site": "Europe_PMC", "availability": "Free",
          "availabilityCode": "F", "url": "\(Self.renderURL)"}]
        """)

        XCTAssertEqual(EuropePMCService.extractFreePDFURL(from: result), Self.renderURL)
    }

    func testSubscriptionRequiredPDFIsRejected() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "pdf", "site": "PubMedCentral", "availability": "Subscription required",
          "availabilityCode": "S", "url": "https://example.org/paywalled.pdf"}]
        """)

        XCTAssertNil(EuropePMCService.extractFreePDFURL(from: result))
    }

    /// An unrecognised code must under-credit rather than defer to the label:
    /// a future access code must not be admitted on the strength of a display
    /// string that happens to read "Free".
    func testUnrecognisedCodeIsRejectedWithoutConsultingLabel() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "pdf", "site": "Europe_PMC", "availability": "Free",
          "availabilityCode": "Z", "url": "\(Self.renderURL)"}]
        """)

        XCTAssertNil(EuropePMCService.extractFreePDFURL(from: result))
    }

    // MARK: - Label fallback for a code-less entry

    func testMissingCodeFallsBackToOpenAccessLabel() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "pdf", "site": "Europe_PMC", "availability": "Open access",
          "url": "\(Self.renderURL)"}]
        """)

        XCTAssertEqual(EuropePMCService.extractFreePDFURL(from: result), Self.renderURL)
    }

    func testMissingCodeFallsBackToRejectingSubscriptionLabel() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "pdf", "site": "PubMedCentral", "availability": "Subscription required",
          "url": "https://example.org/paywalled.pdf"}]
        """)

        XCTAssertNil(EuropePMCService.extractFreePDFURL(from: result))
    }

    func testEmptyCodeFallsBackToLabel() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "pdf", "site": "Europe_PMC", "availability": "Open access",
          "availabilityCode": "", "url": "\(Self.renderURL)"}]
        """)

        XCTAssertEqual(EuropePMCService.extractFreePDFURL(from: result), Self.renderURL)
    }

    func testEntryWithNeitherCodeNorLabelIsRejected() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "pdf", "site": "Europe_PMC", "url": "\(Self.renderURL)"}]
        """)

        XCTAssertNil(EuropePMCService.extractFreePDFURL(from: result))
    }

    // MARK: - Document style

    func testNonPDFDocumentStyleIsIgnored() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "html", "site": "Europe_PMC", "availability": "Open access",
          "availabilityCode": "OA", "url": "https://europepmc.org/article/MED/1"}]
        """)

        XCTAssertNil(EuropePMCService.extractFreePDFURL(from: result))
    }

    /// The realistic payload shape: an HTML entry, a paywalled PDF and the
    /// open-access render URL, in that order.
    func testPicksFirstFreePDFAmongMixedEntries() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "html", "site": "Europe_PMC", "availability": "Open access",
          "availabilityCode": "OA", "url": "https://europepmc.org/article/MED/1"},
         {"documentStyle": "pdf", "site": "Publisher", "availability": "Subscription required",
          "availabilityCode": "S", "url": "https://example.org/paywalled.pdf"},
         {"documentStyle": "pdf", "site": "Europe_PMC", "availability": "Open access",
          "availabilityCode": "OA", "url": "\(Self.renderURL)"}]
        """)

        XCTAssertEqual(EuropePMCService.extractFreePDFURL(from: result), Self.renderURL)
    }

    // MARK: - Degenerate payloads

    func testMissingFullTextUrlListYieldsNil() throws {
        let json = #"{"id": "1", "pmid": "1"}"#
        let result = try JSONDecoder().decode(EuropePMCResult.self, from: Data(json.utf8))

        XCTAssertNil(EuropePMCService.extractFreePDFURL(from: result))
    }

    func testEntryWithoutURLIsSkipped() throws {
        let result = try decodeResult(fullTextUrlJSON: """
        [{"documentStyle": "pdf", "site": "Europe_PMC", "availability": "Open access",
          "availabilityCode": "OA"},
         {"documentStyle": "pdf", "site": "Europe_PMC", "availability": "Free",
          "availabilityCode": "F", "url": "\(Self.renderURL)"}]
        """)

        XCTAssertEqual(EuropePMCService.extractFreePDFURL(from: result), Self.renderURL)
    }
}
