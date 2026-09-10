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

/// Europe PMC states each record's kind, and until #209 we discarded it and
/// guessed the kind back from the accession's shape at two later points.
///
/// This suite pins the two directions. A token Europe PMC sent is authoritative
/// and needs no guessing; where no token was recorded — every document stored
/// before the field existed — the shape rule stands in, and must agree with what
/// the guess used to produce.
final class ArticleIdentifierKindTests: XCTestCase {

    // MARK: - What Europe PMC Told Us

    /// `MED` is Europe PMC's token for a MEDLINE record, whose external
    /// identifier is a PubMed ID.
    func testTheMedlineSourceTokenIsAPubMedIdentifier() {
        XCTAssertEqual(ArticleIdentifierKind(europePMCSource: "MED"), .pubmed)
    }

    /// `PPR` is a preprint, the record class #202 could not reach.
    func testThePreprintSourceTokenIsAPreprint() {
        XCTAssertEqual(ArticleIdentifierKind(europePMCSource: "PPR"), .preprint)
    }

    func testThePMCSourceTokenIsAPMCIdentifier() {
        XCTAssertEqual(ArticleIdentifierKind(europePMCSource: "PMC"), .pmc)
    }

    /// Europe PMC serves books, patents, agricultural records and theses too,
    /// each under its own token. Keeping the token is what lets such a record be
    /// asked for in its own terms instead of under `src:med`, where it matches
    /// nothing.
    func testAnUnrecognisedSourceTokenIsKept() {
        XCTAssertEqual(
            ArticleIdentifierKind(europePMCSource: "NBK"),
            .europePMCSource("nbk")
        )
    }

    /// Tokens are compared and stored lower-cased, because that is the case a
    /// `src:` query takes and Europe PMC sends them upper-case.
    func testSourceTokensAreCaseInsensitive() {
        XCTAssertEqual(ArticleIdentifierKind(europePMCSource: "med"), .pubmed)
        XCTAssertEqual(ArticleIdentifierKind(europePMCSource: "Ppr"), .preprint)
        XCTAssertEqual(ArticleIdentifierKind(europePMCSource: "pAt"), .europePMCSource("pat"))
    }

    /// No token is not a kind. A record that carried none, and every document
    /// stored before this field existed, must fall through to the shape rule
    /// rather than being assigned a kind nobody stated.
    func testAnAbsentSourceTokenIsNotAKind() {
        XCTAssertNil(ArticleIdentifierKind(europePMCSource: nil))
        XCTAssertNil(ArticleIdentifierKind(europePMCSource: ""))
        XCTAssertNil(ArticleIdentifierKind(europePMCSource: "   "))
    }

    // MARK: - The Shape Rule, For Records That Told Us Nothing

    func testAPreprintAccessionIsRecognisedByItsPrefix() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "PPR1287966"), .preprint)
    }

    func testAPMCAccessionIsRecognisedByItsPrefix() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "PMC1082889"), .pmc)
    }

    /// A PubMed ID is all digits, which is the same test the last-resort PubMed
    /// URL applies before pasting a value after `pubmed.ncbi.nlm.nih.gov`.
    func testAnAllDigitsAccessionIsAPubMedIdentifier() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "12662058"), .pubmed)
    }

    /// `NBK…` is neither a preprint, a PMC accession nor a PubMed ID, and the
    /// shape rule cannot say what it is. Answering `.pubmed` would be a label
    /// that lies; `.unknown` is what keeps the existing `src:med` fall-through
    /// from claiming to be a routing decision.
    func testAnUnrecognisedShapeIsUnknown() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "NBK1234"), .unknown)
    }

    func testTheShapeRuleIgnoresCase() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "ppr1287966"), .preprint)
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "pmc1082889"), .pmc)
    }

    // MARK: - Resolution

    /// The whole point of #209: a stated kind is used as stated, even where the
    /// shape rule would have said something else. Europe PMC has served a
    /// preprint record whose accession is not `PPR…`-shaped, and the source
    /// field is the authority on that, not the string.
    func testAStatedKindWinsOverTheShapeRule() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(declared: .preprint, accession: "12662058"),
            .preprint
        )
    }

    /// Nothing stated means the shape rule, which is exactly the behaviour every
    /// document stored before this field existed keeps.
    func testNoStatedKindFallsBackToTheShapeRule() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(declared: nil, accession: "PPR1287966"),
            .preprint
        )
    }

    /// `.unknown` is a stated absence of knowledge, not knowledge, so it defers
    /// to the shape rule the same way a missing token does. Otherwise a
    /// round-trip through a record that stored no token would erase a kind the
    /// shape can still name.
    func testAStatedUnknownDefersToTheShapeRule() {
        XCTAssertEqual(
            ArticleIdentifierKind.resolved(declared: .unknown, accession: "PMC1082889"),
            .pmc
        )
    }

    // MARK: - Persistence

    /// The stored form is Europe PMC's own token, so nothing has to be invented
    /// to write a kind down, and a stored value round-trips to the kind it came
    /// from.
    func testAKindRoundTripsThroughItsSourceToken() {
        for kind: ArticleIdentifierKind in [
            .pubmed, .preprint, .pmc, .europePMCSource("nbk")
        ] {
            XCTAssertEqual(
                ArticleIdentifierKind(europePMCSource: kind.europePMCSourceToken),
                kind,
                "\(kind) did not survive a round-trip through its token"
            )
        }
    }

    /// `.unknown` has no token, because there is nothing to record: writing one
    /// would turn "nobody told us" into a claim.
    func testUnknownHasNoSourceToken() {
        XCTAssertNil(ArticleIdentifierKind.unknown.europePMCSourceToken)
    }
}
