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
    /// Handles various LLM response quirks like scores as strings/doubles,
    /// extra text around JSON, and markdown code blocks.
    ///
    /// - Parameter response: Raw JSON string from LLM.
    /// - Returns: Tuple of (score clamped to 1-5, explanation).
    static func parseScoreResponse(_ response: String) -> (score: Int, explanation: String) {
        // Try to extract JSON from the response (handles markdown code blocks, extra text)
        let jsonString = extractJSON(from: response)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (1, "Failed to parse JSON response")
        }

        // Parse score - handle Int, Double, or String
        let score: Int
        if let intScore = json["score"] as? Int {
            score = intScore
        } else if let doubleScore = json["score"] as? Double {
            score = Int(doubleScore)
        } else if let strScore = json["score"] as? String, let parsed = Int(strScore) {
            score = parsed
        } else {
            return (1, "Failed to parse score value")
        }

        // Parse explanation - be lenient
        let explanation = json["explanation"] as? String
            ?? json["rationale"] as? String
            ?? json["reason"] as? String
            ?? "No explanation provided"

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
        let jsonString = extractJSON(from: response)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let passages = json["passages"] as? [[String: Any]] else {
            return []
        }

        return passages.compactMap { dict in
            // Be lenient with field names
            let text = dict["text"] as? String
                ?? dict["passage"] as? String
                ?? dict["quote"] as? String
            let relevance = dict["relevance"] as? String
                ?? dict["context"] as? String
                ?? dict["explanation"] as? String
                ?? ""

            guard let passageText = text, !passageText.isEmpty else {
                return nil
            }
            return ParsedPassage(text: passageText, relevance: relevance)
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
        let jsonString = extractJSON(from: response)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedReport(
                verdict: .insufficientEvidence,
                summary: "Failed to generate report",
                fullReport: "Error parsing LLM response"
            )
        }

        // Be lenient with field names
        let verdictStr = json["verdict"] as? String ?? "Insufficient Evidence"
        let summary = json["summary"] as? String
            ?? json["brief"] as? String
            ?? "No summary available"
        let fullReport = json["full_report"] as? String
            ?? json["fullReport"] as? String
            ?? json["report"] as? String
            ?? json["detailed_report"] as? String
            ?? "No detailed report available"

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

    /// Extract JSON from an LLM response that may contain extra text.
    ///
    /// Handles common LLM response patterns:
    /// - Pure JSON
    /// - JSON wrapped in markdown code blocks (```json ... ```)
    /// - JSON with leading/trailing text
    ///
    /// - Parameter response: Raw LLM response.
    /// - Returns: Extracted JSON string, or original if no JSON found.
    static func extractJSON(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to find JSON in markdown code block
        if let codeBlockMatch = trimmed.range(of: "```(?:json)?\\s*([\\s\\S]*?)```",
                                               options: .regularExpression) {
            let content = trimmed[codeBlockMatch]
            // Remove the ``` markers
            let stripped = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped
        }

        // Try to find JSON object by looking for { ... }
        if let startIndex = trimmed.firstIndex(of: "{"),
           let endIndex = trimmed.lastIndex(of: "}") {
            return String(trimmed[startIndex...endIndex])
        }

        // Return original if no JSON pattern found
        return trimmed
    }
}
