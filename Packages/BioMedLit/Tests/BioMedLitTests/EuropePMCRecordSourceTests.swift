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

/// Europe PMC states each record's kind in its `source` field, and the decoder
/// read that field into a property nothing ever consulted (#209).
///
/// Everything downstream then had to reconstruct the kind from the accession's
/// shape — twice, and only for the shapes we thought to check. These tests pin
/// the field to the article the search returns, which is the only point at
/// which the kind is known for certain.
final class EuropePMCRecordSourceTests: XCTestCase {

    /// Decode one search result the way the search response does.
    private func decodeResult(_ json: String) throws -> EuropePMCResult {
        try JSONDecoder().decode(EuropePMCResult.self, from: Data(json.utf8))
    }

    private func article(_ json: String) throws -> SearchArticle {
        EuropePMCService.searchArticle(from: try decodeResult(json))
    }

    /// A preprint: no PMID, no PMC ID, and an accession that is the article's
    /// only identifier besides its DOI. Its kind is now carried rather than
    /// guessed from the `PPR` prefix.
    func testAPreprintRecordCarriesThePreprintKind() throws {
        let article = try article("""
        {"id": "PPR1287966", "source": "PPR", "pmid": null, "pmcid": null,
         "doi": "10.64898/2026.07.25.26358746", "title": "A preprint"}
        """)

        XCTAssertEqual(article.identifierKind, .preprint)
        XCTAssertEqual(article.pmid, "PPR1287966")
    }

    func testAMedlineRecordCarriesThePubMedKind() throws {
        let article = try article("""
        {"id": "12662058", "source": "MED", "pmid": "12662058", "title": "An article"}
        """)

        XCTAssertEqual(article.identifierKind, .pubmed)
    }

    /// A PMC-only record: the primary slot falls back to `id`, which holds the
    /// PMC accession. Carrying the kind is what lets the cache file it under the
    /// same name the `pmcId` rung would give it, instead of twice.
    func testAPMCRecordCarriesThePMCKind() throws {
        let article = try article("""
        {"id": "PMC1082889", "source": "PMC", "pmid": null, "pmcid": "PMC1082889",
         "title": "A PMC-only article"}
        """)

        XCTAssertEqual(article.identifierKind, .pmc)
        XCTAssertEqual(article.pmid, "PMC1082889")
    }

    /// The sources nothing downstream could have guessed. Europe PMC serves
    /// books, patents, theses and agricultural records, and every one of them
    /// was asked for under `src:med`, where it matches nothing.
    func testAnUnrecognisedSourceIsCarriedAsItself() throws {
        let article = try article("""
        {"id": "NBK1234", "source": "NBK", "pmid": null, "title": "A book chapter"}
        """)

        XCTAssertEqual(article.identifierKind, .europePMCSource("nbk"))
    }

    /// A record that states no source states no kind. Inventing one here would
    /// put a guess where the record is silent, and the shape rule downstream
    /// already covers that case honestly.
    func testARecordWithoutASourceCarriesNoKind() throws {
        let article = try article("""
        {"id": "12662058", "pmid": "12662058", "title": "An article"}
        """)

        XCTAssertNil(article.identifierKind)
    }
}
