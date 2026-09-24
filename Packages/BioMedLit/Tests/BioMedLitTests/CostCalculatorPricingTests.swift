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

import XCTest
@testable import BioMedLit

/// Tests that model pricing lookup is deterministic and picks the most specific match.
///
/// The lookup falls back to substring matching, and several keys match the same model
/// ID. It previously iterated the pricing dictionary directly, whose order Swift does
/// not define, so the price quoted for a model could differ between runs of the same
/// binary - by 3x for Claude Opus and 12x for GPT-5.2 Pro.
final class CostCalculatorPricingTests: XCTestCase {

    // Note: Swift seeds Dictionary hash order per process, so repeating a lookup within
    // one test run cannot detect order-dependence - it would pass either way. These
    // tests instead assert the property that order-dependence used to violate: for an
    // ID matched by several keys, the most specific key must win. Before the lookup was
    // sorted, each of these had roughly even odds of returning the wrong tier per run.

    func testMostSpecificKeyWinsForOverlappingModelIDs() {
        // "claude-opus-4-5-20251101" contains both "claude-opus-4-5" ($5/$25) and
        // "claude-opus-4" ($15/$75) - a threefold difference.
        let opus45 = CostCalculator.getPricing(for: "claude-opus-4-5-20251101")
        XCTAssertEqual(opus45.input, 5.00, accuracy: 0.0001)
        XCTAssertEqual(opus45.output, 25.00, accuracy: 0.0001)

        // "gpt-5.2-pro" also contains "gpt-5.2" and "gpt-5"; the full tier must win,
        // and it is twelvefold dearer than the one it would be confused with.
        let gpt52Pro = CostCalculator.getPricing(for: "gpt-5.2-pro")
        XCTAssertEqual(gpt52Pro.input, 21.00, accuracy: 0.0001)
        XCTAssertEqual(gpt52Pro.output, 168.00, accuracy: 0.0001)

        // "claude-sonnet-4-5-20250929" contains "claude-sonnet-4-5" and "claude-sonnet-4".
        let sonnet45 = CostCalculator.getPricing(for: "claude-sonnet-4-5-20250929")
        XCTAssertEqual(sonnet45.input, 3.00, accuracy: 0.0001)
        XCTAssertEqual(sonnet45.output, 15.00, accuracy: 0.0001)

        // "claude-opus-4-1" must not be captured by the shorter "claude-opus-4".
        let opus41 = CostCalculator.getPricing(for: "claude-opus-4-1")
        XCTAssertEqual(opus41.input, 15.00, accuracy: 0.0001)
        XCTAssertEqual(opus41.output, 75.00, accuracy: 0.0001)
    }

    func testDeepSeekV4ModelsArePriced() {
        // These IDs replaced the retired V3 ones and must resolve exactly, not by
        // falling through to the default placeholder.
        let flash = CostCalculator.getPricing(for: "deepseek-v4-flash")
        XCTAssertEqual(flash.input, 0.44, accuracy: 0.0001)
        XCTAssertEqual(flash.output, 1.32, accuracy: 0.0001)

        let pro = CostCalculator.getPricing(for: "deepseek-v4-pro")
        XCTAssertEqual(pro.input, 1.32, accuracy: 0.0001)
        XCTAssertEqual(pro.output, 3.96, accuracy: 0.0001)
    }

    func testCurrentClaudeModelsArePriced() {
        // Each of these used to miss every key and fall through to the $1/$3 default.
        let expected: [(id: String, input: Double, output: Double)] = [
            ("claude-fable-5-1", 10.00, 50.00),
            ("claude-opus-5-5", 4.00, 20.00),
            ("claude-opus-5", 5.00, 25.00),
            ("claude-sonnet-5", 2.00, 10.00),
            ("claude-haiku-4-5-20251001", 1.00, 5.00),
        ]
        for model in expected {
            let pricing = CostCalculator.getPricing(for: model.id)
            XCTAssertEqual(pricing.input, model.input, accuracy: 0.0001, model.id)
            XCTAssertEqual(pricing.output, model.output, accuracy: 0.0001, model.id)
        }
    }

    func testNewerOpus4IsNotCapturedByTheRetiredOpus4Rate() {
        // "claude-opus-4-8" contains "claude-opus-4" ($15/$75, threefold dearer).
        for id in ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8"] {
            let pricing = CostCalculator.getPricing(for: id)
            XCTAssertEqual(pricing.input, 5.00, accuracy: 0.0001, id)
            XCTAssertEqual(pricing.output, 25.00, accuracy: 0.0001, id)
        }
        // "claude-sonnet-4-6" contains "claude-sonnet-4"; same rate, but must match.
        XCTAssertEqual(CostCalculator.getPricing(for: "claude-sonnet-4-6").input, 3.00, accuracy: 0.0001)
    }

    func testUnlistedClaudeModelIsPricedByFamilyNotTheGenericDefault() {
        // A model released after this table was written must not be quoted at $1/$3.
        let sonnet = CostCalculator.getPricing(for: "claude-sonnet-6")
        XCTAssertEqual(sonnet.input, 3.00, accuracy: 0.0001)
        XCTAssertEqual(sonnet.output, 15.00, accuracy: 0.0001)

        let opus = CostCalculator.getPricing(for: "claude-opus-6")
        XCTAssertEqual(opus.input, 5.00, accuracy: 0.0001)
        XCTAssertEqual(opus.output, 25.00, accuracy: 0.0001)

        let unknownFamily = CostCalculator.getPricing(for: "claude-lyric-1")
        XCTAssertEqual(unknownFamily.input, 10.00, accuracy: 0.0001)
        XCTAssertEqual(unknownFamily.output, 50.00, accuracy: 0.0001)
    }

    func testUnknownNonClaudeModelKeepsGenericDefault() {
        // Control: the family fallback applies to Claude IDs only.
        let pricing = CostCalculator.getPricing(for: "some-unknown-model")
        XCTAssertEqual(pricing.input, 1.00, accuracy: 0.0001)
        XCTAssertEqual(pricing.output, 3.00, accuracy: 0.0001)
    }
}
