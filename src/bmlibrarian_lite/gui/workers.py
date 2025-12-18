"""
Background worker threads for BMLibrarian Lite GUI.

Provides QThread-based workers for long-running operations:
- AnswerWorker: Generate answers using the interrogation agent
- PDFDiscoveryWorker: Discover and download PDFs from multiple sources
- FulltextDiscoveryWorker: Discover full-text via Europe PMC XML or PDF
- OpenAthensAuthWorker: Handle OpenAthens institutional authentication
- QualityFilterWorker: Filter documents by quality criteria

These workers allow the main GUI thread to remain responsive while
background operations execute.
"""

import logging
import webbrowser
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, TYPE_CHECKING

from PySide6.QtCore import QThread, Signal
from PySide6.QtWidgets import QWidget

from ..pdf_discovery import PDFDiscoverer, DiscoveryResult
from ..pdf_utils import generate_pdf_path
from ..fulltext_discovery import FulltextDiscoverer, FulltextResult, FulltextSourceType

if TYPE_CHECKING:
    from ..data_models import LiteDocument
    from ..quality.data_models import QualityFilter, QualityAssessment
    from ..quality.quality_manager import QualityManager

logger = logging.getLogger(__name__)


class AnswerWorker(QThread):
    """
    Background worker for generating answers.

    Executes the interrogation agent's ask() method in a background thread
    to prevent blocking the GUI.

    Signals:
        finished: Emitted when answer is ready (answer, sources)
        error: Emitted on error (error message)
    """

    finished = Signal(str, list)  # answer, sources
    error = Signal(str)

    def __init__(
        self,
        agent: 'LiteInterrogationAgent',
        question: str,
    ) -> None:
        """
        Initialize the answer worker.

        Args:
            agent: Interrogation agent instance
            question: Question to answer
        """
        super().__init__()
        self.agent = agent
        self.question = question

    def run(self) -> None:
        """Generate answer in background thread."""
        try:
            answer, sources = self.agent.ask(self.question)
            self.finished.emit(answer, sources)
        except Exception as e:
            logger.exception("Answer generation error")
            self.error.emit(str(e))


