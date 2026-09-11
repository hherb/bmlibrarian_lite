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

import BioMedLit
import XCTest
@testable import MedicalFactChecker

/// Whether the app offers to analyse a document's transparency.
///
/// The gate has to ask the same question the analyser does.
/// `TransparencyAnalysisService.analyze` throws `noIdentifiers` unless it is
/// given a DOI or a PubMed ID, and since #212 the three call sites pass
/// ``Document/pubmedID`` — which answers `nil` unless something *stated* the
/// slot holds a PubMed ID — rather than the raw slot.
///
/// The gate still read the raw slot, so a Europe PMC thesis or case-report
/// accession passed it and the analyser then threw. 60 of 100 `SRC:ETH OR
/// SRC:CBA OR SRC:HIR` records sampled on 2026-09-11 carry no DOI, so the
/// button was offered and could not work for the majority of that class.
final class TransparencyEligibilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
    }

    private func makeDocument(
        pmid: String,
        kind: ArticleIdentifierKind? = nil,
        provider: MedicalFactChecker.SearchProvider? = nil,
        doi: String? = nil
    ) -> Document {
        let document = Document(pmid: pmid, title: "An article", abstract: "")
        document.identifierKind = kind
        document.searchSource = provider?.rawValue
        document.doi = doi
        return document
    }

    /// A bare accession nothing vouches for is not a PubMed ID, and with no DOI
    /// there is nothing left to analyse by.
    func testAThesisAccessionWithNoDOIIsNotEligible() {
        let thesis = makeDocument(
            pmid: "889149",
            kind: .europePMCSource("eth"),
            provider: .europePMC
        )

        XCTAssertFalse(thesis.canAnalyzeTransparency)
    }

    /// A preprint accession is not a PubMed ID either, but preprints carry DOIs
    /// — all 100 sampled on 2026-09-11 did — and the DOI is what the analyser
    /// uses.
    func testAPreprintIsEligibleThroughItsDOI() {
        let preprint = makeDocument(
            pmid: "PPR1287966",
            kind: .preprint,
            provider: .europePMC,
            doi: "10.1101/2024.01.01.573000"
        )

        XCTAssertTrue(preprint.canAnalyzeTransparency)
    }

    /// A stated PubMed ID is the common path and must stay eligible.
    func testAStatedPubMedIdentifierIsEligible() {
        let article = makeDocument(pmid: "12662058", kind: .pubmed, provider: .europePMC)

        XCTAssertTrue(article.canAnalyzeTransparency)
    }

    /// A document stored before the kind field existed, from a PubMed search:
    /// the provider vouches for the bare decimal, so the analyser can use it.
    func testALegacyPubMedRowIsEligible() {
        let legacy = makeDocument(pmid: "12662058", provider: .pubmed)

        XCTAssertTrue(legacy.canAnalyzeTransparency)
    }

    /// Nothing to look up by at all.
    func testARecordWithNeitherIsNotEligible() {
        XCTAssertFalse(makeDocument(pmid: "").canAnalyzeTransparency)
    }

    /// A PMC accession is deliberately not a third rung.
    ///
    /// ``Document/canAnalyzeTransparency`` reasons at length that admitting one
    /// would re-open the gap it closes, because `TransparencyAnalysisService`
    /// has no route that starts from a PMC ID. Reasoning is not enforcement: a
    /// well-meant `|| pmcId != nil` would pass every other test in this file.
    func testAPMCOnlyRecordIsNotEligible() {
        let pmcOnly = makeDocument(
            pmid: "",
            kind: .pmc,
            provider: .europePMC
        )
        pmcOnly.pmcId = "PMC1234567"

        XCTAssertFalse(pmcOnly.canAnalyzeTransparency)
    }

    /// A DOI that is present but blank names nothing, and must not open the gate.
    ///
    /// ``Document/doi`` comes straight from a provider's JSON, so `""` is
    /// representable. Both this gate and the analyser's own guard tested
    /// `doi != nil`, which an empty string passes: the button appeared and the
    /// analysis then ran against a blank DOI. Same defect class as #212 one
    /// field over — a value present without naming anything.
    func testABlankDOIIsNotEligible() {
        let blank = makeDocument(pmid: "889149", kind: .europePMCSource("eth"), doi: "")
        let whitespace = makeDocument(
            pmid: "889149",
            kind: .europePMCSource("eth"),
            doi: "   \n "
        )

        XCTAssertFalse(blank.canAnalyzeTransparency)
        XCTAssertFalse(whitespace.canAnalyzeTransparency)
        XCTAssertNil(blank.usableDOI)
        XCTAssertNil(whitespace.usableDOI)
    }

    /// A real DOI survives trimming and still reaches the analyser.
    func testASurroundedDOIIsTrimmedRatherThanRejected() {
        let padded = makeDocument(
            pmid: "889149",
            kind: .europePMCSource("eth"),
            doi: "  10.1101/2024.01.01.573000\n"
        )

        XCTAssertTrue(padded.canAnalyzeTransparency)
        XCTAssertEqual(padded.usableDOI, "10.1101/2024.01.01.573000")
    }
}
