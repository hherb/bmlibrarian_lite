package com.bmlibrarian.factchecker.data.remote.llm

import com.bmlibrarian.factchecker.domain.model.LLMError
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import com.bmlibrarian.factchecker.util.ResponseParser
import kotlinx.coroutines.delay
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
     * Convert a medical claim to a PubMed query.
     *
     * @param provider The LLM provider configuration
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @param claim The medical claim to convert
     * @return Result containing the PubMed query string
     */
    suspend fun convertToPubMedQuery(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        claim: String
    ): Result<String> {
        val systemPrompt = """
            You are a medical librarian expert at converting natural language medical claims
            into effective PubMed search queries. Convert the given claim into a PubMed query
            that will find relevant systematic reviews, meta-analyses, and clinical trials.

            Return ONLY the PubMed query string, nothing else. Use MeSH terms where appropriate.
            Include filters for study types when relevant (e.g., systematic review, meta-analysis, RCT).
        """.trimIndent()

        return chat(
            provider = provider,
            apiKey = apiKey,
            model = model,
            systemPrompt = systemPrompt,
            userPrompt = claim,
            maxTokens = Constants.LLM_QUERY_MAX_TOKENS
        ).map { result ->
            ResponseParser.parsePubMedQueryResponse(result.content)
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

            Verdicts:
            - SUPPORTED: Strong evidence supports the claim
            - LIKELY_SUPPORTED: Evidence tends to support the claim
            - UNCLEAR: Evidence is mixed or insufficient
            - LIKELY_REFUTED: Evidence tends to refute the claim
            - REFUTED: Strong evidence refutes the claim

            Respond in JSON format:
            {
                "verdict": "<SUPPORTED|LIKELY_SUPPORTED|UNCLEAR|LIKELY_REFUTED|REFUTED>",
                "summary": "<2-3 sentence summary>",
                "report": "<full markdown report with citations>"
            }

            Use [1], [2], etc. to reference documents in the report.
        """.trimIndent()

        val citationsText = citations.mapIndexed { index, citation ->
            "[${index + 1}] ${citation.title}\n${citation.passage}"
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
        val pmid: String? = null
    )

    /**
     * Report generation result.
     */
    data class ReportGeneration(
        val verdict: String,
        val summary: String,
        val report: String
    )
}
