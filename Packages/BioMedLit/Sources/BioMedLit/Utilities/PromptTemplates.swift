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

// MARK: - Prompt Templates

/// Centralized LLM prompt templates for the fact-checking workflow.
///
/// All prompts are pure functions that take input data and return formatted
/// prompt strings. This makes them easily testable and maintains consistency
/// across the codebase.
///
/// ## Design Principles
///
/// 1. **Immutable**: Prompts are constructed from input data, never modified
/// 2. **Testable**: Each prompt function can be tested in isolation
/// 3. **Consistent**: Common patterns (JSON output, markdown formatting) are standardized
///
/// ## Example
///
/// ```swift
/// let prompt = PromptTemplates.queryConversion(claim: "aspirin prevents heart disease")
/// let messages = [LLMService.userMessage(prompt)]
/// ```
public enum PromptTemplates {
    // MARK: - Query Conversion

    /// Generate a prompt for converting a research question to a structured query.
    ///
    /// The LLM is asked to identify key concepts and provide MeSH terms and
    /// keywords for each. The output is JSON that can be parsed into a
    /// `StructuredQuery`.
    ///
    /// - Parameter claim: The research question or medical claim.
    /// - Returns: Formatted prompt string.
    public static func queryConversion(claim: String) -> String {
        """
        Convert this research question into a concise PubMed search query.

        Research Question: \(claim)

        Instructions:
        1. Identify 2-3 key concepts from the question
        2. For each concept, provide 1-2 MeSH terms and 1-2 keywords
        3. Keep it CONCISE - fewer specific terms work better than many broad terms
        4. DO NOT add filters like hasabstract or publication type filters - those will be added automatically

        Output ONLY valid JSON in this exact format:
        {
          "concepts": [
            {"name": "concept1", "mesh_terms": ["MeSH Term"], "keywords": ["keyword"]},
            {"name": "concept2", "mesh_terms": ["MeSH Term"], "keywords": ["keyword"]}
          ]
        }

        Example for "amlodipine improves arterial stiffness":
        {
          "concepts": [
            {"name": "amlodipine", "mesh_terms": ["Amlodipine"], "keywords": ["amlodipine"]},
            {"name": "arterial stiffness", "mesh_terms": ["Vascular Stiffness"], "keywords": ["arterial stiffness", "pulse wave velocity"]}
          ]
        }

        Generate JSON for the research question:
        """
    }

    // MARK: - HyDE Generation

    /// Generate a prompt for creating a Hypothetical Document Embedding (HyDE).
    ///
    /// HyDE improves semantic similarity search by generating a hypothetical
    /// abstract that would answer the claim, then using its embedding for
    /// comparison instead of the short claim text.
    ///
    /// Worded as a search aid, not a study to invent: asked for "a real
    /// published study" with numbers, Claude Haiku 5.5 refused some (#819).
    ///
    /// - Parameter claim: The medical claim to generate a hypothetical abstract for.
    /// - Returns: Formatted prompt string.
    public static func hydeGeneration(claim: String) -> String {
        """
        Write a short passage (150-250 words) of the kind a biomedical research abstract answering the following claim or question would contain. It is used only to find related papers by text similarity, never shown or cited as evidence.

        Claim: \(claim)

        The passage should:
        - State the research question the claim raises
        - Name the study designs, populations, interventions and outcomes such research would use
        - Describe the kind of findings that would bear on the claim, in words, without numbers or statistics
        - Use the medical terminology a published abstract on this topic would use

        Output ONLY the passage, no title or labels.
        """
    }

    // MARK: - Alternative Query Generation

    /// Context for generating alternative search queries.
    public struct AlternativeQueryContext: Sendable {
        /// The original research question.
        public let claim: String

        /// The initial query that was tried.
        public let initialQuery: String?

        /// Total results from the initial search.
        public let totalResults: Int

        /// Number of relevant documents found.
        public let relevantCount: Int

        /// Alternative queries earlier rounds already ran, one line each: each
        /// query's concept names joined by " AND ", not the provider query
        /// string it ran as.
        public let triedQueries: [String]

        /// Initialize with search context.
        ///
        /// - Parameters:
        ///   - claim: The original research question.
        ///   - initialQuery: The initial query that was tried.
        ///   - totalResults: Total results from the initial search.
        ///   - relevantCount: Number of relevant documents found.
        ///   - triedQueries: Alternative queries earlier rounds already ran.
        public init(
            claim: String, initialQuery: String?, totalResults: Int, relevantCount: Int,
            triedQueries: [String] = []
        ) {
            self.claim = claim
            self.initialQuery = initialQuery
            self.totalResults = totalResults
            self.relevantCount = relevantCount
            self.triedQueries = triedQueries
        }
    }

