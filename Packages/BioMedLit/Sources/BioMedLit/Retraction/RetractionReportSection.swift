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

/// What a report says about retraction: the opening notice, the papers the
/// run left out and the methods line.
///
/// Built from the checks the run used, not from what is stored now, so the
/// report states what the run saw (the desktop builds it from its screen).
public struct RetractionReportSection: Sendable {
    /// The papers left out as retracted, in the order given.
    public let leftOut: [(title: String, check: PaperRetractionCheck)]
    /// ``RetractionText/savedWorkLine(_:)`` for the run: the report's methods
    /// line and a reopened session's line are the same sentence.
    public let methodsLine: String
    /// The report's opening notice (``RetractionText/reportNotice(_:)``), or
    /// `nil` when nothing was left out and every paper was checked.
    public let notice: String?

    /// - Parameters:
    ///   - papers: Every paper the run held (kept and left out) with the check it used.
    ///   - causes: Why kept papers are unchecked (``RetractionText/uncheckedCauses(_:failed:)``),
    ///     when the live run knows; empty gives the count alone, as the desktop's restored snapshot does.
    public init(papers: [(title: String, check: PaperRetractionCheck)], causes: [String] = []) {
        leftOut = papers.filter { $0.check.isRetracted }
        // As the desktop: the oldest *decided* check; an unchecked answer's time never counts.
        methodsLine = RetractionText.savedWorkLine(papers.map(\.check))
        notice = RetractionText.runSummaryClause(
            excluded: leftOut.count, unchecked: papers.filter { $0.check.isUnchecked }.count, causes: causes
        ).map(RetractionText.reportNotice)
    }

    /// `text` with the notice in front (the desktop's `with_retraction_notice`);
    /// unchanged when it already opens with one.
    func withNotice(_ text: String) -> String {
        guard let notice, !text.hasPrefix(RetractionText.noticeOpening) else { return text }
        return "\(notice)\n\n\(text)"
    }

    /// The left-out section, or `""` when nothing was left out.
    var leftOutMarkdown: String {
        guard !leftOut.isEmpty else { return "" }
        let entries = leftOut.map { RetractionText.leftOutEntry(title: $0.title, check: $0.check) }
        return ([RetractionText.leftOutHeading, ""] + entries).joined(separator: "\n")
    }

    /// The methods line as a Methodology list item.
    var methodsMarkdown: String { "- **Retraction Check:** \(methodsLine)" }
}
