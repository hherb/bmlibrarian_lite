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
import BioMedLit
@testable import MedicalFactChecker

// MARK: - DeepSeek Model Catalog Tests

/// DeepSeek retired the `deepseek-chat` / `deepseek-reasoner` IDs in July 2026
/// and now serves `deepseek-v4-flash` / `deepseek-v4-pro`.
/// See https://api-docs.deepseek.com/quick_start/pricing
struct DeepSeekModelFilterTests {
    @Test func acceptsCurrentModelIDs() {
        #expect(ModelFetchService.isUsableDeepSeekModel("deepseek-v4-flash"))
        #expect(ModelFetchService.isUsableDeepSeekModel("deepseek-v4-pro"))
    }

    @Test func acceptsFutureGenerations() {
        // The filter must not need a code change every time DeepSeek renames its line-up.
        #expect(ModelFetchService.isUsableDeepSeekModel("deepseek-v5-flash"))
    }

    @Test func rejectsNonChatModels() {
        #expect(!ModelFetchService.isUsableDeepSeekModel("deepseek-embedding"))
        #expect(!ModelFetchService.isUsableDeepSeekModel("deepseek-reranker"))
        #expect(!ModelFetchService.isUsableDeepSeekModel(""))
    }
}

struct DeepSeekModelNameTests {
    @Test func formatsVersionedNames() {
        #expect(ModelFetchService.formatDeepSeekModelName("deepseek-v4-flash") == "DeepSeek V4 Flash")
        #expect(ModelFetchService.formatDeepSeekModelName("deepseek-v4-pro") == "DeepSeek V4 Pro")
    }

    @Test func passesThroughUnprefixedIDs() {
        #expect(ModelFetchService.formatDeepSeekModelName("some-other-model") == "some-other-model")
    }
}

struct DeepSeekPricingTests {
    /// Peak-hour cache-miss rates per 1M tokens (August 2026).
    @Test func currentModelPricing() {
        let flash = ModelFetchService.getDeepSeekPricing(for: "deepseek-v4-flash")
        #expect(flash.input == 0.44)
        #expect(flash.output == 1.32)

        let pro = ModelFetchService.getDeepSeekPricing(for: "deepseek-v4-pro")
        #expect(pro.input == 1.32)
        #expect(pro.output == 3.96)
    }

    @Test func costCalculatorKnowsCurrentModels() {
        // 1M input + 1M output tokens on Flash = 0.44 + 1.32
        let flashCost = CostCalculator.calculateCost(
            model: "deepseek-v4-flash",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000
        )
        #expect(abs(flashCost - 1.76) < 0.0001)

        let proCost = CostCalculator.calculateCost(
            model: "deepseek-v4-pro",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000
        )
        #expect(abs(proCost - 5.28) < 0.0001)
    }
}

struct DeepSeekFallbackModelTests {
    @Test func fallbackModelsAreCurrent() {
        let ids = LLMProvider.deepseek.fallbackModels.map(\.id)
        #expect(ids == ["deepseek-v4-flash", "deepseek-v4-pro"])
    }

    @Test func defaultModelIsFlash() {
        #expect(LLMProvider.deepseek.defaultModel?.id == "deepseek-v4-flash")
    }
}

// MARK: - Model Selection Tests

/// A stored model ID outlives the model itself: DeepSeek users carry
/// `deepseek-chat` in UserDefaults long after it stopped being served.
struct ModelSelectionTests {
    private let models = LLMProvider.deepseek.fallbackModels

    @Test func keepsSelectionTheProviderStillOffers() {
        #expect(LLMModel.resolveSelection(current: "deepseek-v4-pro", available: models) == "deepseek-v4-pro")
    }

    @Test func replacesRetiredSelectionWithRecommended() {
        #expect(LLMModel.resolveSelection(current: "deepseek-chat", available: models) == "deepseek-v4-flash")
    }

    @Test func fallsBackToFirstWhenNoneRecommended() {
        let unranked = [
            LLMModel(id: "a", displayName: "A", description: "", inputPrice: 0, outputPrice: 0),
            LLMModel(id: "b", displayName: "B", description: "", inputPrice: 0, outputPrice: 0),
        ]
        #expect(LLMModel.resolveSelection(current: "retired", available: unranked) == "a")
    }

    @Test func keepsSelectionWhenLineUpIsUnknown() {
        // An empty list means "we could not ask the provider", not "no models exist".
        #expect(LLMModel.resolveSelection(current: "hand-typed-model", available: []) == "hand-typed-model")
    }
}

// MARK: - Manual Model Entry Tests

struct ManualModelEntryTests {
    @Test func hostedProvidersOwnTheirCatalogue() {
        #expect(!LLMProvider.deepseek.allowsManualModelEntry)
        #expect(!LLMProvider.anthropic.allowsManualModelEntry)
        #expect(!LLMProvider.openai.allowsManualModelEntry)
        #expect(!LLMProvider.groq.allowsManualModelEntry)
        #expect(!LLMProvider.mistral.allowsManualModelEntry)
    }

    @Test func selfHostedProvidersAcceptAnyName() {
        #expect(LLMProvider.ollama.allowsManualModelEntry)
        #expect(LLMProvider.custom.allowsManualModelEntry)
    }
}

