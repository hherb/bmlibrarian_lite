// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The context (`num_ctx`) an Ollama request is sent, sized to hold it (#760).
///
/// Ollama's default context is 4,096 tokens on most machines, and by default a
/// prompt longer than the context is cut in the middle with no error, so a
/// 16,000-character analysis window plus its prompt could be read in part. The
/// apps therefore send every Ollama request a `num_ctx` sized from the prompt
/// and its token limit, plus `truncate: false` and `shift: false`, so that a
/// prompt which still does not fit is refused (HTTP 400) rather than cut.
///
/// The size is rounded up to a power of two because each new `num_ctx` makes
/// Ollama reload the model; a run then uses only a few sizes. The shared
/// contract is `doc/cross_platform/llm_parity/ollama_context.json`.
public enum OllamaContext {
    /// The `num_ctx` to send a request.
    ///
    /// - Parameters:
    ///   - promptCodePoints: Unicode code points across every message sent.
    ///   - maxTokens: The most tokens the answer may take.
    /// - Returns: The smallest power-of-two size, from
    ///   ``BioMedLitConstants/ollamaMinNumCtx`` up to
    ///   ``BioMedLitConstants/ollamaMaxNumCtx``, that holds the estimated
    ///   prompt tokens, the template allowance and `maxTokens`.
    public static func numCtx(promptCodePoints: Int, maxTokens: Int) -> Int {
        let perToken = BioMedLitConstants.ollamaCharsPerToken
        let promptTokens = (max(0, promptCodePoints) + perToken - 1) / perToken
        let needed = promptTokens + max(0, maxTokens) + BioMedLitConstants.ollamaTemplateTokens
        var size = BioMedLitConstants.ollamaMinNumCtx
        while size < needed && size < BioMedLitConstants.ollamaMaxNumCtx {
            size *= 2
        }
        return size
    }

    /// The `num_ctx` to send a conversation.
    ///
    /// - Parameters:
    ///   - contents: Every message's text.
    ///   - maxTokens: The most tokens the answer may take.
    /// - Returns: ``numCtx(promptCodePoints:maxTokens:)`` over the messages' code points.
    public static func numCtx(contents: [String], maxTokens: Int) -> Int {
        numCtx(promptCodePoints: contents.reduce(0) { $0 + $1.unicodeScalars.count }, maxTokens: maxTokens)
    }

    /// Ollama's native API root for a configured base URL.
    ///
    /// The apps store Ollama's OpenAI-compatible root (`http://host:11434/v1`);
    /// the native API (`/api/chat`, `/api/tags`) sits beside it, so trailing
    /// slashes and a final `/v1` are removed.
    ///
    /// - Parameter baseURL: The configured base URL.
    /// - Returns: The root to append `api/...` to.
    public static func nativeRoot(_ baseURL: String) -> String {
        var root = baseURL
        while root.hasSuffix("/") {
            root.removeLast()
        }
        if root.hasSuffix("/v1") {
            root.removeLast(3)
        }
        return root
    }
}
