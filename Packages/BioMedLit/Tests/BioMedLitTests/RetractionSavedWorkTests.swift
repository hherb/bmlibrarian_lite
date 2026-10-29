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

/// A reopened session's knowledge since its run: an outage never replaces a
/// decided check, and only a cited paper's change for the worse warns.
final class RetractionSavedWorkTests: XCTestCase {
    private let run = Date(timeIntervalSince1970: 1_792_315_800) // 2026-10-18 09:30 UTC
    private var later: Date { run.addingTimeInterval(86_400) }

    private func check(_ status: String, at date: Date) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: status, deciding: nil, unanswered: status == "unchecked" ? ["crossref"] : [],
            checkedAt: date, exportDataAsOf: nil, crossrefFailure: nil)
    }

    func testLatestPrefersTheNewestDecidedCheck() {
        XCTAssertNil(RetractionSavedWork.latest([]))
        let decided = check("clear", at: run)
        XCTAssertEqual(RetractionSavedWork.latest([decided, check("unchecked", at: later)]), decided)
        XCTAssertEqual(RetractionSavedWork.latest([decided, check("retracted", at: later)])?.status, "retracted")
        XCTAssertEqual(RetractionSavedWork.latest([check("unchecked", at: later)])?.status, "unchecked")
    }

    func testRecheckedChecksKeepTheRunAgainstAnOutage() {
        let rows = RetractionSavedWork.recheckedChecks(
            run: ["a": check("clear", at: run), "b": check("unchecked", at: run), "c": check("clear", at: run)],
            stored: ["a": check("unchecked", at: later), "b": check("retracted", at: later),
                     "c": check("clear", at: run.addingTimeInterval(-1)), "x": check("retracted", at: later)])
        XCTAssertEqual(rows["a"]?.status, "clear", "an outage is not knowledge")
        XCTAssertEqual(rows["b"]?.status, "retracted", "a newer answer replaces the run's")
        XCTAssertEqual(rows["c"]?.checkedAt, run, "an older stored check never does")
        XCTAssertNil(rows["x"], "a document the run did not check gets no row")
        let predating = RetractionSavedWork.recheckedChecks(run: [:], stored: ["x": check("clear", at: later)])
        XCTAssertEqual(predating["x"]?.status, "clear", "a run that recorded none reads the stored checks")
    }

    func testOnlyACitedPapersChangeForTheWorseWarns() {
        let runChecks = ["a": check("clear", at: run), "b": check("retracted", at: run), "c": check("clear", at: run)]
        let latest = [
            "a": check("retracted", at: later),             // worse: warns
            "b": check("retracted", at: later),             // what the run saw already
            "c": check("concern", at: run.addingTimeInterval(-1)), // older than the run's
            "d": check("concern", at: later),               // never checked by the run: news
            "e": check("retracted", at: later),             // not cited
        ]
        XCTAssertEqual(
            RetractionSavedWork.changedSinceRun(run: runChecks, latest: latest, cited: ["d", "a", "b", "c"]),
            ["d", "a"])
    }

    /// A run whose check got no answer (a failed check carries its attempt's
    /// time) knew nothing: a retraction known before it is still news.
    func testAnUncheckedRunRowIsNoCheckTime() {
        let older = run.addingTimeInterval(-86_400)
        XCTAssertEqual(
            RetractionSavedWork.changedSinceRun(
                run: ["a": check("unchecked", at: run), "b": check("clear", at: run)],
                latest: ["a": check("retracted", at: older), "b": check("retracted", at: older)],
                cited: ["a", "b"]),
            ["a"], "control: a decided run row older than the warning still anchors it")
    }
}
