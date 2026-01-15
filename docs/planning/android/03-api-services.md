# Phase 3: API Services

## Overview

This phase implements the external API integrations: LLM service (OpenAI-compatible), PubMed/NCBI E-utilities, and Europe PMC. These services handle all network communication with external providers.

**Estimated Duration**: 1 week
**Prerequisites**: Phase 1 & 2 completed
**Deliverable**: All external API integrations working

## API Endpoints Reference

| Service | Base URL | Auth | Format |
|---------|----------|------|--------|
| LLM (varies) | Provider-specific | Bearer token | JSON |
| PubMed | `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/` | Optional API key | JSON/XML |
| Europe PMC | `https://www.ebi.ac.uk/europepmc/webservices/rest` | None | JSON |

## Tasks

### 3.1 Create LLM Provider Configuration

```kotlin
// domain/model/LLMProvider.kt
package com.bmlibrarian.factchecker.domain.model

/**
 * LLM provider configuration.
 * Mirrors iOS LLMProvider enum with all supported providers.
 */
data class LLMProvider(
    val id: String,
    val displayName: String,
    val baseUrl: String,
    val defaultModel: String,
    val models: List<ModelInfo>,
    val supportsModelFetching: Boolean = false
) {
    companion object {
        val ANTHROPIC = LLMProvider(
            id = "anthropic",
            displayName = "Anthropic",
            baseUrl = "https://api.anthropic.com/v1",
            defaultModel = "claude-sonnet-4-20250514",
            models = listOf(
                ModelInfo("claude-sonnet-4-20250514", "Claude Sonnet 4", 3.00, 15.00),
                ModelInfo("claude-opus-4-20250514", "Claude Opus 4", 15.00, 75.00),
                ModelInfo("claude-haiku-3-5-20250514", "Claude 3.5 Haiku", 0.80, 4.00)
            )
        )

        val OPENAI = LLMProvider(
            id = "openai",
            displayName = "OpenAI",
            baseUrl = "https://api.openai.com/v1",
            defaultModel = "gpt-4o",
            models = listOf(
                ModelInfo("gpt-4o", "GPT-4o", 2.50, 10.00),
                ModelInfo("gpt-4o-mini", "GPT-4o Mini", 0.15, 0.60),
                ModelInfo("gpt-4-turbo", "GPT-4 Turbo", 10.00, 30.00)
            ),
            supportsModelFetching = true
        )

        val DEEPSEEK = LLMProvider(
            id = "deepseek",
            displayName = "DeepSeek",
            baseUrl = "https://api.deepseek.com/v1",
            defaultModel = "deepseek-chat",
            models = listOf(
                ModelInfo("deepseek-chat", "DeepSeek Chat", 0.14, 0.28),
                ModelInfo("deepseek-reasoner", "DeepSeek Reasoner", 0.55, 2.19)
            )
        )

        val GROQ = LLMProvider(
            id = "groq",
            displayName = "Groq",
            baseUrl = "https://api.groq.com/openai/v1",
            defaultModel = "llama-3.3-70b-versatile",
            models = listOf(
                ModelInfo("llama-3.3-70b-versatile", "Llama 3.3 70B", 0.59, 0.79),
                ModelInfo("llama-3.1-8b-instant", "Llama 3.1 8B", 0.05, 0.08),
                ModelInfo("mixtral-8x7b-32768", "Mixtral 8x7B", 0.24, 0.24)
            ),
            supportsModelFetching = true
        )

        val MISTRAL = LLMProvider(
            id = "mistral",
            displayName = "Mistral",
            baseUrl = "https://api.mistral.ai/v1",
            defaultModel = "mistral-large-latest",
            models = listOf(
                ModelInfo("mistral-large-latest", "Mistral Large", 2.00, 6.00),
                ModelInfo("mistral-small-latest", "Mistral Small", 0.20, 0.60),
                ModelInfo("codestral-latest", "Codestral", 0.20, 0.60)
            ),
            supportsModelFetching = true
        )

        val OLLAMA = LLMProvider(
            id = "ollama",
            displayName = "Ollama (Local)",
            baseUrl = "http://localhost:11434/v1",
            defaultModel = "llama3.2",
            models = listOf(
                ModelInfo("llama3.2", "Llama 3.2", 0.0, 0.0),
                ModelInfo("mistral", "Mistral 7B", 0.0, 0.0),
                ModelInfo("gemma2", "Gemma 2", 0.0, 0.0)
            ),
            supportsModelFetching = true
        )

        val CUSTOM = LLMProvider(
            id = "custom",
            displayName = "Custom",
            baseUrl = "",
            defaultModel = "",
            models = emptyList()
        )

        val ALL_PROVIDERS = listOf(ANTHROPIC, OPENAI, DEEPSEEK, GROQ, MISTRAL, OLLAMA, CUSTOM)

        fun fromId(id: String): LLMProvider? = ALL_PROVIDERS.find { it.id == id }
    }
}

/**
 * Model information with pricing.
 * Prices are per 1M tokens in USD.
 */
data class ModelInfo(
    val id: String,
    val displayName: String,
    val inputPricePer1M: Double,
    val outputPricePer1M: Double
) {
    /**
     * Calculate cost for given token counts.
     */
    fun calculateCost(inputTokens: Int, outputTokens: Int): Double {
        val inputCost = (inputTokens / 1_000_000.0) * inputPricePer1M
        val outputCost = (outputTokens / 1_000_000.0) * outputPricePer1M
        return inputCost + outputCost
    }
}
```

