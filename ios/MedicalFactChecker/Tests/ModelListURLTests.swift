// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.


import Testing
import Foundation
@testable import MedicalFactChecker

// MARK: - Model List URL Tests

/// The settings screens pass `AppSettings.llmBaseURL`, which - like
/// `LLMProvider.baseURL` - already ends in `/v1`. Appending `v1/models` to it
/// requested `/v1/v1/models`, a 404, so no hosted provider's model list could load.
struct ModelListURLTests {
    @Test(arguments: [
        (LLMProvider.anthropic, "https://api.anthropic.com/v1/models"),
        (LLMProvider.openai, "https://api.openai.com/v1/models"),
        (LLMProvider.groq, "https://api.groq.com/openai/v1/models"),
        (LLMProvider.mistral, "https://api.mistral.ai/v1/models"),
        (LLMProvider.deepseek, "https://api.deepseek.com/v1/models"),
        (LLMProvider.ollama, "http://localhost:11434/api/tags"),
    ])
    func settingsBaseURLYieldsSingleVersionSegment(provider: LLMProvider, expected: String) throws {
        // Exactly what the settings screens pass: the provider's stored /v1 root.
        let url = try ModelFetchService.modelListURL(for: provider, baseURL: provider.baseURL)
        #expect(url.absoluteString == expected)
        #expect(!url.absoluteString.contains("/v1/v1"))
    }

    @Test(arguments: [LLMProvider.anthropic, .openai, .groq, .mistral, .deepseek, .ollama])
    func missingBaseURLMatchesProviderDefault(provider: LLMProvider) throws {
        let fromDefault = try ModelFetchService.modelListURL(for: provider, baseURL: nil)
        let fromBlank = try ModelFetchService.modelListURL(for: provider, baseURL: "  ")
        let fromSettings = try ModelFetchService.modelListURL(for: provider, baseURL: provider.baseURL)
        #expect(fromDefault == fromSettings)
        #expect(fromBlank == fromSettings)
    }

    @Test func trailingSlashIsTolerated() throws {
        let url = try ModelFetchService.modelListURL(for: .openai, baseURL: "https://api.openai.com/v1/")
        #expect(url.absoluteString == "https://api.openai.com/v1/models")
    }

    @Test func remoteOllamaHostKeepsHostAndDropsVersion() throws {
        let url = try ModelFetchService.modelListURL(for: .ollama, baseURL: "http://gpu-box:11434/v1/")
        #expect(url.absoluteString == "http://gpu-box:11434/api/tags")
    }

    @Test func anthropicRequestsFullPage() throws {
        let url = try ModelFetchService.anthropicModelListURL(baseURL: LLMProvider.anthropic.baseURL)
        #expect(url.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
    }

    @Test(arguments: ["not a url", "api.anthropic.com/v1", "ftp://example.com/v1"])
    func invalidBaseURLThrowsInsteadOfCrashing(baseURL: String) {
        #expect(throws: ModelFetchError.self) {
            try ModelFetchService.modelListURL(for: .anthropic, baseURL: baseURL)
        }
    }
}

// MARK: - Anthropic Recommendation Tests

/// The recommended model used to be pinned to "sonnet-4-5", which left newer
/// Sonnets unrecommended and would leave nothing recommended once 4.5 retires.
struct AnthropicRecommendationTests {
    @Test func newestSonnetIsRecommended() {
        let ids = ["claude-sonnet-5", "claude-sonnet-4-6", "claude-sonnet-4-5-20250929",
                   "claude-opus-5-5", "claude-haiku-4-5-20251001"].sorted(by: >)
        #expect(ModelFetchService.recommendedAnthropicModelID(among: ids) == "claude-sonnet-5")
    }

    @Test func noSonnetMeansNoRecommendation() {
        let ids = ["claude-opus-5-5", "claude-haiku-4-5-20251001"]
        #expect(ModelFetchService.recommendedAnthropicModelID(among: ids) == nil)
    }
}
