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

import org.junit.Assume
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL

/**
 * Integration tests for JATS XML download and parsing.
 *
 * These tests hit the real Europe PMC API. Enable by setting:
 *     -DINTEGRATION_TESTS=1
 *
 * Run with:
 *     ./gradlew test -DINTEGRATION_TESTS=1 --tests "*.JATSXMLParserIntegrationTest"
 */
class JATSXMLParserIntegrationTest {

    companion object {
        private const val BASE_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest"
        private const val TIMEOUT_MS = 30_000

        data class TestArticle(
            val label: String,
            val doi: String,
            val pmcId: String,
            val pmid: String
        )

        val TEST_ARTICLES = listOf(
            TestArticle(
                label = "article_1_sage",
                doi = "10.1177/20552076251406653",
                pmcId = "PMC12759138",
                pmid = "41488273"
            ),
            TestArticle(
                label = "article_2_jmir",
                doi = "10.2196/82550",
                pmcId = "PMC12661592",
                pmid = "41313195"
            ),
            TestArticle(
                label = "article_3_mdpi",
                doi = "10.3390/healthcare14010097",
                pmcId = "PMC12785261",
                pmid = "41517028"
            ),
        )
    }

    @Before
    fun checkIntegrationEnabled() {
        val enabled = System.getProperty("INTEGRATION_TESTS") == "1"
            || System.getenv("INTEGRATION_TESTS") == "1"
        Assume.assumeTrue(
            "Integration tests disabled. Set INTEGRATION_TESTS=1 to run.",
            enabled
        )
    }

    private fun downloadXml(pmcId: String): ByteArray {
        val normalizedId = if (pmcId.startsWith("PMC")) pmcId else "PMC$pmcId"
        val url = URL("$BASE_URL/$normalizedId/fullTextXML")
        val connection = url.openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.setRequestProperty("Accept", "application/xml")
        connection.connectTimeout = TIMEOUT_MS
        connection.readTimeout = TIMEOUT_MS

        assertEquals(
            "HTTP request for $pmcId should succeed",
            200,
            connection.responseCode
        )

        return connection.inputStream.readBytes()
    }

    // ==================== Download Tests ====================

    @Test
    fun `download XML succeeds for article 1`() {
        val xmlBytes = downloadXml(TEST_ARTICLES[0].pmcId)
        val xmlString = String(xmlBytes, Charsets.UTF_8)
        assertTrue("XML should be substantial", xmlBytes.size > 1000)
        assertTrue("Should contain article element", xmlString.contains("<article"))
        assertTrue("Should contain closing article", xmlString.contains("</article>"))
    }

    @Test
    fun `download XML succeeds for article 2 with versioned PMC ID`() {
        val xmlBytes = downloadXml(TEST_ARTICLES[1].pmcId)
        assertTrue("XML should be substantial", xmlBytes.size > 1000)
    }

    @Test
    fun `download XML succeeds for article 3`() {
        val xmlBytes = downloadXml(TEST_ARTICLES[2].pmcId)
        assertTrue("XML should be substantial", xmlBytes.size > 1000)
    }

    // ==================== Parse to Markdown Tests ====================

    @Test
    fun `parse to markdown succeeds for article 1`() {
        val article = TEST_ARTICLES[0]
        val xmlBytes = downloadXml(article.pmcId)
        val parser = JATSXMLParser(xmlBytes, knownPmcId = article.pmcId)
        val markdown = parser.parseToMarkdown()

        assertTrue("Markdown should be substantial", markdown.length > 500)
        assertTrue("Should start with title", markdown.startsWith("# "))
        assertTrue("Should contain Abstract section", markdown.contains("## Abstract"))
        assertTrue("Should contain DOI", markdown.contains(article.doi))
    }

    @Test
    fun `parse to markdown succeeds for article 2`() {
        val article = TEST_ARTICLES[1]
        val xmlBytes = downloadXml(article.pmcId)
        val parser = JATSXMLParser(xmlBytes, knownPmcId = article.pmcId)
        val markdown = parser.parseToMarkdown()

        assertTrue("Markdown should be substantial", markdown.length > 500)
        assertTrue("Should start with title", markdown.startsWith("# "))
        assertTrue("Should contain Abstract section", markdown.contains("## Abstract"))
    }

