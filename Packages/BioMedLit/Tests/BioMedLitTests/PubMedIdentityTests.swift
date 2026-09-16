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

/// Nothing may be presented as a PubMed article unless something said it is one.
///
/// Europe PMC serves theses (`ETH`), case reports (`CBA`) and `HIR` records
/// whose accession is a bare decimal number and which carry no PubMed ID.
/// See `ArticleIdentifierKind.inferred(from:)` for the measured size of that
/// population; it is large, and one record would be enough. A bare decimal is also the exact
/// shape of a PubMed ID, so the shape rule called every one of them `.pubmed`
/// and the last resort pasted it after the PubMed base URL.
///
/// The result is not a dead link. Europe PMC thesis `889149` and PubMed article
/// `889149` both exist, and the second is a 1977 paper on mouse courtship. In a
/// tool built to check medical claims against their sources, handing the reader
/// a genuine but unrelated paper is worse than handing them nothing (#212).
///
/// The rule these tests pin: the shape of a number never states a PubMed ID.
/// Only a record that named its source, or a search of PubMed itself, can.
final class PubMedIdentityTests: XCTestCase {

    /// A real Europe PMC thesis accession, and a real PubMed ID.
    private let collidingAccession = "889149"

    // MARK: - The shape rule no longer guesses

    /// The branch this whole slice removes. `.unknown` was already the answer
    /// for every shape the rule cannot name, and it routes to `src:med` exactly
    /// as `.pubmed` did, so no query changes — only the claim does.
    func testABareNumberIsNotNamedAPubMedIdentifierByItsShape() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: collidingAccession), .unknown)
    }

    /// The prefixed shapes are real evidence and stay. A `PPR…` accession is a
    /// preprint whoever hands it to us.
    func testThePrefixedShapesAreStillRecognised() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "PPR1287966"), .preprint)
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "PMC1082889"), .pmc)
    }

    // MARK: - What a provider can vouch for

    /// PubMed returns MEDLINE records and nothing else, so the search itself
    /// states what the record did not. This is what keeps every document stored
    /// before the kind field existed — on the default provider — working.
    func testAPubMedSearchVouchesForItsOwnIdentifiers() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(
                declared: nil,
                accession: collidingAccession,
                provider: .pubmed
            ),
            .pubmed
        )
    }

    /// The case the reader was being harmed by: Europe PMC returns records of
    /// many kinds, so a Europe PMC search vouches for nothing about a bare
    /// number.
    func testAEuropePMCSearchVouchesForNothingAboutABareNumber() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(
                declared: nil,
                accession: collidingAccession,
                provider: .europePMC
            ),
            .unknown
        )
    }

    /// `both` names the search *mode*, not the article's own source: a merged
    /// result records the mode on every document, including the ones only Europe
    /// PMC returned. It therefore cannot vouch for any one article.
    func testAMergedSearchVouchesForNoOneArticle() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(
                declared: nil,
                accession: collidingAccession,
                provider: .both
            ),
            .unknown
        )
    }

    /// A provider's blanket claim must not overrule the identifier in front of
    /// it. `PPR1287966` is not a PubMed ID however it reached us, and calling it
    /// one would ask Europe PMC for it under `src:med`, where it matches
    /// nothing.
    func testAProviderDoesNotRelabelAPrefixedAccession() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(
                declared: nil,
                accession: "PPR1287966",
                provider: .pubmed
            ),
            .preprint
        )
    }

    /// A PubMed search vouches for the records it returns, not for arbitrary
    /// strings. Anything that is not a PubMed ID's shape is still `.unknown`,
    /// so the vouching cannot be used to launder a value into the PubMed URL.
    func testAProviderDoesNotVouchForSomethingShapedLikeNoPubMedIdentifier() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(
                declared: nil,
                accession: "CN101548780",
                provider: .pubmed
            ),
            .unknown
        )
    }

    /// The record's own word outranks the provider's, which is the whole reason
    /// #209 carried the token: a thesis found through a merged search is still a
    /// thesis.
    func testAStatedKindOutranksTheProvider() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(
                declared: .europePMCSource("eth"),
                accession: collidingAccession,
                provider: .pubmed
            ),
            .europePMCSource("eth")
        )
    }

    /// No provider is not a provider that vouches. A caller holding an
    /// identifier from somewhere else entirely gets the shape rule alone.
    func testNoProviderVouchesForNothing() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(declared: nil, accession: collidingAccession),
            .unknown
        )
    }

    // MARK: - The one predicate that authorises a PubMed URL

    /// Every surface that builds a PubMed URL — the retrieval chain's last
    /// resort and nine places in the apps — asks this one function, so the rule
    /// cannot be half-applied the way #186 was fixed on one of four surfaces.
    func testAStatedPubMedIdentifierIsReturned() {
        XCTAssertEqual(
            ArticleIdentifierKind.pubmedID(in: collidingAccession, declared: .pubmed),
            collidingAccession
        )
    }

    func testAnUnvouchedBareNumberIsRefused() {
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: collidingAccession, declared: nil))
    }

    func testAnUnmodelledEuropePMCSourceIsRefused() {
        XCTAssertNil(
            ArticleIdentifierKind.pubmedID(
                in: collidingAccession,
                declared: .europePMCSource("eth")
            )
        )
    }

    func testAPreprintAccessionIsRefused() {
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: "PPR1287966", declared: .preprint))
    }

    /// An empty slot built `https://pubmed.ncbi.nlm.nih.gov//`, PubMed's front
    /// page, and offered it as this article (#202).
    func testAnEmptyIdentifierIsRefused() {
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: "", declared: .pubmed))
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: "   ", declared: .pubmed))
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: nil, declared: .pubmed))
    }

    /// The value is network-supplied and reaches `URL(string:)`, which answers
    /// `nil` for a string containing a space — force-unwrapped at five app
    /// surfaces, so the context menu crashed the app (#213). A stated kind does
    /// not make a malformed value usable.
    func testAStatedKindDoesNotExcuseAMalformedIdentifier() {
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: "126 62058", declared: .pubmed))
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: "12662058/x", declared: .pubmed))
    }

    /// `Character.isNumber` is true for `½` and every non-Latin numeral, so
    /// `١٢٣` once classified as a PubMed ID (#211).
    func testANonASCIINumeralIsRefusedEvenWhenTheKindWasStated() {
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: "١٢٣٤٥٦٧", declared: .pubmed))
    }

    /// Trimmed rather than refused: the identifier is stored as it arrived, and
    /// surrounding whitespace names the same article.
    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(
            ArticleIdentifierKind.pubmedID(in: "  12662058\n", declared: .pubmed),
            "12662058"
        )
    }

    // MARK: - PubMed states the kind at the source

    /// The other half of what keeps the common path working: a record PubMed
    /// itself returned says so, so it needs no provider to vouch for it later
    /// and no document has to be re-examined to know what its slot holds.
    func testPubMedResultsStateThatTheirIdentifiersArePubMedIdentifiers() throws {
        let xml = """
        <?xml version="1.0"?>
        <PubmedArticleSet>
          <PubmedArticle>
            <MedlineCitation>
              <PMID>889149</PMID>
              <Article>
                <ArticleTitle>Pheromonal regulation of male mouse ultrasonic courtship</ArticleTitle>
                <Journal><Title>Animal Behaviour</Title></Journal>
              </Article>
            </MedlineCitation>
          </PubmedArticle>
        </PubmedArticleSet>
        """

        let articles = PubMedXMLParser(data: Data(xml.utf8)).parseArticleSet().articles

        XCTAssertEqual(articles.count, 1)
        XCTAssertEqual(articles.first?.identifierKind, .pubmed)
    }
}
