/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
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

package com.bmlibrarian.factchecker.util

/**
 * The context (`num_ctx`) an Ollama request is sent, sized to hold it (#760).
 *
 * Ollama's default context is 4,096 tokens on most machines, and by default a
 * prompt longer than the context is cut in the middle with no error, so a
 * 16,000-character analysis window plus its prompt could be read in part. The
 * app therefore sends every Ollama request a `num_ctx` sized from the prompt and
 * its token limit, plus `truncate: false` and `shift: false`, so that a prompt
 * which still does not fit is refused (HTTP 400) rather than cut.
 *
 * The size is rounded up to a power of two because each new `num_ctx` makes
 * Ollama reload the model; a run then uses only a few sizes. The shared contract
 * is `doc/cross_platform/llm_parity/ollama_context.json`.
 */
object OllamaContext {

    /**
     * The `num_ctx` to send a request.
     *
     * @param promptCodePoints Unicode code points across every message sent
     * @param maxTokens The most tokens the answer may take
     * @return The smallest power-of-two size, from [Constants.OLLAMA_MIN_NUM_CTX]
     *   up to [Constants.OLLAMA_MAX_NUM_CTX], that holds the estimated prompt
     *   tokens, the template allowance and [maxTokens]; or the maximum when
     *   none does (Ollama then refuses the request)
     */
    fun numCtx(promptCodePoints: Int, maxTokens: Int): Int {
        val perToken = Constants.OLLAMA_CHARS_PER_TOKEN
        val promptTokens = (promptCodePoints.coerceAtLeast(0).toLong() + perToken - 1) / perToken
        val needed = promptTokens + maxTokens.coerceAtLeast(0) + Constants.OLLAMA_TEMPLATE_TOKENS
        var size = Constants.OLLAMA_MIN_NUM_CTX
        while (size < needed && size < Constants.OLLAMA_MAX_NUM_CTX) {
            size *= 2
        }
        return size
    }

    /**
     * The `num_ctx` to send a conversation.
     *
     * @param contents Every message's text
     * @param maxTokens The most tokens the answer may take
     * @return [numCtx] over the messages' code points
     */
    fun numCtx(contents: List<String>, maxTokens: Int): Int =
        numCtx(contents.sumOf { it.codePointCount(0, it.length) }, maxTokens)

    /**
     * Ollama's native API root for a configured base URL.
     *
     * The app stores Ollama's OpenAI-compatible root (`http://host:11434/v1`); the
     * native API (`/api/chat`, `/api/tags`) sits beside it, so trailing slashes
     * and a final `/v1` are removed.
     *
     * @param baseUrl The configured base URL
     * @return The root to append `/api/...` to
     */
    fun nativeRoot(baseUrl: String): String = baseUrl.trimEnd('/').removeSuffix("/v1")
}
