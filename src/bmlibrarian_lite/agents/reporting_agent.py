# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""Lite report generation agent.

This agent synthesizes evidence from multiple citations into a coherent,
professional research summary with proper attribution.
"""

import logging

from ..data_models import Citation, ReportMetadata
from ..transparency.transparency_models import TransparencyResult
from .base import LiteBaseAgent
from .report_risk_helpers import (
    build_risk_context_for_prompt,
    format_reference_risk_annotation,
    should_warn_for_citation,
)

logger = logging.getLogger(__name__)

# System prompt for report generation
REPORTING_SYSTEM_PROMPT = """You are a medical research report writer. Your task is to synthesize evidence from multiple sources into a coherent, professional research summary.

Guidelines:
1. Write in clear, professional medical prose
2. Cite sources using EXACTLY this markdown link format: [Author, Year](docid:DOCUMENT_ID)
   - Copy the "Source:" line exactly as the citation text (e.g., "Smith et al., 2023")
   - Copy the "Document ID:" exactly as the docid value (e.g., "pmid-12345")
   - Example: [Smith et al., 2023](docid:pmid-12345)
   - NEVER invent or modify IDs - use ONLY the exact values provided
3. If multiple passages come from the same source, cite it ONCE per statement, not once per passage
4. Organize findings by themes or topics, not by source
5. Include specific data and findings when available
6. Note any conflicting or contrasting evidence
7. Conclude with a summary of the key findings
8. Use specific years (e.g., "In a 2023 study") - NEVER use vague phrases like "recent studies" or "recently"

Structure your report with:
- An introduction addressing the research question
- Body paragraphs organized thematically
- A conclusion summarizing key findings

Do NOT simply list sources - synthesize the information into a flowing narrative.
IMPORTANT: Every citation MUST use the markdown link format [Author, Year](docid:ID) with the exact values provided."""


class LiteReportingAgent(LiteBaseAgent):
    """Stateless report generation agent.

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
        metadata: ReportMetadata | None = None,
        transparency_results: dict[str, TransparencyResult] | None = None,
    ) -> str:
        """Generate a research report from citations.

        Args:
            question: Research question
            citations: List of citations to synthesize
            metadata: Optional report metadata for methodology section
            transparency_results: Optional dict mapping document_id to TransparencyResult

        Returns:
            Formatted research report as markdown
        """
        if not citations:
            # Check if we had relevant documents but citation extraction failed
            had_relevant_docs = (
                metadata is not None
                and metadata.documents_accepted > 0
            )
            report = self._generate_no_evidence_report(
                question,
                citation_extraction_failed=had_relevant_docs,
            )
            if metadata:
                report += "\n\n" + self.format_methodology_section(metadata)
            return report

        # Format citations for the prompt
        formatted_citations = self._format_citations_for_prompt(citations)

        # Build doc_order and doc_to_ref mapping for risk context
        doc_order: list[str] = []
        doc_to_ref: dict[str, str] = {}
        for citation in citations:
            doc_id = citation.document.id
            if doc_id not in doc_to_ref:
                doc_order.append(doc_id)
                doc_to_ref[doc_id] = citation.formatted_reference

        # Identify risky citations based on threshold
        risky_doc_results: dict[str, TransparencyResult] = {}
        if transparency_results and hasattr(self.config, "transparency"):
            settings = self.config.transparency
            for doc_id in doc_order:
                if doc_id in transparency_results:
                    result = transparency_results[doc_id]
                    if should_warn_for_citation(result, settings):
                        risky_doc_results[doc_id] = result

        # Build risk context for LLM prompt
        risk_context = ""
        if risky_doc_results:
            # Build mapping of citation number to (author_ref, result)
            risky_citations_for_prompt: dict[int, tuple[str, TransparencyResult]] = {}
            for i, doc_id in enumerate(doc_order, 1):
                if doc_id in risky_doc_results:
                    risky_citations_for_prompt[i] = (
                        doc_to_ref[doc_id],
                        risky_doc_results[doc_id],
                    )
            risk_context = build_risk_context_for_prompt(risky_citations_for_prompt)

        # Count unique documents
        unique_doc_ids = {c.document.id for c in citations}
        user_prompt = f"""Research Question: {question}

Evidence from {len(unique_doc_ids)} source(s) ({len(citations)} passages total):

{formatted_citations}
{risk_context}
Write a comprehensive research summary that synthesizes this evidence to answer the research question.

CITATION FORMAT - MANDATORY:
- Use this exact format: [Source](docid:Document ID)
- Copy the "Source:" value as the link text
- Copy the "Document ID:" value as the docid
- Example: [Smith et al., 2023](docid:pmid-12345678)

IMPORTANT: Use ONLY the exact Source and Document ID values provided above. Do not invent IDs."""

        messages = [
            self._create_system_message(REPORTING_SYSTEM_PROMPT),
            self._create_user_message(user_prompt),
        ]

        try:
            report = self._chat(messages, temperature=0.3, max_tokens=4096)

            # Add references section with risk annotations
            references = self._format_references_with_risk(citations, risky_doc_results)
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
        """Generate a brief summary of findings.

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

Write a brief summary (approximately {max_length} characters) of the key findings.

CITATION FORMAT: Use [Source](docid:Document ID) with exact values from above."""

        messages = [
            self._create_system_message(
                "You are a concise medical summarizer. "
                "Provide brief, accurate summaries with citations in "
                "[Author, Year](docid:ID) format."
            ),
            self._create_user_message(user_prompt),
        ]

        try:
            return self._chat(messages, temperature=0.2, max_tokens=1024)
        except Exception as e:
            logger.error(f"Failed to generate summary: {e}")
            return f"Error generating summary: {str(e)}"

    def _generate_no_evidence_report(
        self,
        question: str,
        citation_extraction_failed: bool = False,
    ) -> str:
        """Generate a report when no citations are available.

        Args:
            question: Research question
            citation_extraction_failed: True if relevant documents were found
                but citation extraction failed for all of them

        Returns:
            Report text explaining the situation
        """
        if citation_extraction_failed:
            return f"""## Research Summary

**Research Question:** {question}

Relevant documents were found during the search, but citation extraction was unable to identify specific passages from them. This may be due to:

1. API or network errors during citation extraction
2. Documents having abstracts that are difficult to parse
3. Temporary service issues

### Recommendations

- Try running the search again
- Review the scored documents in the Audit Trail to see what was found
- If the problem persists, check the application logs for errors

---

*No citations extracted*
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
        """Format citations for the LLM prompt.

        Groups passages by document so that multiple passages from the same
        source are presented together. Uses the document's short reference
        (Author, Year) as the citation key, which the LLM should use verbatim.

        Args:
            citations: List of citations

        Returns:
            Formatted string with citations grouped by document
        """
        # Group passages by document ID to present each source once
        doc_order: list[str] = []  # Preserve first-seen order
        doc_passages: dict[str, list[Citation]] = {}
        for citation in citations:
            doc_id = citation.document.id
            if doc_id not in doc_passages:
                doc_order.append(doc_id)
                doc_passages[doc_id] = []
            doc_passages[doc_id].append(citation)

        formatted = []
        for doc_id in doc_order:
            citation_list = doc_passages[doc_id]
            doc = citation_list[0].document
            short_ref = citation_list[0].formatted_reference

            # Format all passages from this document together
            passages_text = "\n".join(
                f'  - "{c.passage}"' for c in citation_list
            )
            formatted.append(f"""Source: {short_ref}
