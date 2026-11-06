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

import Foundation
import BioMedLit

/// What one run's retraction screen has used, in the order it met the
/// documents, and the papers whose check failed.
struct RetractionRun {
    /// The piece of work (``FactCheckWorkflow``'s run generation) this screen belongs to.
    let generation: Int
    var used: [(id: String, paper: RetractionPaper, check: PaperRetractionCheck)] = []
    var failed: Set<RetractionPaper> = []

    /// The used checks of the papers not left out as retracted.
    private var kept: [(id: String, paper: RetractionPaper, check: PaperRetractionCheck)] {
        used.filter { !$0.check.isRetracted }
    }

    /// Why the kept papers are unchecked, for the run's notice and the report's.
    var causes: [String] {
        RetractionText.uncheckedCauses(kept.map { (paper: $0.paper, check: Optional($0.check)) }, failed: failed)
    }

    /// "Retraction check: <the desktop's run summary clause>.", or `nil`.
    var notice: String? {
        let kept = kept
        let clause = RetractionText.runSummaryClause(
            excluded: used.count - kept.count,
            unchecked: kept.filter { $0.check.isUnchecked }.count,
            causes: causes
        )
        return clause.map { "Retraction check: \($0)." }
    }
}
