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

package com.bmlibrarian.factchecker.data.remote.llm

import com.bmlibrarian.factchecker.domain.model.LLMError
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.StructuredQuery
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import com.bmlibrarian.factchecker.util.ResponseParser
import retrofit2.Response
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for LLM API interactions.
 *
 * Supports multiple providers with automatic format detection:
 * - OpenAI-compatible APIs (OpenAI, DeepSeek, Groq, Mistral, Ollama)
 * - Anthropic native API
 *
 * Implements retry logic with exponential backoff for transient failures.
 */
@Singleton
class LLMService @Inject constructor(
    private val openAIApi: OpenAIApi,
    private val anthropicApi: AnthropicApi
) {

    /**
     * Send a chat completion request to the LLM.
     *
     * Automatically selects the appropriate API format based on provider configuration.
     *
     * @param provider The LLM provider configuration
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @param systemPrompt System instructions for the LLM
     * @param userPrompt User message content
     * @param maxTokens Maximum tokens to generate
     * @param temperature Sampling temperature (0.0-1.0)
     * @return Result containing LLMResult on success, or LLMError on failure
     */
    suspend fun chat(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = Constants.LLM_SCORING_MAX_TOKENS,
        temperature: Double = Constants.LLM_DEFAULT_TEMPERATURE.toDouble()
    ): Result<LLMResult> {
        return try {
            NetworkRetry.withExponentialBackoff(
                maxRetries = Constants.NETWORK_MAX_RETRIES,
                shouldRetry = { e -> shouldRetryError(e) }
            ) {
                if (provider.usesAnthropicFormat) {
                    chatAnthropic(provider, apiKey, model, systemPrompt, userPrompt, maxTokens, temperature)
                } else {
                    chatOpenAI(provider, apiKey, model, systemPrompt, userPrompt, maxTokens, temperature)
                }
            }
        } catch (e: LLMError) {
            Result.failure(e)
        } catch (e: Exception) {
            Result.failure(
                LLMError.NetworkError(
                    message = "Network error: ${e.message}",
                    cause = e
                )
            )
        }
    }

    /**
     * Convert a medical claim to a structured query.
     *
     * Uses a structured JSON approach for better cross-platform consistency
     * and more reliable query generation. The structured query is then
     * translated to provider-specific syntax by the caller.
     *
     * Mirrors the iOS FactCheckWorkflow.convertClaimToQuery() for cross-platform
     * consistency, including matching maxTokens (512) and temperature (0.1).
     *
     * @param provider The LLM provider configuration
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @param claim The medical claim to convert
     * @return Result containing the StructuredQuery for provider-specific translation
     */
    suspend fun convertToStructuredQuery(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        claim: String
    ): Result<StructuredQuery> {
        // Use structured JSON prompt for better local model compatibility
        // Mirrors the iOS approach for cross-platform consistency
        val userPrompt = """
            Convert this research question into a concise PubMed search query.

            Research Question: $claim

            Instructions:
            1. Identify 2-3 key concepts from the question
            2. For each concept, provide 1-2 MeSH terms and 1-2 keywords
            3. Keep it CONCISE - fewer specific terms work better than many broad terms
            4. DO NOT add filters like hasabstract or publication type filters - those will be added automatically

            Output ONLY valid JSON in this exact format:
            {
              "concepts": [
                {"name": "concept1", "mesh_terms": ["MeSH Term"], "keywords": ["keyword"]},
                {"name": "concept2", "mesh_terms": ["MeSH Term"], "keywords": ["keyword"]}
              ]
            }

            Example for "amlodipine improves arterial stiffness":
            {
              "concepts": [
                {"name": "amlodipine", "mesh_terms": ["Amlodipine"], "keywords": ["amlodipine"]},
                {"name": "arterial stiffness", "mesh_terms": ["Vascular Stiffness"], "keywords": ["arterial stiffness", "pulse wave velocity"]}
              ]
            }

            Generate JSON for the research question:
        """.trimIndent()

        return chat(
            provider = provider,
            apiKey = apiKey,
            model = model,
            systemPrompt = "You are a medical librarian expert at converting natural language medical claims into effective PubMed search queries.",
            userPrompt = userPrompt,
            maxTokens = Constants.LLM_QUERY_MAX_TOKENS,
            temperature = 0.1
        ).mapCatching { result ->
            StructuredQuery.parse(result.content)
                ?: throw IllegalStateException("Failed to parse structured query from LLM response")
        }
    }

    /**
     * Generate alternative search queries when initial search yields insufficient results.
     *
     * Asks the LLM to generate 2-3 alternative structured queries using different
     * search strategies (synonyms, broader/narrower terms, split compound questions).
     *
     * Mirrors the iOS PromptTemplates.alternativeQueries() for cross-platform consistency.
     *
     * @param provider The LLM provider configuration
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @param claim The original medical claim/question
     * @param initialQuery The initial query that was tried
     * @param totalResults Total results from the initial search
     * @param relevantCount Number of relevant documents found
     * @return Result containing a list of alternative StructuredQuery objects
     */
    suspend fun generateAlternativeQueries(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        claim: String,
        initialQuery: String?,
        totalResults: Int,
        relevantCount: Int
    ): Result<List<StructuredQuery>> {
        val userPrompt = """
            The following medical question did not return enough relevant results with the initial search.

            Question: $claim
            Initial query: ${initialQuery ?: "N/A"}
            Results found: $totalResults
            Relevant documents: $relevantCount

            Generate 2-3 alternative search strategies as structured queries. Consider:
            1. If comparing two treatments/medications, search for each one separately
            2. Use different synonyms or related terms
            3. Break compound questions into simpler components
            4. Try broader or narrower search terms
            5. Focus on key outcomes or mechanisms

            Return a JSON array of structured query objects. Each object should have:
            - "concepts": an array of concepts, each with "name", "mesh_terms", and "keywords"

            Example response:
            [
              {
                "concepts": [
                  {"name": "treatment A", "mesh_terms": ["MeSH Term A"], "keywords": ["keyword A"]},
                  {"name": "condition", "mesh_terms": ["Condition MeSH"], "keywords": ["condition"]}
                ]
              },
              {
                "concepts": [
                  {"name": "treatment B", "mesh_terms": ["MeSH Term B"], "keywords": ["keyword B"]},
                  {"name": "condition", "mesh_terms": ["Condition MeSH"], "keywords": ["condition"]}
                ]
              }
            ]

            Generate alternative structured queries for the medical question:
        """.trimIndent()

        return chat(
            provider = provider,
            apiKey = apiKey,
            model = model,
            systemPrompt = "You are a medical librarian expert at generating alternative search strategies for biomedical literature databases.",
            userPrompt = userPrompt,
            maxTokens = 1024,
            temperature = 0.3
        ).mapCatching { result ->
            val queries = StructuredQuery.parseArray(result.content)
            if (queries.isEmpty()) {
                throw IllegalStateException("Failed to parse alternative queries from LLM response")
            }
            queries
        }
    }

    /**
     * Score a document's relevance to a claim.
     *
     * @param provider The LLM provider configuration
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @param claim The medical claim being evaluated
     * @param title Document title
     * @param abstractText Document abstract (may be null)
     * @return Result containing score (1-5) and rationale
     */
    suspend fun scoreDocument(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        claim: String,
        title: String,
        abstractText: String?
    ): Result<Pair<Int, String>> {
        val systemPrompt = """
            You are evaluating medical literature for relevance to a specific claim.
            Score the document's relevance on a scale of 1-5:

            1 = Not relevant at all
            2 = Marginally relevant
            3 = Moderately relevant
            4 = Highly relevant
            5 = Directly addresses the claim

            Respond in JSON format:
            {"score": <1-5>, "rationale": "<brief explanation>"}
        """.trimIndent()

        val userPrompt = """
            Claim: $claim

            Document Title: $title
            Abstract: ${abstractText ?: "No abstract available"}
        """.trimIndent()

        return chat(
            provider = provider,
            apiKey = apiKey,
            model = model,
            systemPrompt = systemPrompt,
            userPrompt = userPrompt,
            maxTokens = Constants.LLM_SCORING_MAX_TOKENS
        ).map { result ->
            val parsed = ResponseParser.parseScoreResponse(result.content)
            Pair(parsed.score, parsed.rationale)
        }
    }

    /**
     * Extract citation passages from a document.
     *
     * @param provider The LLM provider configuration
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @param claim The medical claim being evaluated
     * @param title Document title
     * @param content Document content (abstract or full text)
     * @return Result containing list of citation extractions
     */
    suspend fun extractCitations(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        claim: String,
        title: String,
        content: String?
    ): Result<List<CitationExtraction>> {
        val systemPrompt = """
            You are extracting key passages from medical literature that are relevant to a claim.
            Identify the most important passages that support or refute the claim.

            Respond in JSON format:
            {"citations": [{"passage": "<exact quote or paraphrase>", "relevance": "<why this is relevant>"}]}

            Extract 1-3 citations maximum.
        """.trimIndent()

        val userPrompt = """
            Claim: $claim

            Document Title: $title
            Content: ${content ?: "No content available"}
        """.trimIndent()

        return chat(
            provider = provider,
            apiKey = apiKey,
            model = model,
            systemPrompt = systemPrompt,
            userPrompt = userPrompt,
            maxTokens = Constants.LLM_CITATION_MAX_TOKENS
        ).map { result ->
            ResponseParser.parseCitationResponse(result.content).map { parsed ->
                CitationExtraction(
                    passage = parsed.passage,
                    relevance = parsed.relevance
                )
            }
        }
    }

    /**
     * Generate an evidence report.
     *
     * @param provider The LLM provider configuration
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @param claim The medical claim being evaluated
     * @param citations List of document citations to synthesize
     * @return Result containing report generation result
     */
    suspend fun generateReport(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        claim: String,
        citations: List<DocumentCitation>
    ): Result<ReportGeneration> {
        val systemPrompt = """
            You are a medical evidence synthesizer creating a fact-check report.
            Based on the provided citations, determine a verdict and write a clear report.

            EVIDENCE WEIGHING PRINCIPLES:
            When synthesizing evidence, consider both supporting AND refuting findings. Evidence quality hierarchy:
            1. Systematic reviews and meta-analyses (strongest)
            2. Randomized controlled trials (RCTs)
            3. Cohort studies (prospective stronger than retrospective)
            4. Case-control studies
            5. Case series and case reports (weakest)

            Verdicts:
            - SUPPORTED: Strong evidence supports the claim
            - LIKELY_SUPPORTED: Evidence tends to support the claim
            - UNCLEAR: Evidence is mixed or insufficient
            - LIKELY_REFUTED: Evidence tends to refute the claim
            - REFUTED: Strong evidence refutes the claim

            CRITICAL - Citation format:
            Use this EXACT format for all inline citations: [Author, Year](doc:ID)
            Example: [Smith et al., 2021](doc:pmid-12345678)
            The ID must be copied EXACTLY from the "ID:" field provided for each citation.
            Do NOT invent or modify IDs - use only the IDs provided.

            IMPORTANT: Use proper markdown with:
            - ## Headers for sections
            - **Bold** for emphasis
            - Bullet points with -

            Respond in JSON format:
            {
                "verdict": "<SUPPORTED|LIKELY_SUPPORTED|UNCLEAR|LIKELY_REFUTED|REFUTED>",
                "summary": "<2-3 sentence summary>",
                "report": "<full markdown report with inline citations using [Author, Year](doc:ID) format>"
            }
        """.trimIndent()

        val citationsText = citations.mapIndexed { index, citation ->
            val authorCitation = citation.formattedAuthorCitation()
            val yearStr = citation.year?.toString() ?: "n.d."
            val docId = citation.pmid?.let { "pmid-$it" } ?: citation.documentId ?: "doc-${index + 1}"
            """
            [${index + 1}] ID: $docId
            Authors: $authorCitation ($yearStr)
            Title: ${citation.title}
            Passage: "${citation.passage}"
            """.trimIndent()
        }.joinToString("\n\n")

        val userPrompt = """
            Claim: $claim

            Evidence:
            $citationsText
        """.trimIndent()

        return chat(
            provider = provider,
            apiKey = apiKey,
            model = model,
            systemPrompt = systemPrompt,
            userPrompt = userPrompt,
            maxTokens = Constants.LLM_REPORT_MAX_TOKENS
        ).map { result ->
            val parsed = ResponseParser.parseReportResponse(result.content)
            ReportGeneration(
                verdict = parsed.verdict,
                summary = parsed.summary,
                report = parsed.report
            )
        }
    }

    /**
     * Generate a hypothetical document for HyDE embedding.
     *
     * @param provider The LLM provider configuration
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @param claim The medical claim
     * @return Result containing the hypothetical abstract text
     */
    suspend fun generateHypotheticalDocument(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        claim: String
    ): Result<String> {
        val systemPrompt = """
            You are generating a hypothetical abstract for a medical research paper that would
            directly address and provide evidence for the given claim. Write a realistic abstract
            in the style of a peer-reviewed medical journal article.

            The abstract should be 150-200 words and include:
            - Background/objective
            - Methods (briefly)
            - Results (with plausible but hypothetical numbers)
            - Conclusion

            Return ONLY the abstract text, nothing else.
        """.trimIndent()

        return chat(
            provider = provider,
            apiKey = apiKey,
            model = model,
            systemPrompt = systemPrompt,
            userPrompt = "Generate a hypothetical abstract for: $claim",
            maxTokens = Constants.LLM_CITATION_MAX_TOKENS
        ).map { it.content.trim() }
    }

    // ==================== Private Implementation ====================

    /**
     * Send a chat request using OpenAI-compatible API format.
     */
    private suspend fun chatOpenAI(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Double
    ): Result<LLMResult> {
        val url = provider.chatCompletionsUrl
        val authorization = "Bearer $apiKey"

        val request = OpenAIChatRequest(
            model = model,
            messages = listOf(
                OpenAIChatMessage(role = "system", content = systemPrompt),
                OpenAIChatMessage(role = "user", content = userPrompt)
            ),
            maxTokens = maxTokens,
            temperature = temperature
        )

        val response = openAIApi.chatCompletion(url, authorization, request)
        return handleOpenAIResponse(response)
    }

    /**
     * Send a chat request using Anthropic API format.
     */
    private suspend fun chatAnthropic(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Double
    ): Result<LLMResult> {
        val url = provider.chatCompletionsUrl

        val request = AnthropicMessagesRequest(
            model = model,
            maxTokens = maxTokens,
            system = systemPrompt,
            messages = listOf(
                AnthropicMessage(role = "user", content = userPrompt)
            ),
            temperature = temperature
        )

        val response = anthropicApi.createMessage(
            url = url,
            apiKey = apiKey,
            anthropicVersion = AnthropicApi.API_VERSION,
            request = request
        )
        return handleAnthropicResponse(response)
    }

    /**
     * Handle OpenAI API response.
     */
    private fun handleOpenAIResponse(response: Response<OpenAIChatResponse>): Result<LLMResult> {
        if (response.isSuccessful) {
            val body = response.body()
            if (body != null) {
                val result = LLMResult.fromOpenAI(body)
                if (result != null) {
                    return Result.success(result)
                }
                throw LLMError.EmptyResponseError()
            }
            throw LLMError.EmptyResponseError()
        } else {
            val errorBody = response.errorBody()?.string()
            throw LLMError.fromHttpError(response.code(), response.message(), errorBody)
        }
    }

    /**
     * Handle Anthropic API response.
     */
    private fun handleAnthropicResponse(response: Response<AnthropicMessagesResponse>): Result<LLMResult> {
        if (response.isSuccessful) {
            val body = response.body()
            if (body != null) {
                val result = LLMResult.fromAnthropic(body)
                if (result != null) {
                    return Result.success(result)
                }
                throw LLMError.EmptyResponseError()
            }
            throw LLMError.EmptyResponseError()
        } else {
            val errorBody = response.errorBody()?.string()
            throw LLMError.fromHttpError(response.code(), response.message(), errorBody)
        }
    }

    /**
     * Determine if an error should trigger a retry.
     */
    private fun shouldRetryError(e: Exception): Boolean {
        return when (e) {
            is LLMError -> LLMError.isRetryable(e)
            else -> NetworkRetry.isRetryableException(e)
        }
    }

    // ==================== Helper Data Classes ====================

    /**
     * Citation extraction result.
     */
    data class CitationExtraction(
        val passage: String,
        val relevance: String
    )

    /**
     * Document citation for report generation.
     */
    data class DocumentCitation(
        val title: String,
        val passage: String,
        val pmid: String? = null,
        val authors: List<String> = emptyList(),
        val year: Int? = null,
        val documentId: String? = null
    ) {
        /**
         * Get formatted author citation text.
         *
         * Returns "Smith et al." for multiple authors or "Smith" for single author.
         */
        fun formattedAuthorCitation(): String {
            if (authors.isEmpty()) return "Unknown"
            val firstAuthor = authors.first().split(" ").firstOrNull() ?: authors.first()
            return if (authors.size > 1) "$firstAuthor et al." else firstAuthor
        }
    }

    /**
     * Report generation result.
     */
    data class ReportGeneration(
        val verdict: String,
        val summary: String,
        val report: String
    )
}
