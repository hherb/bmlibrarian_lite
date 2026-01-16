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

import com.bmlibrarian.factchecker.domain.model.PubMedError
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Response
import java.io.IOException

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

    @Before
    fun setup() {
        api = mockk()
        service = PubMedService(api)
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
    fun `search fails when offset exceeds maximum`() = runTest {
        // Act
        val result = service.search(
            query = "test",
            offset = PubMedApi.MAX_OFFSET + 1
        )

        // Assert
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is PubMedError.InvalidOffsetError)
        assertEquals(PubMedApi.MAX_OFFSET + 1, (error as PubMedError.InvalidOffsetError).offset)
    }

    @Test
    fun `search accepts maximum valid offset`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), retStart = PubMedApi.MAX_OFFSET, any(), any(), any())
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
            offset = PubMedApi.MAX_OFFSET
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
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is PubMedError.ServerError)
    }

    @Test
    fun `search returns error on fetch HTTP failure`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "10",
                    idList = listOf("12345")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.error(500, "Server error".toResponseBody(null))

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is PubMedError.ServerError)
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
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is PubMedError.RateLimitError)
    }

    @Test
    fun `search returns error when esearchResult is null`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(ESearchResponse(esearchResult = null))

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is PubMedError.SearchError)
    }

    @Test
    fun `search returns error when fetch response is empty`() = runTest {
        // Arrange
        coEvery {
            api.search(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Response.success(
            ESearchResponse(
                esearchResult = ESearchResult(
                    count = "10",
                    idList = listOf("12345")
                )
            )
        )

        coEvery {
            api.fetch(any(), any(), any(), any(), any(), any())
        } returns Response.success(null)

        // Act
        val result = service.search(query = "test")

        // Assert
        assertTrue(result.isFailure)
        val error = result.exceptionOrNull()
        assertTrue(error is PubMedError.FetchError)
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
    fun `search passes API key and email when provided`() = runTest {
        // Arrange
        val apiKey = "test-api-key"
        val email = "test@example.com"

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
        service.search(
            query = "test",
            apiKey = apiKey,
            email = email
        )

        // Assert
        coVerify {
            api.search(any(), any(), any(), any(), any(), any(), apiKey = apiKey, email = email)
            api.fetch(any(), any(), any(), any(), apiKey = apiKey, email = email)
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
        val result = service.search(query = "test", offset = PubMedApi.MAX_OFFSET)

        // Assert
        assertTrue(result.isSuccess)
        assertFalse(result.getOrNull()!!.hasMore)
    }

    // ==================== Helper Methods ====================

    /**
     * Creates a sample PubMed XML response for testing.
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

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <PubmedArticleSet>
            $articles
            </PubmedArticleSet>
        """.trimIndent()
    }
}
