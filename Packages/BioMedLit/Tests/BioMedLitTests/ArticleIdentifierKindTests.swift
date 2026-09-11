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
            ArticleIdentifierKind(europePMCSource: "PAT"),
            .europePMCSource("pat")
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

    /// A PubMed ID is all digits — and so is a Europe PMC thesis, case report
    /// or `HIR` accession, none of which carry a PubMed ID at all. The shape
    /// cannot separate them, and calling the whole class `.pubmed` handed the
    /// reader a real but unrelated PubMed article (#212). Only a stated source
    /// or a PubMed search may name one now; see `PubMedIdentityTests`.
    func testAnAllDigitsAccessionIsNotNamedByItsShapeAlone() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "12662058"), .unknown)
    }

    /// `CN…` is neither a preprint, a PMC accession nor a PubMed ID, and the
    /// shape rule cannot say what it is. Answering `.pubmed` would be a label
    /// that lies; `.unknown` is what keeps the existing `src:med` fall-through
    /// from claiming to be a routing decision.
    func testAnUnrecognisedShapeIsUnknown() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "CN101548780"), .unknown)
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
            .pubmed, .preprint, .pmc, .europePMCSource("pat")
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

    // MARK: - The Token Alphabet

    /// A source token outside `[a-z0-9]` is refused rather than carried.
    ///
    /// The token reaches a Europe PMC query as `src:<token>` and a cache
    /// filename as a tag, and both positions assume a closed set: the query
    /// would parse as something else and match nothing — which this ladder
    /// reads as "no such article", the very defect #209 is about — and the tag
    /// is interpolated without sanitising.
    func testASourceTokenOutsideTheAllowedAlphabetIsRefused() {
        // Surrounding whitespace is trimmed before this guard runs, so "eth\n"
        // is a valid token and is deliberately absent here.
        for hostile in ["../etc", "med or *", "pat:x", "a b", "p/t", "e t h"] {
            XCTAssertNil(
                ArticleIdentifierKind(europePMCSource: hostile),
                "\(hostile) was accepted as a source token"
            )
        }
    }

    /// Every token Europe PMC actually publishes is a short alphanumeric word,
    /// so the guard above refuses nothing the provider sends. These six are
    /// live `SRC:` values, each verified to return hits.
    func testTheRealSourceTokensAreAllAccepted() {
        for token in ["MED", "PPR", "PMC", "PAT", "AGR", "ETH", "CBA", "HIR", "CTX"] {
            XCTAssertNotNil(
                ArticleIdentifierKind(europePMCSource: token),
                "\(token) is a live Europe PMC source and must be accepted"
            )
        }
    }

    /// `Character.isNumber` is true for `½`, for superscripts and for every
    /// non-Latin digit, so a shape rule built on it calls `١٢٣` a PubMed ID and
    /// lets it be pasted after the PubMed URL. A PubMed ID is an ASCII decimal
    /// integer and nothing else.
    func testANonASCIINumeralIsNotAPubMedIdentifier() {
        for numeral in ["١٢٣٤٥٦٧", "１２３４５６７", "½", "³⁴⁵"] {
            XCTAssertEqual(
                ArticleIdentifierKind.inferred(from: numeral),
                .unknown,
                "\(numeral) was read as a PubMed identifier"
            )
        }
    }

    /// An empty accession settles nothing. Returning `.pubmed` would put the
    /// empty string behind the PubMed URL, which is PubMed's front page offered
    /// as though it were this article.
    func testAnEmptyAccessionIsUnknown() {
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: ""), .unknown)
        XCTAssertEqual(ArticleIdentifierKind.inferred(from: "   "), .unknown)
    }
}
