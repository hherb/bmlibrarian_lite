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

package com.bmlibrarian.factchecker.data.remote.pubmed

import com.bmlibrarian.factchecker.domain.model.NcbiCredentials
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Response
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException

/**
 * Unit tests for PubMedService.
 *
 * Tests cover:
 * - Search and fetch operations
 * - XML parsing for article metadata
 * - Error handling for various failure modes
 * - Pagination and offset validation
 * - Retry logic for transient failures
 * - Document entity conversion
 */
class PubMedServiceTest {

    private lateinit var api: PubMedApi
    private lateinit var service: PubMedService

    /** What the credential source answers; a test changes it to change what is sent. */
    private var savedCredentials = NcbiCredentials.of(apiKey = null, email = null)

    @Before
    fun setup() {
        api = mockk()
        service = PubMedService(api) { savedCredentials }
    }

    // ==================== Search Success Tests ====================

    @Test
    fun `search returns articles on successful response`() = runTest {
        // Arrange
        val pmids = listOf("12345", "67890")
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "100",
                    idList = pmids
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(createSampleXml(pmids))

        // Act
        val result = service.search(query = "aspirin cardiovascular")

        // Assert
        assertTrue(result.isSuccess)
        val searchResult = result.getOrNull()!!
        assertEquals(2, searchResult.articles.size)
        assertEquals(100, searchResult.totalResults)
        assertTrue(searchResult.hasMore)
    }

