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

/// Tests the payload the parse audit hands its callers (#184).
///
/// Two properties matter here and neither is about the parser. The persisted
/// form has to survive a round trip and be readable by a future version, because
/// it is written into a user's database; and the log wording has to stay put,
/// because the corpus suite reads it and because a rewording should be a visible
/// change rather than a side effect of a refactor.
final class JATSParseWarningsTests: XCTestCase {

    // MARK: - Every case, once

    /// Each `Loss` the audit can produce, for the tests that must cover all of
    /// them. Kept in one place so a new case is added once and every exhaustive
    /// test picks it up.
    private static let everyLoss: [JATSParseWarnings.Loss] = [
        .subArticleDepth(2),
        .openFigures(3),
        .openTables(1),
        .exhibitFootnoteDepth(4),
        .openCaptions(5),
        .openSections(6),
        .depthUnderflows(7),
        .noContent,
        .unspecified,
    ]

    /// A `Loss` case added to the type and not to ``everyLoss`` leaves every
    /// exhaustive test below silently weaker, so prove the list is complete.
    ///
    /// `Mirror` cannot enumerate an enum's cases the way it enumerates a
    /// struct's fields, so this is a `switch` with no `default`: adding a case
    /// stops the package compiling until the list grows too.
    func testEveryLossCaseIsInTheList() {
        for loss in Self.everyLoss {
            switch loss {
            case .subArticleDepth, .openFigures, .openTables, .exhibitFootnoteDepth,
                 .openCaptions, .openSections, .depthUnderflows, .noContent, .unspecified:
                continue
            }
        }
        XCTAssertEqual(
            Self.everyLoss.count, 9,
            "JATSParseWarnings.Loss gained or lost a case without updating everyLoss"
        )
    }

    // MARK: - The persisted form

    /// Every case survives the round trip that the SwiftData cache performs.
    func testEveryLossRoundTripsThroughItsPersistedForm() throws {
        let warnings = JATSParseWarnings(losses: Self.everyLoss)

        let data = try JSONEncoder().encode(warnings)
        let decoded = try JSONDecoder().decode(JATSParseWarnings.self, from: data)

        XCTAssertEqual(decoded, warnings)
    }

    /// The stored keys are ours, not the compiler's.
    ///
    /// Swift's synthesised `Codable` for an enum with associated values emits
    /// `{"openFigures":{"_0":2}}`, and `_0` is an implementation detail of the
    /// synthesis — not something to write into a user's database and then have
    /// to keep reading. Pinned so a later switch to synthesis is a test failure
    /// rather than an unreadable cache.
    func testThePersistedShapeIsNamedRatherThanSynthesised() throws {
        let data = try JSONEncoder().encode(
            JATSParseWarnings(losses: [.openFigures(2)])
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["schemaVersion"] as? Int, JATSParseWarnings.schemaVersion)
        let losses = try XCTUnwrap(json["losses"] as? [[String: Any]])
        XCTAssertEqual(losses.count, 1)
        XCTAssertEqual(losses[0]["kind"] as? String, "openFigures")
        XCTAssertEqual(losses[0]["count"] as? Int, 2)
        XCTAssertNil(losses[0]["_0"], "the synthesised shape leaked into the stored form")
    }

    /// A count-free case stores no count rather than a zero.
    ///
    /// A zero would be indistinguishable from a genuine count of zero if one of
    /// the counted cases ever reached the cache clamped, and it invites a reader
    /// to treat "0 figures were lost" as meaningful.
    func testACountFreeCaseStoresNoCount() throws {
        let data = try JSONEncoder().encode(JATSParseWarnings(losses: [.noContent]))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let losses = try XCTUnwrap(json["losses"] as? [[String: Any]])

        XCTAssertEqual(losses[0]["kind"] as? String, "noContent")
        XCTAssertNil(losses[0]["count"])
    }