### 3.2 Create LLM API Interface and Service

```kotlin
// data/remote/llm/LLMApi.kt
package com.bmlibrarian.factchecker.data.remote.llm

import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.Header
import retrofit2.http.POST
import retrofit2.http.Url

/**
 * Retrofit interface for LLM API calls.
 * Uses dynamic URL to support multiple providers.
 */
interface LLMApi {

    @POST
    suspend fun chatCompletion(
        @Url url: String,
        @Header("Authorization") authorization: String,
        @Header("Content-Type") contentType: String = "application/json",
        @Body request: ChatCompletionRequest
    ): Response<ChatCompletionResponse>
}

/**
 * Chat completion request body.
 */
data class ChatCompletionRequest(
    val model: String,
    val messages: List<ChatMessage>,
    val max_tokens: Int = 4096,
    val temperature: Double = 0.7
)

/**
 * Chat message in the conversation.
 */
data class ChatMessage(
    val role: String, // "system", "user", "assistant"
    val content: String
)

/**
 * Chat completion response.
 */
data class ChatCompletionResponse(
    val id: String?,
    val choices: List<ChatChoice>,
    val usage: TokenUsage?
)

data class ChatChoice(
    val index: Int,
    val message: ChatMessage,
    val finish_reason: String?
)

data class TokenUsage(
    val prompt_tokens: Int,
    val completion_tokens: Int,
    val total_tokens: Int
)
```

