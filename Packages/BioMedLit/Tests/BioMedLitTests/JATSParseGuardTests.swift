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

/// Tests that a failed parse announces itself rather than returning an empty
/// article, and that an empty typed identifier does not latch.
final class JATSParseGuardTests: XCTestCase {

    // MARK: - Capturing what the parser reports

    /// Records the library's diagnostics so a test can assert on them.
    ///
    /// `@unchecked Sendable` with a lock because `BioMedLitLogger` requires
    /// `Sendable` and this is mutable; the lock is what makes that claim true.
    private final class RecordingLogger: BioMedLitLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        private func record(_ level: String, _ message: String) {
            lock.lock(); defer { lock.unlock() }
            messages.append("\(level): \(message)")
        }

        func debug(_ message: String, category: BioMedLitLogCategory) {
            record("DEBUG", message)
        }

        func info(_ message: String, category: BioMedLitLogCategory) {
            record("INFO", message)
        }

        func warning(_ message: String, category: BioMedLitLogCategory) {
            record("WARNING", message)
        }

        func error(_ message: String, category: BioMedLitLogCategory) {
            record("ERROR", message)
        }

        var recorded: [String] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            messages.removeAll()
        }
    }

    private let logger = RecordingLogger()

    override func setUp() {
        super.setUp()
        logger.reset()
        BioMedLitLib.configure(with: BioMedLitConfiguration(
            ncbiEmail: "tests@example.com", logger: logger
        ))
    }

    /// Restore the configuration the rest of the package's tests expect: the
    /// library cannot be un-configured, so put back "configured, no logger".
    override func tearDown() {
        BioMedLitLib.configure(with: BioMedLitConfiguration(
            ncbiEmail: "tests@example.com", logger: nil
        ))
        super.tearDown()
    }

    // MARK: - Empty result

    /// `parseToMarkdown` and `parseToHTML` both refuse an empty result. Without
    /// the same guard, `parseToArticle` returned a well-formed article with no
    /// title, no authors and no body — indistinguishable from a publisher stub,
    /// which is how a 57%-of-articles author loss went unobserved.
    func testAnEmptyArticleThrowsRatherThanReturningAnEmptyResult() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article><front><article-meta></article-meta></front><body></body></article>
        """
        XCTAssertThrowsError(try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()) { error in
            guard case JATSParseError.noContent = error else {
                return XCTFail("expected .noContent, got \(error)")
            }
        }
    }

    /// A title alone is content: some deposits carry metadata and no body, and
    /// refusing those would be its own kind of data loss.
    func testAnArticleWithOnlyATitleIsStillReturned() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article><front><article-meta>
          <title-group><article-title>Metadata only</article-title></title-group>
        </article-meta></front><body></body></article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()
        XCTAssertEqual(article.title, "Metadata only")
    }

    // MARK: - Empty typed identifiers

    private func parseIds(_ ids: String, knownPMCId: String? = nil) throws -> JATSArticle {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article><front><article-meta>
        \(ids)
          <title-group><article-title>T</article-title></title-group>
        </article-meta></front><body><sec><p>Prose.</p></sec></body></article>
        """
        let parser = knownPMCId.map { JATSXMLParser(data: Data(xml.utf8), knownPMCId: $0) }
            ?? JATSXMLParser(data: Data(xml.utf8))
        return try parser.parseToArticle()
    }

    /// An empty typed element stored an empty DOI *and* latched the flag that
    /// stops pattern matching recovering a real one later in the document.
    func testAnEmptyTypedDOIDoesNotBlockRecovery() throws {
        let article = try parseIds("""
          <article-id pub-id-type="doi"></article-id>
          <article-id>10.1371/journal.pgen.1012008</article-id>
        """)

        XCTAssertEqual(article.doi, "10.1371/journal.pgen.1012008")
    }

    func testAnEmptyTypedPMCIdDoesNotBlockRecovery() throws {
        let article = try parseIds("""
          <article-id pub-id-type="pmc"></article-id>
          <article-id>PMC12759138</article-id>
        """)

        XCTAssertEqual(article.pmcId, "PMC12759138")
    }

    /// The typed value still wins when it is actually present.
    func testATypedDOIStillBeatsAPublisherId() throws {
        let article = try parseIds("""
          <article-id pub-id-type="publisher-id">10.1177_20552076251406653</article-id>
          <article-id pub-id-type="doi">10.1177/20552076251406653</article-id>
        """)

        XCTAssertEqual(article.doi, "10.1177/20552076251406653")
    }

    /// A caller-supplied PMC ID still wins over the document's.
    func testKnownPMCIdStillWins() throws {
        let article = try parseIds("""
          <article-id pub-id-type="pmc">PMC9999999</article-id>
        """, knownPMCId: "PMC12759138")

        XCTAssertEqual(article.pmcId, "PMC12759138")
    }

    // MARK: - One parse per instance (#168)

    private static let wellFormedArticle = """
    <?xml version="1.0" encoding="UTF-8"?>
    <article><front><article-meta>
      <title-group><article-title>Metadata only</article-title></title-group>
    </article-meta></front><body><sec><title>Results</title><p>Prose.</p></sec></body></article>
    """

    private func assertAlreadyParsed(
        _ parse: () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try parse(), file: file, line: line) { error in
            guard case JATSParseError.alreadyParsed = error else {
                return XCTFail("expected .alreadyParsed, got \(error)", file: file, line: line)
            }
        }
    }

    /// `XMLParser` is built once from the data and cannot be re-pointed, so an
    /// instance parses once. A second call used to reach the `??` chain with both
    /// `parseError` and `parser.parserError` nil on the consumed parser and report
    /// `"Unknown parsing error"` — a message with no route back to the cause, on a
    /// class whose own documentation reads as "either method on this instance".
    func testASecondParseOnTheSameInstanceSaysTheParserWasConsumed() throws {
        let parser = JATSXMLParser(data: Data(Self.wellFormedArticle.utf8))
        _ = try parser.parseToArticle()

        assertAlreadyParsed { try parser.parseToMarkdown() }
    }

    /// The guard belongs to the instance, not to one entry point: all three
    /// consume the same `XMLParser`.
    func testEveryEntryPointRefusesAConsumedParser() throws {
        let parser = JATSXMLParser(data: Data(Self.wellFormedArticle.utf8))
        _ = try parser.parseToMarkdown()

        assertAlreadyParsed { try parser.parseToMarkdown() }
        assertAlreadyParsed { try parser.parseToHTML() }
        assertAlreadyParsed { try parser.parseToArticle() }
    }

    /// A failed first parse consumes the instance just as a successful one does,
    /// and the second call must not report the first call's cause as its own.
    func testAFailedFirstParseAlsoConsumesTheInstance() {
        let parser = JATSXMLParser(data: Data("<article><body>".utf8))
        XCTAssertThrowsError(try parser.parseToArticle())

        assertAlreadyParsed { try parser.parseToArticle() }
    }

    /// The rule is one parse per *instance*, not one parse per document: the
    /// two-instance form the class documentation now shows must keep working.
    func testASecondInstanceOverTheSameDataParsesNormally() throws {
        let data = Data(Self.wellFormedArticle.utf8)
        let article = try JATSXMLParser(data: data).parseToArticle()
        let markdown = try JATSXMLParser(data: data).parseToMarkdown()

        XCTAssertEqual(article.title, "Metadata only")
        XCTAssertTrue(markdown.contains("Prose."), "markdown was: \(markdown)")
    }

    // MARK: - What the unwind audit reports (#175)

    /// The audit is a pure function of the end-of-parse state, which is the only
    /// way to exercise it: no well-formed document leaves a stack open, because
    /// `XMLParser` refuses an unbalanced one and every guard in the parser tests
    /// the same predicate at both ends. That is the point of a net — it fires
    /// only when the parser itself is wrong — and it is also why the net sat in
    /// `parseToArticle` from the day it was written, with no production call
    /// site, and nobody noticed.
    func testABalancedParseReportsNothing() {
        XCTAssertEqual(JATSXMLParser.unwindDiagnostics(JATSParseUnwindState()), [])
    }

    private func diagnostic(
        _ state: JATSParseUnwindState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let lines = JATSXMLParser.unwindDiagnostics(state)
        guard lines.count == 1 else {
            XCTFail("expected one diagnostic, got \(lines)", file: file, line: line)
            return ""
        }
        return lines[0]
    }

    func testAnUnbalancedSubArticleIsReported() {
        let line = diagnostic(JATSParseUnwindState(subArticleDepth: 2))

        XCTAssertTrue(line.contains("sub-article"), line)
        XCTAssertTrue(line.contains("2"), line)
    }

    func testAnOpenFigureIsReported() {
        let line = diagnostic(JATSParseUnwindState(openFigures: 3))

        XCTAssertTrue(line.contains("<fig>"), line)
        XCTAssertTrue(line.contains("3"), line)
    }

    /// The check #175 says would have surfaced #173 on the spot. It had no
    /// table-side counterpart at all: `currentTable` was a single slot, so there
    /// was nothing for an audit to look at.
    func testAnOpenTableIsReported() {
        let line = diagnostic(JATSParseUnwindState(openTables: 4))

        XCTAssertTrue(line.contains("<table-wrap>"), line)
        XCTAssertTrue(line.contains("4"), line)
    }

    /// A stranded footnote depth is the one imbalance that has actually occurred
    /// on master: every `<p>` after it drained into `appendFootnoteText` and was
    /// discarded, one paragraph at a time, in silence. Fixed in PR #171, before
    /// any release carried it.
    func testAStrandedExhibitFootnoteDepthIsReported() {
        let line = diagnostic(JATSParseUnwindState(exhibitFootnoteDepth: 5))

        XCTAssertTrue(line.contains("footnote"), line)
        XCTAssertTrue(line.contains("5"), line)
    }

    func testAnOpenCaptionIsReported() {
        let line = diagnostic(JATSParseUnwindState(openCaptions: 6))

        XCTAssertTrue(line.contains("<caption>"), line)
        XCTAssertTrue(line.contains("6"), line)
    }

    func testAnOpenSectionIsReported() {
        let line = diagnostic(JATSParseUnwindState(openSections: 7))

        XCTAssertTrue(line.contains("<sec>"), line)
        XCTAssertTrue(line.contains("7"), line)
    }

    /// One line each, so a parse that went wrong in two places says so twice
    /// rather than reporting whichever check is written first.
    func testEveryImbalanceGetsItsOwnLine() {
        let lines = JATSXMLParser.unwindDiagnostics(JATSParseUnwindState(
            subArticleDepth: 1,
            openFigures: 2,
            openTables: 1,
            exhibitFootnoteDepth: 1,
            openCaptions: 1,
            openSections: 1,
            depthUnderflows: 1
        ))

        XCTAssertEqual(lines.count, 7, "\(lines)")
    }

    /// An end tag that arrived with nothing to close (#180).
    ///
    /// The counts above are all "still open at the end". This one is the
    /// opposite imbalance, and it is the only one the audit could not see: every
    /// decrement site clamps at zero, so an over-decrement was erased before the
    /// audit read it.
    func testAnUnderflowIsReported() {
        let line = diagnostic(JATSParseUnwindState(depthUnderflows: 8))

        XCTAssertTrue(line.contains("nothing to close"), line)
        XCTAssertTrue(line.contains("8"), line)
    }

    /// A negative count is not a thing the parser can produce — every counter is
    /// clamped at zero — and the type now refuses to represent one, which is
    /// stronger than tolerating it in the audit. Reporting one as "still open"
    /// would be worse than saying nothing; being unable to *construct* one means
    /// no future caller has to remember that.
    func testANegativeCountIsClampedAtConstruction() {
        XCTAssertEqual(JATSParseUnwindState(subArticleDepth: -1), JATSParseUnwindState())
        XCTAssertEqual(JATSParseUnwindState(depthUnderflows: -3), JATSParseUnwindState())
        XCTAssertEqual(
            JATSXMLParser.unwindDiagnostics(JATSParseUnwindState(subArticleDepth: -1)),
            []
        )
    }

    /// `isBalanced` and `unwindDiagnostics` answer the same question two ways,
    /// so a field added to one and not the other is a silent disagreement. Every
    /// single-field state plus the all-fields state has to agree, which is what
    /// makes "clean" mean the same thing to a caller as it does to the log.
    func testIsBalancedAgreesWithTheDiagnostics() {
        // Keyed by field name so `Mirror` can prove the list is complete. A
        // hand-written array cannot: a field added to the struct and forgotten
        // in both `unwindDiagnostics` and the array leaves the test green, which
        // is the silent disagreement this exists to make impossible.
        let singleFieldStates: [String: JATSParseUnwindState] = [
            "subArticleDepth": JATSParseUnwindState(subArticleDepth: 1),
            "openFigures": JATSParseUnwindState(openFigures: 1),
            "openTables": JATSParseUnwindState(openTables: 1),
            "exhibitFootnoteDepth": JATSParseUnwindState(exhibitFootnoteDepth: 1),
            "openCaptions": JATSParseUnwindState(openCaptions: 1),
            "openSections": JATSParseUnwindState(openSections: 1),
            "depthUnderflows": JATSParseUnwindState(depthUnderflows: 1),
        ]

        let declaredFields = Set(
            Mirror(reflecting: JATSParseUnwindState()).children.compactMap(\.label)
        )
        XCTAssertEqual(
            declaredFields,
            Set(singleFieldStates.keys),
            "JATSParseUnwindState gained or lost a field without updating this test"
        )

        for (field, state) in singleFieldStates {
            XCTAssertFalse(state.isBalanced, field)
            XCTAssertEqual(
                JATSXMLParser.unwindDiagnostics(state).count, 1,
                "\(field) is not balanced but has no line in unwindDiagnostics"
            )
        }

        let clean = JATSParseUnwindState()
        XCTAssertTrue(clean.isBalanced)
        XCTAssertTrue(JATSXMLParser.unwindDiagnostics(clean).isEmpty)

        let everyField = JATSParseUnwindState(
            subArticleDepth: 1, openFigures: 1, openTables: 1,
            exhibitFootnoteDepth: 1, openCaptions: 1, openSections: 1,
            depthUnderflows: 1
        )
        XCTAssertFalse(everyField.isBalanced)
        XCTAssertEqual(
            JATSXMLParser.unwindDiagnostics(everyField).count, declaredFields.count
        )
    }

    // MARK: - The audit sees what the parser has open (#175)

    /// Open one element through the delegate callback and stop there.
    ///
    /// `XMLParserDelegate` conformance is the parser's public surface, so this
    /// drives the real object through its real interface — it simply declines to
    /// deliver the end tag, which is the one thing a well-formed document can
    /// never do. Without it nothing connects a counter to the field the audit
    /// reports it under, and swapping two of those fields changes no behaviour
    /// any other test can see.
    private func stateAfterOpening(_ elements: [String]) -> JATSParseUnwindState {
        let parser = JATSXMLParser(data: Data())
        for element in elements {
            parser.parser(
                XMLParser(data: Data()),
                didStartElement: element,
                namespaceURI: nil,
                qualifiedName: nil,
                attributes: [:]
            )
        }
        return parser.unwindState
    }

    func testAnOpenFigureIsCountedAsAFigure() {
        XCTAssertEqual(stateAfterOpening(["fig"]), JATSParseUnwindState(openFigures: 1))
    }

    func testAnOpenTableIsCountedAsATable() {
        XCTAssertEqual(stateAfterOpening(["table-wrap"]), JATSParseUnwindState(openTables: 1))
    }

    func testAnOpenSubArticleIsCountedAsASubArticle() {
        XCTAssertEqual(stateAfterOpening(["sub-article"]), JATSParseUnwindState(subArticleDepth: 1))
    }

    func testAnOpenExhibitFootnoteIsCountedAsAFootnote() {
        XCTAssertEqual(
            stateAfterOpening(["table-wrap", "table-wrap-foot"]),
            JATSParseUnwindState(openTables: 1, exhibitFootnoteDepth: 1)
        )
    }

    func testAnOpenCaptionIsCountedAsACaption() {
        XCTAssertEqual(
            stateAfterOpening(["fig", "caption"]),
            JATSParseUnwindState(openFigures: 1, openCaptions: 1)
        )
    }

    func testAnOpenSectionIsCountedAsASection() {
        XCTAssertEqual(
            stateAfterOpening(["body", "sec"]),
            JATSParseUnwindState(openSections: 1)
        )
    }

    /// The shape a balanced parse ends in, and the baseline the six above are
    /// measured against: an untouched parser has nothing open.
    func testAParserThatHasSeenNothingHasNothingOpen() {
        XCTAssertEqual(stateAfterOpening([]), JATSParseUnwindState())
    }

    // MARK: - An end tag with nothing to close (#180)

    /// The mirror of `stateAfterOpening`: deliver end tags through the same real
    /// delegate callbacks, declining to send the matching start.
    ///
    /// `opening` runs first so a test can put the parser in the state its defect
    /// needs before the unmatched end tag arrives — `</fn>` only decrements
    /// while an exhibit is open, so it cannot underflow in a vacuum.
    private func stateAfterClosing(
        _ closing: [String],
        opening: [String] = []
    ) -> JATSParseUnwindState {
        let parser = JATSXMLParser(data: Data())
        for element in opening {
            parser.parser(
                XMLParser(data: Data()), didStartElement: element,
                namespaceURI: nil, qualifiedName: nil, attributes: [:]
            )
        }
        for element in closing {
            parser.parser(
                XMLParser(data: Data()), didEndElement: element,
                namespaceURI: nil, qualifiedName: nil
            )
        }
        return parser.unwindState
    }

    /// The clamp at each decrement site is correct for *routing* and wrong for
    /// the audit, so #180 keeps it and counts beside it.
    ///
    /// Correct for routing: a negative `exhibitFootnoteDepth` would let the next
    /// legitimate `<table-wrap-foot>` bring the counter back to 0, switching
    /// footnote routing off while a real footnote is open — a live content-loss
    /// bug strictly worse than the clamp. Wrong for the audit: with a depth of 2
    /// and three decrements, the third clamps to 0 and the counter then reads
    /// "balanced" for the rest of the document while a real element is still
    /// open, so the audit certifies a defective parse as clean — the opposite of
    /// what a net is for.
    func testAnUnmatchedSubArticleEndTagIsCountedAsAnUnderflow() {
        XCTAssertEqual(
            stateAfterClosing(["sub-article"]),
            JATSParseUnwindState(depthUnderflows: 1)
        )
    }

    func testAnUnmatchedTableFootEndTagIsCountedAsAnUnderflow() {
        XCTAssertEqual(
            stateAfterClosing(["table-wrap-foot"]),
            JATSParseUnwindState(depthUnderflows: 1)
        )
    }

    /// `</fn>` decrements only while an exhibit is open, so the underflow needs
    /// a `<table-wrap>` around it — which is also the only shape in which the
    /// defect can occur at all.
    func testAnUnmatchedFootnoteEndTagInsideAnExhibitIsCountedAsAnUnderflow() {
        XCTAssertEqual(
            stateAfterClosing(["fn"], opening: ["table-wrap"]),
            JATSParseUnwindState(openTables: 1, depthUnderflows: 1)
        )
    }

    /// The count, not just the fact. A diagnostic reporting "1" when three end
    /// tags arrived unmatched understates the damage in exactly the way the clamp
    /// did, so the increment has to accumulate rather than latch.
    func testEveryUnmatchedEndTagIsCounted() {
        XCTAssertEqual(
            stateAfterClosing(["table-wrap-foot", "table-wrap-foot", "sub-article"]),
            JATSParseUnwindState(depthUnderflows: 3)
        )
    }

    /// The negative control the three above need. Without it they pass just as
    /// happily against a counter that increments on every end tag, which would
    /// report an underflow for every well-formed document in the corpus.
    func testAMatchedFootnotePairIsNotAnUnderflow() {
        XCTAssertEqual(
            stateAfterClosing(["table-wrap-foot"], opening: ["table-wrap", "table-wrap-foot"]),
            JATSParseUnwindState(openTables: 1)
        )
    }

    // MARK: - The stack-backed counters hide an over-pop too (#182 review)

    /// A `</caption>` with nothing open used to vanish entirely.
    ///
    /// `popLast()` on an empty stack returns `nil` and changes nothing, so
    /// `openCaptions` still read 0 and the audit called the parse clean — the
    /// #180 failure exactly, on a counter the clamp argument never covered.
    func testACaptionEndWithNothingOpenIsCountedAsAnUnderflow() {
        XCTAssertEqual(
            stateAfterClosing(["caption"]),
            JATSParseUnwindState(depthUnderflows: 1)
        )
    }

    /// The same for `</sec>`, whose pop is guarded by `!inAbstract` at both ends
    /// — the start/end-guard pairing whose drift was #171 and #173.
    func testASectionEndWithNothingOpenIsCountedAsAnUnderflow() {
        XCTAssertEqual(
            stateAfterClosing(["sec"]),
            JATSParseUnwindState(depthUnderflows: 1)
        )
    }

    /// `</fig>` and `</table-wrap>` detected this all along and told only the log
    /// — a loss the parser noticed and the reader never heard (#181).
    func testAnExhibitEndWithNothingOpenIsCountedAsAnUnderflow() {
        XCTAssertEqual(
            stateAfterClosing(["fig"]),
            JATSParseUnwindState(depthUnderflows: 1)
        )
        XCTAssertEqual(
            stateAfterClosing(["table-wrap"]),
            JATSParseUnwindState(depthUnderflows: 1)
        )
    }

    /// The negative control for all four: matched pairs must stay silent, or the
    /// counter fires on every well-formed article in the corpus.
    func testMatchedStackPairsAreNotUnderflows() {
        XCTAssertEqual(
            stateAfterClosing(
                ["caption", "fig", "sec"],
                opening: ["sec", "fig", "caption"]
            ),
            JATSParseUnwindState()
        )
    }

    /// Why the clamp stays rather than being removed, and the only site where
    /// that is more than uniformity.
    ///
    /// `inSubArticle` is `subArticleDepth > 0`, so an unclamped over-decrement to
    /// -1 is not merely unreported: the *next* `<sub-article>` brings the counter
    /// back to 0, `inSubArticle` reads false while the parser is inside one, and
    /// the reviewer report is emitted as the article's own body. Removing the
    /// clamp to "let the audit see the negative" would trade a missing diagnostic
    /// for live content corruption, which is why #180 counts beside it instead.
    ///
    /// (`exhibitFootnoteDepth` has no such stake — routing moved to
    /// `inInnermostExhibitFootnote` in #173 — so only this counter can be pinned
    /// this way.)
    func testAnOverDecrementedSubArticleDepthStillExcludesTheNextSubArticle() throws {
        let parser = JATSXMLParser(data: Data(Self.articleWithSubArticle.utf8))
        parser.parser(
            XMLParser(data: Data()), didEndElement: "sub-article",
            namespaceURI: nil, qualifiedName: nil
        )

        let article = try parser.parseToArticle()

        XCTAssertEqual(
            article.bodySections.flatMap(\.paragraphs), ["Real prose."],
            "the reviewer report was emitted as the article's own body"
        )
    }

    private static let articleWithSubArticle = """
    <?xml version="1.0" encoding="UTF-8"?>
    <article>
      <front><article-meta>
        <title-group><article-title>Real article</article-title></title-group>
      </article-meta></front>
      <body><sec><title>Methods</title><p>Real prose.</p></sec></body>
      <sub-article article-type="reviewer-report">
        <body><p>Reviewer prose.</p></body>
      </sub-article>
    </article>
    """

    /// The second half of #180's cost, and the half a `> 0` test cannot express:
    /// after an over-decrement the counter no longer means "how many are open",
    /// it means "how many are open, or fewer". Every other element here balances,
    /// so the spurious `</table-wrap-foot>` is the only thing wrong with this
    /// parse — and without the underflow count the audit certifies it clean.
    func testAnOverDecrementIsNoLongerCertifiedClean() {
        let state = stateAfterClosing(
            ["table-wrap-foot", "table-wrap-foot", "table-wrap"],
            opening: ["table-wrap", "table-wrap-foot"]
        )

        XCTAssertEqual(state, JATSParseUnwindState(depthUnderflows: 1), "\(state)")
    }

    // MARK: - The audit runs on every entry point (#175)

    /// A well-formed article with no `<contrib>` at all. The zero-author warning
    /// is the one end-of-parse check a document *can* trip, so it is what proves
    /// the audit is wired into the production path rather than into
    /// `parseToArticle` alone — which is where it sat, unreachable from
    /// `FullTextService`, from the day it was written.
    private static let authorlessArticle = """
    <?xml version="1.0" encoding="UTF-8"?>
    <article><front><article-meta>
      <title-group><article-title>Nobody wrote this</article-title></title-group>
    </article-meta></front><body><sec><title>Results</title><p>Prose.</p></sec></body></article>
    """

    private func assertReportsZeroAuthors(
        _ parse: (JATSXMLParser) throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) rethrows {
        logger.reset()
        _ = try parse(JATSXMLParser(data: Data(Self.authorlessArticle.utf8)))

        XCTAssertTrue(
            logger.recorded.contains { $0.contains("zero authors") },
            "nothing reported the authorless parse; recorded: \(logger.recorded)",
            file: file, line: line
        )
    }

    func testAnAuthorlessParseIsReportedOnTheArticlePath() throws {
        try assertReportsZeroAuthors { try $0.parseToArticle() }
    }

    /// `FullTextService.fetchEuropePMCXML` calls this one, and nothing else.
    func testAnAuthorlessParseIsReportedOnTheMarkdownPath() throws {
        try assertReportsZeroAuthors { try $0.parseToMarkdown() }
    }

    /// And this one.
    func testAnAuthorlessParseIsReportedOnTheHTMLPath() throws {
        try assertReportsZeroAuthors { try $0.parseToHTML() }
    }

    /// The negative control the three above need: a warning that fires whatever
    /// the document says proves nothing.
    func testAnArticleWithAuthorsIsNotReported() throws {
        _ = try JATSXMLParser(data: Data(Self.wellFormedArticleWithAuthor.utf8)).parseToMarkdown()

        XCTAssertFalse(
            logger.recorded.contains { $0.contains("zero authors") },
            "recorded: \(logger.recorded)"
        )
    }

    private static let wellFormedArticleWithAuthor = """
    <?xml version="1.0" encoding="UTF-8"?>
    <article><front><article-meta>
      <title-group><article-title>Somebody wrote this</article-title></title-group>
      <contrib-group><contrib contrib-type="author">
        <name><surname>Doe</surname><given-names>J</given-names></name>
      </contrib></contrib-group>
    </article-meta></front><body><sec><title>Results</title><p>Prose.</p></sec></body></article>
    """

    private static let contentlessArticle = """
    <?xml version="1.0" encoding="UTF-8"?>
    <article><front><article-meta></article-meta></front><body></body></article>
    """

    /// A parse that produced nothing is one defect, not two: "it also had no
    /// authors" is noise on top of the emptiness reported below it.
    func testAnEmptyParseDoesNotAlsoComplainAboutAuthors() {
        XCTAssertThrowsError(
            try JATSXMLParser(data: Data(Self.contentlessArticle.utf8)).parseToArticle()
        )

        XCTAssertFalse(
            logger.recorded.contains { $0.contains("zero authors") },
            "recorded: \(logger.recorded)"
        )
    }

    /// ...but the emptiness itself must still be reported, and on the paths
    /// production uses. Only `parseToArticle` turns it into `.noContent`;
    /// `parseToHTML` measures its own output, and `buildHTML` emits the
    /// identifiers line first, so with a known PMC ID — which `FullTextService`
    /// always supplies — the result is never empty and never throws. The article
    /// came back stripped to its own accession number, in silence, which is the
    /// shape #175 exists to stop.
    func testAContentlessParseIsReportedOnTheHTMLPath() throws {
        let html = try JATSXMLParser(
            data: Data(Self.contentlessArticle.utf8), knownPMCId: "PMC12759138"
        ).parseToHTML()

        XCTAssertFalse(html.isEmpty, "the identifiers line is why this cannot throw")
        XCTAssertTrue(
            logger.recorded.contains { $0.contains("no title, abstract or body") },
            "recorded: \(logger.recorded)"
        )
    }

    /// The identifier every diagnostic carries. Without it the two parsers
    /// `FullTextService` builds over one document — `XMLParser` is consumed by
    /// its first parse — report twice, and two identical unattributed lines
    /// cannot be told from two genuinely broken articles.
    func testDiagnosticsNameTheArticle() throws {
        _ = try? JATSXMLParser(
            data: Data(Self.contentlessArticle.utf8), knownPMCId: "PMC12759138"
        ).parseToHTML()

        XCTAssertTrue(
            logger.recorded.contains { $0.contains("PMC12759138") },
            "recorded: \(logger.recorded)"
        )
    }

    // MARK: - The unwind audit reaches the caller (#181)

    /// #175 put the audit on the path production uses. It still only *logged*,
    /// so `FullTextService` had no channel to say "this article came back
    /// truncated" and the UI rendered a gutted article exactly as it rendered a
    /// complete one — the reader cannot tell a parser defect from a publisher who
    /// deposited little. These pin the channel that carries it out.
    func testACleanParseReportsNoWarnings() throws {
        let parser = JATSXMLParser(data: Data(Self.wellFormedArticleWithAuthor.utf8))

        _ = try parser.parseToHTML()

        XCTAssertTrue(parser.parseWarnings.isClean, "\(parser.parseWarnings.diagnostics)")
    }

    /// The same imbalance the log already carried, now reachable by a caller.
    func testAnUnclosedFigureReachesTheCaller() throws {
        let parser = JATSXMLParser(data: Data(Self.wellFormedArticleWithAuthor.utf8))
        parser.parser(
            XMLParser(data: Data()), didStartElement: "fig",
            namespaceURI: nil, qualifiedName: nil, attributes: [:]
        )

        _ = try parser.parseToHTML()

        XCTAssertFalse(parser.parseWarnings.isClean)
        XCTAssertTrue(
            parser.parseWarnings.diagnostics.contains { $0.contains("open <fig>") },
            "\(parser.parseWarnings.diagnostics)"
        )
    }

    /// The other loss a reader can act on: an article rendered as its own
    /// accession number and nothing else.
    func testAContentlessParseReachesTheCaller() throws {
        let parser = JATSXMLParser(
            data: Data(Self.contentlessArticle.utf8), knownPMCId: "PMC12759138"
        )

        _ = try parser.parseToHTML()

        XCTAssertTrue(
            parser.parseWarnings.diagnostics.contains { $0.contains("no title, abstract or body") },
            "\(parser.parseWarnings.diagnostics)"
        )
    }

    /// The cry-wolf guard, and the reason `parseWarnings` is not simply "every
    /// line `reportParseCompletion` emits".
    ///
    /// Zero authors is a metadata gap, not a truncation: editorials, corrections
    /// and errata legitimately carry none. A banner that fires on those trains
    /// the reader to dismiss it, and the banner is then worth nothing on the
    /// article where content really was discarded. It stays in the log, where a
    /// developer can still see it.
    func testZeroAuthorsIsLoggedButNotReportedToTheCaller() throws {
        let parser = JATSXMLParser(data: Data(Self.authorlessArticle.utf8))

        _ = try parser.parseToHTML()

        XCTAssertTrue(
            logger.recorded.contains { $0.contains("zero authors") },
            "the warning must still reach the log; recorded: \(logger.recorded)"
        )
        XCTAssertTrue(
            parser.parseWarnings.isClean,
            "a metadata gap must not read as a truncated rendering: "
                + "\(parser.parseWarnings.diagnostics)"
        )
    }

    // MARK: - The unwind audit reaches the log (#175)

    /// Everything above tests `unwindDiagnostics` as a pure function and
    /// `unwindState` as a producer. Nothing joined them: deleting the loop that
    /// emits the lines, or pointing it at a blank state, changed no behaviour any
    /// test could see. That is #175 one layer in — a net that is unit-tested and
    /// not connected — so these drive a real parse with a stack left open.
    ///
    /// - Parameters:
    ///   - element: The element to open and never close.
    ///   - parse: The entry point to run afterwards.
    ///   - expected: A fragment the emitted diagnostic must contain.
    private func assertReportsUnwind(
        opening element: String,
        _ parse: (JATSXMLParser) throws -> Any,
        expecting expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) rethrows {
        logger.reset()
        let parser = JATSXMLParser(data: Data(Self.wellFormedArticleWithAuthor.utf8))
        parser.parser(
            XMLParser(data: Data()), didStartElement: element,
            namespaceURI: nil, qualifiedName: nil, attributes: [:]
        )
        _ = try parse(parser)

        XCTAssertTrue(
            logger.recorded.contains { $0.contains(expected) },
            "the audit never reached the log; recorded: \(logger.recorded)",
            file: file, line: line
        )
    }

    func testAnUnclosedFigureIsReportedOnTheMarkdownPath() throws {
        try assertReportsUnwind(
            opening: "fig", { try $0.parseToMarkdown() }, expecting: "1 open <fig>"
        )
    }

    func testAnUnclosedTableIsReportedOnTheHTMLPath() throws {
        try assertReportsUnwind(
            opening: "table-wrap", { try $0.parseToHTML() }, expecting: "1 open <table-wrap>"
        )
    }

    func testAnUnclosedSectionIsReportedOnTheArticlePath() throws {
        try assertReportsUnwind(
            opening: "sec", { try $0.parseToArticle() }, expecting: "1 open <sec>"
        )
    }

    /// The negative control the three above need: an audit that fires on a clean
    /// parse would prove nothing about the ones that fire on a dirty one.
    func testABalancedParseEmitsNoUnwindDiagnostics() throws {
        _ = try JATSXMLParser(data: Data(Self.wellFormedArticleWithAuthor.utf8)).parseToMarkdown()

        XCTAssertFalse(
            logger.recorded.contains { $0.contains("JATS parse ended with") },
            "recorded: \(logger.recorded)"
        )
    }

    // MARK: - The routing-disagreement canaries (#170)

    /// `withCurrentFigure` and `withCurrentTable` log when the element stack says
    /// an exhibit is open and the collector disagrees, because the symptom is
    /// content quietly going missing with nothing else to go on. Nothing tested
    /// the logs, so both could be deleted by a future refactor without a red
    /// test — and this PR silently changed one of the two messages.
    ///
    /// Driven through the delegate: deliver a `</fig>` the collector never saw an
    /// opening for, which is the one thing well-formed XML cannot produce.
    func testAFigureEndWithNothingOpenIsReported() {
        let parser = JATSXMLParser(data: Data())
        parser.parser(
            XMLParser(data: Data()), didEndElement: "fig",
            namespaceURI: nil, qualifiedName: nil
        )

        XCTAssertTrue(
            logger.recorded.contains { $0.contains("</fig> with no open <fig>") },
            "recorded: \(logger.recorded)"
        )
    }

    func testATableEndWithNothingOpenIsReported() {
        let parser = JATSXMLParser(data: Data())
        parser.parser(
            XMLParser(data: Data()), didEndElement: "table-wrap",
            namespaceURI: nil, qualifiedName: nil
        )

        XCTAssertTrue(
            logger.recorded.contains { $0.contains("</table-wrap> with no open <table-wrap>") },
            "recorded: \(logger.recorded)"
        )
    }
}
