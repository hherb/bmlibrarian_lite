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

package com.bmlibrarian.factchecker.domain.embedding

import com.bmlibrarian.factchecker.util.Constants

/**
 * Utility object for similarity score normalization.
 *
 * Provides functions for converting raw cosine similarity scores
 * to relevance scales. The cosine similarity calculation itself
 * is handled by MediaPipe's TextEmbedder.cosineSimilarity().
 *
 * Mirrors iOS EmbeddingService normalization for cross-platform consistency.
 */
object SimilarityCalculator {

    /**
     * Normalize a raw similarity score (0.0-1.0) to a 1-5 relevance scale.
     *
     * Mapping thresholds are tuned for typical sentence embedding similarity distributions
     * (e.g., Universal Sentence Encoder). These thresholds mirror the iOS implementation
     * for cross-platform consistency.
     *
     * Score mapping:
     * - < 0.3: Score 1 (not relevant)
     * - 0.3-0.45: Score 2 (marginally relevant)
     * - 0.45-0.55: Score 3 (moderately relevant)
     * - 0.55-0.7: Score 4 (highly relevant)
     * - >= 0.7: Score 5 (directly relevant)
     *
     * @param similarity Raw cosine similarity (0.0 to 1.0).
     * @return Normalized score (1 to 5).
     */
    fun normalizeToRelevanceScale(similarity: Double): Int {
        return when {
            similarity < Constants.EMBEDDING_THRESHOLD_SCORE_1 -> 1
            similarity < Constants.EMBEDDING_THRESHOLD_SCORE_2 -> 2
            similarity < Constants.EMBEDDING_THRESHOLD_SCORE_3 -> 3
            similarity < Constants.EMBEDDING_THRESHOLD_SCORE_4 -> 4
            else -> 5
        }
    }

    /**
     * Clamp a similarity value to the valid range [0.0, 1.0].
     *
     * Ensures similarity scores stay within expected bounds even if
     * the underlying embedding model produces out-of-range values.
     *
     * @param similarity The raw similarity value.
     * @return Clamped value between 0.0 and 1.0.
     */
    fun clampSimilarity(similarity: Double): Double {
        return similarity.coerceIn(0.0, 1.0)
    }
}
