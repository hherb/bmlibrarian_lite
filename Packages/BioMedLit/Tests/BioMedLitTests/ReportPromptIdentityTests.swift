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

/// What the report prompt shows the model a document identity looks like.
///
/// The prompt tells the model to copy each ID exactly from the `ID:` field and
/// then demonstrates the format with an example. The example has to match the
/// identities the app actually issues, or the two instructions contradict each
/// other and the model is free to follow the one it was shown.
final class ReportPromptIdentityTests: XCTestCase {
    private var prompt: String {
        PromptTemplates.reportGeneration(
            context: PromptTemplates.ReportContext(
                claim: "Perindopril reduces arterial stiffness",
                citationsText: "[1] ID: 8A1D4C22-0000-4000-8000-000000000001\n",
                citationCount: 1,
                documentCount: 1
            )
        )
    }

    /// The example must not present an identity that looks like a PubMed ID.
    ///
    /// It showed `[Smith et al., 2021](doc:pmid-12345678)`, from when a document
    /// was identified as `pmid-<primary slot>`. That slot also holds Europe PMC
    /// thesis accessions, which are bare decimals (#212), and a model shown that
    /// shape is being invited to write "PMID 12345678" into the prose itself —
    /// where no later renderer can tell it was never a PubMed ID.
    func testTheCitationExampleShowsNoPubMedShapedIdentity() {
        XCTAssertFalse(prompt.contains("doc:pmid-"), prompt)
    }

    /// The example is a UUID, which is what the app actually issues.
    ///
    /// Asserting only the absence of `doc:pmid-` passes if the example is
    /// deleted, or replaced with `doc:PMC123`, or with a bare `doc:12345678` —
    /// the same defect wearing a different costume. This pins the shape that is
    /// meant to be there rather than one of the shapes that is not.
    func testTheCitationExampleShowsAUUIDShapedIdentity() {
        let example = prompt
            .split(separator: "\n")
            .first { $0.contains("Example:") }

        let exampleLine = try? XCTUnwrap(example, "prompt carries no citation example")
        guard let exampleLine else { return }

        let target = exampleLine
            .split(separator: "(doc:")
            .last?
            .prefix { $0 != ")" }
        XCTAssertNotNil(target, String(exampleLine))
        XCTAssertNotNil(
            UUID(uuidString: String(target ?? "")),
            "citation example target is not a UUID: \(exampleLine)"
        )
    }

    /// A UUID reaches the model unchanged in the `ID:` field it is told to copy.
    ///
    /// The example and the field are two halves of one contract; pinning only
    /// the example leaves the producing side free to drift.
    func testAnIdentityReachesThePromptVerbatim() {
        let identity = UUID().uuidString
        let citations = ReportFormatter.formatCitationsForPrompt([
            ReportFormatter.CitationData(
                documentId: identity,
                authors: "Smith et al.",
                year: 2016,
                title: "A trial",
                passage: "It helped."
            )
        ])

        XCTAssertTrue(citations.contains("ID: \(identity)"), citations)
    }

    /// The instruction the example illustrates is still there: the model copies
    /// an ID rather than composing one.
    func testTheModelIsStillToldToCopyTheIdentityVerbatim() {
        XCTAssertTrue(prompt.contains("(doc:ID)"), prompt)
        XCTAssertTrue(prompt.contains("Do NOT invent or modify IDs"), prompt)
    }
}
