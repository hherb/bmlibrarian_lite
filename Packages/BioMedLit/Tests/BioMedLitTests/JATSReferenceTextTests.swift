import XCTest
@testable import BioMedLit

/// A `<mixed-citation>` keeps the text of every part it tags (#398).
///
/// `<mixed-citation>` is the reference as deposited, so every descendant's text
/// is also the citation's. The rules are bmlib's: descendants merge (its #146),
/// and the deposit is printed wherever fewer than two components would print
/// (#268). Unlike bmlib, an `<element-citation>` keeps its leftover text in
/// `citation`; `citationIsDeposit` keeps that from standing in for a tagged part.
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
        XCTAssertTrue(result.html.contains("Sullivan, W. J. Jr. &amp; Jeffers, V. Mechanisms"))
    }

    /// A lone DOI defers too, so the deposit prints (and the DOI loses its link,
    /// as in bmlib, which tracks linkifying a deposit as its #278).
    func testALoneDOIDefersToTheDeposit() throws {
        let refs = """
        <ref id="r5"><mixed-citation>Smith J. A study. Nature 2020. \
        <pub-id pub-id-type="doi">10.1/abc</pub-id></mixed-citation></ref>
        """
        let result = try parse(refs)
        XCTAssertEqual(
            result.references.first?.formattedCitation, "Smith J. A study. Nature 2020. 10.1/abc"
        )
        XCTAssertTrue(result.html.contains("Smith J. A study. Nature 2020. 10.1/abc"))
    }

    /// Control: a *pair* of parts renders structured, not the deposit.
    ///
    /// Pins the threshold at two. That a pair naming no work (authors and year)
    /// still drops the deposit is bmlib's open #276, not settled here.
    func testAPairOfTaggedPartsStillRendersStructured() throws {
        let refs = """
        <ref id="r6"><mixed-citation><person-group person-group-type="author">\
        <name><surname>Kalahasty</surname><given-names>R</given-names></name>, \
        <name><surname>Motati</surname><given-names>L</given-names></name></person-group>. \
        Strokesight: a novel system. arXiv <year>2022</year></mixed-citation></ref>
        """
        let result = try parse(refs)
        XCTAssertEqual(result.references.first?.formattedCitation, "R Kalahasty, L Motati. (2022)")
        XCTAssertTrue(result.html.contains("(2022)"))
        XCTAssertFalse(result.html.contains("Strokesight"))
    }

    /// A formula in a cited title keeps its expression, not its LaTeX source.
    ///
    /// `<tex-math>` holds a whole LaTeX document; it is dropped everywhere, and
    /// the merge into the deposit must not bring it back (bmlib's #147).
    func testAFormulaInADepositDropsItsLaTeX() throws {
        let refs = """
        <ref id="r7"><mixed-citation>Smith J. Role of <inline-formula><alternatives>\
        <tex-math>\\documentclass{minimal}\\begin{document}$\\beta$\\end{document}</tex-math>\
        <mml:math xmlns:mml="http://www.w3.org/1998/Math/MathML"><mml:mi>β</mml:mi></mml:math>\
        </alternatives></inline-formula>-cells. <source>Diabetes</source></mixed-citation></ref>
        """
        let citation = try XCTUnwrap(parse(refs).references.first?.citation)
        XCTAssertEqual(citation, "Smith J. Role of β-cells. Diabetes")
        XCTAssertFalse(citation.contains("documentclass"))
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
        let html = try parse(refs).html
        XCTAssertTrue(html.contains("<em>Lancet</em>"))
        XCTAssertFalse(html.contains("Available online"))
    }

    /// Where `<citation-alternatives>` carries both, the deposit wins (element citation after it).
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

    /// The same, with the `<element-citation>` deposited first.
    func testTheDepositReplacesAnElementCitationBeforeIt() throws {
        let refs = """
        <ref id="r4"><citation-alternatives>\
        <element-citation><year>2020</year><comment>stray</comment></element-citation>\
        <mixed-citation>WHO. Global report. Geneva; <year>2020</year>.</mixed-citation>\
        </citation-alternatives></ref>
        """
        let reference = try parse(refs).references.first
        XCTAssertEqual(reference?.citation, "WHO. Global report. Geneva; 2020.")
        XCTAssertEqual(reference?.citationIsDeposit, true)
        XCTAssertEqual(reference?.formattedCitation, "WHO. Global report. Geneva; 2020.")
    }

    /// Control: the merge ends with its `<mixed-citation>`.
    ///
    /// A following `<element-citation>` reference keeps only its own leftover
    /// text, and a figure after the reference list keeps its caption.
    func testTheMergeEndsWithItsCitation() throws {
        let xml = """
        <?xml version="1.0"?>
        <article><front><article-meta>
          <title-group><article-title>Host article</article-title></title-group>
        </article-meta></front>
        <body><sec><title>Intro</title><p>Text.</p></sec></body>
        <back><ref-list>\(volumeOnly)\
        <ref id="r8"><element-citation><source>Lancet</source><comment>c</comment>\
        </element-citation></ref></ref-list></back>
        <floats-group><fig id="f1"><label>Figure 1</label>\
        <caption><title>Cells</title><p>Stained <italic>in vitro</italic>.</p></caption></fig>\
        </floats-group></article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()
        XCTAssertEqual(article.references.last?.citation, "c")
        XCTAssertEqual(article.references.last?.formattedCitation, "*Lancet*")
        XCTAssertTrue(article.figures.first?.caption.contains("Stained in vitro.") ?? false)
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
