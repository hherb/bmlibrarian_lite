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
import BmlibCore

/// The reader-facing sentences about retraction, worded as the desktop's
/// `retraction_text.py` words them (golden rule 13: no provider text; a
/// failed lookup speaks only through `RequestFailure.describe()`, which
/// ``PaperRetractionCheck/crossrefFailure`` already holds).
///
/// The badge texts live in the app's `RetractionBadge`; the export refresh
/// lines have no counterpart, since the app has no `bmll`. Not ported:
/// `NO_AUDIT_RECORD_LINE`, `without_retraction_notice` and the desktop's
/// pass dialog texts (`retraction_check_line`, `pass_retraction_note`,
/// `with_pass_retraction_clause`, `PASS_LEFT_OUT_SENTENCE`).
public enum RetractionText {
    /// Heading of the report's section for the papers a run left out.
    public static let leftOutHeading = "## Left out as retracted"

    private static let failedCause = "the check failed"
    /// Replaces the desktop's `bmll retractions-update` hint: the app downloads the data itself.
    private static let exportCause = "the Retraction Watch data could not be used (it downloads over Wi-Fi)"
    private static let exportNoticeCause = "a Retraction Watch notice could not be read"
    private static let noIDsCause = "no DOI or PMID"
    private static let noDOICause = "no DOI, which Crossref needs"
    private static let crossrefSilentCause = "Crossref had no usable answer for the DOI"
    private static let cancelledCause = "the check was cancelled before reaching them"
    private static let pubmedLabel = " (PubMed's label)"
    private static let concernIndent = "    "
    private static let sourceNames = ["retraction_watch_export": "Retraction Watch", "crossref": "Crossref"]

    /// Why the kept papers are unchecked, each cause once, in the desktop's order:
    /// the check failed, the Retraction Watch data (absent, then a notice
    /// unreadable), Crossref (its distinct failures joined, then no DOI, then
    /// no usable answer), no identifiers, cancelled.
    ///
    /// - Parameters:
    ///   - papers: Each kept paper and its check; `nil` when the check never reached it.
    ///   - failed: The papers whose check failed at run time.
    /// - Returns: The causes; empty when no paper is unchecked.
    public static func uncheckedCauses(
        _ papers: [(paper: RetractionPaper, check: PaperRetractionCheck?)], failed: Set<RetractionPaper>
    ) -> [String] {
        var found: Set<String> = []
        var crossref: [String] = []
        for (paper, check) in papers {
            if failed.contains(paper) {
                if check?.isUnchecked ?? true { found.insert(failedCause) }
                continue
            }
            guard let check else { found.insert(cancelledCause); continue }
            guard check.isUnchecked else { continue }
            let doiKey = paper.doi.flatMap(RetractionChecker.doiKey)
            if doiKey == nil && paper.pmid.flatMap({ PMID.canonical($0).pmid }) == nil {
                found.insert(noIDsCause)
                continue
            }
            if check.leftUnanswered(.retractionWatchExport) {
                found.insert(check.exportDataAsOf == nil ? exportCause : exportNoticeCause)
            }
            if check.leftUnanswered(.crossref) {
                if let failure = check.crossrefFailure {
                    if !crossref.contains(failure) { crossref.append(failure) }
                } else {
                    found.insert(doiKey == nil ? noDOICause : crossrefSilentCause)
                }
            }
        }
        var causes = [failedCause, exportCause, exportNoticeCause].filter(found.contains)
        if !crossref.isEmpty { causes.append("Crossref could not be used (\(crossref.joined(separator: ", ")))") }
        return causes + [noDOICause, crossrefSilentCause, noIDsCause, cancelledCause].filter(found.contains)
    }

