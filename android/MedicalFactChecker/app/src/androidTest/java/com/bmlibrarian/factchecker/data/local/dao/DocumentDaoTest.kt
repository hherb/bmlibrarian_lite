package com.bmlibrarian.factchecker.data.local.dao

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bmlibrarian.factchecker.data.local.AppDatabase
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Integration tests for DocumentDao.
 *
 * Uses an in-memory Room database for fast, isolated testing.
 */
@RunWith(AndroidJUnit4::class)
class DocumentDaoTest {

    private lateinit var database: AppDatabase
    private lateinit var sessionDao: SessionDao
    private lateinit var documentDao: DocumentDao
    private lateinit var testSession: SessionEntity

    @Before
    fun setup() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        sessionDao = database.sessionDao()
        documentDao = database.documentDao()

        // Create a test session for foreign key constraint
        testSession = SessionEntity(claimText = "Test claim")
        kotlinx.coroutines.runBlocking {
            sessionDao.insert(testSession)
        }
    }

    @After
    fun teardown() {
        database.close()
    }

    // ==================== Insert and Query Tests ====================

    @Test
    fun insertAndRetrieveDocument() = runTest {
        val document = createTestDocument()

        documentDao.insert(document)
        val retrieved = documentDao.getById(document.id)

        assertNotNull(retrieved)
        assertEquals(document.id, retrieved!!.id)
        assertEquals("Test Article Title", retrieved.title)
        assertEquals("12345678", retrieved.pmid)
    }

    @Test
    fun insertAllDocuments() = runTest {
        val documents = listOf(
            createTestDocument(pmid = "111"),
            createTestDocument(pmid = "222"),
            createTestDocument(pmid = "333")
        )

        documentDao.insertAll(documents)

        val all = documentDao.getBySessionIdSync(testSession.id)
        assertEquals(3, all.size)
    }

    @Test
    fun getBySessionId() = runTest {
        val doc1 = createTestDocument(pmid = "111", resultPosition = 0)
        val doc2 = createTestDocument(pmid = "222", resultPosition = 1)
        documentDao.insertAll(listOf(doc1, doc2))

        val documents = documentDao.getBySessionId(testSession.id).first()

        assertEquals(2, documents.size)
        assertEquals("111", documents[0].pmid) // Ordered by result_position
        assertEquals("222", documents[1].pmid)
    }

    // ==================== Scoring Tests ====================

    @Test
    fun updateScore() = runTest {
        val document = createTestDocument()
        documentDao.insert(document)

        documentDao.updateScore(document.id, 4, "Highly relevant to claim")

        val retrieved = documentDao.getById(document.id)
        assertEquals(4, retrieved?.relevanceScore)
        assertEquals("Highly relevant to claim", retrieved?.scoreRationale)
        assertNotNull(retrieved?.scoredAt)
    }

    @Test
    fun getScoredBySessionId() = runTest {
        val scored = createTestDocument(pmid = "111").let {
            documentDao.insert(it)
            documentDao.updateScore(it.id, 4, "Relevant")
            it
        }
        val unscored = createTestDocument(pmid = "222")
        documentDao.insert(unscored)

        val scoredDocs = documentDao.getScoredBySessionId(testSession.id).first()

        assertEquals(1, scoredDocs.size)
        assertEquals("111", scoredDocs[0].pmid)
    }

    @Test
    fun getRelevantBySessionId() = runTest {
        val doc1 = createTestDocument(pmid = "111")
        val doc2 = createTestDocument(pmid = "222")
        val doc3 = createTestDocument(pmid = "333")

        documentDao.insertAll(listOf(doc1, doc2, doc3))
        documentDao.updateScore(doc1.id, 5, "Very relevant")
        documentDao.updateScore(doc2.id, 3, "Moderately relevant")
        documentDao.updateScore(doc3.id, 2, "Not relevant")

        val relevant = documentDao.getRelevantBySessionId(testSession.id, minScore = 3).first()

        assertEquals(2, relevant.size)
        assertEquals(5, relevant[0].relevanceScore) // Ordered by score desc
        assertEquals(3, relevant[1].relevanceScore)
    }

    @Test
    fun getUnscoredBySessionId() = runTest {
        val scored = createTestDocument(pmid = "111")
        val unscored1 = createTestDocument(pmid = "222")
        val unscored2 = createTestDocument(pmid = "333")

        documentDao.insertAll(listOf(scored, unscored1, unscored2))
        documentDao.updateScore(scored.id, 4, "Relevant")

        val unscored = documentDao.getUnscoredBySessionId(testSession.id)

        assertEquals(2, unscored.size)
    }

    // ==================== Full Text Tests ====================

    @Test
    fun updateFullTextMarkdown() = runTest {
        val document = createTestDocument()
        documentDao.insert(document)

        documentDao.updateFullTextMarkdown(
            document.id,
            "# Full Text Content",
            "europepmc"
        )

        val retrieved = documentDao.getById(document.id)
        assertEquals("# Full Text Content", retrieved?.fullTextMarkdown)
        assertEquals("europepmc", retrieved?.fullTextSource)
        assertNotNull(retrieved?.fullTextFetchedAt)
    }

    @Test
    fun updatePdfPath() = runTest {
        val document = createTestDocument()
        documentDao.insert(document)

        documentDao.updatePdfPath(document.id, "/path/to/file.pdf", "unpaywall")

        val retrieved = documentDao.getById(document.id)
        assertEquals("/path/to/file.pdf", retrieved?.pdfPath)
        assertEquals("unpaywall", retrieved?.fullTextSource)
    }

    @Test
    fun markFullTextUnavailable() = runTest {
        val document = createTestDocument()
        documentDao.insert(document)

        documentDao.markFullTextUnavailable(document.id)

        val retrieved = documentDao.getById(document.id)
        assertTrue(retrieved?.fullTextUnavailable ?: false)
    }

    @Test
    fun getWithFullText() = runTest {
        val withMarkdown = createTestDocument(pmid = "111")
        val withPdf = createTestDocument(pmid = "222")
        val withoutFullText = createTestDocument(pmid = "333")

        documentDao.insertAll(listOf(withMarkdown, withPdf, withoutFullText))
        documentDao.updateFullTextMarkdown(withMarkdown.id, "Content", "europepmc")
        documentDao.updatePdfPath(withPdf.id, "/path.pdf", "unpaywall")

        val withFullText = documentDao.getWithFullText(testSession.id)

        assertEquals(2, withFullText.size)
    }

    // ==================== Lookup Tests ====================

    @Test
    fun getByPmidAndSession() = runTest {
        val document = createTestDocument(pmid = "12345678")
        documentDao.insert(document)

        val found = documentDao.getByPmidAndSession("12345678", testSession.id)
        val notFound = documentDao.getByPmidAndSession("99999999", testSession.id)

        assertNotNull(found)
        assertNull(notFound)
    }

    @Test
    fun getByDoiAndSession() = runTest {
        val document = createTestDocument(doi = "10.1234/test")
        documentDao.insert(document)

        val found = documentDao.getByDoiAndSession("10.1234/test", testSession.id)
        val notFound = documentDao.getByDoiAndSession("10.9999/fake", testSession.id)

        assertNotNull(found)
        assertNull(notFound)
    }

    // ==================== Count Tests ====================

    @Test
    fun countBySessionId() = runTest {
        documentDao.insertAll(listOf(
            createTestDocument(pmid = "111"),
            createTestDocument(pmid = "222"),
            createTestDocument(pmid = "333")
        ))

        assertEquals(3, documentDao.countBySessionId(testSession.id))
    }

    @Test
    fun countScoredBySessionId() = runTest {
        val doc1 = createTestDocument(pmid = "111")
        val doc2 = createTestDocument(pmid = "222")
        val doc3 = createTestDocument(pmid = "333")

        documentDao.insertAll(listOf(doc1, doc2, doc3))
        documentDao.updateScore(doc1.id, 4, "Relevant")
        documentDao.updateScore(doc2.id, 3, "Somewhat relevant")

        assertEquals(2, documentDao.countScoredBySessionId(testSession.id))
    }

    @Test
    fun countRelevantBySessionId() = runTest {
        val doc1 = createTestDocument(pmid = "111")
        val doc2 = createTestDocument(pmid = "222")
        val doc3 = createTestDocument(pmid = "333")

        documentDao.insertAll(listOf(doc1, doc2, doc3))
        documentDao.updateScore(doc1.id, 5, "Very relevant")
        documentDao.updateScore(doc2.id, 3, "Moderately relevant")
        documentDao.updateScore(doc3.id, 1, "Not relevant")

        assertEquals(2, documentDao.countRelevantBySessionId(testSession.id, minScore = 3))
    }

    // ==================== Delete Tests ====================

    @Test
    fun deleteBySessionId() = runTest {
        documentDao.insertAll(listOf(
            createTestDocument(pmid = "111"),
            createTestDocument(pmid = "222")
        ))

        documentDao.deleteBySessionId(testSession.id)

        assertEquals(0, documentDao.countBySessionId(testSession.id))
    }

    @Test
    fun cascadeDeleteWhenSessionDeleted() = runTest {
        documentDao.insertAll(listOf(
            createTestDocument(pmid = "111"),
            createTestDocument(pmid = "222")
        ))

        sessionDao.delete(testSession)

        assertEquals(0, documentDao.countBySessionId(testSession.id))
    }

    // ==================== Helper Functions ====================

    private fun createTestDocument(
        pmid: String = "12345678",
        doi: String = "10.1234/test",
        resultPosition: Int = 0
    ): DocumentEntity {
        return DocumentEntity(
            sessionId = testSession.id,
            pmid = pmid,
            doi = doi,
            title = "Test Article Title",
            abstractText = "This is a test abstract.",
            authors = listOf("Author A", "Author B"),
            journal = "Test Journal",
            publicationYear = 2024,
            resultPosition = resultPosition
        )
    }
}
