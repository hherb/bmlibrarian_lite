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

package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.util.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for WorkflowConfig data class.
 */
class WorkflowConfigTest {

    // ==================== Default Configuration Tests ====================

    @Test
    fun `default configuration has expected values`() {
        val config = WorkflowConfig.default()

        assertEquals(SearchProvider.PUBMED, config.searchProvider)
        assertFalse(config.includePreprints)
        assertEquals(WorkflowConfig.DEFAULT_BATCH_SIZE, config.batchSize)
        assertEquals(Constants.SCORING_MIN_RELEVANT_SCORE, config.relevanceThreshold)
        assertEquals(WorkflowConfig.DEFAULT_TARGET_RELEVANT_DOCUMENTS, config.targetRelevantDocuments)
        assertEquals(WorkflowConfig.DEFAULT_MAX_BATCHES, config.maxBatches)
        assertEquals(Constants.DEFAULT_MAX_RUN_BUDGET_USD.toDouble(), config.maxRunBudgetUsd, 0.001)
        assertEquals(Constants.DEFAULT_MONTHLY_BUDGET_USD.toDouble(), config.monthlyBudgetUsd, 0.001)
        assertTrue(config.smartSearchEnabled)
        assertEquals(WorkflowConfig.DEFAULT_SMART_SEARCH_THRESHOLD, config.smartSearchThreshold)
    }

    @Test
    fun `testing configuration has minimal values`() {
        val config = WorkflowConfig.forTesting()

        assertEquals(WorkflowConfig.MIN_BATCH_SIZE, config.batchSize)
        assertEquals(3, config.targetRelevantDocuments)
        assertEquals(2, config.maxBatches)
        assertEquals(0.10, config.maxRunBudgetUsd, 0.001)
        assertFalse(config.smartSearchEnabled)
    }

    // ==================== Validation Tests ====================

    @Test
    fun `valid configuration passes validation`() {
        val config = WorkflowConfig.default()

        assertTrue(config.isValid())
        assertTrue(config.validate().isEmpty())
    }

    @Test
    fun `invalid batch size fails validation - too small`() {
        val config = WorkflowConfig(batchSize = WorkflowConfig.MIN_BATCH_SIZE - 1)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Batch size") })
    }

    @Test
    fun `invalid batch size fails validation - too large`() {
        val config = WorkflowConfig(batchSize = WorkflowConfig.MAX_BATCH_SIZE + 1)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Batch size") })
    }

    @Test
    fun `valid batch size at boundaries passes validation`() {
        val minConfig = WorkflowConfig(batchSize = WorkflowConfig.MIN_BATCH_SIZE)
        val maxConfig = WorkflowConfig(batchSize = WorkflowConfig.MAX_BATCH_SIZE)

        assertTrue(minConfig.isValid())
        assertTrue(maxConfig.isValid())
    }

    @Test
    fun `invalid relevance threshold fails validation - too low`() {
        val config = WorkflowConfig(relevanceThreshold = Constants.SCORING_MIN_SCORE - 1)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Relevance threshold") })
    }

    @Test
    fun `invalid relevance threshold fails validation - too high`() {
        val config = WorkflowConfig(relevanceThreshold = Constants.SCORING_MAX_SCORE + 1)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Relevance threshold") })
    }

    @Test
    fun `invalid target relevant documents fails validation`() {
        val config = WorkflowConfig(targetRelevantDocuments = 0)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Target relevant documents") })
    }

    @Test
    fun `invalid max batches fails validation`() {
        val config = WorkflowConfig(maxBatches = 0)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Max batches") })
    }

    @Test
    fun `invalid run budget fails validation - zero`() {
        val config = WorkflowConfig(maxRunBudgetUsd = 0.0)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Max run budget") })
    }

    @Test
    fun `invalid run budget fails validation - negative`() {
        val config = WorkflowConfig(maxRunBudgetUsd = -1.0)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Max run budget") })
    }

    @Test
    fun `invalid monthly budget fails validation`() {
        val config = WorkflowConfig(monthlyBudgetUsd = 0.0)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Monthly budget") })
    }

    @Test
    fun `invalid smart search threshold fails validation`() {
        val config = WorkflowConfig(smartSearchThreshold = -1)

        assertFalse(config.isValid())
        assertTrue(config.validate().any { it.contains("Smart search threshold") })
    }

    @Test
    fun `zero smart search threshold is valid`() {
        val config = WorkflowConfig(smartSearchThreshold = 0)

        assertTrue(config.isValid())
    }

    @Test
    fun `multiple validation errors are all reported`() {
        val config = WorkflowConfig(
            batchSize = 1,
            relevanceThreshold = 10,
            targetRelevantDocuments = 0,
            maxBatches = 0
        )

        val errors = config.validate()

        assertTrue(errors.size >= 4)
    }

    // ==================== Search Provider Tests ====================

    @Test
    fun `all search providers are valid`() {
        SearchProvider.entries.forEach { provider ->
            val config = WorkflowConfig(searchProvider = provider)
            assertTrue(config.isValid())
        }
    }

    // ==================== Configuration Copying Tests ====================

    @Test
    fun `configuration can be modified via copy`() {
        val original = WorkflowConfig.default()
        val modified = original.copy(
            searchProvider = SearchProvider.BOTH,
            includePreprints = true,
            batchSize = 50
        )

        assertEquals(SearchProvider.BOTH, modified.searchProvider)
        assertTrue(modified.includePreprints)
        assertEquals(50, modified.batchSize)

        // Original unchanged
        assertEquals(SearchProvider.PUBMED, original.searchProvider)
        assertFalse(original.includePreprints)
    }

    // ==================== Constants Tests ====================

    @Test
    fun `constants have sensible values`() {
        assertTrue(WorkflowConfig.DEFAULT_BATCH_SIZE > 0)
        assertTrue(WorkflowConfig.MIN_BATCH_SIZE > 0)
        assertTrue(WorkflowConfig.MAX_BATCH_SIZE > WorkflowConfig.MIN_BATCH_SIZE)
        assertTrue(WorkflowConfig.DEFAULT_BATCH_SIZE >= WorkflowConfig.MIN_BATCH_SIZE)
        assertTrue(WorkflowConfig.DEFAULT_BATCH_SIZE <= WorkflowConfig.MAX_BATCH_SIZE)
        assertTrue(WorkflowConfig.DEFAULT_TARGET_RELEVANT_DOCUMENTS > 0)
        assertTrue(WorkflowConfig.DEFAULT_MAX_BATCHES > 0)
        assertTrue(WorkflowConfig.DEFAULT_SMART_SEARCH_THRESHOLD >= 0)
    }
}
