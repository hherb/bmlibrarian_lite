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

package com.bmlibrarian.factchecker.data.local.dao

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bmlibrarian.factchecker.data.local.AppDatabase
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Integration tests for SessionDao.
 *
 * Uses an in-memory Room database for fast, isolated testing.
 */
@RunWith(AndroidJUnit4::class)
class SessionDaoTest {

    private lateinit var database: AppDatabase
    private lateinit var sessionDao: SessionDao

    @Before
    fun setup() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        sessionDao = database.sessionDao()
    }

    @After
    fun teardown() {
        database.close()
    }

    // ==================== Insert and Query Tests ====================

    @Test
    fun insertAndRetrieveSession() = runTest {
        val session = SessionEntity(claimText = "Vitamin D prevents COVID-19")

        sessionDao.insert(session)
        val retrieved = sessionDao.getById(session.id)

        assertNotNull(retrieved)
        assertEquals(session.id, retrieved!!.id)
        assertEquals("Vitamin D prevents COVID-19", retrieved.claimText)
        assertEquals(WorkflowStep.IDLE, retrieved.workflowStep)
    }

    @Test
    fun insertReplacesExistingSession() = runTest {
        val session = SessionEntity(claimText = "Original claim")
        sessionDao.insert(session)

        val updated = session.copy(claimText = "Updated claim")
        sessionDao.insert(updated)

        val retrieved = sessionDao.getById(session.id)
        assertEquals("Updated claim", retrieved?.claimText)
    }

    @Test
    fun getByIdReturnsNullForNonexistent() = runTest {
        val result = sessionDao.getById("nonexistent-id")

        assertNull(result)
    }

    // ==================== Update Tests ====================

    @Test
    fun updateSession() = runTest {
        val session = SessionEntity(claimText = "Original claim")
        sessionDao.insert(session)

        val updated = session.copy(
            pubmedQuery = "vitamin D COVID-19",
            workflowStep = WorkflowStep.CONVERTING_QUERY
        )
        sessionDao.update(updated)

        val retrieved = sessionDao.getById(session.id)
        assertEquals("vitamin D COVID-19", retrieved?.pubmedQuery)
        assertEquals(WorkflowStep.CONVERTING_QUERY, retrieved?.workflowStep)
    }

    @Test
    fun updateWorkflowStep() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)

        sessionDao.updateWorkflowStep(session.id, WorkflowStep.SCORING_DOCUMENTS)

        val retrieved = sessionDao.getById(session.id)
        assertEquals(WorkflowStep.SCORING_DOCUMENTS, retrieved?.workflowStep)
    }

    @Test
    fun addTokenUsage() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)

        sessionDao.addTokenUsage(session.id, 100, 50, 0.01)
        sessionDao.addTokenUsage(session.id, 200, 100, 0.02)

        val retrieved = sessionDao.getById(session.id)
        assertEquals(300, retrieved?.totalInputTokens)
        assertEquals(150, retrieved?.totalOutputTokens)
        assertEquals(0.03, retrieved?.estimatedCostUsd ?: 0.0, 0.001)
    }

    @Test
    fun updateQuery() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)

        sessionDao.updateQuery(session.id, "main query", "alternative query")

        val retrieved = sessionDao.getById(session.id)
        assertEquals("main query", retrieved?.pubmedQuery)
        assertEquals("alternative query", retrieved?.alternativeQuery)
    }

    @Test
    fun setError() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)

        sessionDao.setError(session.id, "Network timeout")

        val retrieved = sessionDao.getById(session.id)
        assertEquals(WorkflowStep.FAILED, retrieved?.workflowStep)
        assertEquals("Network timeout", retrieved?.errorMessage)
    }

    // ==================== Delete Tests ====================

    @Test
    fun deleteSession() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)

        sessionDao.delete(session)

        assertNull(sessionDao.getById(session.id))
    }

    @Test
    fun deleteById() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)

        sessionDao.deleteById(session.id)

        assertNull(sessionDao.getById(session.id))
    }

    @Test
    fun deleteAll() = runTest {
        repeat(3) {
            sessionDao.insert(SessionEntity(claimText = "Claim $it"))
        }

        sessionDao.deleteAll()

        val all = sessionDao.getAllSessions().first()
        assertTrue(all.isEmpty())
    }

    // ==================== Flow Query Tests ====================

    @Test
    fun getAllSessionsReturnsOrderedByCreationDate() = runTest {
        val session1 = SessionEntity(claimText = "First")
        sessionDao.insert(session1)

        val session2 = SessionEntity(claimText = "Second")
        sessionDao.insert(session2)

        val session3 = SessionEntity(claimText = "Third")
        sessionDao.insert(session3)

        val all = sessionDao.getAllSessions().first()

        assertEquals(3, all.size)
        // Newest first
        assertEquals("Third", all[0].claimText)
        assertEquals("Second", all[1].claimText)
        assertEquals("First", all[2].claimText)
    }

    @Test
    fun getCompletedSessions() = runTest {
        val session1 = SessionEntity(
            claimText = "Completed",
            workflowStep = WorkflowStep.COMPLETED
        )
        val session2 = SessionEntity(
            claimText = "In Progress",
            workflowStep = WorkflowStep.SCORING_DOCUMENTS
        )

        sessionDao.insert(session1)
        sessionDao.insert(session2)

        val completed = sessionDao.getCompletedSessions().first()

        assertEquals(1, completed.size)
        assertEquals("Completed", completed[0].claimText)
    }

    @Test
    fun getSessionsByStep() = runTest {
        val session1 = SessionEntity(
            claimText = "Scoring 1",
            workflowStep = WorkflowStep.SCORING_DOCUMENTS
        )
        val session2 = SessionEntity(
            claimText = "Scoring 2",
            workflowStep = WorkflowStep.SCORING_DOCUMENTS
        )
        val session3 = SessionEntity(
            claimText = "Idle",
            workflowStep = WorkflowStep.IDLE
        )

        sessionDao.insert(session1)
        sessionDao.insert(session2)
        sessionDao.insert(session3)

        val scoring = sessionDao.getSessionsByStep(WorkflowStep.SCORING_DOCUMENTS).first()

        assertEquals(2, scoring.size)
    }

    // ==================== Count Tests ====================

    @Test
    fun count() = runTest {
        assertEquals(0, sessionDao.count())

        repeat(5) {
            sessionDao.insert(SessionEntity(claimText = "Claim $it"))
        }

        assertEquals(5, sessionDao.count())
    }

    @Test
    fun countCompleted() = runTest {
        sessionDao.insert(SessionEntity(claimText = "C1", workflowStep = WorkflowStep.COMPLETED))
        sessionDao.insert(SessionEntity(claimText = "C2", workflowStep = WorkflowStep.COMPLETED))
        sessionDao.insert(SessionEntity(claimText = "IP", workflowStep = WorkflowStep.SCORING_DOCUMENTS))

        assertEquals(2, sessionDao.countCompleted())
    }

    // ==================== Pagination Tests ====================

    @Test
    fun updatePubMedPagination() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)

        sessionDao.updatePubMedPagination(session.id, 50, 500)

        val retrieved = sessionDao.getById(session.id)
        assertEquals(50, retrieved?.pubmedOffset)
        assertEquals(500, retrieved?.pubmedTotalResults)
    }

    @Test
    fun updateEpmcPagination() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)

        sessionDao.updateEpmcPagination(session.id, "cursor123", 1000)

        val retrieved = sessionDao.getById(session.id)
        assertEquals("cursor123", retrieved?.epmcCursor)
        assertEquals(1000, retrieved?.epmcTotalResults)
    }

    // ==================== Search Provider Tests ====================

    @Test
    fun sessionWithSearchProvider() = runTest {
        val session = SessionEntity(
            claimText = "Test claim",
            searchProvider = SearchProvider.BOTH,
            includePreprints = true
        )
        sessionDao.insert(session)

        val retrieved = sessionDao.getById(session.id)

        assertEquals(SearchProvider.BOTH, retrieved?.searchProvider)
        assertTrue(retrieved?.includePreprints ?: false)
    }
}