    /// A payload from a future version is refused, not guessed at.
    ///
    /// The caller's contract is that a record it cannot read reports a loss
    /// rather than a clean parse, and that only works if decoding actually
    /// fails.
    func testAFutureSchemaVersionIsRefused() {
        let future = Data(#"{"schemaVersion": 99, "losses": []}"#.utf8)

        XCTAssertThrowsError(
            try JSONDecoder().decode(JATSParseWarnings.self, from: future)
        )
    }

    /// An unrecognised loss kind is refused for the same reason.
    func testAnUnknownLossKindIsRefused() {
        let unknown = Data(
            #"{"schemaVersion": 1, "losses": [{"kind": "openMarginalia", "count": 1}]}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(JATSParseWarnings.self, from: unknown)
        )
    }

    /// A counted kind stored without its count is refused rather than read as
    /// zero, which would be a loss of unknown size reported as no loss at all.
    func testACountedKindWithoutItsCountIsRefused() {
        let countless = Data(
            #"{"schemaVersion": 1, "losses": [{"kind": "openFigures"}]}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(JATSParseWarnings.self, from: countless)
        )
    }

    /// The shape this field held before #184: a bare array of rendered English.
    ///
    /// It must fail to decode. The caller turns a decode failure into an
    /// unspecified loss, which is the right answer for a record whose detail we
    /// can no longer read — and the wrong answer would be to map the sentences
    /// back to cases, re-creating in a persisted format the wording coupling
    /// this whole change removes.
    func testTheLegacyStringPayloadIsRefused() {
        let legacy = Data(
            """
            ["JATS parse ended with 2 open <fig> — those figures and their content were discarded"]
            """.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(JATSParseWarnings.self, from: legacy)
        )
    }

    // MARK: - The log wording

    /// Every diagnostic the audit writes, pinned to the byte.
    ///
    /// These strings are what `BioMedLitLib.logger` receives, and
    /// `JATSRealCorpusTests.testParsingReportsNoContentLoss` reads that log's
    /// text. They moved into ``JATSParseWarnings/Loss`` unchanged so the log,
    /// the corpus digests and that test all stayed still across #184 — which
    /// also means a later rewording is a visible change here rather than a
    /// silent one there.
    func testEveryLossRendersItsLogLineUnchanged() {
        let expected: [JATSParseWarnings.Loss: String] = [
            .subArticleDepth(2):
                "JATS sub-article depth ended at 2, not 0 — "
                + "content after the imbalance was discarded",
            .openFigures(3):
                "JATS parse ended with 3 open <fig> — "
                + "those figures and their content were discarded",
            .openTables(1):
                "JATS parse ended with 1 open <table-wrap> — "
                + "those tables and their content were discarded",
            .exhibitFootnoteDepth(4):
                "JATS exhibit footnote depth ended at 4, not 0 — "
                + "prose after the imbalance was routed into a footnote and discarded",
            .openCaptions(5):
                "JATS parse ended with 5 open <caption> — "
                + "prose after the imbalance was read as caption text",
            .openSections(6):
                "JATS parse ended with 6 open <sec> — "
                + "those sections and their prose were never emitted",
            .depthUnderflows(7):
                "JATS parse saw 7 end tag(s) with nothing to close — "
                + "a counter closed an element it never opened, so any other "
                + "imbalance reported here understates what was misrouted",
            .noContent:
                "JATS parse extracted no title, abstract or body — "
                + "any rendered full text carries only its identifiers",
            .unspecified:
                "This article's parse diagnostics could not be read back — "
                + "some content may be missing",
        ]

        XCTAssertEqual(
            Set(expected.keys), Set(Self.everyLoss),
            "a Loss case has no pinned log line"
        )
        for (loss, line) in expected {
            XCTAssertEqual(loss.logLine, line)
        }
    }

    /// `diagnostics` is the log rendering of the losses, in their own order.
    ///
    /// Kept as a property so the banner, the log loop and the persistence path
    /// all carried on working across #184 unchanged.
    func testDiagnosticsRenderTheLossesInOrder() {
        let warnings = JATSParseWarnings(losses: [.openTables(1), .openFigures(2)])

        XCTAssertEqual(
            warnings.diagnostics,
            [JATSParseWarnings.Loss.openTables(1).logLine,
             JATSParseWarnings.Loss.openFigures(2).logLine]
        )
    }

    // MARK: - Clean means empty

    func testNoLossesIsClean() {
        XCTAssertTrue(JATSParseWarnings().isClean)
        XCTAssertTrue(JATSParseWarnings().diagnostics.isEmpty)
    }

    /// Including the case that says only that *something* was lost — the answer
    /// a caller gives for a record it could not read, and the one answer that
    /// must never be mistaken for a clean parse.
    func testAnUnspecifiedLossIsNotClean() {
        XCTAssertFalse(JATSParseWarnings(losses: [.unspecified]).isClean)
    }
}