```kotlin
// data/remote/llm/LLMService.kt
package com.bmlibrarian.factchecker.data.remote.llm

import com.bmlibrarian.factchecker.domain.model.LLMProvider
import kotlinx.coroutines.delay
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for LLM API interactions.
 * Supports multiple providers with OpenAI-compatible API.
 */
@Singleton
class LLMService @Inject constructor(
    private val api: LLMApi
) {

    /**
     * Result of an LLM call.
     */
    data class LLMResult(
        val content: String,
        val inputTokens: Int,
        val outputTokens: Int,
        val finishReason: String?
    )

    /**
     * Send a chat completion request to the LLM.
     *
     * @param provider The LLM provider configuration
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @param systemPrompt System instructions for the LLM
     * @param userPrompt User message content
     * @param maxRetries Maximum retry attempts on failure
     */
    suspend fun chat(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxRetries: Int = 3
    ): Result<LLMResult> {
        val url = "${provider.baseUrl}/chat/completions"
        val authorization = "Bearer $apiKey"

        val request = ChatCompletionRequest(
            model = model,
            messages = listOf(
                ChatMessage(role = "system", content = systemPrompt),
                ChatMessage(role = "user", content = userPrompt)
            )
        )

        var lastException: Exception? = null

        repeat(maxRetries) { attempt ->
            try {
                val response = api.chatCompletion(url, authorization, request = request)

                if (response.isSuccessful) {
                    val body = response.body()
                    if (body != null && body.choices.isNotEmpty()) {
                        val choice = body.choices.first()
                        return Result.success(
                            LLMResult(
                                content = choice.message.content,
                                inputTokens = body.usage?.prompt_tokens ?: 0,
                                outputTokens = body.usage?.completion_tokens ?: 0,
                                finishReason = choice.finish_reason
                            )
                        )
                    }
                    return Result.failure(Exception("Empty response from LLM"))
                } else {
                    val errorBody = response.errorBody()?.string()
                    lastException = Exception("API error ${response.code()}: $errorBody")

                    // Don't retry on auth errors
                    if (response.code() in listOf(401, 403)) {
                        return Result.failure(lastException!!)
                    }
                }
            } catch (e: Exception) {
                lastException = e
            }

            // Exponential backoff
            if (attempt < maxRetries - 1) {
                delay((1L shl attempt) * 1000) // 1s, 2s, 4s
            }
        }

        return Result.failure(lastException ?: Exception("Unknown error"))
    }

    /**
     * Convert a medical claim to a PubMed query.
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

        val result = chat(provider, apiKey, model, systemPrompt, claim)
        return result.map { it.content.trim() }
    }

    /**
     * Score a document's relevance to a claim.
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

        val result = chat(provider, apiKey, model, systemPrompt, userPrompt)
        return result.mapCatching { llmResult ->
            parseScoreResponse(llmResult.content)
        }
    }

    /**
     * Extract citation passages from a document.
     */
    suspend fun extractCitations(
        provider: LLMProvider,
        apiKey: String,
        model: String,
        claim: String,
        title: String,
        abstractText: String?
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
            Content: ${abstractText ?: "No content available"}
        """.trimIndent()

        val result = chat(provider, apiKey, model, systemPrompt, userPrompt)
        return result.mapCatching { llmResult ->
            parseCitationResponse(llmResult.content)
        }
    }

    /**
     * Generate an evidence report.
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

        val result = chat(provider, apiKey, model, systemPrompt, userPrompt)
        return result.mapCatching { llmResult ->
            parseReportResponse(llmResult.content)
        }
    }

    // Helper data classes for parsing
    data class CitationExtraction(val passage: String, val relevance: String)
    data class DocumentCitation(val title: String, val passage: String, val pmid: String?)
    data class ReportGeneration(val verdict: String, val summary: String, val report: String)

    // Parsing helpers (using Gson or manual parsing)
    private fun parseScoreResponse(json: String): Pair<Int, String> {
        // Parse JSON response for score and rationale
        val cleanJson = json.trim().removePrefix("```json").removeSuffix("```").trim()
        val regex = Regex(""""score"\s*:\s*(\d+).*?"rationale"\s*:\s*"([^"]+)"""", RegexOption.DOT_MATCHES_ALL)
        val match = regex.find(cleanJson)
        return if (match != null) {
            val score = match.groupValues[1].toInt().coerceIn(1, 5)
            val rationale = match.groupValues[2]
            Pair(score, rationale)
        } else {
            Pair(3, "Unable to parse response")
        }
    }

    private fun parseCitationResponse(json: String): List<CitationExtraction> {
        // Parse JSON response for citations
        val cleanJson = json.trim().removePrefix("```json").removeSuffix("```").trim()
        val results = mutableListOf<CitationExtraction>()
        val regex = Regex(""""passage"\s*:\s*"([^"]+)".*?"relevance"\s*:\s*"([^"]+)"""", RegexOption.DOT_MATCHES_ALL)
        regex.findAll(cleanJson).forEach { match ->
            results.add(CitationExtraction(match.groupValues[1], match.groupValues[2]))
        }
        return results
    }

    private fun parseReportResponse(json: String): ReportGeneration {
        val cleanJson = json.trim().removePrefix("```json").removeSuffix("```").trim()
        val verdictRegex = Regex(""""verdict"\s*:\s*"([^"]+)"""")
        val summaryRegex = Regex(""""summary"\s*:\s*"([^"]+)"""")
        val reportRegex = Regex(""""report"\s*:\s*"([\s\S]*?)(?:"\s*[,}])""")

        val verdict = verdictRegex.find(cleanJson)?.groupValues?.get(1) ?: "UNCLEAR"
        val summary = summaryRegex.find(cleanJson)?.groupValues?.get(1) ?: "Unable to generate summary"
        val report = reportRegex.find(cleanJson)?.groupValues?.get(1)?.replace("\\n", "\n") ?: summary

        return ReportGeneration(verdict, summary, report)
    }
}
```

