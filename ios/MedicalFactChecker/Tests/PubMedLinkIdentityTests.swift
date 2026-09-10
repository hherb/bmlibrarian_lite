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

/// The rule the retrieval chain has enforced since #202 had never reached the
/// app, where nine surfaces built a PubMed URL straight from `document.pmid`.
///
/// The slot holds whatever identifier the record had, so those surfaces offered
/// a preprint `https://pubmed.ncbi.nlm.nih.gov/PPR1287966/` (a 404) and an
/// identifier-less record `…/pubmed.ncbi.nlm.nih.gov//` (PubMed's front page) —
/// the second at exactly the moment the reader has been told no full text
/// exists. Five of them force-unwrapped `URL(string:)`, which answers `nil` for
/// a value containing a space, so a malformed network value crashed the app when
/// a context menu drew (#213).
///
/// Worse than either, a Europe PMC thesis or case-report accession is a bare
/// decimal, and pasting one after the PubMed URL returns a **real but unrelated
/// article** (#212).
final class PubMedLinkIdentityTests: XCTestCase {
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

    // MARK: - What may become a PubMed link

    /// The record said so, which is the strongest thing that can be said.
    func testAStatedPubMedIdentifierGetsItsLink() {
        let document = makeDocument(pmid: "12662058", kind: .pubmed, provider: .europePMC)

        XCTAssertEqual(
            document.pubmedURL?.absoluteString,
            "https://pubmed.ncbi.nlm.nih.gov/12662058/"
        )
    }

    /// A document stored before the kind field existed, found on the default
    /// provider. PubMed returns MEDLINE records and nothing else, so the search
    /// vouches for what the document never recorded — which is what keeps the
    /// overwhelming majority of stored documents linking to their PubMed record.
    func testALegacyPubMedSearchResultKeepsItsLink() {
        let document = makeDocument(pmid: "12662058", provider: .pubmed)

        XCTAssertEqual(
            document.pubmedURL?.absoluteString,
            "https://pubmed.ncbi.nlm.nih.gov/12662058/"
        )
    }

    // MARK: - What may not

    /// #212 on the reader's screen. Europe PMC thesis `889149` and PubMed
    /// article `889149` — a 1977 paper on mouse courtship — both exist, so this
    /// link would open a genuine article that is not the one on the card.
    func testALegacyEuropePMCNumericAccessionGetsNoLink() {
        let document = makeDocument(pmid: "889149", provider: .europePMC)

        XCTAssertNil(document.pubmedURL)
    }

    /// `both` names the search mode, and a merged search records it on every
    /// document including the ones only Europe PMC returned. It cannot vouch.
    func testALegacyMergedSearchResultGetsNoLink() {
        let document = makeDocument(pmid: "889149", provider: .both)

        XCTAssertNil(document.pubmedURL)
    }

    func testAStatedThesisAccessionGetsNoLink() {
        let document = makeDocument(
            pmid: "889149",
            kind: .europePMCSource("eth"),
            provider: .europePMC
        )

        XCTAssertNil(document.pubmedURL)
    }

    /// The 404 named in #213, and the shape the whole ladder exists to serve.
    func testAPreprintAccessionGetsNoLink() {
        let document = makeDocument(pmid: "PPR1287966", kind: .preprint, provider: .europePMC)

        XCTAssertNil(document.pubmedURL)
    }

    /// `…/pubmed.ncbi.nlm.nih.gov//` is PubMed's front page, which `URL(string:)`
    /// accepts happily.
    func testAnEmptySlotGetsNoLink() {
        XCTAssertNil(makeDocument(pmid: "", provider: .pubmed).pubmedURL)
    }

    /// The crash. `URL(string:)` answers `nil` here and five surfaces
    /// force-unwrapped it, so drawing a context menu over this document brought
    /// the app down.
    func testAMalformedIdentifierGetsNoLinkAndDoesNotCrash() {
        XCTAssertNil(makeDocument(pmid: "126 62058", provider: .pubmed).pubmedURL)
    }

    // MARK: - The browser fallback

    /// A DOI is preferred whatever the identifier is, so the common case is
    /// untouched by all of this.
    func testTheDOIIsStillPreferredForTheBrowserFallback() {
        let document = makeDocument(pmid: "889149", provider: .europePMC, doi: "10.1/abc")

        XCTAssertEqual(document.fullTextLinkDestination?.host, "doi.org")
    }

    /// `fullTextLinkDestination` renders the "Open Publisher" link *inside* the
    /// "full text not available" branch, so an invented destination is offered
    /// at the moment the reader has been told nothing else exists. Having no
    /// route is the honest answer; a route to the wrong article is not.
    func testADocumentWithNothingToPointAtOffersNoDestination() {
        let document = makeDocument(pmid: "889149", provider: .europePMC)

        XCTAssertNil(document.fullTextLinkDestination)
    }

    // MARK: - Citations

    /// A fabricated PubMed ID inside a citation in a medical evidence report is
    /// the most consequential form this takes: it outlives the app, in an
    /// exported PDF someone else reads.
    func testACitationNamesAPubMedIdentifierAsOne() {
        let document = makeDocument(pmid: "12662058", kind: .pubmed, provider: .pubmed)

        XCTAssertTrue(document.fullCitation.contains("PMID: 12662058"))
    }

    /// Not dropped — named. The accession is how the reader finds the article
    /// again, and Europe PMC is the namespace that can resolve it.
    func testACitationNamesAPreprintAccessionAsEuropePMCs() {
        let document = makeDocument(
            pmid: "PPR1287966",
            kind: .preprint,
            provider: .europePMC
        )

        XCTAssertTrue(
            document.fullCitation.contains("Europe PMC: PPR1287966"),
            document.fullCitation
        )
        XCTAssertFalse(document.fullCitation.contains("PMID"), document.fullCitation)
    }

    func testACitationNamesAPMCAccessionAsAPMCID() {
        let document = makeDocument(
            pmid: "PMC1082889",
            kind: .pmc,
            provider: .europePMC
        )

        XCTAssertTrue(document.fullCitation.contains("PMCID: PMC1082889"), document.fullCitation)
    }

    /// The kind is unknown but the namespace is not: a Europe PMC search
    /// returned it, so Europe PMC can resolve it, and that much is true of a
    /// legacy row as well as a stated one.
    func testACitationNamesAnUnclassifiedEuropePMCAccessionByItsProvider() {
        let document = makeDocument(pmid: "889149", provider: .europePMC)

        XCTAssertTrue(document.fullCitation.contains("Europe PMC: 889149"), document.fullCitation)
    }

    /// Nothing named the record and nothing named the search, so there is no
    /// namespace to print. A bare number under any label invites the reader to
    /// read it as a PubMed ID.
    func testACitationOmitsAnIdentifierNothingCanResolve() {
        let document = makeDocument(pmid: "889149", provider: .both)

        XCTAssertFalse(document.fullCitation.contains("889149"), document.fullCitation)
    }
}
