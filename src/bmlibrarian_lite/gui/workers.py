"""
Background worker threads for BMLibrarian Lite GUI.

Provides QThread-based workers for long-running operations:
- AnswerWorker: Generate answers using the interrogation agent
- PDFDiscoveryWorker: Discover and download PDFs from multiple sources
- FulltextDiscoveryWorker: Discover full-text via Europe PMC XML or PDF
- OpenAthensAuthWorker: Handle OpenAthens institutional authentication
- QualityFilterWorker: Filter documents by quality criteria
- IncrementalSearchWorker: Search for new documents incrementally
- ReclassifyWorker: Re-run study design classification
- RescoreWorker: Re-run relevance scoring

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
    from ..config import LiteConfig
    from ..data_models import LiteDocument
    from ..quality.data_models import QualityFilter, QualityAssessment
    from ..quality.quality_manager import QualityManager
    from ..storage import LiteStorage

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


class IncrementalSearchWorker(QThread):
    """
    Background worker for incremental PubMed searches with deduplication.

    Fetches documents in batches until:
    - Target NEW documents reached, OR
    - PubMed returns no more results, OR
    - Maximum offset reached

    This enables re-running a research question to find additional
    documents that haven't been scored yet.

    Signals:
        progress: Emitted with (new_docs_found, target, message)
        batch_complete: Emitted when a batch is fetched (batch_docs)
        finished: Emitted when search completes (all_new_docs)
        error: Emitted on error (error message)
    """

    progress = Signal(int, int, str)  # new_docs_found, target, message
    batch_complete = Signal(list)  # batch of new LiteDocuments
    finished = Signal(list)  # all new LiteDocuments
    error = Signal(str)

    def __init__(
        self,
        question: str,
        pubmed_query: str,
        target_new_docs: int,
        already_scored_ids: set,
        config: "LiteConfig",
        storage: "LiteStorage",
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the incremental search worker.

        Args:
            question: Natural language research question
            pubmed_query: PubMed query string to execute
            target_new_docs: Target number of new documents to find
            already_scored_ids: Set of document IDs already scored
            config: Lite configuration
            storage: Storage layer for saving documents
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.question = question
        self.pubmed_query = pubmed_query
        self.target_new_docs = target_new_docs
        self.already_scored_ids = already_scored_ids
        self.config = config
        self.storage = storage
        self._cancelled = False

    def run(self) -> None:
        """Execute incremental search in background thread."""
        try:
            from ..pubmed import PubMedSearchClient
            from ..data_models import LiteDocument, DocumentSource
            from ..constants import (
                INCREMENTAL_SEARCH_BATCH_SIZE,
                MAX_PUBMED_SEARCH_OFFSET,
            )

            client = PubMedSearchClient(
                email=self.config.pubmed.email,
            )

            all_new_docs: List["LiteDocument"] = []
            offset = 0
            batch_size = INCREMENTAL_SEARCH_BATCH_SIZE

            while len(all_new_docs) < self.target_new_docs and not self._cancelled:
                # Check offset limit
                if offset >= MAX_PUBMED_SEARCH_OFFSET:
                    logger.info(
                        f"Reached max offset {MAX_PUBMED_SEARCH_OFFSET}, stopping"
                    )
                    break

                # Search with offset
                self.progress.emit(
                    len(all_new_docs),
                    self.target_new_docs,
                    f"Searching PubMed (offset {offset})...",
                )

                result = client.search_with_offset(
                    query_string=self.pubmed_query,
                    max_results=batch_size,
                    start_offset=offset,
                )

                if not result.pmids:
                    logger.info("No more results from PubMed")
                    break

                # Fetch article metadata
                self.progress.emit(
                    len(all_new_docs),
                    self.target_new_docs,
                    f"Fetching {len(result.pmids)} article details...",
                )

                articles = client.fetch_articles(result.pmids)

                # Filter out already scored documents
                batch_new_docs: List["LiteDocument"] = []
                for article in articles:
                    if self._cancelled:
                        break

                    doc_id = f"pmid-{article.pmid}"
                    if doc_id in self.already_scored_ids:
                        continue

                    # Convert to LiteDocument
                    doc = LiteDocument(
                        id=doc_id,
                        title=article.title,
                        abstract=article.abstract,
                        authors=article.authors,
                        year=self._extract_year(article.publication_date),
                        journal=article.publication,
                        doi=article.doi,
                        pmid=article.pmid,
                        pmc_id=article.pmc_id,
                        mesh_terms=article.mesh_terms,
                        source=DocumentSource.PUBMED,
                    )

                    batch_new_docs.append(doc)
                    all_new_docs.append(doc)

                    # Stop if we've reached our target
                    if len(all_new_docs) >= self.target_new_docs:
                        break

                if batch_new_docs:
                    self.batch_complete.emit(batch_new_docs)

                # Update progress
                self.progress.emit(
                    len(all_new_docs),
                    self.target_new_docs,
                    f"Found {len(all_new_docs)} new documents",
                )

                # Move to next batch
                offset += batch_size

                # If we got fewer results than batch size, we've exhausted results
                if len(result.pmids) < batch_size:
                    logger.info(
                        f"Got {len(result.pmids)} < {batch_size}, "
                        "results exhausted"
                    )
                    break

            if not self._cancelled:
                self.finished.emit(all_new_docs)

        except Exception as e:
            logger.exception("Incremental search failed")
            if not self._cancelled:
                self.error.emit(str(e))

    def _extract_year(self, date_str: Optional[str]) -> Optional[int]:
        """
        Extract year from a date string.

        Args:
            date_str: Date string in various formats

        Returns:
            Year as integer or None
        """
        if not date_str:
            return None
        try:
            # Try to extract year from YYYY-MM-DD or just YYYY
            year_str = date_str.split("-")[0]
            return int(year_str)
        except (ValueError, IndexError):
            return None

    def cancel(self) -> None:
        """Request cancellation of the operation."""
        self._cancelled = True


class ReclassifyWorker(QThread):
    """
    Background worker for re-running study design classification.

    Re-classifies all provided documents using the study classifier,
    updating the stored quality assessments.

    Signals:
        progress: Emitted with (current, total, message) during classification
        finished: Emitted with (success_count, fail_count) when complete
        error: Emitted with error message on failure
    """

    progress = Signal(int, int, str)  # current, total, message
    finished = Signal(int, int)  # success_count, fail_count
    error = Signal(str)

    def __init__(
        self,
        config: "LiteConfig",
        storage: "LiteStorage",
        documents: List["LiteDocument"],
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the reclassify worker.

        Args:
            config: Lite configuration
            storage: Storage layer for saving results
            documents: List of documents to reclassify
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.config = config
        self.storage = storage
        self.documents = documents
        self._cancelled = False

    def run(self) -> None:
        """Execute re-classification in background thread."""
        try:
            from ..quality.study_classifier import LiteStudyClassifier
            from ..quality.data_models import StudyDesign

            classifier = LiteStudyClassifier(config=self.config)

            success_count = 0
            fail_count = 0
            total = len(self.documents)

            for i, doc in enumerate(self.documents):
                if self._cancelled:
                    break

                self.progress.emit(
                    i + 1,
                    total,
                    f"Classifying {i + 1}/{total}: {doc.title[:50]}...",
                )

                try:
                    classification = classifier.classify(doc)

                    # Check if classification succeeded
                    if classification.study_design != StudyDesign.UNKNOWN:
                        # Save to database
                        self.storage.save_study_classification(
                            document_id=doc.id,
                            classification=classification,
                        )
                        success_count += 1
                        logger.info(
                            f"Classified {doc.id}: {classification.study_design.value} "
                            f"(confidence: {classification.confidence:.2f})"
                        )
                    else:
                        fail_count += 1
                        logger.warning(
                            f"Classification failed for {doc.id}: "
                            f"UNKNOWN design with confidence {classification.confidence}"
                        )

                except Exception as e:
                    fail_count += 1
                    logger.warning(
                        f"Failed to classify document {doc.id}: {e}"
                    )

            if not self._cancelled:
                self.finished.emit(success_count, fail_count)

        except Exception as e:
            logger.exception("Reclassification failed")
            if not self._cancelled:
                self.error.emit(str(e))

    def cancel(self) -> None:
        """Request cancellation of the operation."""
        self._cancelled = True


class RescoreWorker(QThread):
    """
    Background worker for re-running relevance scoring.

    Re-scores all provided documents using the scoring agent,
    updating the stored scored documents.

    Signals:
        progress: Emitted with (current, total, message) during scoring
        finished: Emitted with (success_count, fail_count) when complete
        error: Emitted with error message on failure
    """

    progress = Signal(int, int, str)  # current, total, message
    finished = Signal(int, int)  # success_count, fail_count
    error = Signal(str)

    def __init__(
        self,
        config: "LiteConfig",
        storage: "LiteStorage",
        question: str,
        documents: List["LiteDocument"],
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the rescore worker.

        Args:
            config: Lite configuration
            storage: Storage layer for saving results
            question: Research question for scoring context
            documents: List of documents to rescore
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.config = config
        self.storage = storage
        self.question = question
        self.documents = documents
        self._cancelled = False

    def run(self) -> None:
        """Execute re-scoring in background thread."""
        try:
            from ..agents.scoring_agent import LiteScoringAgent

            scoring_agent = LiteScoringAgent(config=self.config)

            success_count = 0
            fail_count = 0
            total = len(self.documents)

            # Get or create a checkpoint for this re-scoring run
            checkpoint = self.storage.create_checkpoint(
                research_question=self.question,
            )

            for i, doc in enumerate(self.documents):
                if self._cancelled:
                    break

                self.progress.emit(
                    i + 1,
                    total,
                    f"Scoring {i + 1}/{total}: {doc.title[:50]}...",
                )

                try:
                    scored_doc = scoring_agent.score_document(
                        self.question, doc
                    )

                    # Save the scored document to storage
                    self.storage.save_scored_document(
                        scored_doc, checkpoint.id
                    )
                    success_count += 1

                except Exception as e:
                    fail_count += 1
                    logger.warning(
                        f"Failed to score document {doc.id}: {e}"
                    )

            if not self._cancelled:
                self.finished.emit(success_count, fail_count)

        except Exception as e:
            logger.exception("Re-scoring failed")
            if not self._cancelled:
                self.error.emit(str(e))

    def cancel(self) -> None:
        """Request cancellation of the operation."""
        self._cancelled = True