    @Test
    fun `parse to markdown succeeds for article 3`() {
        val article = TEST_ARTICLES[2]
        val xmlBytes = downloadXml(article.pmcId)
        val parser = JATSXMLParser(xmlBytes, knownPmcId = article.pmcId)
        val markdown = parser.parseToMarkdown()

        assertTrue("Markdown should be substantial", markdown.length > 500)
        assertTrue("Should start with title", markdown.startsWith("# "))
        assertTrue("Should contain Abstract section", markdown.contains("## Abstract"))
    }

    // ==================== Parse to HTML Tests ====================

    @Test
    fun `parse to HTML succeeds for article 1`() {
        val article = TEST_ARTICLES[0]
        val xmlBytes = downloadXml(article.pmcId)
        val parser = JATSXMLParser(xmlBytes, knownPmcId = article.pmcId)
        val html = parser.parseToHTML()

        assertTrue("HTML should be substantial", html.length > 500)
        assertTrue("Should contain h1 tag", html.contains("<h1>"))
        assertTrue("Should contain Abstract heading", html.contains("<h2>Abstract</h2>"))
    }

    // ==================== Parse to Article (Structured) Tests ====================

    @Test
    fun `parse to article succeeds for article 1`() {
        val article = TEST_ARTICLES[0]
        val xmlBytes = downloadXml(article.pmcId)
        val parser = JATSXMLParser(xmlBytes, knownPmcId = article.pmcId)
        val jatsArticle = parser.parseToArticle()

        assertTrue("Title should not be empty", jatsArticle.title.isNotEmpty())
        assertTrue("Authors should not be empty", jatsArticle.authors.isNotEmpty())
        assertTrue("Abstract should not be empty", jatsArticle.abstractSections.isNotEmpty())
        assertTrue("Body sections should not be empty", jatsArticle.bodySections.isNotEmpty())
        assertEquals("DOI should match", article.doi, jatsArticle.doi)
    }

    @Test
    fun `parse to article succeeds for article 2`() {
        val article = TEST_ARTICLES[1]
        val xmlBytes = downloadXml(article.pmcId)
        val parser = JATSXMLParser(xmlBytes, knownPmcId = article.pmcId)
        val jatsArticle = parser.parseToArticle()

        assertTrue("Title should not be empty", jatsArticle.title.isNotEmpty())
        assertTrue("Abstract should not be empty", jatsArticle.abstractSections.isNotEmpty())
        assertTrue("Body sections should not be empty", jatsArticle.bodySections.isNotEmpty())
    }

    @Test
    fun `parse to article succeeds for article 3`() {
        val article = TEST_ARTICLES[2]
        val xmlBytes = downloadXml(article.pmcId)
        val parser = JATSXMLParser(xmlBytes, knownPmcId = article.pmcId)
        val jatsArticle = parser.parseToArticle()

        assertTrue("Title should not be empty", jatsArticle.title.isNotEmpty())
        assertTrue("Abstract should not be empty", jatsArticle.abstractSections.isNotEmpty())
        assertTrue("Body sections should not be empty", jatsArticle.bodySections.isNotEmpty())
        assertTrue("References should not be empty", jatsArticle.references.isNotEmpty())
    }

    // ==================== Body Section Structure Tests ====================

    @Test
    fun `body sections have content for article 1`() {
        val article = TEST_ARTICLES[0]
        val xmlBytes = downloadXml(article.pmcId)
        val parser = JATSXMLParser(xmlBytes, knownPmcId = article.pmcId)
        val jatsArticle = parser.parseToArticle()

        val sectionsWithContent = jatsArticle.bodySections.filter { it.paragraphs.isNotEmpty() }
        assertTrue(
            "At least one body section should have paragraphs",
            sectionsWithContent.isNotEmpty()
        )

        val sectionsWithTitles = jatsArticle.bodySections.filter { it.title.isNotEmpty() }
        assertTrue(
            "At least one body section should have a title",
            sectionsWithTitles.isNotEmpty()
        )
    }

    // ==================== References Tests ====================

