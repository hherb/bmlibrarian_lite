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

/// The PDF cache used to be keyed on the PMID alone, and refused an empty one.
///
/// The refusal was correct — every article with no PMID would otherwise share
/// one entry — but it cost those articles their PDF extraction entirely, and
/// the tier reported a download failure indistinguishable from a real one
/// (#202). A Europe PMC record can carry a PMC ID with no PMID, and those are
/// exactly the open-access articles most likely to have a usable free PDF.
///
/// The repair is a ladder: the first identifier the document actually has,
/// tagged with which kind it is so two kinds can never name the same entry.
final class ArticleCacheKeyTests: XCTestCase {
    // MARK: - The ladder

    /// The primary identifier wins when there is one, which keeps every
    /// article that already had a cache entry on the same rung it was on.
    func testPrimaryIdentifierIsPreferredOverEveryOtherIdentifier() {
        let key = ArticleCacheKey(pmid: "12345678", pmcId: "PMC7654321", doi: "10.1/abc")

        XCTAssertEqual(key?.filenameComponent, "id_12345678")
    }

    /// The defect #202 names, directly: a Europe PMC article with a PMC ID and
    /// no PMID must get a cache entry rather than be refused.
    func testPMCIdentifierIsUsedWhenThePrimarySlotIsEmpty() {
        let key = ArticleCacheKey(pmid: "", pmcId: "PMC7654321", doi: "10.1/abc")

        XCTAssertEqual(key?.filenameComponent, "pmc_PMC7654321")
    }

    /// A DOI is the last rung, and goes in as a digest rather than as
    /// sanitised text: `10.1/abc` and `10.1_abc` both sanitise to `10_1_abc`
    /// and would share an entry, which is the very collision this ladder exists
    /// to prevent.
    func testDOIIsUsedWhenNoIdentifierIsAvailableAndIsDigested() throws {
        let key = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: nil, doi: "10.1/abc"))

        XCTAssertTrue(key.filenameComponent.hasPrefix("doi_"))
        // Not the sanitised text: `10.1/abc` sanitises to `10_1_abc`, which is
        // what the next test shows would merge two distinct articles.
        XCTAssertNotEqual(key.filenameComponent, "doi_10_1_abc")
    }

    /// Two DOIs that sanitise to the same string must still get their own
    /// entries. This is the case a sanitised DOI would have merged.
    func testDOIsThatSanitiseIdenticallyGetDifferentKeys() {
        let slashed = ArticleCacheKey(pmid: nil, pmcId: nil, doi: "10.1/abc")
        let underscored = ArticleCacheKey(pmid: nil, pmcId: nil, doi: "10.1_abc")

        XCTAssertNotEqual(slashed?.filenameComponent, underscored?.filenameComponent)
    }

    /// An article carrying none of the three has no stable name to file bytes
    /// under, so it is refused — as an empty PMID always was.
    func testAnArticleWithNoIdentifierAtAllHasNoKey() {
        XCTAssertNil(ArticleCacheKey(pmid: "", pmcId: "", doi: ""))
        XCTAssertNil(ArticleCacheKey(pmid: nil, pmcId: nil, doi: nil))
    }

    // MARK: - Collisions across rungs

    /// The reason every rung is tagged, including the first.
    ///
    /// `EuropePMCService` fills the primary slot as `result.pmid ?? result.id`,
    /// so it holds a PubMed ID, a Europe PMC preprint accession, or a PMC ID
    /// depending on the record. Untagged, an article whose primary slot happens
    /// to hold `PMC7654321` would name the same entry as a different article
    /// reached by that PMC ID, and one would be served the other's bytes.
    func testAPMCIdentifierInThePrimarySlotDoesNotCollideWithThePMCRung() {
        let viaPrimary = ArticleCacheKey(pmid: "PMC7654321", pmcId: nil, doi: nil)
        let viaPMCRung = ArticleCacheKey(pmid: "", pmcId: "PMC7654321", doi: nil)

        XCTAssertNotEqual(viaPrimary?.filenameComponent, viaPMCRung?.filenameComponent)
    }

    // MARK: - Preprints

    /// A Europe PMC preprint carries no PMID and no PMC ID: its accession
    /// arrives in the primary slot, and it must key on that rather than fall
    /// through to the DOI. Verified against live Europe PMC — a `SRC:PPR`
    /// record answers `pmid: null, pmcid: null, id: "PPR1287966"`.
    func testAPreprintAccessionKeysOnThePrimaryRung() {
        let key = ArticleCacheKey(pmid: "PPR1287966", pmcId: nil, doi: "10.64898/2026.07.25.26358746")

        XCTAssertEqual(key?.filenameComponent, "id_PPR1287966")
    }

    // MARK: - Path safety

    /// An identifier reaches this type from a search result, so a value holding
    /// `/` or `..` must not be able to walk the written file out of the cache
    /// directory.
    func testAHostileIdentifierCannotEscapeTheCacheDirectory() throws {
        let key = try XCTUnwrap(ArticleCacheKey(pmid: "../../etc/passwd", pmcId: nil, doi: nil))

        XCTAssertFalse(key.filenameComponent.contains("/"))
        XCTAssertFalse(key.filenameComponent.contains(".."))
    }

    /// Whitespace is not an identifier. A slot holding only spaces must fall
    /// through to the next rung rather than name an entry after nothing.
    func testAWhitespaceOnlyIdentifierFallsThroughToTheNextRung() {
        let key = ArticleCacheKey(pmid: "   ", pmcId: "PMC7654321", doi: nil)

        XCTAssertEqual(key?.filenameComponent, "pmc_PMC7654321")
    }
}
