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

/// One paper to check: the identifiers and label its record carries.
public struct RetractionPaper: Hashable, Sendable {
    /// The paper's DOI, in any form bmlib normalises.
    public let doi: String?
    /// The paper's PMID; one that is not canonical is no PMID.
    public let pmid: String?
    /// The record's publication types (PubMed's label).
    public let publicationTypes: [String]

    public init(doi: String?, pmid: String?, publicationTypes: [String]) {
        self.doi = doi
        self.pmid = pmid
        self.publicationTypes = publicationTypes
    }

    /// The key that names this paper across documents (the desktop's
    /// `paper_key`, which it stores checks under; the apps store them per
    /// document and match by this key when reading): `doi:` and the Crossref
    /// key, else `pmid:` and the canonical PMID; `nil` with neither.
    public var paperKey: String? {
        if let key = doi.flatMap(RetractionChecker.doiKey) { return "doi:\(key)" }
        return pmid.flatMap { PMID.canonical($0).pmid }.map { "pmid:\($0)" }
    }
}

/// The notice a verdict rests on, by contract names.
public struct StoredRetractionEvidence: Codable, Equatable, Sendable {
    /// Where it was found (`retraction_watch_export`, `pubmed_label`, …).
    public let source: String
    /// What it is (`retraction`, `expression_of_concern`, …).
    public let kind: String
    /// The notice's date, ISO, as precise as deposited.
    public let date: String?
    /// The notice's normalised DOI.
    public let noticeDOI: String?
    /// The Retraction Watch record ID.
    public let recordID: String?
    /// The source's own word for the kind.
    public let rawKind: String?

    public init(source: String, kind: String, date: String?, noticeDOI: String?, recordID: String?, rawKind: String?) {
        self.source = source
        self.kind = kind
        self.date = date
        self.noticeDOI = noticeDOI
        self.recordID = recordID
        self.rawKind = rawKind
    }
}

/// One paper's verdict and what it rests on: the desktop's `PaperCheck`, in
/// the form the app stores as JSON.
public struct PaperRetractionCheck: Codable, Equatable, Sendable {
    /// The status's contract name: `retracted`, `concern`, `clear` or `unchecked`.
    public let status: String
    /// The newest retraction or concern, otherwise the newest reinstatement.
    public let deciding: StoredRetractionEvidence?
    /// Every lookup that did not answer (`retraction_watch_export`, `crossref`).
    public let unanswered: [String]
    /// When it was decided.
    public let checkedAt: Date
    /// The `dataAsOf` of the index consulted; `nil` when it was not consulted.
    public let exportDataAsOf: String?
    /// Why Crossref did not answer, in the app's own words
    /// (`RequestFailure.describe()`); `nil` when it answered or was not asked.
    public let crossrefFailure: String?

    public init(
        status: String,
        deciding: StoredRetractionEvidence?,
        unanswered: [String],
        checkedAt: Date,
        exportDataAsOf: String?,
        crossrefFailure: String?
    ) {
        self.status = status
        self.deciding = deciding
        self.unanswered = unanswered
        self.checkedAt = checkedAt
        self.exportDataAsOf = exportDataAsOf
        self.crossrefFailure = crossrefFailure
    }

    /// The status; a name this build cannot read is unchecked, never clear.
    public var retractionStatus: RetractionStatus {
        RetractionNames.value(status, in: RetractionNames.statuses) ?? .unchecked
    }

    /// Whether the paper is retracted.
    public var isRetracted: Bool { retractionStatus == .retracted }
    /// Whether an expression of concern stands.
    public var isConcern: Bool { retractionStatus == .concern }
    /// Whether every source was consulted and none warns.
    public var isClear: Bool { retractionStatus == .clear }
    /// Whether the evidence could not decide (never read as clear).
    public var isUnchecked: Bool { retractionStatus == .unchecked }

    /// Whether the deciding evidence is the record's own PubMed label.
    public var isDecidedByLabel: Bool {
        deciding.flatMap { RetractionNames.value($0.source, in: RetractionNames.sources) } == .pubmedLabel
    }

    /// Whether `lookup` did not answer.
    func leftUnanswered(_ lookup: RetractionLookup) -> Bool {
        unanswered.contains(RetractionNames.name(lookup, in: RetractionNames.lookups))
    }
}

extension PaperRetractionCheck {
    /// The stored form of bmlib's verdict.
    init(verdict: RetractionVerdict, checkedAt: Date, exportDataAsOf: String?, crossrefFailure: String?) {
        self.init(
            status: RetractionNames.name(verdict.status, in: RetractionNames.statuses),
            deciding: verdict.deciding.map {
                StoredRetractionEvidence(
                    source: RetractionNames.name($0.source, in: RetractionNames.sources),
                    kind: RetractionNames.name($0.kind, in: RetractionNames.kinds),
                    date: $0.date,
                    noticeDOI: $0.noticeDoi,
                    recordID: $0.recordId,
                    rawKind: $0.rawKind
                )
            },
            unanswered: verdict.unanswered.map { RetractionNames.name($0, in: RetractionNames.lookups) },
            checkedAt: checkedAt,
            exportDataAsOf: exportDataAsOf,
            crossrefFailure: crossrefFailure
        )
    }

