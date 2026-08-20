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
}