class PDFDiscoveryWorker(QThread):
    """
    Background worker for PDF discovery and download.

    Discovers and downloads PDFs from multiple sources:
    - PubMed Central (PMC) for open access articles
    - Unpaywall API for open access discovery
    - Direct DOI resolution

    Signals:
        progress: Emitted with (stage, status) during download
        finished: Emitted with file_path when download succeeds
        verification_warning: Emitted with (file_path, warning_message) on verification mismatch
        paywall_detected: Emitted with (article_url, error_message) when paywall blocks access
        error: Emitted with error message on failure
    """

    progress = Signal(str, str)  # stage, status
    finished = Signal(str)  # file_path on success
    verification_warning = Signal(str, str)  # file_path, warning_message
    paywall_detected = Signal(str, str)  # article_url, error_message
    error = Signal(str)  # error message

    def __init__(
        self,
        doc_dict: Dict[str, Any],
        output_dir: Path,
        unpaywall_email: Optional[str] = None,
        openathens_url: Optional[str] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize PDF discovery worker.

        Args:
            doc_dict: Document dictionary with doi, pmid, title, year, etc.
            output_dir: Base directory for PDF storage (year subdirs created)
            unpaywall_email: Email for Unpaywall API
            openathens_url: OpenAthens institution URL for authenticated downloads
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.doc_dict = doc_dict
        self.output_dir = output_dir
        self.unpaywall_email = unpaywall_email
        self.openathens_url = openathens_url
        self._cancelled = False
        self._discoverer: Optional[PDFDiscoverer] = None

    def run(self) -> None:
        """Execute PDF discovery and download."""
        try:
            # Extract identifiers from doc_dict
            doi = self.doc_dict.get("doi")
            pmid = self.doc_dict.get("pmid")
            pmcid = self.doc_dict.get("pmcid") or self.doc_dict.get("pmc_id")
            title = self.doc_dict.get("title")

            if not (doi or pmid or pmcid):
                self.error.emit(
                    "No identifiers available (DOI, PMID, or PMCID required).\n"
                    "Please enter an identifier manually."
                )
                return

            # Generate output path
            output_path = generate_pdf_path(self.doc_dict, self.output_dir)

            # Create discoverer with progress callback
            self._discoverer = PDFDiscoverer(
                unpaywall_email=self.unpaywall_email,
                openathens_url=self.openathens_url,
                progress_callback=self._emit_progress,
            )

            # Perform discovery and download
            result = self._discoverer.discover_and_download(
                output_path=output_path,
                doi=doi,
                pmid=pmid,
                pmcid=pmcid,
                title=title,
                expected_title=title,
            )

            # Handle result
            if self._cancelled:
                return

            if result.success:
                if result.verification_warning:
                    self.verification_warning.emit(
                        str(result.file_path),
                        result.verification_warning,
                    )
                self.finished.emit(str(result.file_path))
            elif result.is_paywall:
                self.paywall_detected.emit(
                    result.paywall_url or "",
                    result.error or "Access requires subscription",
                )
            else:
                self.error.emit(result.error or "Unknown error during PDF discovery")

        except Exception as e:
            logger.exception("PDF discovery failed")
            self.error.emit(f"PDF discovery error: {str(e)}")

    def _emit_progress(self, stage: str, status: str) -> None:
        """Emit progress signal from discoverer callback."""
        if not self._cancelled:
            self.progress.emit(stage, status)

    def cancel(self) -> None:
        """Request cancellation of the operation."""
        self._cancelled = True
        if self._discoverer:
            self._discoverer.cancel()


class FulltextDiscoveryWorker(QThread):
    """
    Background worker for full-text discovery.

    Discovers and retrieves full-text content from multiple sources:
    1. Cached full-text markdown (fastest)
    2. Europe PMC XML API (best quality)
    3. Cached PDF
    4. PDF download from various sources

    Signals:
        progress: Emitted with (stage, status) during discovery
        finished: Emitted with (markdown_content, file_path, source_type) on success
        paywall_detected: Emitted with (article_url, error_message) when paywall blocks access
        error: Emitted with error message on failure
    """

    progress = Signal(str, str)  # stage, status
    finished = Signal(str, str, str)  # markdown_content, file_path, source_type
    paywall_detected = Signal(str, str)  # article_url, error_message
    error = Signal(str)  # error message

    def __init__(
        self,
        doc_dict: Dict[str, Any],
        unpaywall_email: Optional[str] = None,
        openathens_url: Optional[str] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize full-text discovery worker.

        Args:
            doc_dict: Document dictionary with doi, pmid, pmcid, title, year, etc.
            unpaywall_email: Email for Unpaywall API
            openathens_url: OpenAthens institution URL for authenticated downloads
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.doc_dict = doc_dict
        self.unpaywall_email = unpaywall_email
        self.openathens_url = openathens_url
        self._cancelled = False
        self._discoverer: Optional[FulltextDiscoverer] = None

    def run(self) -> None:
        """Execute full-text discovery."""
        try:
            # Extract identifiers from doc_dict
            doi = self.doc_dict.get("doi")
            pmid = self.doc_dict.get("pmid")
            pmcid = self.doc_dict.get("pmcid") or self.doc_dict.get("pmc_id")
            title = self.doc_dict.get("title")

            if not (doi or pmid or pmcid):
                self.error.emit(
                    "No identifiers available (DOI, PMID, or PMCID required).\n"
                    "Please enter an identifier manually."
                )
                return

            # Create discoverer with progress callback
            self._discoverer = FulltextDiscoverer(
                unpaywall_email=self.unpaywall_email,
                openathens_url=self.openathens_url,
                progress_callback=self._emit_progress,
            )

            # Perform discovery
            result = self._discoverer.discover_fulltext(
                doc_dict=self.doc_dict,
            )

            # Handle result
            if self._cancelled:
                return

            if result.success:
                file_path = str(result.file_path) if result.file_path else ""
                self.finished.emit(
                    result.markdown_content or "",
                    file_path,
                    result.source_type.value,
                )
            elif result.is_paywall:
                self.paywall_detected.emit(
                    result.paywall_url or "",
                    result.error or "Access requires subscription",
                )
            else:
                self.error.emit(result.error or "Full-text not available")

        except Exception as e:
            logger.exception("Full-text discovery failed")
            self.error.emit(f"Full-text discovery error: {str(e)}")

    def _emit_progress(self, stage: str, status: str) -> None:
        """Emit progress signal from discoverer callback."""
        if not self._cancelled:
            self.progress.emit(stage, status)

    def cancel(self) -> None:
        """Request cancellation of the operation."""
        self._cancelled = True
        if self._discoverer:
            self._discoverer.cancel()


class OpenAthensAuthWorker(QThread):
    """
    Background worker for OpenAthens interactive authentication.

    Opens the institutional login page in the default web browser and
    waits for the user to complete authentication. The browser session
    will typically persist cookies that can be used for subsequent
    PDF downloads.

    Note: This is a simple browser-based authentication flow. For full
    automation, the main BMLibrarian application provides more advanced
    session management.

    Signals:
        finished: Emitted when authentication is presumed complete
        error: Emitted with error message on failure
    """

    finished = Signal()  # Authentication presumed complete
    error = Signal(str)  # error message

    def __init__(
        self,
        institution_url: str,
        session_max_age_hours: int = 24,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize OpenAthens authentication worker.

        Args:
            institution_url: Institution's OpenAthens login URL (HTTPS)
            session_max_age_hours: Maximum session age before re-authentication
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.institution_url = institution_url
        self.session_max_age_hours = session_max_age_hours

    def run(self) -> None:
        """Execute OpenAthens interactive authentication via browser."""
        try:
            if not self.institution_url:
                self.error.emit("No institution URL configured.")
                return

            # Convert domain to OpenAthens Redirector URL if needed
            institution_url = self.institution_url
            if not institution_url.startswith(("http://", "https://")):
                # Assume it's a domain - convert to OpenAthens Redirector URL
                # OpenAthens Redirector format: https://go.openathens.net/redirector/DOMAIN
                institution_url = f"https://go.openathens.net/redirector/{institution_url}"
                logger.info(f"Converted domain to OpenAthens Redirector URL: {institution_url}")

            logger.info(f"Opening browser for OpenAthens authentication: {institution_url}")

            # Open browser for authentication
            success = webbrowser.open(institution_url)

            if not success:
                self.error.emit(
                    "Could not open web browser.\n"
                    "Please open your browser manually and navigate to:\n"
                    f"{institution_url}"
                )
                return

            # Give the user time to authenticate (browser has been opened)
            # The actual authentication happens in the browser, and cookies
            # will be stored by the browser. For full session management,
            # the main BMLibrarian app provides more sophisticated handling.

            # Signal that browser was opened successfully
            # User will need to complete authentication in browser
            self.finished.emit()

        except Exception as e:
            logger.exception("OpenAthens authentication failed")
            self.error.emit(f"Authentication error: {str(e)}")


class QualityFilterWorker(QThread):
    """
    Background worker for quality filtering documents.

    Executes quality assessment and filtering in a background thread
    to prevent blocking the GUI during LLM calls.

    Signals:
        progress: Emitted during progress (current, total, assessment)
        finished: Emitted when filtering completes (filtered_docs, all_assessments)
        error: Emitted on error (error message)
    """

    progress = Signal(int, int, object)  # current, total, QualityAssessment
    finished = Signal(list, list)  # filtered docs, all assessments
    error = Signal(str)

    def __init__(
        self,
        quality_manager: "QualityManager",
        documents: List["LiteDocument"],
        filter_settings: "QualityFilter",
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the quality filter worker.

        Args:
            quality_manager: QualityManager instance for assessment
            documents: List of documents to filter
            filter_settings: Quality filter configuration
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.quality_manager = quality_manager
        self.documents = documents
        self.filter_settings = filter_settings
        self._cancelled = False

    def run(self) -> None:
        """Run quality filtering in background thread."""
        try:
            def progress_callback(
                current: int,
                total: int,
                assessment: "QualityAssessment",
            ) -> None:
                """Emit progress signal if not cancelled."""
                if not self._cancelled:
                    self.progress.emit(current, total, assessment)

            filtered, assessments = self.quality_manager.filter_documents(
                self.documents,
                self.filter_settings,
                progress_callback=progress_callback,
            )

            if not self._cancelled:
                self.finished.emit(filtered, assessments)

        except Exception as e:
            logger.exception("Quality filtering failed")
            if not self._cancelled:
                self.error.emit(str(e))

    def cancel(self) -> None:
        """Request cancellation of the operation."""
        self._cancelled = True