    /// A check that failed before any lookup answered: unchecked, both lookups
    /// unanswered, so it is never reused and never stands against an answer.
    ///
    /// - Parameter date: When the check was attempted.
    public static func failed(at date: Date) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: RetractionNames.name(RetractionStatus.unchecked, in: RetractionNames.statuses),
            deciding: nil,
            unanswered: [RetractionLookup.retractionWatchExport, .crossref]
                .map { RetractionNames.name($0, in: RetractionNames.lookups) },
            checkedAt: date,
            exportDataAsOf: nil,
            crossrefFailure: nil
        )
    }

    /// Whether this stored check may stand in for a fresh one (the desktop's
    /// `RetractionChecker.check`): no older than
    /// ``BioMedLitConstants/retractionCheckMaxAgeDays``, every lookup
    /// answered (a failure is not knowledge), a status this build can read
    /// (the desktop drops such a row, so the paper is checked again), and,
    /// unless it already says retracted, the paper's own label does not
    /// retract it (a fresh label is never hidden behind a stored clear).
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - publicationTypes: The paper's record's publication types now.
    public func isReusable(now: Date, publicationTypes: [String]) -> Bool {
        let maxAge = TimeInterval(BioMedLitConstants.retractionCheckMaxAgeDays) * TransparencyConstants.secondsPerDay
        guard now.timeIntervalSince(checkedAt) <= maxAge, unanswered.isEmpty,
              RetractionNames.value(status, in: RetractionNames.statuses) != nil else { return false }
        if isRetracted { return true }
        let label = BmlibCore.retractionStatus(doi: nil, export: nil, crossref: nil, publicationTypes: publicationTypes)
        return label.status != .retracted
    }

    /// Whether this stored check stands against `fresh` (the desktop's
    /// `_keeps`): only when `fresh` leaves unanswered a lookup this one
    /// answered and does not warn more. A fresh retraction, or a concern over
    /// a stored clear, is news even while a lookup is down.
    ///
    /// This decides what is **stored**: when it stands, keep this row, its
    /// `checkedAt` included, and do not write `fresh`. Otherwise `fresh`
    /// replaces it. With no stored row, `fresh` is written whatever it says
    /// (the desktop writes such a check only while the row is still missing,
    /// so a concurrent writer's answer is never overwritten by a failure).
    /// What is **shown** is ``shown(against:)``.
    ///
    /// - Parameter fresh: The check just made.
    public func standsAgainst(_ fresh: PaperRetractionCheck) -> Bool {
        guard !Set(fresh.unanswered).subtracting(unanswered).isEmpty else { return false }
        if fresh.isRetracted { return false }
        return !(fresh.isConcern && isClear)
    }

    /// The check the reader is shown, this being the stored one and `fresh`
    /// the one just made (retraction_checks.py: `old if kept else fresh`).
    ///
    /// This stored check is shown only when it ``standsAgainst(_:)`` `fresh`
    /// **and** warns (retracted or concern): an outage never hides a known
    /// warning. A stored clear that stands is kept in storage but not shown,
    /// since a clear resting on a lookup that is now down is not knowledge
    /// today: the reader sees `fresh`, unchecked, never a stale clear.
    ///
    /// - Parameter fresh: The check just made.
    public func shown(against fresh: PaperRetractionCheck) -> PaperRetractionCheck {
        standsAgainst(fresh) && (isRetracted || isConcern) ? self : fresh
    }
}

/// The workflow's injection point: checks for papers, at the current time.
public typealias RetractionCheck = @Sendable ([RetractionPaper]) async throws -> [RetractionPaper: PaperRetractionCheck]

/// Decides each paper's retraction status from the Retraction Watch index,
/// Crossref and its own label. bmlib's rule decides; this only gathers the
/// evidence, and keeps "not consulted" and "not asked" apart from "found
/// nothing".
public struct RetractionChecker: Sendable {
    private let index: RetractionIndex?
    private let crossref: RetractionCrossrefLookup

    /// - Parameters:
    ///   - index: The current index, or `nil` when there is none (the export
    ///     is then not consulted and nothing reads as clear).
    ///   - crossref: The Crossref lookup.
    public init(index: RetractionIndex?, crossref: RetractionCrossrefLookup) {
        self.index = index
        self.crossref = crossref
    }

    /// Check `papers`, asking Crossref once per normalised DOI.
    ///
    /// - Parameters:
    ///   - papers: The papers; equal papers share one check.
    ///   - now: Stored as each check's `checkedAt`.
    /// - Returns: A check per paper, every paper included.
    /// - Throws: `CancellationError` only.
    public func check(_ papers: [RetractionPaper], now: Date) async throws -> [RetractionPaper: PaperRetractionCheck] {
        var keys: [RetractionPaper: String?] = [:]
        for paper in papers { keys[paper] = paper.doi.flatMap(Self.doiKey) }
        var dois: [String] = []
        for case let doi? in papers.map({ keys[$0] ?? nil }) where !dois.contains(doi) { dois.append(doi) }
        let answers = try await crossref.results(for: dois)
        var out: [RetractionPaper: PaperRetractionCheck] = [:]
        for (paper, doi) in keys {
            let export = index?.lookup(doi: doi, pmid: paper.pmid.flatMap { PMID.canonical($0).pmid })
            let answer = doi.flatMap { answers[$0] }
            let verdict = retractionStatus(
                doi: doi, export: export, crossref: answer?.result, publicationTypes: paper.publicationTypes
            )
            out[paper] = PaperRetractionCheck(
                verdict: verdict,
                checkedAt: now,
                exportDataAsOf: export == nil ? nil : index?.dataAsOf(),
                crossrefFailure: answer?.failure?.describe()
            )
        }
        return out
    }

    /// The key bmlib files `doi`'s Crossref answer under (the desktop's
    /// `crossref_key`), from bmlib's own request builder; `nil` for no DOI.
    static func doiKey(_ doi: String) -> String? {
        let requests = crossrefRetractionRequests(dois: [doi], mailto: nil)
        return requests.batches.first?.dois.first ?? requests.unsendable.first
    }
}
