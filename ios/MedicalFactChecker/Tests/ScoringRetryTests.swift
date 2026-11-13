// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import BioMedLit
import Foundation
import Testing
@testable import MedicalFactChecker

/// #761: a scoring retry follows an unreadable reply, so it asks with the
/// correction note instead of re-sending the identical request.
struct ScoringRetryTests {
    @Test func theFirstAttemptAsksAsWritten() {
        let sent = ParallelScoringService.scoringMessages("task", attempt: 0)
        #expect(sent.map(\.role) == ["user"])
        #expect(sent.map(\.content) == ["task"])
    }

    @Test func everyLaterAttemptCarriesTheNote() {
        for attempt in 1...2 {
            let sent = ParallelScoringService.scoringMessages("task", attempt: attempt)
            #expect(sent.map(\.role) == ["user"])
            #expect(sent.map(\.content) == ["task\n\n\(ResponseParser.jsonCorrectionNote)"])
        }
    }
}
