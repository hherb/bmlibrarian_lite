# Phase 2: ResponseParser Updates

## Objective

Add structured query parsing capabilities to the iOS `ResponseParser` to support the new provider-agnostic query system.

## Files to Modify

- `ios/MedicalFactChecker/Sources/Utilities/ResponseParser.swift`

## Current iOS State

The iOS `ResponseParser` has:
- `parseScoreResponse()` - parsing relevance scores
- `parsePassagesResponse()` - parsing citation passages
- `parseReportResponse()` - parsing evidence reports
- `parseStringArray()` - parsing string arrays
- Helper functions for JSON extraction and validation

## Changes to Add

### New Function: parseStructuredQueryArray

Add this function to parse arrays of structured queries from LLM responses (used in smart search):

```swift
// MARK: - Structured Query Parsing

/// Parse an array of structured queries from an LLM response.
///
/// Expected JSON format:
/// ```json
/// [
///   {"concepts": [{"name": "...", "mesh_terms": ["..."], "keywords": ["..."]}]},
///   {"concepts": [...]}
/// ]
/// ```
///
/// - Parameter response: Raw JSON string from LLM.
/// - Returns: Array of StructuredQuery objects, or empty array if parsing fails.
static func parseStructuredQueryArray(_ response: String) -> [StructuredQuery] {
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
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        print("[ResponseParser] Failed to parse structured query array from: \(response.prefix(200))")
        return []
    }

    return array.compactMap { parseStructuredQueryDict($0) }
}
```

### New Private Helper: parseStructuredQueryDict

```swift
/// Parse a single structured query dictionary.
///
/// - Parameter dict: Dictionary containing query data.
/// - Returns: StructuredQuery if parsing succeeds, nil otherwise.
private static func parseStructuredQueryDict(_ dict: [String: Any]) -> StructuredQuery? {
    guard let conceptsArray = dict["concepts"] as? [[String: Any]] else {
        return nil
    }

    let concepts = conceptsArray.compactMap { conceptDict -> SearchConcept? in
        let name = conceptDict["name"] as? String ?? ""
        let meshTerms = conceptDict["mesh_terms"] as? [String] ?? []
        let keywords = conceptDict["keywords"] as? [String] ?? []

        // Skip empty concepts
        if meshTerms.isEmpty && keywords.isEmpty {
            return nil
        }

        return SearchConcept(name: name, meshTerms: meshTerms, keywords: keywords)
    }

    guard !concepts.isEmpty else {
        return nil
    }

    return StructuredQuery(concepts: concepts)
}
```

## Dependencies

This phase depends on Phase 3 (StructuredQuery) for the `StructuredQuery` and `SearchConcept` types. However, you can:

1. Add a placeholder import comment: `// Requires: StructuredQuery from Phase 3`
2. Or implement Phase 3 first
3. Or implement both in parallel and resolve at compile time

## Import Statement

If `StructuredQuery` is in a separate file, no import needed (same module).

## Validation Steps

1. Build iOS project after Phase 3 is complete
2. Write unit test for `parseStructuredQueryArray`:
   ```swift
   func testParseStructuredQueryArray() {
       let json = """
       [
         {"concepts": [{"name": "drug", "mesh_terms": ["Amlodipine"], "keywords": ["amlodipine"]}]},
         {"concepts": [{"name": "condition", "mesh_terms": ["Hypertension"], "keywords": ["high blood pressure"]}]}
       ]
       """
       let queries = ResponseParser.parseStructuredQueryArray(json)
       XCTAssertEqual(queries.count, 2)
       XCTAssertEqual(queries[0].concepts[0].name, "drug")
   }
   ```

## Reference Files

- macOS version: `macos/MedicalFactCheckerMac/Sources/Utilities/ResponseParser.swift` (lines 357-428)
