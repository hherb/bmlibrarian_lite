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
    /// only when the parser itself is wrong — and it is also why the net went
    /// three releases without a production call site and nobody noticed.
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
        let line = diagnostic(JATSParseUnwindState(openFigures: 1))

        XCTAssertTrue(line.contains("<fig>"), line)
    }

    /// The check #175 says would have surfaced #173 on the spot. It had no
    /// table-side counterpart at all: `currentTable` was a single slot, so there
    /// was nothing for an audit to look at.
    func testAnOpenTableIsReported() {
        let line = diagnostic(JATSParseUnwindState(openTables: 1))

        XCTAssertTrue(line.contains("<table-wrap>"), line)
    }

    /// A stranded footnote depth is the one imbalance that has actually shipped:
    /// every `<p>` after it drained into `appendFootnoteText` and was discarded,
    /// one paragraph at a time, in silence (#173, fixed in #171).
    func testAStrandedExhibitFootnoteDepthIsReported() {
        let line = diagnostic(JATSParseUnwindState(exhibitFootnoteDepth: 1))

        XCTAssertTrue(line.contains("footnote"), line)
    }

    func testAnOpenCaptionIsReported() {
        let line = diagnostic(JATSParseUnwindState(openCaptions: 1))

        XCTAssertTrue(line.contains("<caption>"), line)
    }

    func testAnOpenSectionIsReported() {
        let line = diagnostic(JATSParseUnwindState(openSections: 3))

        XCTAssertTrue(line.contains("<sec>"), line)
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
            openSections: 1
        ))

        XCTAssertEqual(lines.count, 6, "\(lines)")
    }

    /// A negative count is not a thing the parser can produce — every counter is
    /// clamped at zero — but reporting one as "still open" would be worse than
    /// saying nothing.
    func testANegativeCountIsNotReportedAsAnImbalance() {
        XCTAssertEqual(
            JATSXMLParser.unwindDiagnostics(JATSParseUnwindState(subArticleDepth: -1)),
            []
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

    // MARK: - The audit runs on every entry point (#175)

    /// A well-formed article with no `<contrib>` at all. The zero-author warning
    /// is the one end-of-parse check a document *can* trip, so it is what proves
    /// the audit is wired into the production path rather than into
    /// `parseToArticle` alone — which is where it sat, unreachable from
    /// `FullTextService`, for three releases.
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

    /// A parse that produced nothing at all already throws `.noContent`, and
    /// "it also had no authors" is noise on top of that. The audit runs before
    /// the throw, so this needs saying out loud.
    func testAnEmptyParseDoesNotAlsoComplainAboutAuthors() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article><front><article-meta></article-meta></front><body></body></article>
        """
        XCTAssertThrowsError(try JATSXMLParser(data: Data(xml.utf8)).parseToArticle())

        XCTAssertFalse(
            logger.recorded.contains { $0.contains("zero authors") },
            "recorded: \(logger.recorded)"
        )
    }
}
