import XCTest
@testable import BioMedLit

/// A `<mixed-citation>` keeps the text of every part it tags (#398).
///
/// `<mixed-citation>` is the reference as the publisher typeset it, with their
/// punctuation between the tagged parts, so every descendant's text is also the
/// citation's. The children popped their buffers without merging, which left
/// the deposited string as punctuation, and the renderers printed whatever was
/// tagged in place of it. The rule is bmlib's: descendants merge (its #146), and
/// the deposit is printed wherever fewer than two components would print (#268).
final class JATSReferenceTextTests: XCTestCase {

    private func parse(_ refs: String) throws -> JATSParseResult {
        let xml = """
        <?xml version="1.0"?>
        <article><front><article-meta>
          <title-group><article-title>Host article</article-title></title-group>
        </article-meta></front>
        <body><sec><title>Intro</title><p>Text.</p></sec></body>
        <back><ref-list>\(refs)</ref-list></back></article>
        """
        let parser = JATSXMLParser(data: Data(xml.utf8))
        let article = try parser.parseToArticle()
        let html = try JATSXMLParser(data: Data(xml.utf8)).parseToHTML()
        return JATSParseResult(references: article.references, html: html)
    }

    struct JATSParseResult {
        let references: [JATSReferenceInfo]
        let html: String
    }

    /// A real PMC shape: the volume is the only tagged part.
    private let volumeOnly = """
    <ref id="r1"><mixed-citation publication-type="journal">Sullivan, W. J. Jr. &amp; Jeffers, V. \
    Mechanisms of Toxoplasma gondii persistence and latency. FEMS Microbiol. Rev.\
    <volume>36</volume>, 717–733 (2012).</mixed-citation></ref>
    """

    /// A standard NLM deposit: every part tagged, punctuation between them.
    private let fullyTagged = """
    <ref id="r2"><mixed-citation publication-type="journal"><person-group person-group-type="author">\
    <name><surname>Schuster</surname> <given-names>KH</given-names></name>, \
    <name><surname>Zalon</surname> <given-names>AJ</given-names></name></person-group>. \
    <article-title>Impaired oligodendrocyte maturation in SCA3</article-title>. \
    <source>J Neurosci</source>. <year>2022</year>;<volume>42</volume>:\
    <fpage>1604</fpage>–<lpage>17</lpage>.</mixed-citation></ref>
    """

    func testTheDepositKeepsTheTextOfItsTaggedParts() throws {
        let citation = try parse(fullyTagged).references.first?.citation
        XCTAssertEqual(
            citation,
            "Schuster KH, Zalon AJ. Impaired oligodendrocyte maturation in SCA3. "
                + "J Neurosci. 2022;42:1604–17."
        )
    }

    func testALoneTaggedPartDefersToTheDeposit() throws {
        let result = try parse(volumeOnly)
        let expected = "Sullivan, W. J. Jr. & Jeffers, V. Mechanisms of Toxoplasma gondii "
            + "persistence and latency. FEMS Microbiol. Rev.36, 717–733 (2012)."
        XCTAssertEqual(result.references.first?.formattedCitation, expected)
        XCTAssertTrue(result.html.contains("Mechanisms of Toxoplasma gondii persistence"))
    }

    /// Control: a reference tagging several parts still renders structured.
    func testSeveralTaggedPartsStillRenderStructured() throws {
        let result = try parse(fullyTagged)
        XCTAssertEqual(
            result.references.first?.formattedCitation,
            "KH Schuster, AJ Zalon. Impaired oligodendrocyte maturation in SCA3. "
                + "*J Neurosci*. (2022). 42:1604-17"
        )
        XCTAssertTrue(result.html.contains("<em>J Neurosci</em>"))
    }

    /// Control: `<element-citation>` has no deposit, so its lone part still prints.
    ///
    /// Its ``citation`` keeps the text of the children not modelled (here a
    /// `<comment>`), as it did before — which is why that text must never stand
    /// in for the tagged part.
    func testAnElementCitationPrintsItsLonePart() throws {
        let refs = """
        <ref id="r3"><element-citation publication-type="journal">\
        <source>Lancet</source><comment>Available online</comment></element-citation></ref>
        """
        let reference = try parse(refs).references.first
        XCTAssertEqual(reference?.citation, "Available online")
        XCTAssertEqual(reference?.citationIsDeposit, false)
        XCTAssertEqual(reference?.formattedCitation, "*Lancet*")
    }

    /// Where `<citation-alternatives>` carries both, the deposit wins in either order.
    func testTheDepositSurvivesAnElementCitationAfterIt() throws {
        let refs = """
        <ref id="r4"><citation-alternatives>\
        <mixed-citation>WHO. Global report. Geneva; <year>2020</year>.</mixed-citation>\
        <element-citation><year>2020</year><comment>stray</comment></element-citation>\
        </citation-alternatives></ref>
        """
        let reference = try parse(refs).references.first
        XCTAssertEqual(reference?.citation, "WHO. Global report. Geneva; 2020.")
        XCTAssertEqual(reference?.formattedCitation, "WHO. Global report. Geneva; 2020.")
    }

    /// Outside a citation the same elements are metadata, not prose.
    func testTheArticlesOwnTitleIsUnchanged() throws {
        let xml = """
        <?xml version="1.0"?>
        <article><front><article-meta>
          <title-group><article-title>Host <italic>in vitro</italic> article</article-title></title-group>
          <pub-date><year>2024</year></pub-date>
        </article-meta></front>
        <body><sec><title>Intro</title><p>Text.</p></sec></body></article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()
        XCTAssertEqual(article.title, "Host in vitro article")
        XCTAssertEqual(article.year, "2024")
    }
}
