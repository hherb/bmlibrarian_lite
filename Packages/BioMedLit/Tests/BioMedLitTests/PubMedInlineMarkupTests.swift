import XCTest
@testable import BioMedLit

/// Inline markup inside a title or abstract is part of its text.
///
/// efetch carries `<i>`, `<b>`, `<sup>` and `<sub>` as child elements of
/// `<ArticleTitle>` and `<AbstractText>`. The parser once cleared its buffer at
/// every element boundary, so a title kept only the text after its last inline
/// child: PMID 42357316 was listed as "Evaluation." (Android's handler had
/// already been fixed the same way — `TEXT_ELEMENTS` in its PubMedService.kt).
final class PubMedInlineMarkupTests: XCTestCase {

    /// PMID 42357316 as efetch returns it, trimmed to the elements that matter.
    private let record = """
    <?xml version="1.0"?>
    <PubmedArticleSet>
      <PubmedArticle>
        <MedlineCitation Status="MEDLINE" Owner="NLM">
          <PMID Version="1">42357316</PMID>
          <Article PubModel="Electronic">
            <Journal><Title>Pharmaceutics</Title></Journal>
            <ArticleTitle>Compressed Medicated Chewing Gum with Lysozyme Hydrochloride and Ascorbic Acid for Xerostomia Relief and Oral Health Support: Formulation Development, Optimization, <i>In Vitro</i> and <i>In Vivo</i> Evaluation.</ArticleTitle>
            <Abstract>
              <AbstractText Label="BACKGROUND">Levels of CO<sub>2</sub> rose by 10<sup>3</sup> in <i>S. mutans</i> cultures.</AbstractText>
              <AbstractText Label="RESULTS"><b>Both</b> groups improved.</AbstractText>
            </Abstract>
          </Article>
        </MedlineCitation>
      </PubmedArticle>
    </PubmedArticleSet>
    """

    private func parse(_ xml: String) -> [SearchArticle] {
        PubMedXMLParser(data: Data(xml.utf8)).parseArticleSet().articles
    }

    func testATitleKeepsTheTextAroundItsInlineMarkup() {
        XCTAssertEqual(
            parse(record).first?.title,
            "Compressed Medicated Chewing Gum with Lysozyme Hydrochloride and Ascorbic Acid for "
                + "Xerostomia Relief and Oral Health Support: Formulation Development, Optimization, "
                + "In Vitro and In Vivo Evaluation."
        )
    }

    func testAnAbstractKeepsTheTextAroundItsInlineMarkup() {
        XCTAssertEqual(
            parse(record).first?.abstract,
            "Levels of CO2 rose by 103 in S. mutans cultures. Both groups improved."
        )
    }

    /// Control: markup-free text still reads as before.
    func testPlainFieldsAreUnchanged() {
        let article = parse(record).first
        XCTAssertEqual(article?.pmid, "42357316")
        XCTAssertEqual(article?.journal, "Pharmaceutics")
    }
}
