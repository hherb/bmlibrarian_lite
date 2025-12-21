"""
Report display tab for BMLibrarian Lite.

Provides a dedicated full-screen view for systematic review reports with:
- HTML-rendered markdown reports
- Clickable citations that open documents in the interrogation tab
- Load/export functionality
- Audit trail viewing
"""

import json
import logging
import re
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

from PySide6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QTextBrowser,
    QPushButton,
    QLabel,
    QFileDialog,
    QMessageBox,
    QDialog,
    QDialogButtonBox,
)
from PySide6.QtCore import Signal, QUrl

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..config import LiteConfig
from ..storage import LiteStorage
from ..data_models import LiteDocument, ScoredDocument, Citation, ReportMetadata
from ..quality import QualityAssessment

# Directory for auto-saved reports
REPORTS_DIR = Path.home() / "bmlibrarian_reports" / "LITE"

logger = logging.getLogger(__name__)


class ReportTab(QWidget):
    """
    Report display tab widget.

    Provides a full-screen view for displaying and interacting with
    systematic review reports. Reports are rendered as HTML with
    clickable citations.

    Attributes:
        config: Lite configuration
        storage: Storage layer

    Signals:
        document_requested: Emitted when user clicks a citation (document_id)
    """

    # Emitted when user clicks a citation link in the report
    document_requested = Signal(str)  # document_id

    def __init__(
        self,
        config: LiteConfig,
        storage: LiteStorage,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the report tab.

        Args:
            config: Lite configuration
            storage: Storage layer
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.config = config
        self.storage = storage

        self._current_report: str = ""
        self._current_question: str = ""

        # Store citations by document ID for later access
        self._citations_by_doc_id: Dict[str, Citation] = {}

        # Audit trail data
        self._documents_found: List[LiteDocument] = []
        self._scored_documents: List[ScoredDocument] = []
        self._all_citations: List[Citation] = []
        self._quality_assessments: Dict[str, QualityAssessment] = {}
        self._current_report_path: Optional[Path] = None
        self._loaded_audit_data: Optional[Dict[str, Any]] = None
        self._report_metadata: Optional[ReportMetadata] = None

        # Ensure reports directory exists
        REPORTS_DIR.mkdir(parents=True, exist_ok=True)

        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the user interface."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(8))
        layout.setContentsMargins(scaled(8), scaled(8), scaled(8), scaled(8))

        # Status label at top
        self.status_label = QLabel("No report loaded")
        layout.addWidget(self.status_label)

        # Report display - takes most of the space
        self.report_view = QTextBrowser()
        self.report_view.setReadOnly(True)
        self.report_view.setOpenExternalLinks(False)
        self.report_view.setOpenLinks(False)
        self.report_view.anchorClicked.connect(self._on_citation_clicked)
        self.report_view.setPlaceholderText(
            "Reports will appear here after running a systematic review...\n\n"
            "Use the Systematic Review tab to:\n"
            "1. Enter a research question\n"
            "2. Search PubMed for relevant articles\n"
            "3. Score and extract citations\n"
            "4. Generate a comprehensive report\n\n"
            "Click on any citation to open the document for detailed Q&A.\n\n"
            "You can also load a previously saved report using the Load Report button."
        )
        layout.addWidget(self.report_view, stretch=1)

        # Button row at bottom
        button_layout = QHBoxLayout()

        # Load Report button
        self.load_btn = QPushButton("Load Report")
        self.load_btn.clicked.connect(self._load_report)
        self.load_btn.setToolTip("Load a previously saved report")
        button_layout.addWidget(self.load_btn)

        # Audit Trail button
        self.audit_btn = QPushButton("Audit Trail")
        self.audit_btn.setEnabled(False)
        self.audit_btn.clicked.connect(self._show_audit_trail)
        self.audit_btn.setToolTip(
            "View which documents were found, scored, and used for citations"
        )
        button_layout.addWidget(self.audit_btn)

        button_layout.addStretch()

        self.export_btn = QPushButton("Export Report")
        self.export_btn.setEnabled(False)
        self.export_btn.clicked.connect(self._export_report)
        self.export_btn.setToolTip("Save report to file")
        button_layout.addWidget(self.export_btn)

        layout.addLayout(button_layout)

    def display_report(
        self,
        report: str,
        question: str,
        citations: List[Citation],
        documents_found: List[LiteDocument],
        scored_documents: List[ScoredDocument],
        quality_assessments: Optional[Dict[str, QualityAssessment]] = None,
        quality_filter_settings: Optional[Dict[str, Any]] = None,
        report_metadata: Optional[ReportMetadata] = None,
    ) -> None:
        """
        Display a report from the systematic review workflow.

        Args:
            report: Markdown report content
            question: Research question
            citations: List of citations extracted
            documents_found: All documents found in search
            scored_documents: Documents that passed scoring
            quality_assessments: Optional quality assessments by doc ID
            quality_filter_settings: Optional quality filter settings used
            report_metadata: Optional metadata for reproducibility
        """
        self._current_report = report
        self._current_question = question
        self._all_citations = citations
        self._documents_found = documents_found
        self._scored_documents = scored_documents
        self._quality_assessments = quality_assessments or {}
        self._quality_filter_settings = quality_filter_settings
        self._report_metadata = report_metadata

        # Store citations by document ID
        self._citations_by_doc_id.clear()
        for citation in citations:
            doc_id = citation.document.id
            self._citations_by_doc_id[doc_id] = citation

        # Convert and display
        html_report = self._make_citations_clickable(report)
        self.report_view.setHtml(html_report)

        # Update UI state
        self.status_label.setText(
            f"Report generated - {len(citations)} citations | "
            "Click citations to view documents"
        )
        self.export_btn.setEnabled(bool(report))
        self.audit_btn.setEnabled(bool(scored_documents))

        # Auto-save the report
        if report and not report.startswith(("No documents", "Workflow cancelled")):
            self._auto_save_report()

    def _make_citations_clickable(self, markdown_report: str) -> str:
        """
        Convert markdown report to HTML with clickable citation links.

        Handles two citation formats:
        1. New format: [Author et al., 2023](docid:pmid-12345) - document ID in link
        2. Legacy format: [Author et al., 2023] - uses fuzzy matching (fallback)

        Args:
            markdown_report: Original markdown report

        Returns:
            HTML with clickable citation links
        """
        import markdown

        # Step 1: Convert docid: links to bmlibrarian:// links BEFORE markdown processing
        docid_pattern = r'\[([^\]]+)\]\(docid:([^)]+)\)'

        def replace_docid_link(match: re.Match) -> str:
            citation_text = match.group(1)
            doc_id = match.group(2)
            if doc_id in self._citations_by_doc_id:
                return f'[{citation_text}](bmlibrarian://doc/{doc_id})'
            logger.warning(f"Document ID '{doc_id}' not found in citations")
            return f'[{citation_text}]'

        processed_markdown = re.sub(docid_pattern, replace_docid_link, markdown_report)

        # Step 2: Convert markdown to HTML
        md = markdown.Markdown(extensions=['extra', 'nl2br', 'sane_lists'])
        html = md.convert(processed_markdown)

        # Step 3: Handle legacy citations (fallback)
        legacy_pattern = r'\[([A-Za-z][^,\[\]]+(?:,\s*\d{4})?)\](?!\()'

        def replace_legacy_citation(match: re.Match) -> str:
            citation_text = match.group(1)
            doc_id = self._find_document_by_citation(citation_text)
            if doc_id:
                return f'<a href="bmlibrarian://doc/{doc_id}" style="color: #2196F3; text-decoration: underline; cursor: pointer;">[{citation_text}]</a>'
            return match.group(0)

        html = re.sub(legacy_pattern, replace_legacy_citation, html)

        # Wrap in HTML structure with styling
        styled_html = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body {{
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
                    font-size: 14px;
                    line-height: 1.6;
                    color: #333;
                    padding: 8px;
                }}
                h1, h2, h3 {{ color: #1a1a1a; }}
                h1 {{ font-size: 1.5em; border-bottom: 1px solid #eee; padding-bottom: 0.3em; }}
                h2 {{ font-size: 1.3em; }}
                h3 {{ font-size: 1.1em; }}
                blockquote {{
                    border-left: 3px solid #2196F3;
                    padding-left: 1em;
                    margin-left: 0;
                    color: #555;
                    background-color: #f8f9fa;
                }}
                a {{
                    color: #2196F3;
                    text-decoration: none;
                }}
                a:hover {{
                    text-decoration: underline;
                }}
                ul, ol {{ padding-left: 1.5em; }}
                code {{
                    background-color: #f0f0f0;
                    padding: 2px 4px;
                    border-radius: 3px;
                }}
            </style>
        </head>
        <body>
        {html}
        </body>
        </html>
        """
        return styled_html

    def _find_document_by_citation(self, citation_text: str) -> Optional[str]:
        """
        Find document ID from citation text using fuzzy matching.

        Args:
            citation_text: Citation text to match (e.g., "Smith et al., 2023")

        Returns:
            Document ID if found, None otherwise
        """
        citation_lower = citation_text.lower()

        for doc_id, citation in self._citations_by_doc_id.items():
            doc = citation.document
            formatted_authors = doc.formatted_authors.lower()

            year_match = re.search(r'(\d{4})', citation_text)
            citation_year = year_match.group(1) if year_match else None

            if doc.authors:
                first_author_last = doc.authors[0].split()[-1].lower()
                if first_author_last in citation_lower:
                    if citation_year:
                        if doc.year and str(doc.year) == citation_year:
                            return doc_id
                    else:
                        return doc_id

            if formatted_authors.split(',')[0] in citation_lower:
                if citation_year:
                    if doc.year and str(doc.year) == citation_year:
                        return doc_id
                else:
                    return doc_id

        return None

    def _on_citation_clicked(self, url: QUrl) -> None:
        """
        Handle citation link click.

        Args:
            url: Clicked URL (bmlibrarian://doc/{doc_id})
        """
        if url.scheme() == "bmlibrarian" and url.host() == "doc":
            doc_id = url.path().lstrip('/')
            logger.info(f"Citation clicked: {doc_id}")
            self.document_requested.emit(doc_id)
        elif url.scheme() in ("http", "https"):
            from PySide6.QtGui import QDesktopServices
            QDesktopServices.openUrl(url)

    def get_citation(self, doc_id: str) -> Optional[Citation]:
        """
        Get citation by document ID.

        Args:
            doc_id: Document ID

        Returns:
            Citation if found, None otherwise
        """
        return self._citations_by_doc_id.get(doc_id)

    def _export_report(self) -> None:
        """Export the report to a file."""
        if not self._current_report:
            return

        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export Report",
            "research_report.md",
            "Markdown (*.md);;Text (*.txt);;All Files (*)",
        )

        if file_path:
            try:
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(self._current_report)
                self.status_label.setText(f"Report exported to {file_path}")
            except Exception as e:
                self.status_label.setText(f"Export failed: {e}")

    def _auto_save_report(self) -> None:
        """
        Auto-save report with audit trail to ~/bmlibrarian_reports/.

        Creates two files:
        - {timestamp}_report.md: The markdown report
        - {timestamp}_audit.json: Full audit trail with documents, scores, citations
        """
        try:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            safe_question = re.sub(r'[^\w\s-]', '', self._current_question)[:50].strip()
            safe_question = re.sub(r'\s+', '_', safe_question)

            report_path = REPORTS_DIR / f"{timestamp}_{safe_question}_report.md"
            audit_path = REPORTS_DIR / f"{timestamp}_{safe_question}_audit.json"

            # Save the markdown report
            with open(report_path, "w", encoding="utf-8") as f:
                f.write(self._current_report)

            # Build audit trail
            quality_filter_settings = getattr(self, '_quality_filter_settings', None) or {}

            # Include methodology from report metadata if available
            methodology = None
            report_metadata = getattr(self, '_report_metadata', None)
            if report_metadata:
                methodology = report_metadata.to_dict()

            audit_data = {
                "metadata": {
                    "timestamp": datetime.now().isoformat(),
                    "research_question": self._current_question,
                    "report_file": str(report_path),
                    "version": methodology.get("version", 1) if methodology else 1,
                },
                "methodology": methodology,
                "workflow_summary": {
                    "documents_searched": len(self._documents_found),
                    "documents_scored_relevant": len(self._scored_documents),
                    "documents_rejected": len(self._documents_found) - len(self._scored_documents),
                    "citations_extracted": len(self._all_citations),
                    "quality_filter_applied": bool(quality_filter_settings),
                    "quality_assessments_count": len(self._quality_assessments),
                },
                "quality_filter_settings": quality_filter_settings,
                "documents_found": [
                    {
                        "id": doc.id,
                        "title": doc.title,
                        "authors": doc.authors,
                        "year": doc.year,
                        "journal": doc.journal,
                        "pmid": doc.pmid,
                        "doi": doc.doi,
                        "quality_assessment": (
                            {
                                "study_design": self._quality_assessments[doc.id].study_design.value,
                                "quality_tier": self._quality_assessments[doc.id].quality_tier.name,
                                "quality_score": self._quality_assessments[doc.id].quality_score,
                                "confidence": self._quality_assessments[doc.id].confidence,
                                "assessment_tier": self._quality_assessments[doc.id].assessment_tier,
                            }
                            if doc.id in self._quality_assessments
                            else None
                        ),
                    }
                    for doc in self._documents_found
                ],
                "scored_documents": [
                    {
                        "id": sd.document.id,
                        "title": sd.document.title,
                        "score": sd.score,
                        "explanation": sd.explanation,
                        "is_relevant": sd.is_relevant,
                    }
                    for sd in self._scored_documents
                ],
                "rejected_documents": [
                    {
                        "id": doc.id,
                        "title": doc.title,
                        "reason": "Score below minimum threshold",
                    }
                    for doc in self._documents_found
                    if doc.id not in {sd.document.id for sd in self._scored_documents}
                ],
                "citations": [
                    {
                        "document_id": c.document.id,
                        "document_title": c.document.title,
                        "document_abstract": c.document.abstract,
                        "document_authors": c.document.authors,
                        "document_year": c.document.year,
                        "document_journal": c.document.journal,
                        "document_doi": c.document.doi,
                        "document_pmid": c.document.pmid,
                        "document_pmc_id": c.document.pmc_id,
                        "passage": c.passage,
                        "relevance_score": c.relevance_score,
                        "context": c.context,
                    }
                    for c in self._all_citations
                ],
            }

            with open(audit_path, "w", encoding="utf-8") as f:
                json.dump(audit_data, f, indent=2, ensure_ascii=False)

            self._current_report_path = report_path
            logger.info(f"Auto-saved report to {report_path}")

        except Exception as e:
            logger.warning(f"Failed to auto-save report: {e}")

    def _load_report(self) -> None:
        """Load a previously saved report with its audit trail."""
        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Load Report",
            str(REPORTS_DIR),
            "Markdown (*.md);;All Files (*)",
        )

        if not file_path:
            return

        path = Path(file_path)
        if not path.exists():
            QMessageBox.warning(self, "File Not Found", f"File not found: {path}")
            return

        try:
            # Load the markdown report
            report = path.read_text(encoding="utf-8")
            self._current_report = report

            # Try to load the accompanying audit file
            audit_path = path.with_name(path.name.replace("_report.md", "_audit.json"))
            if audit_path.exists():
                with open(audit_path, "r", encoding="utf-8") as f:
                    audit_data = json.load(f)

                # Restore research question
                self._current_question = audit_data.get("metadata", {}).get(
                    "research_question", ""
                )

                # Restore citations for clickable links
                self._citations_by_doc_id.clear()
                for cit_data in audit_data.get("citations", []):
                    doc = LiteDocument(
                        id=cit_data["document_id"],
                        title=cit_data["document_title"],
                        abstract=cit_data.get("document_abstract", ""),
                        authors=cit_data.get("document_authors", []),
                        year=cit_data.get("document_year"),
                        journal=cit_data.get("document_journal"),
                        doi=cit_data.get("document_doi"),
                        pmid=cit_data.get("document_pmid"),
                        pmc_id=cit_data.get("document_pmc_id"),
                    )
                    citation = Citation(
                        document=doc,
                        passage=cit_data["passage"],
                        relevance_score=cit_data["relevance_score"],
                        context=cit_data.get("context", ""),
                    )
                    self._citations_by_doc_id[doc.id] = citation

                self.audit_btn.setEnabled(True)
                self._current_report_path = path
                self._loaded_audit_data = audit_data

                self.status_label.setText(
                    f"Loaded report with {len(self._citations_by_doc_id)} citations"
                )
            else:
                self.status_label.setText("Loaded report (no audit trail found)")

            # Display the report
            html_report = self._make_citations_clickable(report)
            self.report_view.setHtml(html_report)
            self.export_btn.setEnabled(True)

        except Exception as e:
            logger.exception("Failed to load report")
            QMessageBox.critical(self, "Load Error", f"Failed to load report:\n{e}")

    def _show_audit_trail(self) -> None:
        """Show the audit trail dialog with workflow details."""
        if self._loaded_audit_data:
            audit_data = self._loaded_audit_data
        else:
            audit_data = {
                "metadata": {
                    "research_question": self._current_question,
                },
                "workflow_summary": {
                    "documents_searched": len(self._documents_found),
                    "documents_scored_relevant": len(self._scored_documents),
                    "documents_rejected": len(self._documents_found) - len(self._scored_documents),
                    "citations_extracted": len(self._all_citations),
                },
                "scored_documents": [
                    {
                        "id": sd.document.id,
                        "title": sd.document.title,
                        "score": sd.score,
                        "explanation": sd.explanation,
                    }
                    for sd in self._scored_documents
                ],
                "rejected_documents": [
                    {
                        "id": doc.id,
                        "title": doc.title,
                    }
                    for doc in self._documents_found
                    if doc.id not in {sd.document.id for sd in self._scored_documents}
                ],
                "citations": [
                    {
                        "document_title": c.document.title,
                        "passage": c.passage[:200] + "..." if len(c.passage) > 200 else c.passage,
                        "relevance_score": c.relevance_score,
                    }
                    for c in self._all_citations
                ],
            }

        lines = [
            "# Audit Trail",
            "",
            f"**Research Question:** {audit_data['metadata']['research_question']}",
            "",
            "## Summary",
            "",
            f"- Documents searched: {audit_data['workflow_summary']['documents_searched']}",
            f"- Documents scored as relevant: {audit_data['workflow_summary']['documents_scored_relevant']}",
            f"- Documents rejected: {audit_data['workflow_summary']['documents_rejected']}",
            f"- Citations extracted: {audit_data['workflow_summary']['citations_extracted']}",
            "",
            "## Relevant Documents (with scores)",
            "",
        ]

        for sd in audit_data.get("scored_documents", []):
            lines.append(f"### {sd['title']}")
            lines.append(f"- **Score:** {sd['score']}/5")
            lines.append(f"- **ID:** {sd['id']}")
            if sd.get('explanation'):
                lines.append(f"- **Explanation:** {sd['explanation']}")
            lines.append("")

        lines.append("## Rejected Documents")
        lines.append("")

        rejected = audit_data.get("rejected_documents", [])
        if rejected:
            for rd in rejected[:20]:
                lines.append(f"- {rd['title']}")
            if len(rejected) > 20:
                lines.append(f"- ... and {len(rejected) - 20} more")
        else:
            lines.append("*No documents were rejected*")

        lines.append("")
        lines.append("## Citations Extracted")
        lines.append("")

        for i, cit in enumerate(audit_data.get("citations", []), 1):
            lines.append(f"### Citation {i}: {cit['document_title']}")
            lines.append(f"> {cit['passage']}")
            lines.append("")

        audit_text = "\n".join(lines)

        dialog = QDialog(self)
        dialog.setWindowTitle("Audit Trail")
        dialog.resize(scaled(600), scaled(500))

        layout = QVBoxLayout(dialog)

        audit_view = QTextBrowser()
        audit_view.setOpenExternalLinks(False)

        import markdown as md
        html = md.markdown(audit_text, extensions=['extra', 'nl2br'])
        audit_view.setHtml(f"""
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                       font-size: 13px; line-height: 1.5; padding: 10px; }}
                h1 {{ color: #1a1a1a; font-size: 1.4em; border-bottom: 1px solid #eee; }}
                h2 {{ color: #333; font-size: 1.2em; }}
                h3 {{ color: #444; font-size: 1.05em; }}
                blockquote {{ border-left: 3px solid #2196F3; padding-left: 10px;
                             color: #555; background: #f9f9f9; margin: 5px 0; }}
                ul {{ padding-left: 20px; }}
            </style>
        </head>
        <body>{html}</body>
        </html>
        """)
        layout.addWidget(audit_view)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        buttons.rejected.connect(dialog.reject)
        layout.addWidget(buttons)

        dialog.exec()