### 3.3 Create PubMed API Interface and Service

```kotlin
// data/remote/pubmed/PubMedApi.kt
package com.bmlibrarian.factchecker.data.remote.pubmed

import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Query

/**
 * Retrofit interface for NCBI E-utilities PubMed API.
 */
interface PubMedApi {

    /**
     * Search PubMed for articles matching a query.
     */
    @GET("esearch.fcgi")
    suspend fun search(
        @Query("db") db: String = "pubmed",
        @Query("term") term: String,
        @Query("retmode") retMode: String = "json",
        @Query("retmax") retMax: Int = 20,
        @Query("retstart") retStart: Int = 0,
        @Query("usehistory") useHistory: String = "y",
        @Query("api_key") apiKey: String? = null,
        @Query("email") email: String? = null
    ): Response<ESearchResponse>

    /**
     * Fetch article details by PMIDs.
     */
    @GET("efetch.fcgi")
    suspend fun fetch(
        @Query("db") db: String = "pubmed",
        @Query("id") ids: String, // Comma-separated PMIDs
        @Query("retmode") retMode: String = "xml",
        @Query("rettype") retType: String = "abstract",
        @Query("api_key") apiKey: String? = null,
        @Query("email") email: String? = null
    ): Response<String> // Returns XML
}

/**
 * ESearch response structure.
 */
data class ESearchResponse(
    val esearchresult: ESearchResult?
)

data class ESearchResult(
    val count: String?,
    val retmax: String?,
    val retstart: String?,
    val idlist: List<String>?,
    val webenv: String?,
    val querykey: String?
)
```