    /// A run's summary clause, naming why papers are unchecked.
    ///
    /// - Parameters:
    ///   - excluded: Papers left out as retracted.
    ///   - unchecked: Kept papers whose status could not be checked.
    ///   - causes: ``uncheckedCauses(_:failed:)``; empty for a restored snapshot, which records none.
    /// - Returns: The clause; `nil` when both counts are 0.
    public static func runSummaryClause(excluded: Int, unchecked: Int, causes: [String]) -> String? {
        var parts: [String] = []
        if excluded > 0 {
            parts.append("\(grouped(excluded)) \(excluded == 1 ? "retracted paper" : "retracted papers") left out")
        }
        if unchecked > 0 {
            let owner = unchecked == 1 ? "1 paper's" : "\(grouped(unchecked)) papers'"
            let clause = "\(owner) retraction status could not be checked"
            parts.append(causes.isEmpty ? clause : "\(clause): \(causes.joined(separator: "; "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// One paper's status, for a banner: the deciding notice's date and DOI
    /// (or "(PubMed's label)"), the unanswered sources, or "No retraction
    /// found"; then the Retraction Watch data's day when it was consulted.
    public static func paperStatusLine(_ check: PaperRetractionCheck) -> String {
        var line: String
        if check.isRetracted || check.isConcern {
            line = check.isRetracted ? "Retracted" : "Expression of concern"
            // the label, not a notice: a notice without a DOI is still Retraction Watch's or Crossref's
            if check.deciding == nil || check.isDecidedByLabel {
                line += pubmedLabel
            } else if let evidence = check.deciding {
                if let date = evidence.date, !date.isEmpty { line += check.isRetracted ? " on \(date)" : ", \(date)" }
                if let notice = evidence.noticeDOI, !notice.isEmpty { line += " (notice \(notice))" }
            }
        } else if check.isUnchecked {
            let names = check.unanswered.map { lookup -> String in
                let name = sourceNames[lookup] ?? lookup
                guard lookup == "crossref", let failure = check.crossrefFailure else { return name }
                return "\(name) (\(failure))"
            }
            line = "Retraction status not checked"
            if !names.isEmpty { line += ": " + names.joined(separator: ", ") }
        } else {
            line = "No retraction found"
        }
        if let asOf = check.exportDataAsOf { line += "; Retraction Watch data as of \(asOf)" }
        return line
    }

    /// When the status was checked (the UTC date), or that it never was.
    public static func checkedOnLine(_ date: Date?) -> String {
        guard let date else { return "Retraction status never checked" }
        return "Retraction status checked \(isoDay(date))"
    }

    /// The report's methods line: when the run's status was checked and how
    /// many kept papers were not. A run that held papers and decided none
    /// (`checkedAt == nil`) says it could not check, never a date.
    ///
    /// - Parameters:
    ///   - checkedAt: The oldest check time among decided papers, or `nil`.
    ///   - notChecked: Kept papers that could not be checked.
    ///   - heldPapers: Whether the run held any paper to check.
    public static func methodsLine(checkedAt: Date?, notChecked: Int, heldPapers: Bool) -> String {
        guard let checkedAt else {
            return heldPapers ? "Retraction status could not be checked" : checkedOnLine(nil)
        }
        var line = checkedOnLine(checkedAt)
        if notChecked > 0 { line += "; \(notChecked == 1 ? "1 paper" : "\(grouped(notChecked)) papers") could not be checked" }
        return line
    }

    /// The report's opening notice (the desktop's `format_retraction_notice`):
    /// "> **Retraction check:** <clause>.".
    public static func reportNotice(_ clause: String) -> String { "\(noticeOpening)\(clause)." }
    /// How the report's notice opens (the desktop's `_NOTICE_OPENING`).
    static let noticeOpening = "> **Retraction check:** "

    /// A reopened session's line (the desktop's `saved_work_line`): when its
    /// decided papers were checked (the oldest), and how many were not;
    /// "could not be checked" when none is decided, "never checked" for none.
    public static func savedWorkLine(_ checks: [PaperRetractionCheck]) -> String {
        methodsLine(
            checkedAt: checks.filter { !$0.isUnchecked }.map(\.checkedAt).min(),
            notChecked: checks.filter(\.isUnchecked).count, heldPapers: !checks.isEmpty)
    }

    /// The button that checks a reopened session's papers again.
    public static let checkAgainLabel = "Check again"
    /// The saved-work line while *Check again* runs.
    public static let checkingAgainLine = "Checking retraction status…"
    /// Added to the saved-work line when *Check again* failed.
    public static let checkAgainFailed = "; it could not be checked again, so this is still the run's record"
    /// Added to the saved-work line when the stored checks could not be read.
    public static let storedChecksUnread = "; later checks could not be read"
    /// Added to the saved-work line when *Check again*'s answers could not be saved.
    public static let checkAgainNotSaved = "; the new status could not be saved with this run"

    /// *Check again*'s note for decided papers no source answered this time,
    /// whose record stays; `""` for none.
    public static func notCheckedAgainClause(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return "; \(count == 1 ? "1 paper" : "\(grouped(count)) papers") could not be checked again"
    }

    /// Warns that papers a saved report cites are now retracted or under
    /// concern (the desktop's `saved_work_warning`), one paper per line. It
    /// suggests re-running the question; the report is not rewritten.
    ///
    /// - Parameter changed: Each paper's title and latest check.
    /// - Returns: The warning; `nil` when nothing changed.
    public static func savedWorkWarning(_ changed: [(title: String, check: PaperRetractionCheck)]) -> String? {
        guard !changed.isEmpty else { return nil }
        let subject = changed.count == 1
            ? "1 paper this report cites has" : "\(grouped(changed.count)) papers this report cites have"
        let papers = changed.map { paper in
            "• \(paper.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")): \(paperStatusLine(paper.check))"
        }
        return (["Since this report was written, \(subject) a retraction warning:"] + papers
            + ["The report has not been changed; re-run the question to bring it up to date."])
            .joined(separator: "\n")
    }

    /// A left-out paper's line (the desktop's `excluded_line`): why the run
    /// left it out, then its status now when that differs.
    ///
    /// - Parameters:
    ///   - runCheck: The check the run used.
    ///   - current: The latest check (*Check again*'s, or the run's own).
    public static func excludedLine(runCheck: PaperRetractionCheck, current: PaperRetractionCheck) -> String {
        let line = "Excluded: retracted. \(paperStatusLine(runCheck))"
        let now = paperStatusLine(current)
        return now == paperStatusLine(runCheck) ? line : "\(line). Checked again: \(now)"
    }

    /// One entry of the left-out section: "- <title>. Retracted <date>; notice <doi>",
    /// or "Retracted (PubMed's label)". The title is escaped for markdown.
    public static func leftOutEntry(title: String, check: PaperRetractionCheck) -> String {
        var line = "- \(plainTitle(title)). Retracted"
        if check.deciding == nil || check.isDecidedByLabel {
            line += pubmedLabel
        } else if let evidence = check.deciding {
            if let date = evidence.date, !date.isEmpty { line += " \(date)" }
            if let notice = evidence.noticeDOI, !notice.isEmpty { line += "; notice \(notice)" }
        }
        return line
    }

    /// The caveat under a cited paper that stands under an expression of concern.
    public static func concernCaveat(_ check: PaperRetractionCheck) -> String {
        let detail = [check.deciding?.date, check.deciding?.noticeDOI.map { "notice \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return "\(concernIndent)⚠️ Expression of concern" + (detail.isEmpty ? "" : " (\(detail))")
    }

    /// A title safe inside one markdown line: whitespace collapsed, specials escaped.
    static func plainTitle(_ title: String) -> String {
        let collapsed = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.reduce(into: "") { out, ch in
            if "\\`*_[]<>".contains(ch) { out.append("\\") }
            out.append(ch)
        }
    }

    /// The desktop's `{n:,}`.
    private static func grouped(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    /// `yyyy-MM-dd` in UTC, as the desktop's `as_utc(...).date().isoformat()`.
    private static func isoDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
