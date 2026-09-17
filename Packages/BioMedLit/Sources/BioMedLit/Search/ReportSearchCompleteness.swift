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

/// What a report says about the search behind it, read from what it recorded.
///
/// A report is stored as text plus the contract's `search_shortfalls` record.
/// Everything a reader is told about the evidence base being partial comes from
/// the record: whether the search was incomplete, the sentence that says so, and
/// what is left of the report once that sentence is taken off the front.
///
/// ## Why the record and not the text
///
/// The text used to answer all three questions by itself, by matching the
/// notice's own opening words. That made anything which rewrote the text answer
/// for the search — a regeneration, an export saved back, or a model whose
/// analysis happened to begin with those words — and a report could then claim
/// a complete search it never made, or disown a complete one (#284).
///
/// ## What a missing record means
///
/// `nil` is only a report saved before the record existed. Its text is the text
/// this app wrote, notice included, so it is read the old way. A record that is
/// present but unreadable is neither complete nor readable: it reports as
/// incomplete and says that what it recorded could not be read, because the one
/// answer it must never give is "the search was complete".
public struct ReportSearchCompleteness: Sendable, Equatable {
    /// Whether the search behind the report failed to retrieve something.
    ///
    /// `true` also for a record that could not be read: a report that cannot
    /// say what it is missing must not pass as one that is missing nothing.
    public let wasIncomplete: Bool

    /// The sentence telling the reader what the search is missing, as plain text.
    ///
    /// `nil` when the search was complete. Every surface that shows a report
    /// draws this above the verdict, before the report's own text.
    public let notice: String?

    /// The report's text with the notice taken off the front.
    ///
    /// Unchanged when the search was complete, and when the record could not be
    /// read: nothing is taken off a report on the strength of a record nobody
    /// could read.
    public let bodyAfterNotice: String

    /// What a report whose search lost nothing records.
    ///
    /// The same value ``BioMedLit/SearchFailureReporting/reportRecord(for:)``
    /// returns for no shortfalls, for a caller that has none to encode.
    public static var completeSearchRecord: String { SearchFailureConstants.completeSearchRecord }

    /// What a report says in place of the notice when its own record cannot be read.
    ///
    /// Public because the apps pin it: what such a report must never say
    /// instead is that its search was complete.
    public static var unreadableRecordNotice: String { SearchFailureConstants.unreadableRecordNotice }

    /// Read what a stored report says about its search.
    ///
    /// - Parameters:
    ///   - record: The report's `search_shortfalls` record: `"[]"` for a
    ///     complete search, the contract's JSON array for an incomplete one, and
    ///     `nil` only for a report saved before the record existed.
    ///   - reportText: The report's full text, as it was stored.
    public init(record: String?, reportText: String) {
        guard let record else {
            // Saved before the record existed: the text is this app's own, and
            // carries the notice if there was one.
            let split = SearchFailureReporting.splitPlainNotice(reportText)
            self.wasIncomplete = split.notice != nil
            self.notice = split.notice
            self.bodyAfterNotice = split.body
            return
        }

        do {
            let shortfalls = try SearchFailureReporting.shortfalls(fromJSON: record)
            guard !shortfalls.isEmpty else {
                self.wasIncomplete = false
                self.notice = nil
                self.bodyAfterNotice = reportText
                return
            }
            // The record says what is missing, so the sentence is written from
            // it rather than read out of the text, which may have been rewritten
            // since. The text is only asked where its notice ends.
            self.wasIncomplete = true
            self.notice = SearchFailureReporting.plainNotice(
                SearchFailureReporting.notice(for: shortfalls)
            )
            self.bodyAfterNotice = SearchFailureReporting.splitPlainNotice(reportText).body
        } catch let error as DamagedShortfallRecordError {
            // The reader is told, and so is the log: the reason names the shape
            // that was wrong and never quotes the stored value, so it is safe to
            // write down, and without it a damaged record is indistinguishable
            // from a genuine shortfall in the logs (golden rule 8).
            BioMedLitLib.logger?.error(
                "A report's search-shortfall record could not be read: \(error.reason)",
                category: .search
            )
            self.wasIncomplete = true
            self.notice = SearchFailureConstants.unreadableRecordNotice
            self.bodyAfterNotice = reportText
        } catch {
            BioMedLitLib.logger?.error(
                "A report's search-shortfall record could not be read: \(String(describing: error))",
                category: .search
            )
            self.wasIncomplete = true
            self.notice = SearchFailureConstants.unreadableRecordNotice
            self.bodyAfterNotice = reportText
        }
    }
}