Document ID: {doc.id}
Title: {doc.title}
Authors: {doc.formatted_authors}
Year: {doc.year or 'n.d.'}
Journal: {doc.journal or 'Unknown'}
Key passages:
{passages_text}
""")
        return "\n".join(formatted)

    def _format_references(self, citations: list[Citation]) -> str:
        """Format reference list for the report.

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

    def _format_references_with_risk(
        self,
        citations: list[Citation],
        risky_doc_results: dict[str, TransparencyResult],
    ) -> str:
        """Format reference list with risk annotations for risky citations.

        Args:
            citations: List of citations
            risky_doc_results: Dict mapping document_id to TransparencyResult for risky docs

        Returns:
            Formatted reference list with risk annotations
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

            # Add risk annotation if this document is risky
            if doc.id in risky_doc_results:
                annotation = format_reference_risk_annotation(risky_doc_results[doc.id])
                if annotation:
                    references.append(annotation)

        return "\n".join(references)

    def get_citation_count(self, citations: list[Citation]) -> int:
        """Get unique document count from citations.

        Args:
            citations: List of citations

        Returns:
            Number of unique source documents
        """
        return len({c.document.id for c in citations})

    def export_report_with_metadata(
        self,
        question: str,
        report: str,
        citations: list[Citation],
    ) -> dict:
        """Export report with metadata for saving.

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
        """Format the methodology section for the report.

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
            lines.append("- **Filter Applied:** Yes")
            if metadata.quality_filter_settings:
                min_tier = metadata.quality_filter_settings.get("minimum_tier", "Unknown")
                lines.append(f"- **Minimum Tier:** {min_tier}")
            lines.append(
                f"- **Documents Filtered:** {metadata.documents_filtered_by_quality:,}"
            )
        else:
            lines.append("Quality filtering was not applied.")
        lines.append("")

        # Transparency analysis section
        lines.append("### Transparency Analysis")
        if metadata.transparency_analysis_applied:
            lines.append("- **Analysis Applied:** Yes")
            total_analyzed = (
                metadata.transparency_low_risk_count
                + metadata.transparency_medium_risk_count
                + metadata.transparency_high_risk_count
            )
            lines.append(f"- **Documents Analyzed:** {total_analyzed:,}")
            lines.append("")
            lines.append("**Risk Distribution:**")
            lines.append("")
            lines.append("| Risk Level | Count |")
            lines.append("|------------|-------|")
            lines.append(f"| Low        | {metadata.transparency_low_risk_count}     |")
            lines.append(
                f"| Medium     | {metadata.transparency_medium_risk_count}     |"
            )
            lines.append(f"| High       | {metadata.transparency_high_risk_count}     |")
        else:
            lines.append("Transparency analysis was not applied.")
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
            "*Report generated by BMLibrarian Lite*",
        ])

        # Add version and timestamp
        timestamp = metadata.generated_at.strftime("%Y-%m-%d %H:%M:%S")
        lines.append(f"*Version {metadata.version} | Generated: {timestamp}*")

        return "\n".join(lines)