    @Test
    fun `search returns empty result when no PMIDs found`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "0",
                    idList = emptyList()
                )
            )
        )

        // Act
        val result = service.search(query = "nonexistent query")

        // Assert
        assertTrue(result.isSuccess)
        val searchResult = result.getOrNull()!!
        assertEquals(0, searchResult.articles.size)
        assertEquals(0, searchResult.totalResults)
        assertFalse(searchResult.hasMore)
    }

    @Test
    fun `search respects pagination parameters`() = runTest {
        // Arrange
        val offset = 20
        val batchSize = 10
        coEvery {
            api.search(any(), any(), any(), retMax = batchSize, retStart = offset, any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "50",
                    idList = listOf("11111", "22222")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(createSampleXml(listOf("11111", "22222")))

        // Act
        val result = service.search(
            query = "test",
            offset = offset,
            batchSize = batchSize
        )

        // Assert
        assertTrue(result.isSuccess)
        coVerify {
            api.search(any(), "test", any(), batchSize, offset, any(), any(), any())
        }
    }

    // ==================== Offset Validation Tests ====================

    @Test
    fun `search accepts maximum valid offset`() = runTest {
        // Arrange: retstart can be at most 9998 (checked live 2026-09-15)
        coEvery {
            api.search(any(), any(), any(), any(), retStart = LAST_LISTABLE_OFFSET, any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "10000",
                    idList = listOf("12345")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(createSampleXml(listOf("12345")))

        // Act
        val result = service.search(
            query = "test",
            offset = LAST_LISTABLE_OFFSET
        )

        // Assert
        assertTrue(result.isSuccess)
    }

    // ==================== Error Handling Tests ====================

    @Test
    fun `search returns error on search HTTP failure`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.error(500, "Server error".toResponseBody(null))

        // Act
        val result = service.search(query = "test")

        // Assert
        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 500), failureOf(result))
    }

    @Test
    fun `search records the PMIDs of a fetch that failed`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "1",
                    idList = listOf("12345")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.error(500, "Server error".toResponseBody(null))

        // Act
        val result = service.search(query = "test")

        // Assert: the search stands; its fetched articles do not
        val searched = result.getOrThrow()
        assertTrue(searched.articles.isEmpty())
        assertEquals(
            listOf(RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 500), 1)),
            searched.shortfalls
        )
    }

    @Test
    fun `search returns error on rate limit`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.error(429, "Rate limited".toResponseBody(null))

        // Act
        val result = service.search(query = "test")

        // Assert
        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 429), failureOf(result))
    }

    // ==================== Retry Logic Tests ====================

    @Test
    fun `search retries on network failure and succeeds`() = runTest {
        // Arrange
        var searchCallCount = 0
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } answers {
            searchCallCount++
            if (searchCallCount < 3) {
                throw IOException("Network error")
            }
            Response.success(
                ESearchResponse(
                    esearchResult = ESearchResult(
                        count = "1",
                        idList = listOf("12345")
                    )
                )
            )
        }

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(createSampleXml(listOf("12345")))

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(3, searchCallCount)
    }

    @Test
    fun `search retries on server error and succeeds`() = runTest {
        // Arrange
        var callCount = 0
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } answers {
            callCount++
            if (callCount < 2) {
                Response.error(503, "Service unavailable".toResponseBody(null))
            } else {
                Response.success(
                    ESearchResponse(
                        esearchResult = ESearchResult(
                            count = "1",
                            idList = listOf("12345")
                        )
                    )
                )
            }
        }

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(createSampleXml(listOf("12345")))

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(2, callCount)
    }

    // ==================== XML Parsing Tests ====================

    @Test
    fun `search parses article with complete metadata`() = runTest {
        // Arrange
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <PubmedArticleSet>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>12345678</PMID>
                        <Article>
                            <Journal>
                                <Title>Journal of Medicine</Title>
                                <JournalIssue>
                                    <PubDate>
                                        <Year>2024</Year>
                                    </PubDate>
                                </JournalIssue>
                            </Journal>
                            <ArticleTitle>Effect of Aspirin on Heart Disease</ArticleTitle>
                            <Abstract>
                                <AbstractText Label="BACKGROUND">This is the background.</AbstractText>
                                <AbstractText Label="METHODS">These are the methods.</AbstractText>
                                <AbstractText Label="RESULTS">These are the results.</AbstractText>
                            </Abstract>
                            <AuthorList>
                                <Author>
                                    <LastName>Smith</LastName>
                                    <ForeName>John</ForeName>
                                </Author>
                                <Author>
                                    <LastName>Doe</LastName>
                                    <ForeName>Jane</ForeName>
                                </Author>
                            </AuthorList>
                            <ELocationID EIdType="doi">10.1234/test.2024</ELocationID>
                        </Article>
                        <MeshHeadingList>
                            <MeshHeading>
                                <DescriptorName>Aspirin</DescriptorName>
                            </MeshHeading>
                            <MeshHeading>
                                <DescriptorName>Cardiovascular Diseases</DescriptorName>
                            </MeshHeading>
                        </MeshHeadingList>
                    </MedlineCitation>
                    <PubmedData>
                        <ArticleIdList>
                            <ArticleId IdType="pmc">PMC9876543</ArticleId>
                        </ArticleIdList>
                    </PubmedData>
                </PubmedArticle>
            </PubmedArticleSet>
        """.trimIndent()

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "1",
                    idList = listOf("12345678")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)

        // Act
        val result = service.search(query = "aspirin")

        // Assert
        assertTrue(result.isSuccess)
        val article = result.getOrNull()!!.articles.first()
        assertEquals("12345678", article.pmid)
        assertEquals("Effect of Aspirin on Heart Disease", article.title)
        assertEquals("Journal of Medicine", article.journal)
        assertEquals(2024, article.publicationYear)
        assertEquals("10.1234/test.2024", article.doi)
        assertEquals("PMC9876543", article.pmcId)
        assertEquals(2, article.authors.size)
        assertEquals("Smith John", article.authors[0])
        assertEquals("Doe Jane", article.authors[1])
        assertEquals(2, article.meshTerms.size)
        assertTrue(article.meshTerms.contains("Aspirin"))
        assertTrue(article.abstractText?.contains("background") == true)
    }

    @Test
    fun `search handles article with minimal metadata`() = runTest {
        // Arrange
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <PubmedArticleSet>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>99999</PMID>
                        <Article>
                            <ArticleTitle>Minimal Article</ArticleTitle>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
            </PubmedArticleSet>
        """.trimIndent()

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "1",
                    idList = listOf("99999")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        val article = result.getOrNull()!!.articles.first()
        assertEquals("99999", article.pmid)
        assertEquals("Minimal Article", article.title)
        assertTrue(article.authors.isEmpty())
        assertTrue(article.meshTerms.isEmpty())
    }

    @Test
    fun `search skips articles without PMID`() = runTest {
        // Arrange
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <PubmedArticleSet>
                <PubmedArticle>
                    <MedlineCitation>
                        <Article>
                            <ArticleTitle>Article Without PMID</ArticleTitle>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>12345</PMID>
                        <Article>
                            <ArticleTitle>Article With PMID</ArticleTitle>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
            </PubmedArticleSet>
        """.trimIndent()

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "2",
                    idList = listOf("12345", "00000")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(1, result.getOrNull()!!.articles.size)
        assertEquals("12345", result.getOrNull()!!.articles.first().pmid)
    }

    @Test
    fun `search skips articles without title`() = runTest {
        // Arrange
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <PubmedArticleSet>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>11111</PMID>
                        <Article>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>22222</PMID>
                        <Article>
                            <ArticleTitle>Valid Article</ArticleTitle>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
            </PubmedArticleSet>
        """.trimIndent()

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "2",
                    idList = listOf("11111", "22222")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(1, result.getOrNull()!!.articles.size)
    }

    @Test
    fun `search handles MedlineDate format`() = runTest {
        // Arrange
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <PubmedArticleSet>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>12345</PMID>
                        <Article>
                            <Journal>
                                <JournalIssue>
                                    <PubDate>
                                        <MedlineDate>2024 Jan-Feb</MedlineDate>
                                    </PubDate>
                                </JournalIssue>
                            </Journal>
                            <ArticleTitle>Test Article</ArticleTitle>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
            </PubmedArticleSet>
        """.trimIndent()

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "1",
                    idList = listOf("12345")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        val article = result.getOrNull()!!.articles.first()
        assertEquals(2024, article.publicationYear)
        assertEquals("2024 Jan-Feb", article.publicationDate)
    }

    @Test
    fun `search parses XML with DOCTYPE without fetching external DTD`() = runTest {
        // Real PubMed EFetch responses begin with a DOCTYPE referencing the remote
        // NLM DTD. The parser must decode the document offline rather than reaching
        // out to the network.
        //
        // The systemId deliberately points at a closed port on the loopback
        // interface: a parser that resolved external DTDs would attempt (and fail)
        // that connection, so this test fails if the SAFE_SAX_FEATURES hardening or
        // the no-op resolveEntity is removed. Using the real https://dtd.nlm.nih.gov
        // systemId would NOT discriminate - an unhardened parser fetches it
        // successfully on a networked machine and the test would still pass.
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE PubmedArticleSet SYSTEM "http://127.0.0.1:1/pubmed_190101.dtd">
            <PubmedArticleSet>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>32000000</PMID>
                        <Article>
                            <ArticleTitle>Article With DOCTYPE</ArticleTitle>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
            </PubmedArticleSet>
        """.trimIndent()

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "1",
                    idList = listOf("32000000")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        val article = result.getOrNull()!!.articles.first()
        assertEquals("32000000", article.pmid)
        assertEquals("Article With DOCTYPE", article.title)
    }

    @Test
    fun `search blocks external entity references in fetched XML`() = runTest {
        // XXE guard: an external general entity pointing at a local file must not
        // be resolved into the parsed output. With entity resolution blocked the
        // reference expands to nothing, leaving the surrounding title text intact.
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE PubmedArticleSet [
            <!ENTITY xxe SYSTEM "file:///etc/passwd">
            ]>
            <PubmedArticleSet>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>34000000</PMID>
                        <Article>
                            <ArticleTitle>Safe&xxe; Title</ArticleTitle>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
            </PubmedArticleSet>
        """.trimIndent()

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "1",
                    idList = listOf("34000000")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        val article = result.getOrNull()!!.articles.first()
        assertEquals("Safe Title", article.title)
        assertFalse(
            "external entity must not be expanded into the parsed title",
            article.title.contains("root:")
        )
    }

    @Test
    fun `search returns articles decoded before malformed XML aborts the parse`() = runTest {
        // parseArticleXml is deliberately resilient: a malformed batch still yields
        // the articles decoded before the failure rather than an empty list. The
        // document below is truncated mid-way through the SECOND article, after the
        // first one has closed cleanly.
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <PubmedArticleSet>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>35000000</PMID>
                        <Article>
                            <ArticleTitle>Complete Article</ArticleTitle>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>35000001</PMID>
                        <Article>
                            <ArticleTitle>Truncated Article
        """.trimIndent()

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "2",
                    idList = listOf("35000000", "35000001")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        val articles = result.getOrNull()!!.articles
        assertEquals(1, articles.size)
        assertEquals("35000000", articles.first().pmid)
        assertEquals("Complete Article", articles.first().title)
    }

    @Test
    fun `search preserves text around inline markup in title and abstract`() = runTest {
        // PubMed titles and abstracts routinely contain inline markup (<i> for
        // species/gene names, <sup>/<sub> for exponents/subscripts). The parser
        // must keep the surrounding text - and in particular an article whose
        // title ends in markup must NOT be dropped for want of a title.
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <PubmedArticleSet>
                <PubmedArticle>
                    <MedlineCitation>
                        <PMID>33000000</PMID>
                        <Article>
                            <ArticleTitle>Complete genome sequence of <i>Escherichia coli</i></ArticleTitle>
                            <Abstract>
                                <AbstractText>Aspirin lowers CRP by <sup>50</sup>% overall.</AbstractText>
                            </Abstract>
                        </Article>
                    </MedlineCitation>
                </PubmedArticle>
            </PubmedArticleSet>
        """.trimIndent()

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "1",
                    idList = listOf("33000000")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(xml)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isSuccess)
        val articles = result.getOrNull()!!.articles
        assertEquals(1, articles.size)
        val article = articles.first()
        assertEquals("Complete genome sequence of Escherichia coli", article.title)
        assertTrue(
            "abstract should retain text on both sides of the <sup> markup",
            article.abstractText?.contains("Aspirin lowers CRP by 50% overall.") == true
        )
    }

    // ==================== Document Entity Conversion Tests ====================

    @Test
    fun `toDocumentEntities converts articles correctly`() {
        // Arrange
        val articles = listOf(
            ParsedArticle(
                pmid = "12345",
                doi = "10.1234/test",
                pmcId = "PMC123",
                title = "Test Article",
                abstractText = "This is the abstract",
                authors = listOf("Smith John", "Doe Jane"),
                journal = "Test Journal",
                publicationYear = 2024,
                meshTerms = listOf("Term1", "Term2")
            ),
            ParsedArticle(
                pmid = "67890",
                title = "Another Article",
                authors = emptyList()
            )
        )

        // Act
        val entities = service.toDocumentEntities(
            articles = articles,
            sessionId = "session-123",
            batchNumber = 2,
            startPosition = 10
        )

        // Assert
        assertEquals(2, entities.size)

        val first = entities[0]
        assertEquals("session-123", first.sessionId)
        assertEquals("12345", first.pmid)
        assertEquals("10.1234/test", first.doi)
        assertEquals("PMC123", first.pmcId)
        assertEquals("Test Article", first.title)
        assertEquals("This is the abstract", first.abstractText)
        assertEquals(listOf("Smith John", "Doe Jane"), first.authors)
        assertEquals("Test Journal", first.journal)
        assertEquals(2024, first.publicationYear)
        assertEquals(listOf("Term1", "Term2"), first.meshTerms)
        assertEquals(Constants.SOURCE_PUBMED, first.source)
        assertFalse(first.isPreprint)
        assertEquals(2, first.batchNumber)
        assertEquals(10, first.resultPosition)

        val second = entities[1]
        assertEquals("67890", second.pmid)
        assertEquals(11, second.resultPosition)
    }

    // ==================== API Key and Email Tests ====================

    @Test
    fun `search sends the saved API key and email with both requests`() = runTest {
        // Arrange
        val apiKey = "test-api-key"
        val email = "test@example.com"
        savedCredentials = NcbiCredentials.of(apiKey = apiKey, email = email)

        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), apiKey = apiKey, email = email)
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "1",
                    idList = listOf("12345")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), apiKey = apiKey, email = email)
        } returns Response.success(createSampleXml(listOf("12345")))

        // Act
        service.search(query = "test")

        // Assert
        coVerify {
            api.search(any(), any(), any(), any(), any(), any(), apiKey = apiKey, email = email)
            api.fetch(any(), any(), any(), any(), apiKey = apiKey, email = email)
        }
    }

    @Test
    fun `a key cleared in settings is not sent, not even empty`() = runTest {
        // Arrange: settings store "not set" as a blank string
        savedCredentials = NcbiCredentials.of(apiKey = "", email = " ")
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(esearchResult = ESearchResult(count = "1", idList = listOf("12345")))
        )
        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(createSampleXml(listOf("12345")))

        // Act
        service.search(query = "test")

        // Assert
        coVerify {
            api.search(any(), any(), any(), any(), any(), any(), apiKey = null, email = null)
            api.fetch(any(), any(), any(), any(), apiKey = null, email = null)
        }
    }

    @Test
    fun `a key saved after the service was built applies to the next search`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(esearchResult = ESearchResult(count = "0", idList = emptyList()))
        )
        service.search(query = "before")

        // Act
        savedCredentials = NcbiCredentials.of(apiKey = "saved-later", email = null)
        service.search(query = "after")

        // Assert
        coVerify {
            api.search(any(), term = "before", any(), any(), any(), any(), apiKey = null, email = null)
            api.search(any(), term = "after", any(), any(), any(), any(), apiKey = "saved-later", email = null)
        }
    }

    @Test
    fun `unreadable saved credentials fail the search instead of throwing`() = runTest {
        // Arrange: encrypted preferences throw on a broken keystore
        val failing = PubMedService(api) { throw java.security.GeneralSecurityException("keystore unavailable") }

        // Act
        val result = failing.search(query = "test")

        // Assert
        assertEquals(RequestFailure(RequestFailureKind.REQUEST_FAILED), failureOf(result))
        coVerify(exactly = 0) {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        }
    }

    @Test
    fun `a 400 while a key is saved fails the search without its body, and is not retried`() = runTest {
        // Arrange: NCBI's 400 for a bad key repeats the key in its body. The
        // advice for a PubMed 400 tells the user to check the saved key.
        val apiKey = "rejected-key-0123456789"
        savedCredentials = NcbiCredentials.of(apiKey = apiKey, email = null)
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.error(400, """{"error":"API key invalid","api-key":"$apiKey"}""".toResponseBody(null))

        // Act
        val result = service.search(query = "test")

        // Assert
        assertEquals(RequestFailure(RequestFailureKind.HTTP_STATUS, 400), failureOf(result))
        assertFalse("the error carried the key", result.exceptionOrNull()?.message.orEmpty().contains(apiKey))
        coVerify(exactly = 1) {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        }
    }

    @Test
    fun `a cancelled search stays cancelled`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } throws CancellationException("the claim was abandoned")

        // Act
        val thrown = try {
            service.search(query = "test")
            null
        } catch (e: CancellationException) {
            e
        }

        // Assert
        assertTrue("cancellation became a failed result instead", thrown != null)
    }

    @Test
    fun `a redirect fails the search and is not retried`() = runTest {
        // Arrange: Response.error(code, body) refuses codes below 400, so the
        // 3xx is built from the raw response a no-redirect client returns
        val redirect = okhttp3.Response.Builder()
            .request(Request.Builder().url(Constants.PUBMED_BASE_URL + "esearch.fcgi").build())
            .protocol(Protocol.HTTP_1_1)
            .code(307)
            .message("Temporary Redirect")
            .header("Location", "https://collector.example/")
            .build()
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.error("".toResponseBody(null), redirect)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertEquals(RequestFailure(RequestFailureKind.REDIRECT_REFUSED, 307), failureOf(result))
        coVerify(exactly = 1) {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        }
    }

    // ==================== Pagination Tests ====================

    @Test
    fun `search correctly calculates hasMore when more results exist`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "100",
                    idList = listOf("1", "2", "3", "4", "5")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(createSampleXml(listOf("1", "2", "3", "4", "5")))

        // Act
        val result = service.search(query = "test", offset = 0, batchSize = 5)

        // Assert
        assertTrue(result.isSuccess)
        val searchResult = result.getOrNull()!!
        assertTrue(searchResult.hasMore)
        assertEquals(5, searchResult.nextOffset)
    }

    @Test
    fun `search correctly calculates hasMore when at end of results`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "8",
                    idList = listOf("6", "7", "8")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(createSampleXml(listOf("6", "7", "8")))

        // Act
        val result = service.search(query = "test", offset = 5, batchSize = 5)

        // Assert
        assertTrue(result.isSuccess)
        val searchResult = result.getOrNull()!!
        assertFalse(searchResult.hasMore)
        assertEquals(8, searchResult.nextOffset)
    }

    @Test
    fun `search sets hasMore false when approaching max offset`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "15000",
                    idList = listOf("1")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(createSampleXml(listOf("1")))

        // Act
        val result = service.search(query = "test", offset = LAST_LISTABLE_OFFSET)

        // Assert
        assertTrue(result.isSuccess)
        assertFalse(result.getOrNull()!!.hasMore)
    }

    // ==================== Helper Methods ====================

    /** The failure a result carries, asserting it is a PubMed source failure. */
    private fun failureOf(result: Result<PubMedSearchResult>): RequestFailure {
        val error = result.exceptionOrNull()
        assertTrue("expected a SourceRequestException, got $error", error is SourceRequestException)
        assertEquals(SearchProvider.PUBMED, (error as SourceRequestException).provider)
        return error.failure
    }

    /**
     * Creates a sample PubMed XML response for testing.
     *
     * The XML declaration is emitted at column 0 (no leading whitespace); a
     * conformant XML parser rejects any content, including whitespace, before
     * the `<?xml ...?>` prolog.
     */
    private fun createSampleXml(pmids: List<String>): String {
        val articles = pmids.mapIndexed { index, pmid ->
            """
            <PubmedArticle>
                <MedlineCitation>
                    <PMID>$pmid</PMID>
                    <Article>
                        <ArticleTitle>Test Article $index</ArticleTitle>
                        <Abstract>
                            <AbstractText>Abstract for article $index</AbstractText>
                        </Abstract>
                    </Article>
                </MedlineCitation>
            </PubmedArticle>
            """.trimIndent()
        }.joinToString("\n")

        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<PubmedArticleSet>\n" +
            "$articles\n" +
            "</PubmedArticleSet>"
    }

    private companion object {
        /** The highest `retstart` E-utilities accepts (checked live 2026-09-15). */
        const val LAST_LISTABLE_OFFSET = 9_998
    }
}
