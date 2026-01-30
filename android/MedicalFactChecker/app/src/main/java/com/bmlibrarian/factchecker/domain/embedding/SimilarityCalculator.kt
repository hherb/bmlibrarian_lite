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

import kotlin.math.sqrt

/**
 * Utility class for computing vector similarity metrics.
 *
 * Provides mathematical functions for comparing embedding vectors,
 * primarily using cosine similarity which measures the angle between
 * two vectors regardless of magnitude.
 */
object SimilarityCalculator {

    /**
     * Compute cosine similarity between two vectors.
     *
     * Cosine similarity measures the cosine of the angle between two vectors,
     * resulting in a value between -1 and 1:
     * - 1 means the vectors point in the same direction
     * - 0 means the vectors are orthogonal (perpendicular)
     * - -1 means the vectors point in opposite directions
     *
     * For text embeddings, values are typically between 0 and 1.
     *
     * @param vectorA First embedding vector.
     * @param vectorB Second embedding vector.
     * @return Cosine similarity (-1.0 to 1.0), or 0.0 if vectors are empty or mismatched.
     */
    fun cosineSimilarity(vectorA: FloatArray, vectorB: FloatArray): Double {
        if (vectorA.size != vectorB.size || vectorA.isEmpty()) {
            return 0.0
        }

        var dotProduct = 0.0
        var normA = 0.0
        var normB = 0.0

        for (i in vectorA.indices) {
            dotProduct += vectorA[i] * vectorB[i]
            normA += vectorA[i] * vectorA[i]
            normB += vectorB[i] * vectorB[i]
        }

        val denominator = sqrt(normA) * sqrt(normB)
        return if (denominator > 0) dotProduct / denominator else 0.0
    }

    /**
     * Normalize a raw similarity score (0.0-1.0) to a 1-5 relevance scale.
     *
     * Mapping thresholds are tuned for typical sentence embedding similarity distributions:
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
            similarity < 0.3 -> 1
            similarity < 0.45 -> 2
            similarity < 0.55 -> 3
            similarity < 0.7 -> 4
            else -> 5
        }
    }

    /**
     * Clamp a similarity value to the valid range [0.0, 1.0].
     *
     * @param similarity The raw similarity value.
     * @return Clamped value between 0.0 and 1.0.
     */
    fun clampSimilarity(similarity: Double): Double {
        return similarity.coerceIn(0.0, 1.0)
    }
}