// MARK: - Thinking Mode Tests

/// DeepSeek V4 enables chain-of-thought by default, which spends output tokens on
/// reasoning and makes `temperature` a no-op.
/// See https://api-docs.deepseek.com/guides/thinking_mode/
struct ThinkingModeTests {
    private let url = URL(string: "https://api.deepseek.com/v1")!

    @Test func deepSeekOptsOutOfThinking() async {
        let service = LLMService(baseURL: url, apiKey: "k", model: "deepseek-v4-flash", provider: .deepseek)
        #expect(await service.thinkingConfig?.type == "disabled")
    }

    @Test func otherProvidersAreSentNoThinkingField() async {
        // Providers that do not know the field may reject the whole request.
        for provider in [LLMProvider.anthropic, .openai, .groq, .mistral, .ollama, .custom] {
            let service = LLMService(baseURL: url, apiKey: "k", model: "m", provider: provider)
            #expect(await service.thinkingConfig == nil)
        }
    }

    @Test func nilThinkingIsOmittedFromTheRequestBody() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let plain = ChatCompletionRequest(
            model: "gpt-4o-mini",
            messages: [LLMService.userMessage("hi")],
            temperature: 0.1,
            maxTokens: 10,
            responseFormat: nil,
            thinking: nil
        )
        let plainJSON = String(decoding: try encoder.encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("thinking"))

        let deepSeek = ChatCompletionRequest(
            model: "deepseek-v4-flash",
            messages: [LLMService.userMessage("hi")],
            temperature: 0.1,
            maxTokens: 10,
            responseFormat: nil,
            thinking: .disabled
        )
        let deepSeekJSON = String(decoding: try encoder.encode(deepSeek), as: UTF8.self)
        #expect(deepSeekJSON.contains("\"thinking\":{\"type\":\"disabled\"}"))
    }
}

// MARK: - Model Fetch Error Tests

/// The whole point of threading the HTTP status through `ModelFetchError` is that the
/// user sees it, so the rendered message is what needs pinning.
struct ModelFetchErrorTests {
    @Test func apiErrorReportsTheHTTPStatus() {
        let message = ModelFetchError.apiError(statusCode: 503).errorDescription ?? ""
        #expect(message.contains("503"))
    }

    @Test func rejectedCredentialsSayToCheckTheKey() {
        // A 401 is the most actionable failure here, and reads identically to a 503
        // unless it is called out.
        for status in [401, 403] {
            let message = ModelFetchError.apiError(statusCode: status).errorDescription ?? ""
            #expect(message.contains("\(status)"))
            #expect(message.lowercased().contains("api key"))
        }
    }

    @Test func aNonHTTPResponseIsNotReportedAsAStatusCode() {
        // Previously this surfaced as "HTTP 0", which is not a status and left the user
        // with nothing to act on.
        let message = ModelFetchError.invalidResponse.errorDescription ?? ""
        #expect(!message.contains("0"))
        #expect(message.lowercased().contains("base url"))
    }
}

// MARK: - Unlisted Model Tests

/// A stored model the provider no longer offers must stay visible rather than being
/// swapped for a healthy-looking one that the app is not going to send.
struct UnlistedModelTests {
    @Test func retiredModelIsLabelledAndHasNoPrice() {
        let stale = LLMModel.notListed(id: "deepseek-chat", provider: .deepseek)

        #expect(stale.id == "deepseek-chat")
        #expect(stale.displayName.contains("deepseek-chat"))
        #expect(stale.isUnavailable)
        // Zero prices must not be read as "free" - the price is unknown, not nothing.
        #expect(stale.priceDescription != "Free (local)")
    }

    @Test func handTypedLocalNameIsNotFlaggedAsRetired() {
        // Ollama accepts any name the user types; absence from the catalogue is
        // expected there, not a retirement, and a local model really is free.
        let manual = LLMModel.notListed(id: "my-local-model", provider: .ollama)

        #expect(manual.displayName == "my-local-model")
        #expect(!manual.isUnavailable)
        #expect(manual.priceDescription == "Free (local)")
    }

    @Test func customEndpointModelIsUnpricedRatherThanFree() {
        // A custom endpoint is usually a paid third party. Reporting it as free would
        // understate what a run costs, which is the opposite of the intended bias.
        let custom = LLMModel.notListed(id: "some-hosted-model", provider: .custom)

        #expect(custom.displayName == "some-hosted-model")
        #expect(custom.priceDescription != "Free (local)")
    }
}

// MARK: - DeepSeek Pricing Fallback Tests

struct DeepSeekPricingFallbackTests {
    @Test func unknownNonFlashIDsGetTheFlagshipRate() {
        // Deliberate: an estimate that is too high is safer than one that is too low.
        let pricing = ModelFetchService.getDeepSeekPricing(for: "deepseek-v5-ultra")
        #expect(pricing.input == 1.32)
        #expect(pricing.output == 3.96)
    }

    @Test func aFutureFlashTierIsPricedAsV4Flash() {
        // Documents the one case where the "never understates" rule does not hold, so
        // the table gets revisited when a new generation ships.
        let pricing = ModelFetchService.getDeepSeekPricing(for: "deepseek-v5-flash")
        #expect(pricing.input == 0.44)
        #expect(pricing.output == 1.32)
    }
}
