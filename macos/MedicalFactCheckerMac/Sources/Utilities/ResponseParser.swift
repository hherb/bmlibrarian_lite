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

    /// Result of parsing a score response.
    struct ScoreResult {
        /// The parsed score (1-5), or nil if parsing failed.
        let score: Int?
        /// Explanation for the score, or error message if parsing failed.
        let explanation: String
        /// Whether parsing failed (for retry logic).
        let parseFailed: Bool

        /// Convenience for successful parses.
        static func success(score: Int, explanation: String) -> ScoreResult {
            ScoreResult(score: score, explanation: explanation, parseFailed: false)
        }

        /// Convenience for failed parses.
        static func failure(_ message: String) -> ScoreResult {
            ScoreResult(score: nil, explanation: message, parseFailed: true)
        }
    }

    /// Parse a relevance score response from the LLM.
    ///
    /// Expected JSON format: `{"score": 1-5, "explanation": "..."}`
    /// Handles various LLM response quirks like scores as strings/doubles,
    /// extra text around JSON, and markdown code blocks.
    ///
    /// - Parameter response: Raw JSON string from LLM.
    /// - Returns: ScoreResult with score (nil if failed), explanation, and parseFailed flag.
    static func parseScoreResponse(_ response: String) -> ScoreResult {
        // Try to extract JSON from the response (handles markdown code blocks, extra text)
        let jsonString = extractJSON(from: response)

        // Try to fix common JSON issues from local models
        let fixedJSON = fixJSONString(jsonString)

        guard let data = fixedJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Log for debugging
            print("[ResponseParser] Failed to parse JSON. Raw response: \(response.prefix(200))")
            return .failure("Failed to parse JSON response")
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
            print("[ResponseParser] Failed to parse score value from: \(json)")
            return .failure("Failed to parse score value")
        }

        // Validate score is in expected range
        guard score >= 1 && score <= 5 else {
            print("[ResponseParser] Score out of range: \(score)")
            return .failure("Score \(score) out of valid range (1-5)")
        }

        // Parse explanation - be lenient
        let explanation = json["explanation"] as? String
            ?? json["rationale"] as? String
            ?? json["reason"] as? String
            ?? "No explanation provided"

        return .success(score: clampScore(score), explanation: explanation)
    }

    /// Fix common JSON issues from local models.
    ///
    /// Handles:
    /// - Trailing commas before closing braces
    /// - Single quotes instead of double quotes
    /// - Unescaped newlines in strings
    ///
    /// - Parameter json: The JSON string to fix.
    /// - Returns: Fixed JSON string.
    private static func fixJSONString(_ json: String) -> String {
        var fixed = json

        // Remove trailing commas before closing braces/brackets
        // e.g., {"score": 3,} -> {"score": 3}
        fixed = fixed.replacingOccurrences(
            of: ",\\s*([}\\]])",
            with: "$1",
            options: .regularExpression
        )

        // Replace single quotes with double quotes (only outside of already double-quoted strings)
        // This is tricky, so only do simple cases
        if !fixed.contains("\"") && fixed.contains("'") {
            fixed = fixed.replacingOccurrences(of: "'", with: "\"")
        }

        return fixed
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
            // Log the parsing failure for debugging
            print("[ResponseParser] Failed to parse report JSON")
            print("[ResponseParser] Raw response length: \(response.count)")
            print("[ResponseParser] Extracted JSON length: \(jsonString.count)")
            if response.count < 2000 {
                print("[ResponseParser] Raw response: \(response)")
            } else {
                print("[ResponseParser] Raw response (first 500 chars): \(String(response.prefix(500)))")
            }
            return ParsedReport(
                verdict: .insufficientEvidence,
                summary: "Failed to generate report",
                fullReport: "Error parsing LLM response. The model may have returned an unexpected format."
            )
        }

        // Be lenient with field names
        let verdictStr = json["verdict"] as? String ?? "Insufficient Evidence"
        let summary = json["summary"] as? String
            ?? json["brief"] as? String
            ?? "No summary available"

        // Handle full_report - it might be a string or a nested object
        let fullReport = extractReportContent(from: json)

        return ParsedReport(
            verdict: parseVerdict(verdictStr),
            summary: summary,
            fullReport: fullReport
        )
    }

    // MARK: - Report Content Extraction

    /// Extract report content from JSON, handling various formats.
    ///
    /// Some LLMs return full_report as a string, others as a nested object
    /// with section keys. This function handles both cases.
    ///
    /// - Parameter json: The parsed JSON dictionary.
    /// - Returns: The report content as a string.
    private static func extractReportContent(from json: [String: Any]) -> String {
        // Try common field names as strings first
        let fieldNames = ["full_report", "fullReport", "report", "detailed_report"]

        for fieldName in fieldNames {
            // Check if it's a string
            if let stringValue = json[fieldName] as? String {
                return stringValue
            }

            // Check if it's a nested object (some LLMs structure the report as an object)
            if let objectValue = json[fieldName] as? [String: Any] {
                return convertNestedReportToString(objectValue)
            }
        }

        return "No detailed report available"
    }

    /// Convert a nested report object to a markdown string.
    ///
    /// Handles cases where the LLM returns the report as a structured object like:
    /// ```json
    /// {
    ///     "full_report": {
    ///         "## Section 1": "content...",
    ///         "## Section 2": "content..."
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter object: The nested report object.
    /// - Returns: Formatted markdown string.
    private static func convertNestedReportToString(_ object: [String: Any]) -> String {
        var result = ""

        // Sort keys to maintain consistent order
        let sortedKeys = object.keys.sorted()

        for key in sortedKeys {
            let value = object[key]

            // If the key looks like a markdown header, use it as-is
            let header = key.hasPrefix("#") ? key : "## \(key)"

            if let stringValue = value as? String {
                result += "\(header)\n\n\(stringValue)\n\n"
            } else if let arrayValue = value as? [String] {
                result += "\(header)\n\n"
                for item in arrayValue {
                    result += "- \(item)\n"
                }
                result += "\n"
            } else if let nestedObject = value as? [String: Any] {
                // Recursively handle nested objects
                result += "\(header)\n\n"
                result += convertNestedReportToString(nestedObject)
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Array Parsing

    /// Parse an array of strings from an LLM response.
    ///
    /// Expected JSON format: `["string1", "string2", ...]`
    ///
    /// - Parameter response: Raw JSON string from LLM.
    /// - Returns: Array of strings, or empty array if parsing fails.
    static func parseStringArray(_ response: String) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract JSON array
        var jsonString = trimmed

        // Handle markdown code blocks
        if let codeBlockMatch = trimmed.range(of: "```(?:json)?\\s*([\\s\\S]*?)```",
                                               options: .regularExpression) {
            jsonString = trimmed[codeBlockMatch]
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Find array bounds
        if let startIndex = jsonString.firstIndex(of: "["),
           let endIndex = jsonString.lastIndex(of: "]") {
            jsonString = String(jsonString[startIndex...endIndex])
        }

        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }

        return array.filter { !$0.isEmpty }
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
    /// - Nested or malformed JSON with extra braces
    ///
    /// - Parameter response: Raw LLM response.
    /// - Returns: Extracted JSON string, or original if no JSON found.
    static func extractJSON(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to find JSON in markdown code block first (most reliable)
        if let codeBlockMatch = trimmed.range(of: "```(?:json)?\\s*([\\s\\S]*?)```",
                                               options: .regularExpression) {
            let content = trimmed[codeBlockMatch]
            // Remove the ``` markers
            let stripped = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Verify it's valid JSON before returning
            if isValidJSON(stripped) {
                return stripped
            }
        }

        // Try to find balanced JSON object using brace matching
        if let jsonString = extractBalancedJSON(from: trimmed) {
            return jsonString
        }

        // Fallback: simple first-brace to last-brace extraction
        if let startIndex = trimmed.firstIndex(of: "{"),
           let endIndex = trimmed.lastIndex(of: "}") {
            return String(trimmed[startIndex...endIndex])
        }

        // Return original if no JSON pattern found
        return trimmed
    }

    /// Extract a balanced JSON object from a string by matching braces.
    ///
    /// Handles cases where the response contains multiple JSON objects or nested braces.
    ///
    /// - Parameter string: The string to extract JSON from.
    /// - Returns: The extracted JSON string, or nil if no valid JSON found.
    private static func extractBalancedJSON(from string: String) -> String? {
        guard let startIndex = string.firstIndex(of: "{") else {
            return nil
        }

        var braceCount = 0
        var inString = false
        var escapeNext = false
        var endIndex: String.Index?

        for index in string.indices[startIndex...] {
            let char = string[index]

            if escapeNext {
                escapeNext = false
                continue
            }

            if char == "\\" && inString {
                escapeNext = true
                continue
            }

            if char == "\"" {
                inString = !inString
                continue
            }

            if !inString {
                if char == "{" {
                    braceCount += 1
                } else if char == "}" {
                    braceCount -= 1
                    if braceCount == 0 {
                        endIndex = index
                        break
                    }
                }
            }
        }

        guard let finalEnd = endIndex else {
            return nil
        }

        let jsonString = String(string[startIndex...finalEnd])

        // Verify it's valid JSON before returning
        if isValidJSON(jsonString) {
            return jsonString
        }

        return nil
    }

    /// Check if a string is valid JSON.
    ///
    /// - Parameter string: The string to validate.
    /// - Returns: True if the string is valid JSON.
    private static func isValidJSON(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8) else {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
