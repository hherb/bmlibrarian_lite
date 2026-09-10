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

/// Europe PMC will only answer for an identifier if it is asked under the right
/// source, and the primary identifier slot does not hold one kind of thing.
///
/// `EuropePMCService` fills it as `result.pmid ?? result.id ?? ""`, so it
/// carries a PubMed ID for a MEDLINE record, a `PPR…` accession for a preprint,
/// a PMC ID for a PMC-only record, and nothing at all for a record with neither.
/// Every one of them used to be asked for as `ext_id:<id> src:med`, which only
/// the first can match.
///
/// The cost fell on preprints. A preprint reached its full text only if it also
/// carried a DOI, through the rung below — never by its own accession — and one
/// that did not was unreachable. The hit counts below were *recorded*, not
/// asserted: this suite pins the query strings, and nothing in CI re-checks the
/// counts against Europe PMC. They were measured against the live API on
/// 2026-09-10:
///
/// ```
/// ext_id:PPR1287966 src:ppr   -> 1      ext_id:PPR1287966 src:med -> 0
/// ext_id:12662058   src:med   -> 1
/// PMCID:PMC1082889            -> 1      ext_id:PMC1082889 src:pmc -> 0
///                                       ext_id:PMC1082889 src:med -> 0
/// ```
final class IdentifierQueryTests: XCTestCase {
    private func queries(pmid: String?, pmcId: String? = nil, doi: String?) -> [String] {
        FullTextService.identifierQueries(pmid: pmid, pmcId: pmcId, doi: doi).map(\.query)
    }

    /// The case that already worked, pinned so routing the others cannot
    /// silently change it.
    func testAPubMedIdentifierIsAskedForUnderTheMedlineSource() {
        XCTAssertEqual(queries(pmid: "12662058", doi: nil), ["ext_id:12662058 src:med"])
    }

    /// The defect: a preprint accession asked for under `src:med` matches
    /// nothing, so the preprint's own record was unreachable.
    func testAPreprintAccessionIsAskedForUnderThePreprintSource() {
        XCTAssertEqual(queries(pmid: "PPR1287966", doi: nil), ["ext_id:PPR1287966 src:ppr"])
    }

    /// A PMC ID in the primary slot needs the `PMCID` field: neither `src:med`
    /// nor `src:pmc` matches it as an `ext_id`.
    func testAPMCIdentifierIsAskedForByItsOwnField() {
        XCTAssertEqual(queries(pmid: "PMC1082889", doi: nil), ["PMCID:PMC1082889"])
    }

    /// Case must not decide the route: Europe PMC accessions are conventionally
    /// upper-case, but nothing guarantees the value reaches us that way.
    func testAccessionRoutingIgnoresCase() {
        XCTAssertEqual(queries(pmid: "ppr1287966", doi: nil), ["ext_id:ppr1287966 src:ppr"])
        XCTAssertEqual(queries(pmid: "pmc1082889", doi: nil), ["PMCID:pmc1082889"])
    }

    /// The DOI rung is unchanged, and still runs after the primary identifier.
    func testTheDOIQueryFollowsThePrimaryIdentifier() {
        XCTAssertEqual(
            queries(pmid: "12662058", doi: "10.1/abc"),
            ["ext_id:12662058 src:med", "DOI:\"10.1/abc\""]
        )
    }

    /// The other half of #202: an article can carry a PMC ID and nothing else,
    /// and until the PMC ID was asked for it resolved no render URL, so the
    /// cache-key fix alone still left it with no PDF to extract.
    ///
    /// `PMCID:PMC1082889` was measured against the live API on 2026-09-10: it
    /// matches, and the record carries a `pdf | OA` render URL.
    func testAnArticleWithOnlyAPMCIdentifierStillHasAQuery() {
        XCTAssertEqual(queries(pmid: "", pmcId: "PMC1082889", doi: nil), ["PMCID:PMC1082889"])
    }

    /// The rungs run in the same order the cache key climbs them, so the
    /// most specific identifier is always asked for first.
    func testThePMCRungSitsBetweenThePrimaryIdentifierAndTheDOI() {
        XCTAssertEqual(
            queries(pmid: "12662058", pmcId: "PMC1082889", doi: "10.1/abc"),
            ["ext_id:12662058 src:med", "PMCID:PMC1082889", "DOI:\"10.1/abc\""]
        )
    }

    /// A blank slot contributes nothing rather than a query that asks for the
    /// empty string.
    func testABlankIdentifierContributesNoQuery() {
        XCTAssertEqual(queries(pmid: "", doi: "10.1/abc"), ["DOI:\"10.1/abc\""])
        XCTAssertEqual(queries(pmid: "   ", doi: nil), [])
        XCTAssertEqual(queries(pmid: nil, doi: nil), [])
    }

    /// A PMC-only Europe PMC record arrives with its accession in *both* slots —
    /// `result.pmid ?? result.id` yields the PMC ID when there is no PMID — so
    /// both rungs build the same query. Asking Europe PMC the identical question
    /// twice pays the retry backoff twice on the failure path, for exactly the
    /// record class the PMC rung was added to serve.
    func testTheSameQueryIsNotAskedTwice() {
        XCTAssertEqual(
            queries(pmid: "PMC1082889", pmcId: "PMC1082889", doi: nil),
            ["PMCID:PMC1082889"]
        )
    }

    /// An accession shape the routing does not recognise falls through to
    /// `src:med`, where it matches nothing.
    ///
    /// Europe PMC returns records whose `id` is an `NBK…`, `PAT…` or `AGR…`
    /// accession, and none of those is a PubMed ID. Pinned so the fall-through
    /// is a decision on record rather than an accident: a future rung for one of
    /// these shapes should change this expectation deliberately. The zero-hit
    /// search it produces is now logged by `searchForPMCIdAndPDFUrl`, which is
    /// what keeps it from being silent the way #202 was.
    func testAnUnrecognisedAccessionShapeFallsThroughToTheMedlineSource() {
        XCTAssertEqual(queries(pmid: "NBK1234", doi: nil), ["ext_id:NBK1234 src:med"])
    }
}
