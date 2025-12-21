"""
Lite report generation agent.

This agent synthesizes evidence from multiple citations into a coherent,
professional research summary with proper attribution.
"""

import logging
from datetime import datetime
from typing import Optional

from ..data_models import Citation, ReportMetadata
from .base import LiteBaseAgent

logger = logging.getLogger(__name__)

# System prompt for report generation
REPORTING_SYSTEM_PROMPT = """You are a medical research report writer. Your task is to synthesize evidence from multiple sources into a coherent, professional research summary.

Guidelines:
1. Write in clear, professional medical prose
2. Cite sources using EXACTLY this markdown link format: [Author et al., Year](docid:DOCUMENT_ID)
   - The DOCUMENT_ID is provided in each source (e.g., "pmid-12345")
   - Example: [Smith et al., 2023](docid:pmid-12345)
   - You MUST use the exact document ID provided - never make up IDs
3. Organize findings by themes or topics, not by source
4. Include specific data and findings when available
5. Note any conflicting or contrasting evidence
6. Conclude with a summary of the key findings
7. Use specific years (e.g., "In a 2023 study") - NEVER use vague phrases like "recent studies" or "recently"

Structure your report with:
- An introduction addressing the research question
- Body paragraphs organized thematically
- A conclusion summarizing key findings

Do NOT simply list sources - synthesize the information into a flowing narrative.
IMPORTANT: Every citation MUST use the markdown link format [Author, Year](docid:ID) with the exact document ID provided."""


