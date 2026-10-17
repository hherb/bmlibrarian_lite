/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
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
import org.junit.Test

/**
 * An author role declared on the contributor group (bmlib#111).
 *
 * About 57% of open-access articles declare `content-type="author"` on the
 * `<contrib-group>` and leave each `<contrib>` bare. A contributor's own
 * `contrib-type` decides alone; else the innermost enclosing group that declares
 * a role; else the contributor is an author. Case is folded.
 */
class JATSAuthorRoleTest {

    private fun contrib(surname: String, given: String = "A", attrs: String = ""): String =
        "<contrib $attrs><name><surname>$surname</surname><given-names>$given</given-names></name></contrib>"

    /** The surnames the parser reads as authors of an article-meta holding [groups]. */
    private fun authors(groups: String): List<String> = JATSXMLParser(
        """
        <?xml version="1.0"?>
        <article><front><article-meta>
          <title-group><article-title>Host article</article-title></title-group>
          $groups
        </article-meta></front><body><sec><title>Intro</title><p>Text.</p></sec></body></article>
        """.trimIndent().toByteArray()
    ).parseToArticle().authors.map { it.surname }

    @Test
    fun `a group role makes bare contribs authors`() {
        val groups = """<contrib-group content-type="author">${contrib("Smith")}${contrib("Jones", "B")}</contrib-group>"""
        assertEquals(listOf("Smith", "Jones"), authors(groups))
    }

    @Test
    fun `an editor group is not authors`() {
        val groups = """<contrib-group content-type="author">${contrib("Smith")}</contrib-group>
            <contrib-group content-type="editor">${contrib("Ed")}</contrib-group>"""
        assertEquals(listOf("Smith"), authors(groups))
    }

    @Test
    fun `a contribs own editor role wins inside an author group`() {
        val groups = """<contrib-group content-type="author">${contrib("Smith")}
            ${contrib("Ed", attrs = "contrib-type=\"editor\"")}</contrib-group>"""
        assertEquals(listOf("Smith"), authors(groups))
    }

    @Test
    fun `role case is folded`() {
        val groups = """<contrib-group content-type="Author">${contrib("Smith")}</contrib-group>
            <contrib-group content-type="EDITOR">${contrib("Ed")}</contrib-group>"""
        assertEquals(listOf("Smith"), authors(groups))
    }

    @Test
    fun `an empty attribute declares nothing`() {
        val groups = """<contrib-group content-type="">${contrib("Smith")}
            ${contrib("Jones", "B", "contrib-type=\"\"")}</contrib-group>"""
        assertEquals(listOf("Smith", "Jones"), authors(groups))
    }

    @Test
    fun `every group is read`() {
        val groups = """<contrib-group content-type="author">${contrib("Smith")}</contrib-group>
            <contrib-group content-type="author">${contrib("Jones", "B")}</contrib-group>"""
        assertEquals(listOf("Smith", "Jones"), authors(groups))
    }

    @Test
    fun `contrib-type author still reads`() {
        val groups = """<contrib-group>${contrib("Smith", attrs = "contrib-type=\"author\"")}
            ${contrib("Ed", attrs = "contrib-type=\"editor\"")}</contrib-group>"""
        assertEquals(listOf("Smith"), authors(groups))
    }

    @Test
    fun `a bare roster inside an editor group stays editors`() {
        val groups = """<contrib-group content-type="editor"><contrib-group>${contrib("Ed")}</contrib-group></contrib-group>
            <contrib-group content-type="author">${contrib("Smith")}</contrib-group>"""
        assertEquals(listOf("Smith"), authors(groups))
    }

    @Test
    fun `a collab roster is not listed`() {
        val groups = """<contrib-group content-type="author">${contrib("Smith")}
            <contrib><collab>Study Group<contrib-group>${contrib("Member")}</contrib-group></collab></contrib>
            </contrib-group>"""
        assertEquals(listOf("Smith"), authors(groups))
    }

    /** The authors of a whole article whose `<front>` holds [front] and which holds [after] after `<body>`. */
    private fun authorsOf(front: String, after: String = ""): List<String> = JATSXMLParser(
        """
        <?xml version="1.0"?>
        <article><front>$front</front>
        <body><sec><title>Intro</title><p>Text.</p></sec></body>$after</article>
        """.trimIndent().toByteArray()
    ).parseToArticle().authors.map { it.surname }

    private val ownMeta = """<article-meta><title-group><article-title>T</article-title></title-group>
        <contrib-group content-type="author">${contrib("Smith")}</contrib-group></article-meta>"""

    @Test
    fun `a bare contrib in journal-meta adds no author`() {
        val front = """<journal-meta><contrib-group>${contrib("Editor")}</contrib-group></journal-meta>$ownMeta"""
        assertEquals(listOf("Smith"), authorsOf(front))
    }

    @Test
    fun `a bare contrib in a sub-article front-stub adds no author`() {
        val after = """<sub-article><front-stub><contrib-group>${contrib("Reviewer")}</contrib-group></front-stub></sub-article>"""
        assertEquals(listOf("Smith"), authorsOf(ownMeta, after))
    }

    @Test
    fun `a bare contrib in a sub-article front article-meta adds no author`() {
        val after = """<sub-article><front><article-meta><contrib-group>${contrib("Reviewer")}</contrib-group>
            </article-meta></front></sub-article>"""
        assertEquals(listOf("Smith"), authorsOf(ownMeta, after))
    }

    @Test
    fun `the innermost declared content-type decides in nested groups`() {
        val groups = """<contrib-group content-type="author">
            <contrib-group content-type="editor">${contrib("Ed")}</contrib-group>
            <contrib-group>${contrib("Smith")}</contrib-group>
            </contrib-group>"""
        assertEquals(listOf("Smith"), authors(groups))
    }

    // bmlib#266: the inference starts only at a contrib-group directly in article-meta.

    @Test
    fun `a bare contrib in a supplement group is not an author`() {
        val groups = """<contrib-group content-type="author">${contrib("Smith")}</contrib-group>
            <supplement><contrib-group>${contrib("SupEd")}</contrib-group></supplement>"""
        assertEquals(listOf("Smith"), authors(groups))
    }

    @Test
    fun `a supplement group declaring author still infers nothing`() {
        val groups = """<supplement><contrib-group content-type="author">${contrib("SupAuthor")}</contrib-group></supplement>"""
        assertEquals(emptyList<String>(), authors(groups))
    }

    @Test
    fun `a bare contrib in a sec-meta group is not an author`() {
        val groups = """<sec-meta><contrib-group>${contrib("SecAuthor")}</contrib-group></sec-meta>"""
        assertEquals(emptyList<String>(), authors(groups))
    }

    @Test
    fun `an own author role in a nested group is still read`() {
        val groups = """<supplement><contrib-group>${contrib("Own", attrs = "contrib-type=\"author\"")}
            ${contrib("Bare")}</contrib-group></supplement>"""
        assertEquals(listOf("Own"), authors(groups))
    }

    @Test
    fun `the direct child group still infers`() {
        assertEquals(listOf("Smith"), authors("""<contrib-group>${contrib("Smith")}</contrib-group>"""))
    }

    @Test
    fun `a roster nested in the article's group follows the stack rule`() {
        val groups = """<contrib-group content-type="author">
            <contrib-group>${contrib("Inner")}</contrib-group>
            <contrib-group content-type="editor">${contrib("InnerEd")}</contrib-group>
            </contrib-group>"""
        assertEquals(listOf("Inner"), authors(groups))
    }
}
