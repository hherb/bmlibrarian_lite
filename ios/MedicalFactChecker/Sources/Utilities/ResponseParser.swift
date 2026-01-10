//
//  ResponseParser.swift
//  MedicalFactChecker
//
//  Pure functions for parsing LLM JSON responses.
//

import Foundation

/// Utility functions for parsing LLM JSON responses.
///
/// All functions are pure, stateless, and easily testable.
enum ResponseParser {

    // MARK: - Score Parsing

    /// Parse a relevance score response from the LLM.
    ///
    /// Expected JSON format: `{"score": 1-5, "explanation": "..."}`
    ///
    /// - Parameter response: Raw JSON string from LLM.
    /// - Returns: Tuple of (score clamped to 1-5, explanation).
    static func parseScoreResponse(_ response: String) -> (score: Int, explanation: String) {
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let score = json["score"] as? Int,
              let explanation = json["explanation"] as? String else {
            return (1, "Failed to parse score")
        }
        return (clampScore(score), explanation)
    }

    // MARK: - Citation Parsing

    /// A parsed citation passage with context.
    struct ParsedPassage {
        let text: String
        let relevance: String
    }

    /// Parse citation passages from an LLM response.
    ///
    /// Expected JSON format: `{"passages": [{"text": "...", "relevance": "..."}]}`
    ///
    /// - Parameter response: Raw JSON string from LLM.
    /// - Returns: Array of parsed passages.
    static func parsePassagesResponse(_ response: String) -> [ParsedPassage] {
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let passages = json["passages"] as? [[String: Any]] else {
            return []
        }

        return passages.compactMap { dict in
            guard let text = dict["text"] as? String,
                  let relevance = dict["relevance"] as? String else {
                return nil
            }
            return ParsedPassage(text: text, relevance: relevance)
        }
    }

    // MARK: - Report Parsing

    /// A parsed evidence report.
    struct ParsedReport {
        let verdict: Verdict
        let summary: String
        let fullReport: String
    }

    /// Parse an evidence report from an LLM response.
    ///
    /// Expected JSON format:
    /// ```json
    /// {
    ///     "verdict": "Supported|Partially Supported|Not Supported|...",
    ///     "summary": "...",
    ///     "full_report": "..."
    /// }
    /// ```
    ///
    /// - Parameter response: Raw JSON string from LLM.
    /// - Returns: Parsed report, or default values if parsing fails.
    static func parseReportResponse(_ response: String) -> ParsedReport {
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdictStr = json["verdict"] as? String,
              let summary = json["summary"] as? String,
              let fullReport = json["full_report"] as? String else {
            return ParsedReport(
                verdict: .insufficientEvidence,
                summary: "Failed to generate report",
                fullReport: "Error parsing LLM response"
            )
        }

        return ParsedReport(
            verdict: parseVerdict(verdictStr),
            summary: summary,
            fullReport: fullReport
        )
    }

    // MARK: - Verdict Parsing

    /// Parse a verdict string into the Verdict enum.
    ///
    /// - Parameter string: Verdict string from LLM (case-insensitive).
    /// - Returns: Matching Verdict enum value.
    static func parseVerdict(_ string: String) -> Verdict {
        let normalized = string.lowercased()

        if normalized.contains("partially") {
            return .partiallySupported
        }
        if normalized.contains("not supported") {
            return .notSupported
        }
        if normalized.contains("supported") {
            return .supported
        }
        if normalized.contains("conflicting") {
            return .conflicting
        }
        return .insufficientEvidence
    }

    // MARK: - Helpers

    /// Clamp a score to the valid range of 1-5.
    ///
    /// - Parameter score: Raw score value.
    /// - Returns: Score clamped to 1-5.
    static func clampScore(_ score: Int) -> Int {
        min(5, max(1, score))
    }
}