```kotlin
// data/remote/pubmed/PubMedService.kt
package com.bmlibrarian.factchecker.data.remote.pubmed

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import kotlinx.coroutines.delay
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.StringReader
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for PubMed/NCBI E-utilities API interactions.
 */
@Singleton
class PubMedService @Inject constructor(
    private val api: PubMedApi
) {

    companion object {
        const val BASE_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
        const val DEFAULT_BATCH_SIZE = 20
        const val MAX_OFFSET = 9999
        const val RATE_LIMIT_DELAY_MS = 334L // ~3 requests per second
    }

    /**
     * Search result containing documents and pagination info.
     */
    data class SearchResult(
        val documents: List<DocumentEntity>,
        val totalResults: Int,
        val nextOffset: Int
    )

    /**
     * Search PubMed for articles matching a query.
     *
     * @param query PubMed search query
     * @param sessionId Session ID for the documents
     * @param offset Starting position for pagination
     * @param batchSize Number of results to fetch
     * @param apiKey Optional NCBI API key (increases rate limit)
     * @param email Email for NCBI identification
     */
    suspend fun search(
        query: String,
        sessionId: String,
        offset: Int = 0,
        batchSize: Int = DEFAULT_BATCH_SIZE,
        apiKey: String? = null,
        email: String? = null
    ): Result<SearchResult> {
        return try {
            // Step 1: Search for PMIDs
            val searchResponse = api.search(
                term = query,
                retMax = batchSize,
                retStart = offset,
                apiKey = apiKey,
                email = email
            )

            if (!searchResponse.isSuccessful) {
                return Result.failure(Exception("Search failed: ${searchResponse.code()}"))
            }

            val searchResult = searchResponse.body()?.esearchresult
                ?: return Result.failure(Exception("Empty search response"))

            val pmids = searchResult.idlist ?: emptyList()
            val totalResults = searchResult.count?.toIntOrNull() ?: 0

            if (pmids.isEmpty()) {
                return Result.success(SearchResult(emptyList(), totalResults, offset))
            }

            // Rate limit delay
            delay(RATE_LIMIT_DELAY_MS)

            // Step 2: Fetch article details
            val fetchResponse = api.fetch(
                ids = pmids.joinToString(","),
                apiKey = apiKey,
                email = email
            )

            if (!fetchResponse.isSuccessful) {
                return Result.failure(Exception("Fetch failed: ${fetchResponse.code()}"))
            }

            val xml = fetchResponse.body()
                ?: return Result.failure(Exception("Empty fetch response"))

            // Step 3: Parse XML to documents
            val documents = parseArticleXml(xml, sessionId, offset)

            Result.success(SearchResult(
                documents = documents,
                totalResults = totalResults,
                nextOffset = offset + pmids.size
            ))

        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Parse PubMed XML response into document entities.
     */
    private fun parseArticleXml(xml: String, sessionId: String, startPosition: Int): List<DocumentEntity> {
        val documents = mutableListOf<DocumentEntity>()
        var position = startPosition

        try {
            val factory = XmlPullParserFactory.newInstance()
            val parser = factory.newPullParser()
            parser.setInput(StringReader(xml))

            var eventType = parser.eventType
            var currentArticle: ArticleBuilder? = null
            var currentTag = ""
            var inAuthor = false
            var authorLastName = ""
            var authorForeName = ""

            while (eventType != XmlPullParser.END_DOCUMENT) {
                when (eventType) {
                    XmlPullParser.START_TAG -> {
                        currentTag = parser.name
                        when (currentTag) {
                            "PubmedArticle" -> currentArticle = ArticleBuilder()
                            "Author" -> inAuthor = true
                        }
                    }
                    XmlPullParser.TEXT -> {
                        val text = parser.text?.trim() ?: ""
                        if (text.isNotEmpty() && currentArticle != null) {
                            when (currentTag) {
                                "PMID" -> if (currentArticle.pmid == null) currentArticle.pmid = text
                                "ArticleTitle" -> currentArticle.title = text
                                "AbstractText" -> currentArticle.abstractText += text + " "
                                "Title" -> if (currentArticle.journal == null) currentArticle.journal = text
                                "Year" -> if (currentArticle.year == null) currentArticle.year = text.toIntOrNull()
                                "MedlineDate" -> if (currentArticle.year == null) {
                                    currentArticle.year = text.take(4).toIntOrNull()
                                }
                                "LastName" -> if (inAuthor) authorLastName = text
                                "ForeName" -> if (inAuthor) authorForeName = text
                                "DescriptorName" -> currentArticle.meshTerms.add(text)
                                "ELocationID" -> if (parser.getAttributeValue(null, "EIdType") == "doi") {
                                    currentArticle.doi = text
                                }
                            }
                        }
                    }
                    XmlPullParser.END_TAG -> {
                        when (parser.name) {
                            "Author" -> {
                                if (authorLastName.isNotEmpty()) {
                                    val fullName = if (authorForeName.isNotEmpty()) {
                                        "$authorLastName $authorForeName"
                                    } else {
                                        authorLastName
                                    }
                                    currentArticle?.authors?.add(fullName)
                                }
                                inAuthor = false
                                authorLastName = ""
                                authorForeName = ""
                            }
                            "PubmedArticle" -> {
                                currentArticle?.let { builder ->
                                    if (builder.pmid != null && builder.title != null) {
                                        documents.add(
                                            DocumentEntity(
                                                sessionId = sessionId,
                                                pmid = builder.pmid,
                                                doi = builder.doi,
                                                title = builder.title!!,
                                                abstractText = builder.abstractText.trim().ifEmpty { null },
                                                authors = builder.authors.toList(),
                                                journal = builder.journal,
                                                publicationYear = builder.year,
                                                meshTerms = builder.meshTerms.toList(),
                                                source = "pubmed",
                                                resultPosition = position++
                                            )
                                        )
                                    }
                                }
                                currentArticle = null
                            }
                        }
                        currentTag = ""
                    }
                }
                eventType = parser.next()
            }
        } catch (e: Exception) {
            // Log parsing error but return what we have
            e.printStackTrace()
        }

        return documents
    }

    /**
     * Helper class for building articles during XML parsing.
     */
    private class ArticleBuilder {
        var pmid: String? = null
        var doi: String? = null
        var title: String? = null
        var abstractText: String = ""
        var journal: String? = null
        var year: Int? = null
        val authors = mutableListOf<String>()
        val meshTerms = mutableListOf<String>()
    }
}
```