class LiteReportingAgent(LiteBaseAgent):
    """
    Stateless report generation agent.

    Synthesizes citations into a coherent research report with proper
    attribution and a references section.

    This agent:
    1. Takes a research question and list of citations
    2. Uses LLM to synthesize findings into a narrative
    3. Returns a formatted report with references
    """

    TASK_ID = "report_generation"

    def generate_report(
        self,
        question: str,
        citations: list[Citation],
        metadata: Optional[ReportMetadata] = None,
    ) -> str:
        """
        Generate a research report from citations.

        Args:
            question: Research question
            citations: List of citations to synthesize
            metadata: Optional report metadata for methodology section

        Returns:
            Formatted research report as markdown
        """
        if not citations:
            report = self._generate_no_evidence_report(question)
            if metadata:
                report += "\n\n" + self.format_methodology_section(metadata)
            return report

        # Format citations for the prompt
        formatted_citations = self._format_citations_for_prompt(citations)

        user_prompt = f"""Research Question: {question}

Evidence from {len(citations)} source passages:

{formatted_citations}

Write a comprehensive research summary that synthesizes this evidence to answer the research question.

CITATION FORMAT REQUIREMENT: Use markdown links with the Document ID for EVERY citation:
[Author et al., Year](docid:DOCUMENT_ID)

Example: If citing source [1] with Document ID "pmid-12345", write: [Smith et al., 2023](docid:pmid-12345)

This format is MANDATORY - do not use plain [Author, Year] citations."""

        messages = [
            self._create_system_message(REPORTING_SYSTEM_PROMPT),
            self._create_user_message(user_prompt),
        ]

        try:
            report = self._chat(messages, temperature=0.3, max_tokens=4096)

            # Add references section
            references = self._format_references(citations)
            full_report = f"{report}\n\n## References\n\n{references}"

            # Add methodology section if metadata provided
            if metadata:
                full_report += "\n\n" + self.format_methodology_section(metadata)

            return full_report

        except Exception as e:
            logger.error(f"Failed to generate report: {e}")
            return f"Error generating report: {str(e)}"

    def generate_brief_summary(
        self,
        question: str,
        citations: list[Citation],
        max_length: int = 500,
    ) -> str:
        """
        Generate a brief summary of findings.

        Args:
            question: Research question
            citations: List of citations
            max_length: Approximate maximum length in characters

        Returns:
            Brief summary text
        """
        if not citations:
            return "No relevant evidence was found for this research question."

        formatted_citations = self._format_citations_for_prompt(citations[:5])  # Limit for brevity

        user_prompt = f"""Research Question: {question}

Evidence from selected sources:

{formatted_citations}

Write a brief summary (approximately {max_length} characters) of the key findings. Include citations."""

        messages = [
            self._create_system_message(
                "You are a concise medical summarizer. "
                "Provide brief, accurate summaries with citations."
            ),
            self._create_user_message(user_prompt),
        ]

        try:
            return self._chat(messages, temperature=0.2, max_tokens=1024)
        except Exception as e:
            logger.error(f"Failed to generate summary: {e}")
            return f"Error generating summary: {str(e)}"

    def _generate_no_evidence_report(self, question: str) -> str:
        """
        Generate a report when no evidence is found.

        Args:
            question: Research question

        Returns:
            Report text explaining no evidence was found
        """
        return f"""## Research Summary

**Research Question:** {question}

No relevant evidence was found in the searched literature. This may indicate:

1. The topic has limited published research
2. The search terms may need refinement
3. The research question may need to be rephrased

### Recommendations

- Try broadening the search terms
- Consider related topics that may provide indirect evidence
- Check if the question can be broken into sub-questions
- Search additional databases or preprint servers

---

*No citations available*
"""

    def _format_citations_for_prompt(self, citations: list[Citation]) -> str:
        """
        Format citations for the LLM prompt.

        Includes document IDs so the LLM can create proper citation links.

        Args:
            citations: List of citations

        Returns:
            Formatted string with numbered citations including document IDs
        """
        formatted = []
        for i, citation in enumerate(citations, 1):
            doc = citation.document
            formatted.append(f"""[{i}] {doc.formatted_authors} ({doc.year or 'n.d.'})
Document ID: {doc.id}
Title: {doc.title}
Journal: {doc.journal or 'Unknown'}
Passage: "{citation.passage}"
""")
        return "\n".join(formatted)

    def _format_references(self, citations: list[Citation]) -> str:
        """
        Format reference list for the report.

        Args:
            citations: List of citations

        Returns:
            Formatted reference list
        """
        # Deduplicate by document ID
        seen: set[str] = set()
        unique_citations = []
        for citation in citations:
            if citation.document.id not in seen:
                seen.add(citation.document.id)
                unique_citations.append(citation)

        references = []
        for i, citation in enumerate(unique_citations, 1):
            doc = citation.document
            ref = f"{i}. {doc.formatted_authors}"
            if doc.year:
                ref += f" ({doc.year})"
            ref += f". {doc.title}"
            if doc.journal:
                ref += f". *{doc.journal}*"
            if doc.doi:
                ref += f". DOI: {doc.doi}"
            if doc.pmid:
                ref += f". PMID: {doc.pmid}"
            references.append(ref)

        return "\n".join(references)

    def get_citation_count(self, citations: list[Citation]) -> int:
        """
        Get unique document count from citations.

        Args:
            citations: List of citations

        Returns:
            Number of unique source documents
        """
        return len(set(c.document.id for c in citations))

    def export_report_with_metadata(
        self,
        question: str,
        report: str,
        citations: list[Citation],
    ) -> dict:
        """
        Export report with metadata for saving.

        Args:
            question: Research question
            report: Generated report text
            citations: List of citations used

        Returns:
            Dictionary with report and metadata
        """
        unique_docs = set()
        for c in citations:
            unique_docs.add(c.document.id)

        return {
            "research_question": question,
            "report": report,
            "citation_count": len(citations),
            "unique_source_count": len(unique_docs),
            "sources": [
                {
                    "id": c.document.id,
                    "title": c.document.title,
                    "authors": c.document.formatted_authors,
                    "year": c.document.year,
                    "pmid": c.document.pmid,
                    "passage": c.passage,
                }
                for c in citations
            ],
        }

    def format_methodology_section(self, metadata: ReportMetadata) -> str:
        """
        Format the methodology section for the report.

        Creates a structured markdown section containing all workflow
        parameters and statistics for reproducibility.

        Args:
            metadata: Report metadata with workflow details

        Returns:
            Formatted methodology section as markdown
        """
        lines = [
            "---",
            "",
            "## Methodology",
            "",
            "### Search Strategy",
            f"- **Research Question:** {metadata.research_question}",
            f"- **PubMed Query:** `{metadata.pubmed_query}`",
        ]

        # Add search date if available
        if metadata.pubmed_search_date:
            date_str = metadata.pubmed_search_date.strftime("%Y-%m-%d")
            lines.append(f"- **Search Date:** {date_str}")

        lines.extend([
            f"- **Total Results Available:** {metadata.total_results_available:,}",
            f"- **Documents Retrieved:** {metadata.documents_retrieved:,}",
            "",
            "### Document Screening",
            f"- **Scoring Threshold:** ≥{metadata.min_score_threshold}/5",
            f"- **Documents Scored:** {metadata.documents_scored:,}",
            f"- **Accepted:** {metadata.documents_accepted:,} | "
            f"**Rejected:** {metadata.documents_rejected:,}",
            "",
        ])

        # Add score distribution table
        if metadata.score_distribution:
            lines.extend([
                "**Score Distribution:**",
                "",
                "| Score | Count |",
                "|-------|-------|",
            ])
            for score in range(5, 0, -1):
                count = metadata.score_distribution.get(score, 0)
                lines.append(f"| {score}     | {count}     |")
            lines.append("")

        # Quality assessment section
        lines.append("### Quality Assessment")
        if metadata.quality_filter_applied:
            lines.append(f"- **Filter Applied:** Yes")
            if metadata.quality_filter_settings:
                min_tier = metadata.quality_filter_settings.get("minimum_tier", "Unknown")
                lines.append(f"- **Minimum Tier:** {min_tier}")
            lines.append(
                f"- **Documents Filtered:** {metadata.documents_filtered_by_quality:,}"
            )
        else:
            lines.append("Quality filtering was not applied.")
        lines.append("")

        # AI models section
        if metadata.model_configs:
            lines.extend([
                "### AI Models Used",
                "",
                "| Task | Provider | Model | Temperature |",
                "|------|----------|-------|-------------|",
            ])
            # Define task display names
            task_names = {
                "query_conversion": "Query Generation",
                "document_scoring": "Document Scoring",
                "citation_extraction": "Citation Extraction",
                "report_generation": "Report Generation",
                "quality_assessment": "Quality Assessment",
            }
            for task_id, config in metadata.model_configs.items():
                task_name = task_names.get(task_id, task_id.replace("_", " ").title())
                provider = config.get("provider", "unknown")
                model = config.get("model", "unknown")
                temp = config.get("temperature", "default")
                lines.append(f"| {task_name} | {provider} | {model} | {temp} |")
            lines.append("")

        # Citation summary
        lines.extend([
            "### Citation Summary",
            f"- **Citations Extracted:** {metadata.citations_extracted:,}",
            f"- **Unique Sources:** {metadata.unique_sources_cited:,}",
            "",
            "---",
            f"*Report generated by BMLibrarian Lite*",
        ])

        # Add version and timestamp
        timestamp = metadata.generated_at.strftime("%Y-%m-%d %H:%M:%S")
        lines.append(f"*Version {metadata.version} | Generated: {timestamp}*")

        return "\n".join(lines)