    /// Generate a prompt for creating alternative search strategies.
    ///
    /// Called when the initial search doesn't find enough relevant documents,
    /// and for each further round the reader asks for.
    /// The LLM generates 2-3 alternative structured queries using different
    /// search approaches.
    ///
    /// - Parameter context: Context about the initial search results.
    /// - Returns: Formatted prompt string.
    public static func alternativeQueries(context: AlternativeQueryContext) -> String {
        """
        The following medical question did not return enough relevant results with the initial search.

        Question: \(context.claim)
        Initial query: \(context.initialQuery ?? "N/A")
        Results found: \(context.totalResults)
        Relevant documents: \(context.relevantCount)
        \(triedQueriesSection(context.triedQueries))
        Generate 2-3 alternative search strategies as structured queries. Consider:
        1. If comparing two treatments/medications, search for each one separately
        2. Use different synonyms or related terms
        3. Break compound questions into simpler components
        4. Try broader or narrower search terms
        5. Focus on key outcomes or mechanisms

        Return a JSON array of structured query objects. Each object should have:
        - "concepts": an array of concepts, each with "name", "mesh_terms", and "keywords"

        Example response:
        [
          {
            "concepts": [
              {"name": "treatment A", "mesh_terms": ["MeSH Term A"], "keywords": ["keyword A"]},
              {"name": "condition", "mesh_terms": ["Condition MeSH"], "keywords": ["condition"]}
            ]
          },
          {
            "concepts": [
              {"name": "treatment B", "mesh_terms": ["MeSH Term B"], "keywords": ["keyword B"]},
              {"name": "condition", "mesh_terms": ["Condition MeSH"], "keywords": ["condition"]}
            ]
          }
        ]

        Generate alternative structured queries for the medical question:
        """
    }

    /// The prompt's lines naming the alternative queries already run, so a
    /// later round asks for different ones; empty on the first round.
    private static func triedQueriesSection(_ tried: [String]) -> String {
        guard !tried.isEmpty else { return "" }
        let lines = tried.map { "- \($0)" }.joined(separator: "\n")
        return """

        These alternative queries were already run. \
        Do not repeat them; take different approaches (broader terms, related \
        conditions, mechanisms or outcomes):
        \(lines)

        """
    }

    // MARK: - Report Generation

    /// Context for generating an evidence report.
    public struct ReportContext: Sendable {
        /// The medical claim being evaluated.
        public let claim: String

        /// Formatted citations text.
        public let citationsText: String

        /// Number of citations.
        public let citationCount: Int

        /// Number of source documents.
        public let documentCount: Int

        /// Initialize with report context.
        ///
        /// - Parameters:
        ///   - claim: The medical claim being evaluated.
        ///   - citationsText: Formatted citations text.
        ///   - citationCount: Number of citations.
        ///   - documentCount: Number of source documents.
        public init(claim: String, citationsText: String, citationCount: Int, documentCount: Int) {
            self.claim = claim
            self.citationsText = citationsText
            self.citationCount = citationCount
            self.documentCount = documentCount
        }
    }

    /// Generate a prompt for synthesizing an evidence report.
    ///
    /// The LLM analyzes citations and produces a structured verdict with
    /// supporting evidence and limitations.
    ///
    /// - Parameter context: Context about the claim and evidence.
    /// - Returns: Formatted prompt string.
    public static func reportGeneration(context: ReportContext) -> String {
        """
        You are a medical evidence synthesizer. Analyze the following evidence to evaluate a medical claim.

        Claim: \(context.claim)

        Evidence from \(context.citationCount) citation(s) across \(context.documentCount) document(s):

        \(context.citationsText)

        EVIDENCE WEIGHING PRINCIPLES:
        When synthesizing evidence, consider both supporting AND refuting findings. Evidence quality hierarchy (highest to lowest):
        1. Systematic reviews and meta-analyses (strongest - synthesize multiple studies)
        2. Randomized controlled trials (RCTs) - especially large, well-designed ones
        3. Cohort studies (prospective stronger than retrospective)
        4. Case-control studies
        5. Case series and case reports (weakest)
        6. Narrative reviews and expert opinion

        Also consider:
        - Sample size: Larger studies (thousands) carry more weight than small ones (dozens)
        - A single high-quality RCT can outweigh multiple observational studies
        - If high-quality evidence conflicts with lower-quality evidence, prioritize the higher-quality
        - Report the balance of evidence fairly - if most evidence refutes the claim, the verdict should reflect that

        Write an evidence report that:
        1. States a verdict: Supported, Partially Supported, Not Supported, Insufficient Evidence, or Conflicting Evidence
        2. Provides a 2-3 sentence summary of the key findings
        3. Discusses the evidence briefly with inline citations, noting study quality where relevant
        4. Notes any important limitations
        5. If evidence conflicts, explain which findings carry more weight and why

        CRITICAL - Citation format:
        Use this EXACT format for all inline citations: [Author, Year](doc:ID)
        Example: [Smith et al., 2021](doc:8A1D4C22-9F3B-4E77-B0A6-2C51D9E4F108)
        The ID must be copied EXACTLY from the "ID:" field provided for each citation above.
        Do NOT invent or modify IDs - use only the IDs provided.

        IMPORTANT: Use proper markdown with:
        - ## Headers for sections
        - **Bold** for emphasis
        - Bullet points with -
        - Blank lines between paragraphs (use \\n\\n in JSON)

        Respond in JSON format only:
        {
            "verdict": "<one of: Supported, Partially Supported, Not Supported, Insufficient Evidence, Conflicting Evidence>",
            "summary": "<2-3 sentence summary>",
            "full_report": "<markdown report with proper line breaks using \\n\\n between sections>"
        }
        """
    }
}