### 3.4 Create Europe PMC API Interface and Service

```kotlin
// data/remote/europepmc/EuropePMCApi.kt
package com.bmlibrarian.factchecker.data.remote.europepmc

import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Query

/**
 * Retrofit interface for Europe PMC REST API.
 */
interface EuropePMCApi {

    /**
     * Search Europe PMC for articles.
     */
    @GET("search")
    suspend fun search(
        @Query("query") query: String,
        @Query("resultType") resultType: String = "core",
        @Query("pageSize") pageSize: Int = 20,
        @Query("cursorMark") cursorMark: String = "*",
        @Query("format") format: String = "json",
        @Query("sort") sort: String = "RELEVANCE desc"
    ): Response<EuropePMCSearchResponse>
}

/**
 * Europe PMC search response.
 */
data class EuropePMCSearchResponse(
    val hitCount: Int?,
    val nextCursorMark: String?,
    val resultList: ResultList?
)

data class ResultList(
    val result: List<EuropePMCArticle>?
)

data class EuropePMCArticle(
    val id: String?,
    val pmid: String?,
    val pmcid: String?,
    val doi: String?,
    val title: String?,
    val abstractText: String?,
    val authorString: String?,
    val journalTitle: String?,
    val pubYear: String?,
    val isOpenAccess: String?,
    val source: String?
)
```

```kotlin
// data/remote/europepmc/EuropePMCService.kt
package com.bmlibrarian.factchecker.data.remote.europepmc

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for Europe PMC API interactions.
 */
@Singleton
class EuropePMCService @Inject constructor(
    private val api: EuropePMCApi
) {

    companion object {
        const val BASE_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/"
    }

    /**
     * Search result with cursor-based pagination.
     */
    data class SearchResult(
        val documents: List<DocumentEntity>,
        val totalResults: Int,
        val nextCursor: String?
    )

    /**
     * Search Europe PMC for articles.
     *
     * @param query Search query
     * @param sessionId Session ID for documents
     * @param cursor Cursor for pagination (null or "*" for first page)
     * @param batchSize Number of results per page
     * @param includePreprints Whether to include preprints
     */
    suspend fun search(
        query: String,
        sessionId: String,
        cursor: String? = null,
        batchSize: Int = 20,
        includePreprints: Boolean = false
    ): Result<SearchResult> {
        return try {
            // Build query with optional preprint filter
            val fullQuery = if (!includePreprints) {
                "($query) AND (SRC:MED OR SRC:PMC)"
            } else {
                query
            }

            val response = api.search(
                query = fullQuery,
                pageSize = batchSize,
                cursorMark = cursor ?: "*"
            )

            if (!response.isSuccessful) {
                return Result.failure(Exception("Europe PMC search failed: ${response.code()}"))
            }

            val body = response.body()
                ?: return Result.failure(Exception("Empty response from Europe PMC"))

            val articles = body.resultList?.result ?: emptyList()
            val documents = articles.mapIndexedNotNull { index, article ->
                article.toDocumentEntity(sessionId, index)
            }

            // nextCursorMark is null when no more results
            val nextCursor = if (documents.size < batchSize) null else body.nextCursorMark

            Result.success(SearchResult(
                documents = documents,
                totalResults = body.hitCount ?: 0,
                nextCursor = nextCursor
            ))

        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Convert Europe PMC article to DocumentEntity.
     */
    private fun EuropePMCArticle.toDocumentEntity(sessionId: String, position: Int): DocumentEntity? {
        if (title.isNullOrBlank()) return null

        val isPreprint = source?.lowercase() in listOf("ppr", "preprint")

        return DocumentEntity(
            sessionId = sessionId,
            pmid = pmid,
            pmcId = pmcid,
            doi = doi,
            title = title,
            abstractText = abstractText,
            authors = parseAuthors(authorString),
            journal = journalTitle,
            publicationYear = pubYear?.toIntOrNull(),
            source = if (isPreprint) "preprint" else "europepmc",
            isPreprint = isPreprint,
            resultPosition = position
        )
    }

    /**
     * Parse author string into list.
     */
    private fun parseAuthors(authorString: String?): List<String> {
        if (authorString.isNullOrBlank()) return emptyList()
        return authorString.split(",")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
    }
}
```

