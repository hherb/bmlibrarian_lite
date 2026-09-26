/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

package com.bmlibrarian.factchecker.util.jats

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A `<mixed-citation>` keeps the text of every part it tags (#398).
 *
 * Mirrors the Swift `JATSReferenceTextTests`: descendants merge into the
 * deposit (bmlib's #146), and the deposit is printed wherever fewer than two
 * components would print (bmlib's #268). Unlike bmlib, an `<element-citation>`
 * keeps its leftover text in `citation`; `citationIsDeposit` keeps that from
 * standing in for a tagged part.
 */
class JATSReferenceTextTest {

    private fun document(refs: String): ByteArray = """
        <?xml version="1.0"?>
        <article><front><article-meta>
          <title-group><article-title>Host article</article-title></title-group>
        </article-meta></front>
        <body><sec><title>Intro</title><p>Text.</p></sec></body>
        <back><ref-list>$refs</ref-list></back></article>
    """.trimIndent().toByteArray()

    private fun references(refs: String): List<JATSReferenceInfo> =
        JATSXMLParser(document(refs)).parseToArticle().references

    private fun html(refs: String): String = JATSXMLParser(document(refs)).parseToHTML()

    /** A real PMC shape: the volume is the only tagged part. */
    private val volumeOnly = "<ref id=\"r1\"><mixed-citation publication-type=\"journal\">" +
        "Sullivan, W. J. Jr. &amp; Jeffers, V. Mechanisms of Toxoplasma gondii persistence " +
        "and latency. FEMS Microbiol. Rev.<volume>36</volume>, 717–733 (2012).</mixed-citation></ref>"

    /** A standard NLM deposit: every part tagged, punctuation between them. */
    private val fullyTagged = "<ref id=\"r2\"><mixed-citation publication-type=\"journal\">" +
        "<person-group person-group-type=\"author\">" +
        "<name><surname>Schuster</surname> <given-names>KH</given-names></name>, " +
        "<name><surname>Zalon</surname> <given-names>AJ</given-names></name></person-group>. " +
        "<article-title>Impaired oligodendrocyte maturation in SCA3</article-title>. " +
        "<source>J Neurosci</source>. <year>2022</year>;<volume>42</volume>:" +
        "<fpage>1604</fpage>–<lpage>17</lpage>.</mixed-citation></ref>"

    @Test
    fun theDepositKeepsTheTextOfItsTaggedParts() {
        assertEquals(
            "Schuster KH, Zalon AJ. Impaired oligodendrocyte maturation in SCA3. " +
                "J Neurosci. 2022;42:1604–17.",
            references(fullyTagged).first().citation
        )
    }

    @Test
    fun aLoneTaggedPartDefersToTheDeposit() {
        val expected = "Sullivan, W. J. Jr. & Jeffers, V. Mechanisms of Toxoplasma gondii " +
            "persistence and latency. FEMS Microbiol. Rev.36, 717–733 (2012)."
        assertEquals(expected, references(volumeOnly).first().formattedCitation)
        assertTrue(html(volumeOnly).contains("Sullivan, W. J. Jr. &amp; Jeffers, V. Mechanisms"))
    }

    /**
     * A lone DOI defers too, so the deposit prints (and the DOI loses its link,
     * as in bmlib, which tracks linkifying a deposit as its #278).
     */
    @Test
    fun aLoneDoiDefersToTheDeposit() {
        val refs = "<ref id=\"r5\"><mixed-citation>Smith J. A study. Nature 2020. " +
            "<pub-id pub-id-type=\"doi\">10.1/abc</pub-id></mixed-citation></ref>"
        assertEquals("Smith J. A study. Nature 2020. 10.1/abc", references(refs).first().formattedCitation)
        assertTrue(html(refs).contains("Smith J. A study. Nature 2020. 10.1/abc"))
    }

    /**
     * Control: a *pair* of parts renders structured, not the deposit.
     *
     * Pins the threshold at two. That a pair naming no work (authors and year)
     * still drops the deposit is bmlib's open #276, not settled here.
     */
    @Test
    fun aPairOfTaggedPartsStillRendersStructured() {
        val refs = "<ref id=\"r6\"><mixed-citation><person-group person-group-type=\"author\">" +
            "<name><surname>Kalahasty</surname><given-names>R</given-names></name>, " +
            "<name><surname>Motati</surname><given-names>L</given-names></name></person-group>. " +
            "Strokesight: a novel system. arXiv <year>2022</year></mixed-citation></ref>"
        assertEquals("R Kalahasty, L Motati. (2022)", references(refs).first().formattedCitation)
        val html = html(refs)
        assertTrue(html.contains("(2022)"))
        assertFalse(html.contains("Strokesight"))
    }

    /**
     * A formula in a cited title keeps its expression, not its LaTeX source.
     *
     * `<tex-math>` holds a whole LaTeX document; it is dropped everywhere, and
     * the merge into the deposit must not bring it back (bmlib's #147).
     */
    @Test
    fun aFormulaInADepositDropsItsLatex() {
        val refs = "<ref id=\"r7\"><mixed-citation>Smith J. Role of <inline-formula><alternatives>" +
            "<tex-math>\\documentclass{minimal}\\begin{document}\$\\beta\$\\end{document}</tex-math>" +
            "<mml:math xmlns:mml=\"http://www.w3.org/1998/Math/MathML\"><mml:mi>β</mml:mi></mml:math>" +
            "</alternatives></inline-formula>-cells. <source>Diabetes</source></mixed-citation></ref>"
        val citation = references(refs).first().citation
        assertEquals("Smith J. Role of β-cells. Diabetes", citation)
        assertFalse(citation.contains("documentclass"))
    }

    /** Control: a reference tagging several parts still renders structured. */
    @Test
    fun severalTaggedPartsStillRenderStructured() {
        assertEquals(
            "KH Schuster, AJ Zalon. Impaired oligodendrocyte maturation in SCA3. " +
                "*J Neurosci*. (2022). 42:1604-17",
            references(fullyTagged).first().formattedCitation
        )
        assertTrue(html(fullyTagged).contains("<em>J Neurosci</em>"))
    }

    /** Control: an `<element-citation>` has no deposit, so its lone part still prints. */
    @Test
    fun anElementCitationPrintsItsLonePart() {
        val refs = "<ref id=\"r3\"><element-citation publication-type=\"journal\">" +
            "<source>Lancet</source><comment>Available online</comment></element-citation></ref>"
        val reference = references(refs).first()
        assertEquals("Available online", reference.citation)
        assertFalse(reference.citationIsDeposit)
        assertEquals("*Lancet*", reference.formattedCitation)
        val html = html(refs)
        assertTrue(html.contains("<em>Lancet</em>"))
        assertFalse(html.contains("Available online"))
    }

    /** Where `<citation-alternatives>` carries both, the deposit wins (element citation after it). */
    @Test
    fun theDepositSurvivesAnElementCitationAfterIt() {
        val reference = references(
            "<ref id=\"r4\"><citation-alternatives>" +
                "<mixed-citation>WHO. Global report. Geneva; <year>2020</year>.</mixed-citation>" +
                "<element-citation><year>2020</year><comment>stray</comment></element-citation>" +
                "</citation-alternatives></ref>"
        ).first()
        assertEquals("WHO. Global report. Geneva; 2020.", reference.citation)
        assertEquals("WHO. Global report. Geneva; 2020.", reference.formattedCitation)
    }

    /** The same, with the `<element-citation>` deposited first. */
    @Test
    fun theDepositReplacesAnElementCitationBeforeIt() {
        val reference = references(
            "<ref id=\"r4\"><citation-alternatives>" +
                "<element-citation><year>2020</year><comment>stray</comment></element-citation>" +
                "<mixed-citation>WHO. Global report. Geneva; <year>2020</year>.</mixed-citation>" +
                "</citation-alternatives></ref>"
        ).first()
        assertEquals("WHO. Global report. Geneva; 2020.", reference.citation)
        assertTrue(reference.citationIsDeposit)
        assertEquals("WHO. Global report. Geneva; 2020.", reference.formattedCitation)
    }

    /**
     * Control: the merge ends with its `<mixed-citation>`.
     *
     * A following `<element-citation>` reference keeps only its own leftover
     * text, and a figure after the reference list keeps its caption.
     */
    @Test
    fun theMergeEndsWithItsCitation() {
        val xml = """
            <?xml version="1.0"?>
            <article><front><article-meta>
              <title-group><article-title>Host article</article-title></title-group>
            </article-meta></front>
            <body><sec><title>Intro</title><p>Text.</p></sec></body>
            <back><ref-list>$volumeOnly<ref id="r8"><element-citation><source>Lancet</source><comment>c</comment></element-citation></ref></ref-list></back>
            <floats-group><fig id="f1"><label>Figure 1</label><caption><title>Cells</title><p>Stained <italic>in vitro</italic>.</p></caption></fig></floats-group></article>
        """.trimIndent().toByteArray()
        val article = JATSXMLParser(xml).parseToArticle()
        assertEquals("c", article.references.last().citation)
        assertEquals("*Lancet*", article.references.last().formattedCitation)
        assertTrue(article.figures.first().caption.contains("Stained in vitro."))
    }

    /** Outside a citation the same elements are metadata, not prose. */
    @Test
    fun theArticlesOwnTitleIsUnchanged() {
        val xml = """
            <?xml version="1.0"?>
            <article><front><article-meta>
              <title-group><article-title>Host <italic>in vitro</italic> article</article-title></title-group>
              <pub-date><year>2024</year></pub-date>
            </article-meta></front>
            <body><sec><title>Intro</title><p>Text.</p></sec></body></article>
        """.trimIndent().toByteArray()
        val article = JATSXMLParser(xml).parseToArticle()
        assertEquals("Host in vitro article", article.title)
        assertEquals("2024", article.year)
    }
}