    @Test
    fun `references have structured data for article 3`() {
        val article = TEST_ARTICLES[2]
        val xmlBytes = downloadXml(article.pmcId)
        val parser = JATSXMLParser(xmlBytes, knownPmcId = article.pmcId)
        val jatsArticle = parser.parseToArticle()

        assertTrue("Should have references", jatsArticle.references.isNotEmpty())

        val refsWithAuthors = jatsArticle.references.filter { it.authors.isNotEmpty() }
        assertTrue(
            "At least some references should have parsed authors",
            refsWithAuthors.isNotEmpty()
        )
    }

    // ==================== Identifier Resolution Helpers ====================

    /**
     * Search Europe PMC by a query and extract the PMC ID from the first result.
     */
    private fun resolvePmcId(query: String): String {
        val searchUrl = URL("$BASE_URL/search?query=${java.net.URLEncoder.encode(query, "UTF-8")}&format=json&resultType=lite&pageSize=1")
        val connection = searchUrl.openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.setRequestProperty("Accept", "application/json")
        connection.connectTimeout = TIMEOUT_MS
        connection.readTimeout = TIMEOUT_MS

        assertEquals("Search for '$query' should succeed", 200, connection.responseCode)

        val responseBody = connection.inputStream.bufferedReader().readText()
        // Simple JSON extraction - find pmcid field
        val pmcIdRegex = """"pmcid"\s*:\s*"(PMC\d+)"""".toRegex()
        val match = pmcIdRegex.find(responseBody)
        assertNotNull("Should find PMC ID in search results for '$query'", match)
        return match!!.groupValues[1]
    }

    private fun downloadXmlByPmid(pmid: String): ByteArray {
        val pmcId = resolvePmcId("ext_id:$pmid src:med")
        return downloadXml(pmcId)
    }

    private fun downloadXmlByDoi(doi: String): ByteArray {
        val pmcId = resolvePmcId("DOI:\"$doi\"")
        return downloadXml(pmcId)
    }

    // ==================== Find Full Text by PMID ====================

    @Test
    fun `find full text by PMID for article 1`() {
        val article = TEST_ARTICLES[0]
        val xmlBytes = downloadXmlByPmid(article.pmid)
        val parser = JATSXMLParser(xmlBytes)
        val markdown = parser.parseToMarkdown()

        assertTrue("Should get substantial markdown via PMID", markdown.length > 500)
        assertTrue("Should start with title", markdown.startsWith("# "))
    }

    @Test
    fun `find full text by PMID for article 2`() {
        val article = TEST_ARTICLES[1]
        val xmlBytes = downloadXmlByPmid(article.pmid)
        val parser = JATSXMLParser(xmlBytes)
        val markdown = parser.parseToMarkdown()

        assertTrue("Should get substantial markdown via PMID", markdown.length > 500)
    }

    @Test
    fun `find full text by PMID for article 3`() {
        val article = TEST_ARTICLES[2]
        val xmlBytes = downloadXmlByPmid(article.pmid)
        val parser = JATSXMLParser(xmlBytes)
        val markdown = parser.parseToMarkdown()

        assertTrue("Should get substantial markdown via PMID", markdown.length > 500)
    }

    // ==================== Find Full Text by DOI ====================

    @Test
    fun `find full text by DOI for article 1`() {
        val article = TEST_ARTICLES[0]
        val xmlBytes = downloadXmlByDoi(article.doi)
        val parser = JATSXMLParser(xmlBytes)
        val markdown = parser.parseToMarkdown()

        assertTrue("Should get substantial markdown via DOI", markdown.length > 500)
        assertTrue("Should start with title", markdown.startsWith("# "))
    }

    @Test
    fun `find full text by DOI for article 2`() {
        val article = TEST_ARTICLES[1]
        val xmlBytes = downloadXmlByDoi(article.doi)
        val parser = JATSXMLParser(xmlBytes)
        val markdown = parser.parseToMarkdown()

        assertTrue("Should get substantial markdown via DOI", markdown.length > 500)
    }

    @Test
    fun `find full text by DOI for article 3`() {
        val article = TEST_ARTICLES[2]
        val xmlBytes = downloadXmlByDoi(article.doi)
        val parser = JATSXMLParser(xmlBytes)
        val markdown = parser.parseToMarkdown()

        assertTrue("Should get substantial markdown via DOI", markdown.length > 500)
    }
}
