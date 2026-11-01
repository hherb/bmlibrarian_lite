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

/// What a reopened session knows about its papers since its run, worked out
/// from the checks the run used (its snapshot, never rewritten) and the checks
/// stored since (the desktop's `latest_checks`, `rechecked_snapshot` and
/// `changed_since_snapshot` in `retraction_screen.py`).
///
/// The snapshot keeps what the run saw, as the desktop's `run_status` does;
/// *Check again* writes only the stored checks.
public enum RetractionSavedWork {
    /// A paper's latest knowledge among its stored checks: the newest decided
    /// one (retracted, concern, clear), else the newest. An unchecked check
    /// never replaces a decided one: an outage is not knowledge.
    public static func latest(_ checks: [PaperRetractionCheck]) -> PaperRetractionCheck? {
        let decided = checks.filter { !$0.isUnchecked }
        return (decided.isEmpty ? checks : decided).max { $0.checkedAt < $1.checkedAt }
    }

    /// The checks a reopened session's line is read from: each the run's,
    /// unless the document's stored check is newer and is not an unchecked one
    /// over a decided one. A session whose run recorded none (it predates the
    /// check) reads the stored checks alone, as does a scored paper the run
    /// has no check of (Find More Evidence on such a session, #684); one with
    /// no stored check either is unchecked, as in the report written again (#685).
    ///
    /// - Parameters:
    ///   - run: The checks the run used, by document id.
    ///   - stored: Each of the session's documents' stored check, by document id.
    ///   - scored: The session's scored documents' ids.
    /// - Returns: The checks, by document id.
    public static func recheckedChecks(
        run: [String: PaperRetractionCheck], stored: [String: PaperRetractionCheck], scored: Set<String> = []
    ) -> [String: PaperRetractionCheck] {
        guard !run.isEmpty else { return stored }
        let checks = run.merging(stored.filter { run[$0.key] != nil || scored.contains($0.key) }) { old, new in
            rechecked(old, stored: new)
        }
        // an unchecked check's time is no check time, so the stand-in's never shows
        return checks.merging(scored.map { ($0, PaperRetractionCheck.failed(at: .distantPast)) }) { kept, _ in kept }
    }

    /// One paper's check since its run: `stored` when it is newer than `run`
    /// and is not an unchecked one over a decided one, else `run`.
    public static func rechecked(_ run: PaperRetractionCheck, stored: PaperRetractionCheck) -> PaperRetractionCheck {
        stored.checkedAt > run.checkedAt && !(stored.isUnchecked && !run.isUnchecked) ? stored : run
    }

    /// The cited papers whose status changed for the worse since the run:
    /// the latest check is no older than the run's, says retracted or concern,
    /// and the run saw another status. A paper the run never checked, or
    /// checked without an answer, warns whenever its latest check does: an
    /// unchecked check's time is no check time (as the desktop's failed row
    /// has none), so an older retraction known elsewhere is still news.
    ///
    /// - Parameters:
    ///   - run: The checks the run used, by document id.
    ///   - latest: Each cited paper's latest check, by document id.
    ///   - cited: The documents the report cites, in the order to warn in.
    /// - Returns: The changed documents' ids, in `cited`'s order.
    public static func changedSinceRun(
        run: [String: PaperRetractionCheck], latest: [String: PaperRetractionCheck], cited: [String]
    ) -> [String] {
        cited.filter { id in
            guard let check = latest[id], check.isRetracted || check.isConcern else { return false }
            guard let seen = run[id], !seen.isUnchecked else { return true }
            return check.checkedAt >= seen.checkedAt && check.status != seen.status
        }
    }
}
