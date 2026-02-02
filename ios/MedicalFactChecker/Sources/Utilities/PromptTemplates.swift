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
enum PromptTemplates {
    // MARK: - Query Conversion

    /// Generate a prompt for converting a research question to a structured query.
    ///
    /// The LLM is asked to identify key concepts and provide MeSH terms and
    /// keywords for each. The output is JSON that can be parsed into a
    /// `StructuredQuery`.
    ///
    /// - Parameter claim: The research question or medical claim.
    /// - Returns: Formatted prompt string.
    static func queryConversion(claim: String) -> String {
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
    /// - Parameter claim: The medical claim to generate a hypothetical abstract for.
    /// - Returns: Formatted prompt string.
    static func hydeGeneration(claim: String) -> String {
        """
        Generate a hypothetical medical research abstract that would directly address and provide evidence for the following claim or question.

        Claim: \(claim)

        Write a realistic abstract (150-250 words) that:
        - Has a clear objective related to the claim
        - Describes methods briefly
        - States specific findings with numbers/percentages where appropriate
        - Draws a conclusion about the claim

        Output ONLY the abstract text, no title or labels. Write as if this were a real published study.
        """
    }

    // MARK: - Alternative Query Generation

    /// Context for generating alternative search queries.
    struct AlternativeQueryContext {
        /// The original research question.
        let claim: String

        /// The initial query that was tried.
        let initialQuery: String?

        /// Total results from the initial search.
        let totalResults: Int

        /// Number of relevant documents found.
        let relevantCount: Int
    }

    /// Generate a prompt for creating alternative search strategies.
    ///
    /// Called when the initial search doesn't find enough relevant documents.
    /// The LLM generates 2-3 alternative structured queries using different
    /// search approaches.
    ///
    /// - Parameter context: Context about the initial search results.
    /// - Returns: Formatted prompt string.
    static func alternativeQueries(context: AlternativeQueryContext) -> String {
        """
        The following medical question did not return enough relevant results with the initial search.

        Question: \(context.claim)
        Initial query: \(context.initialQuery ?? "N/A")
        Results found: \(context.totalResults)
        Relevant documents: \(context.relevantCount)

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

    // MARK: - Report Generation

    /// Context for generating an evidence report.
    struct ReportContext {
        /// The medical claim being evaluated.
        let claim: String

        /// Formatted citations text.
        let citationsText: String

        /// Number of citations.
        let citationCount: Int

        /// Number of source documents.
        let documentCount: Int
    }

    /// Generate a prompt for synthesizing an evidence report.
    ///
    /// The LLM analyzes citations and produces a structured verdict with
    /// supporting evidence and limitations.
    ///
    /// - Parameter context: Context about the claim and evidence.
    /// - Returns: Formatted prompt string.
    static func reportGeneration(context: ReportContext) -> String {
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
        Example: [Smith et al., 2021](doc:pmid-12345678)
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
