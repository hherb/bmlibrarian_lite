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

/// What ``MantaShadow`` needs of a MANTA server.
protocol MantaJudging: Sendable {
    /// Ask MANTA to judge one paper.
    func judge(_ request: MantaJudgeRequest) async throws -> MantaJudgement
    /// Tell MANTA what the LLM made of a judged paper.
    func reference(_ reference: MantaReference) async throws
}

extension MantaService: MantaJudging {}

/// One LLM-scored paper for MANTA to judge beside the LLM.
struct MantaShadowItem: Sendable {
    let pmid: String
    let claim: String
    let title: String
    let abstract: String
    let ids: [String: String]
    let llmScore: Int
    let llmModel: String
    let indexing: MantaIndexing?
}

/// What MANTA made of one paper, for ``Document/applyManta(_:serverURL:)``.
struct MantaShadowResult: Sendable {
    enum Outcome: Sendable {
        case judged(MantaJudgement)
        case unreachable(String)
        case failed(String)
    }

    let pmid: String
    let outcome: Outcome
    let judgedAt: Date
    /// Whether the LLM's score reached the server; a failed post keeps the judgement.
    let referencePosted: Bool
}

/// Judges each observed paper with MANTA, one at a time in order, off the scoring path.
///
/// The shadow never changes the fact check: its results go only to `onResult`.
actor MantaShadow {
    /// The app name the server's ledger records.
    static let app = "macos"
    /// What MANTA is asked for each paper.
    static let tasks = ["relevance", "design"]

    private let service: MantaJudging
    private let onResult: @MainActor @Sendable (MantaShadowResult) -> Void
    private var pending: [MantaShadowItem] = []
    private var worker: Task<Void, Never>?
    /// Bumped by ``cancel()``; a worker from an earlier generation delivers nothing.
    private var generation = 0

    init(service: MantaJudging, onResult: @escaping @MainActor @Sendable (MantaShadowResult) -> Void) {
        self.service = service
        self.onResult = onResult
    }

    /// Queue a paper; it is judged after every paper observed before it.
    func observe(_ item: MantaShadowItem) {
        pending.append(item)
        if worker == nil {
            let current = generation
            worker = Task { await self.drain(generation: current) }
        }
    }

    /// Drop every pending paper. One in flight delivers nothing: `MantaService` reports a
    /// cancelled request as unreachable, which a stopped run must not store.
    func cancel() {
        pending.removeAll()
        generation += 1
        worker?.cancel()
        worker = nil
    }

    private func drain(generation current: Int) async {
        while current == generation, !pending.isEmpty {
            let item = pending.removeFirst()
            guard let result = await run(item, generation: current), current == generation else { return }
            await onResult(result)
        }
        if current == generation { worker = nil }
    }

    /// Judge, then post the reference (skipped when cancelled meanwhile).
    private func run(_ item: MantaShadowItem, generation current: Int) async -> MantaShadowResult? {
        let request = MantaJudgeRequest(
            app: Self.app, question: item.claim, title: item.title, abstract: item.abstract,
            ids: item.ids, tasks: Self.tasks)
        let judgement: MantaJudgement
        do {
            judgement = try await service.judge(request)
        } catch {
            return MantaShadowResult(
                pmid: item.pmid, outcome: Self.outcome(for: error), judgedAt: Date(), referencePosted: false)
        }
        guard current == generation else { return nil }
        let judgedAt = Date()
        let reference = MantaReference(
            judgementID: judgement.judgementID, app: Self.app, llmModel: item.llmModel,
            llmScore: item.llmScore, llmDesign: nil, indexing: item.indexing)
        let posted = (try? await service.reference(reference)) != nil
        return MantaShadowResult(
            pmid: item.pmid, outcome: .judged(judgement), judgedAt: judgedAt, referencePosted: posted)
    }

    static func outcome(for error: Error) -> MantaShadowResult.Outcome {
        switch error {
        case MantaServiceError.unreachable(let message): return .unreachable(message)
        case MantaServiceError.refused(let status, let message): return .failed("\(status): \(message)")
        default: return .failed(String(describing: error))
        }
    }
}
