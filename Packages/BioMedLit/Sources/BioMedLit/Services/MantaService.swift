// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What `POST /v1/judge` is asked: the question and one paper.
public struct MantaJudgeRequest: Encodable, Sendable {
    public var app: String
    public var question: String
    public var title: String
    public var abstract: String
    public var ids: [String: String]
    public var tasks: [String]

    public init(
        app: String, question: String, title: String, abstract: String,
        ids: [String: String], tasks: [String]
    ) {
        self.app = app
        self.question = question
        self.title = title
        self.abstract = abstract
        self.ids = ids
        self.tasks = tasks
    }
}

/// MANTA's judgement of one paper: relevance, and design when asked.
public struct MantaJudgement: Decodable, Equatable, Sendable {
    public let judgementID: String
    public let revision: String
    public let seconds: Double
    public let truncated: Bool
    public let expectedScore: Double
    public let relevanceProbabilities: [String: Double]
    public let verdict: String
    public let cutoff: Double
    public let design: String?
    public let designProbability: Double?
    public let designProbabilities: [String: Double]?

    private enum CodingKeys: String, CodingKey {
        case judgementID = "judgement_id"
        case revision, seconds, truncated, relevance, design
    }

    private enum RelevanceKeys: String, CodingKey {
        case probabilities, verdict, cutoff
        case expectedScore = "expected_score"
    }

    private enum DesignKeys: String, CodingKey {
        case probabilities, answer, probability
    }

    public init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: CodingKeys.self)
        judgementID = try top.decode(String.self, forKey: .judgementID)
        revision = try top.decode(String.self, forKey: .revision)
        seconds = try top.decode(Double.self, forKey: .seconds)
        truncated = try top.decode(Bool.self, forKey: .truncated)
        let rel = try top.nestedContainer(keyedBy: RelevanceKeys.self, forKey: .relevance)
        expectedScore = try rel.decode(Double.self, forKey: .expectedScore)
        relevanceProbabilities = try rel.decode([String: Double].self, forKey: .probabilities)
        verdict = try rel.decode(String.self, forKey: .verdict)
        cutoff = try rel.decode(Double.self, forKey: .cutoff)
        if top.contains(.design), try !top.decodeNil(forKey: .design) {
            let des = try top.nestedContainer(keyedBy: DesignKeys.self, forKey: .design)
            design = try des.decodeIfPresent(String.self, forKey: .answer)
            designProbability = try des.decodeIfPresent(Double.self, forKey: .probability)
            designProbabilities = try des.decodeIfPresent([String: Double].self, forKey: .probabilities)
        } else {
            design = nil
            designProbability = nil
            designProbabilities = nil
        }
    }
}

/// A paper's own PubMed indexing, posted back with the LLM's score.
public struct MantaIndexing: Encodable, Sendable {
    public var publicationTypes: [String]
    public var meshTerms: [String]
    public var medlineStatus: String?
    public var indexingMethod: String?

    public init(
        publicationTypes: [String], meshTerms: [String], medlineStatus: String?, indexingMethod: String?
    ) {
        self.publicationTypes = publicationTypes
        self.meshTerms = meshTerms
        self.medlineStatus = medlineStatus
        self.indexingMethod = indexingMethod
    }

    private enum CodingKeys: String, CodingKey {
        case publicationTypes = "publication_types"
        case meshTerms = "mesh_terms"
        case medlineStatus = "medline_status"
        case indexingMethod = "indexing_method"
    }

    /// Optionals go out as explicit `null`, the server's keys always present.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(publicationTypes, forKey: .publicationTypes)
        try c.encode(meshTerms, forKey: .meshTerms)
        try c.encode(medlineStatus, forKey: .medlineStatus)
        try c.encode(indexingMethod, forKey: .indexingMethod)
    }
}

/// What `POST /v1/reference` is told: the LLM's own score for a judged paper.
public struct MantaReference: Encodable, Sendable {
    public var judgementID: String
    public var app: String
    public var llmModel: String
    public var llmScore: Int?
    public var llmDesign: String?
    public var indexing: MantaIndexing?

    public init(
        judgementID: String, app: String, llmModel: String, llmScore: Int?, llmDesign: String?,
        indexing: MantaIndexing?
    ) {
        self.judgementID = judgementID
        self.app = app
        self.llmModel = llmModel
        self.llmScore = llmScore
        self.llmDesign = llmDesign
        self.indexing = indexing
    }

    private enum CodingKeys: String, CodingKey {
        case judgementID = "judgement_id"
        case app
        case llmModel = "llm_model"
        case llmScore = "llm_score"
        case llmDesign = "llm_design"
        case indexing
    }

    /// Optionals go out as explicit `null`, the server's keys always present.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(judgementID, forKey: .judgementID)
        try c.encode(app, forKey: .app)
        try c.encode(llmModel, forKey: .llmModel)
        try c.encode(llmScore, forKey: .llmScore)
        try c.encode(llmDesign, forKey: .llmDesign)
        try c.encode(indexing, forKey: .indexing)
    }
}

/// Why a MANTA call gave no answer.
public enum MantaServiceError: Error, Equatable, Sendable {
    /// The server could not be reached (not running, refused, timed out).
    case unreachable(String)
    /// The server answered with a non-2xx status; `message` is its `error` field.
    case refused(status: Int, message: String)
    /// The server answered 2xx with a body that is not the expected JSON.
    case unreadable
}

/// Client for the local MANTA server (`tools/manta_server/`). No retries; abstracts are never logged.
public struct MantaService: Sendable {
    /// Seconds a request may take before it counts as unreachable.
    public static let requestTimeoutSeconds: TimeInterval = 60

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Ask MANTA to judge one paper.
    public func judge(_ request: MantaJudgeRequest) async throws -> MantaJudgement {
        let data = try await post("v1/judge", body: request)
        do {
            return try JSONDecoder().decode(MantaJudgement.self, from: data)
        } catch {
            throw MantaServiceError.unreadable
        }
    }

    /// Tell MANTA what the LLM made of a judged paper.
    public func reference(_ reference: MantaReference) async throws {
        _ = try await post("v1/reference", body: reference)
    }

    private func post<Body: Encodable>(_ path: String, body: Body) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw MantaServiceError.unreadable
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw MantaServiceError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MantaServiceError.unreadable }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw MantaServiceError.refused(status: http.statusCode, message: message ?? "")
        }
        return data
    }
}
