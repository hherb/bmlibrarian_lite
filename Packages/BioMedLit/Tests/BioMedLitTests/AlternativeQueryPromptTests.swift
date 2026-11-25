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

/// A later smart search round is told which alternative queries already ran.
final class AlternativeQueryPromptTests: XCTestCase {
    private func prompt(tried: [String]) -> String {
        PromptTemplates.alternativeQueries(context: .init(
            claim: "Aspirin prevents stroke", initialQuery: "aspirin AND stroke",
            totalResults: 4, relevantCount: 1, triedQueries: tried
        ))
    }

    func testTheFirstRoundNamesNoEarlierQueries() {
        let text = prompt(tried: [])
        XCTAssertFalse(text.contains("already run"))
        XCTAssertTrue(text.contains("Relevant documents: 1\n\nGenerate 2-3"), "the first round's prompt is unchanged")
    }

    func testALaterRoundListsTheQueriesAlreadyRun() {
        let text = prompt(tried: ["aspirin AND ischaemic stroke", "salicylate AND cerebrovascular"])
        XCTAssertTrue(text.contains("already run"))
        XCTAssertTrue(text.contains("- aspirin AND ischaemic stroke\n- salicylate AND cerebrovascular\n\nGenerate 2-3"))
    }
}

/// #819: the HyDE prompt asks for a search passage, not a study to invent.
final class HydePromptTests: XCTestCase {
    func testThePromptAsksForNoInventedStudyOrNumbers() {
        let text = PromptTemplates.hydeGeneration(claim: "Aspirin prevents stroke").lowercased()
        XCTAssertTrue(text.contains("aspirin prevents stroke"))
        XCTAssertFalse(text.contains("real published"))
        XCTAssertFalse(text.contains("with numbers"))
        XCTAssertTrue(text.contains("without numbers"))
    }
}