### 3.5 Update NetworkModule

```kotlin
// di/NetworkModule.kt
package com.bmlibrarian.factchecker.di

import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCApi
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.llm.LLMApi
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedApi
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedService
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import retrofit2.converter.scalars.ScalarsConverterFactory
import java.util.concurrent.TimeUnit
import javax.inject.Named
import javax.inject.Singleton

/**
 * Hilt module providing network dependencies.
 */
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun provideOkHttpClient(): OkHttpClient {
        val loggingInterceptor = HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BODY
        }

        return OkHttpClient.Builder()
            .addInterceptor(loggingInterceptor)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS) // LLM calls can be slow
            .writeTimeout(60, TimeUnit.SECONDS)
            .build()
    }

    @Provides
    @Singleton
    fun provideLLMApi(client: OkHttpClient): LLMApi {
        // LLM API uses dynamic URLs, so base URL doesn't matter
        return Retrofit.Builder()
            .baseUrl("https://api.anthropic.com/") // Placeholder
            .client(client)
            .addConverterFactory(GsonConverterFactory.create())
            .build()
            .create(LLMApi::class.java)
    }

    @Provides
    @Singleton
    @Named("pubmed")
    fun providePubMedRetrofit(client: OkHttpClient): Retrofit {
        return Retrofit.Builder()
            .baseUrl(PubMedService.BASE_URL)
            .client(client)
            .addConverterFactory(ScalarsConverterFactory.create()) // For XML responses
            .addConverterFactory(GsonConverterFactory.create())
            .build()
    }

    @Provides
    @Singleton
    fun providePubMedApi(@Named("pubmed") retrofit: Retrofit): PubMedApi {
        return retrofit.create(PubMedApi::class.java)
    }

    @Provides
    @Singleton
    @Named("europepmc")
    fun provideEuropePMCRetrofit(client: OkHttpClient): Retrofit {
        return Retrofit.Builder()
            .baseUrl(EuropePMCService.BASE_URL)
            .client(client)
            .addConverterFactory(GsonConverterFactory.create())
            .build()
    }

    @Provides
    @Singleton
    fun provideEuropePMCApi(@Named("europepmc") retrofit: Retrofit): EuropePMCApi {
        return retrofit.create(EuropePMCApi::class.java)
    }
}
```

### 3.6 Add Scalars Converter Dependency

Add to `app/build.gradle.kts`:

```kotlin
implementation("com.squareup.retrofit2:converter-scalars:2.9.0")
```

## Verification Checklist

- [ ] LLMService can make chat completion requests
- [ ] LLMService handles all 7 providers correctly
- [ ] PubMedService returns valid search results
- [ ] PubMed XML parsing extracts all fields
- [ ] EuropePMCService returns valid search results
- [ ] Cursor-based pagination works for Europe PMC
- [ ] Error handling and retry logic work correctly
- [ ] Rate limiting is properly implemented

## Testing

### Unit Tests

```kotlin
// test/data/remote/llm/LLMServiceTest.kt
@Test
fun `parseScoreResponse extracts score and rationale`() {
    val json = """{"score": 4, "rationale": "Directly relevant to the claim"}"""
    val result = service.parseScoreResponse(json)
    assertEquals(4, result.first)
    assertEquals("Directly relevant to the claim", result.second)
}

@Test
fun `parseScoreResponse handles markdown code blocks`() {
    val json = """```json
    {"score": 3, "rationale": "Moderately relevant"}
    ```"""
    val result = service.parseScoreResponse(json)
    assertEquals(3, result.first)
}
```

### Integration Tests

```kotlin
// androidTest/data/remote/pubmed/PubMedServiceTest.kt
@Test
fun searchPubMed_returnsResults() = runTest {
    val result = pubMedService.search(
        query = "COVID-19 vaccine efficacy",
        sessionId = "test-session"
    )
    assertTrue(result.isSuccess)
    val searchResult = result.getOrNull()!!
    assertTrue(searchResult.documents.isNotEmpty())
    assertTrue(searchResult.totalResults > 0)
}
```

## Next Phase

Continue to [Phase 4: Workflow Engine](./04-workflow-engine.md)
