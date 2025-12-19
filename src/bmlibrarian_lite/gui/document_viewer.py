"""
Document viewer widgets for BMLibrarian Lite.

Provides tabbed document viewing components:
- PDFViewerTab: Tab for viewing PDF documents with native PDF rendering
- FullTextTab: Tab for viewing full text/markdown content
- LiteDocumentViewWidget: Combined tabbed document viewer

Usage:
    from bmlibrarian_lite.gui.document_viewer import LiteDocumentViewWidget

    viewer = LiteDocumentViewWidget()
    text = viewer.load_file("/path/to/document.pdf")
    print(viewer.get_text())
"""

import logging
from pathlib import Path
from typing import Optional

from PySide6.QtPdf import QPdfDocument
from PySide6.QtPdfWidgets import QPdfView
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSpinBox,
    QTabWidget,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

from bmlibrarian_lite.resources.styles.dpi_scale import get_font_scale, scaled

logger = logging.getLogger(__name__)


class PDFViewerTab(QWidget):
    """
    Tab for viewing PDF documents with native PDF rendering.

    Uses PySide6's QPdfView for actual PDF display with zoom
    and page navigation controls.

    Attributes:
        pdf_view: The QPdfView widget for rendering PDFs
        pdf_document: The QPdfDocument instance
    """

    # Zoom presets
    ZOOM_MIN = 25
    ZOOM_MAX = 400
    ZOOM_DEFAULT = 100
    ZOOM_STEP = 25

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        """
        Initialize PDF viewer tab.

        Args:
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.scale = get_font_scale()
        self._pdf_path: Optional[str] = None
        self._pdf_text: str = ""
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the user interface."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Toolbar for PDF controls
        toolbar = self._create_toolbar()
        layout.addWidget(toolbar)

        # PDF document and view
        self.pdf_document = QPdfDocument(self)
        self.pdf_view = QPdfView(self)
        self.pdf_view.setDocument(self.pdf_document)
        self.pdf_view.setPageMode(QPdfView.PageMode.MultiPage)
        self.pdf_view.setZoomMode(QPdfView.ZoomMode.Custom)
        self.pdf_view.setZoomFactor(self.ZOOM_DEFAULT / 100.0)
        layout.addWidget(self.pdf_view, 1)

        # Connect page change to update page label
        self.pdf_view.pageNavigator().currentPageChanged.connect(self._on_page_changed)

    def _create_toolbar(self) -> QWidget:
        """Create the PDF navigation toolbar."""
        toolbar = QWidget()
        toolbar.setStyleSheet(
            "QWidget { background-color: #F0F0F0; border-bottom: 1px solid #D0D0D0; }"
        )
        toolbar.setFixedHeight(scaled(36))

        layout = QHBoxLayout(toolbar)
        layout.setContentsMargins(scaled(8), scaled(4), scaled(8), scaled(4))
        layout.setSpacing(scaled(8))

        # Zoom out button
        self.zoom_out_btn = QPushButton("-")
        self.zoom_out_btn.setFixedSize(scaled(28), scaled(28))
        self.zoom_out_btn.setToolTip("Zoom out")
        self.zoom_out_btn.clicked.connect(self._zoom_out)
        layout.addWidget(self.zoom_out_btn)

        # Zoom percentage spinbox
        self.zoom_spinbox = QSpinBox()
        self.zoom_spinbox.setRange(self.ZOOM_MIN, self.ZOOM_MAX)
        self.zoom_spinbox.setValue(self.ZOOM_DEFAULT)
        self.zoom_spinbox.setSuffix("%")
        self.zoom_spinbox.setFixedWidth(scaled(80))
        self.zoom_spinbox.valueChanged.connect(self._on_zoom_changed)
        layout.addWidget(self.zoom_spinbox)

        # Zoom in button
        self.zoom_in_btn = QPushButton("+")
        self.zoom_in_btn.setFixedSize(scaled(28), scaled(28))
        self.zoom_in_btn.setToolTip("Zoom in")
        self.zoom_in_btn.clicked.connect(self._zoom_in)
        layout.addWidget(self.zoom_in_btn)

        # Fit width button
        self.fit_width_btn = QPushButton("Fit Width")
        self.fit_width_btn.setToolTip("Fit page width to view")
        self.fit_width_btn.clicked.connect(self._fit_width)
        layout.addWidget(self.fit_width_btn)

        layout.addStretch()

        # Page navigation
        self.page_label = QLabel("Page: 0 / 0")
        layout.addWidget(self.page_label)

        # Previous page button
        self.prev_page_btn = QPushButton("<")
        self.prev_page_btn.setFixedSize(scaled(28), scaled(28))
        self.prev_page_btn.setToolTip("Previous page")
        self.prev_page_btn.clicked.connect(self._prev_page)
        layout.addWidget(self.prev_page_btn)

        # Next page button
        self.next_page_btn = QPushButton(">")
        self.next_page_btn.setFixedSize(scaled(28), scaled(28))
        self.next_page_btn.setToolTip("Next page")
        self.next_page_btn.clicked.connect(self._next_page)
        layout.addWidget(self.next_page_btn)

        return toolbar

    def _zoom_in(self) -> None:
        """Increase zoom level."""
        new_zoom = min(self.zoom_spinbox.value() + self.ZOOM_STEP, self.ZOOM_MAX)
        self.zoom_spinbox.setValue(new_zoom)

    def _zoom_out(self) -> None:
        """Decrease zoom level."""
        new_zoom = max(self.zoom_spinbox.value() - self.ZOOM_STEP, self.ZOOM_MIN)
        self.zoom_spinbox.setValue(new_zoom)

    def _on_zoom_changed(self, value: int) -> None:
        """Handle zoom spinbox value change."""
        self.pdf_view.setZoomMode(QPdfView.ZoomMode.Custom)
        self.pdf_view.setZoomFactor(value / 100.0)

    def _fit_width(self) -> None:
        """Set zoom mode to fit width."""
        self.pdf_view.setZoomMode(QPdfView.ZoomMode.FitToWidth)
        # Update spinbox to reflect actual zoom (approximate)
        self.zoom_spinbox.blockSignals(True)
        actual_zoom = int(self.pdf_view.zoomFactor() * 100)
        self.zoom_spinbox.setValue(actual_zoom)
        self.zoom_spinbox.blockSignals(False)

    def _prev_page(self) -> None:
        """Go to previous page."""
        navigator = self.pdf_view.pageNavigator()
        if navigator.currentPage() > 0:
            navigator.jump(navigator.currentPage() - 1, navigator.currentLocation())

    def _next_page(self) -> None:
        """Go to next page."""
        navigator = self.pdf_view.pageNavigator()
        if navigator.currentPage() < self.pdf_document.pageCount() - 1:
            navigator.jump(navigator.currentPage() + 1, navigator.currentLocation())

    def _on_page_changed(self, page: int) -> None:
        """Update page label when page changes."""
        total = self.pdf_document.pageCount()
        self.page_label.setText(f"Page: {page + 1} / {total}")

    def _update_page_controls(self) -> None:
        """Update page navigation controls after loading."""
        total = self.pdf_document.pageCount()
        current = self.pdf_view.pageNavigator().currentPage()
        self.page_label.setText(f"Page: {current + 1} / {total}")

    def load_pdf(self, pdf_path: str) -> bool:
        """
        Load a PDF file.

        Args:
            pdf_path: Path to PDF file

        Returns:
            True if loaded successfully
        """
        path = Path(pdf_path)
        if not path.exists():
            logger.warning(f"PDF file not found: {pdf_path}")
            return False

        try:
            # Load into QPdfDocument for native rendering
            error = self.pdf_document.load(str(path))
            if error != QPdfDocument.Error.None_:
                logger.error(f"Failed to load PDF: {error}")
                return False

            self._pdf_path = pdf_path
            self._update_page_controls()

            # Also extract text for the Full Text tab
            self._extract_text(pdf_path)

            return True

        except Exception as e:
            logger.error(f"Failed to load PDF: {e}")
            return False

    def _extract_text(self, pdf_path: str) -> None:
        """Extract text from PDF for the Full Text tab."""
        try:
            import fitz  # PyMuPDF

            doc = fitz.open(pdf_path)
            text_parts = []
            for page_num, page in enumerate(doc, 1):
                text_parts.append(f"--- Page {page_num} ---\n")
                text_parts.append(page.get_text())
            doc.close()
            self._pdf_text = "\n".join(text_parts)

        except ImportError:
            logger.warning("PyMuPDF not available for text extraction")
            self._pdf_text = ""
        except Exception as e:
            logger.warning(f"Failed to extract PDF text: {e}")
            self._pdf_text = ""

    def get_text(self) -> str:
        """
        Get all text from the loaded PDF.

        Returns:
            Extracted text or empty string
        """
        return self._pdf_text

    def get_pdf_path(self) -> Optional[str]:
        """
        Get the path of the currently loaded PDF.

        Returns:
            PDF file path or None if no PDF is loaded
        """
        return self._pdf_path

    def clear(self) -> None:
        """Clear the PDF viewer."""
        self._pdf_path = None
        self._pdf_text = ""
        self.pdf_document.close()
        self.page_label.setText("Page: 0 / 0")
        self.zoom_spinbox.setValue(self.ZOOM_DEFAULT)


class FullTextTab(QWidget):
    """
    Tab for viewing full text / markdown content.

    Uses QTextBrowser with basic markdown support.

    Attributes:
        content_viewer: The text viewer widget
    """

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        """
        Initialize full text tab.

        Args:
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.scale = get_font_scale()
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the user interface."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Use QTextBrowser with markdown support
        self.content_viewer = QTextBrowser()
        self.content_viewer.setReadOnly(True)
        self.content_viewer.setOpenExternalLinks(True)
        layout.addWidget(self.content_viewer)

    def set_content(self, text: str) -> None:
        """
        Set the text content to display.

        Args:
            text: Text content (plain text or markdown)
        """
        # Try to render as markdown if it looks like markdown
        if self._looks_like_markdown(text):
            self.content_viewer.setMarkdown(text)
        else:
            self.content_viewer.setPlainText(text)

    def _looks_like_markdown(self, text: str) -> bool:
        """
        Check if text appears to be markdown.

        Args:
            text: Text to check

        Returns:
            True if text appears to contain markdown
        """
        markdown_indicators = ['#', '**', '__', '```', '- ', '* ', '1. ', '[', '](']
        return any(indicator in text for indicator in markdown_indicators)

    def get_text(self) -> str:
        """
        Get the current text content.

        Returns:
            Current text content
        """
        return self.content_viewer.toPlainText()

    def clear(self) -> None:
        """Clear the content."""
        self.content_viewer.clear()


class LiteDocumentViewWidget(QWidget):
    """
    Simplified document view widget for BMLibrarian Lite.

    Provides two tabs:
    - PDF tab: PDF viewer with text selection
    - Full Text tab: Plain text / markdown viewer

    Unlike the full version, this does not include database features,
    PDF discovery, or chunk embedding.

    Attributes:
        pdf_tab: The PDF viewer tab
        fulltext_tab: The full text viewer tab
        tab_widget: The tab container widget

    Example:
        viewer = LiteDocumentViewWidget()
        text = viewer.load_file("/path/to/paper.pdf")
        title = viewer.get_title()
    """

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        """
        Initialize document view widget.

        Args:
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.scale = get_font_scale()
        self._current_text: str = ""
        self._current_title: str = ""
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the user interface."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # Tab widget
        self.tab_widget = QTabWidget()

        # Tab 1: PDF Viewer
        self.pdf_tab = PDFViewerTab()
        self.tab_widget.addTab(self.pdf_tab, "PDF")

        # Tab 2: Full Text
        self.fulltext_tab = FullTextTab()
        self.tab_widget.addTab(self.fulltext_tab, "Full Text")

        layout.addWidget(self.tab_widget)

    def load_file(self, file_path: str) -> str:
        """
        Load a document file.

        Args:
            file_path: Path to document file

        Returns:
            Extracted text content

        Raises:
            ValueError: If file type is not supported or file is empty
        """
        path = Path(file_path)
        self._current_title = path.name

        if path.suffix.lower() == '.pdf':
            return self._load_pdf(file_path)
        elif path.suffix.lower() in ['.txt', '.md']:
            return self._load_text(file_path)
        else:
            raise ValueError(f"Unsupported file type: {path.suffix}")

    def _load_pdf(self, file_path: str) -> str:
        """
        Load a PDF file.

        Args:
            file_path: Path to PDF file

        Returns:
            Extracted text content
        """
        # Load into PDF tab
        if self.pdf_tab.load_pdf(file_path):
            text = self.pdf_tab.get_text()
            self._current_text = text
            # Also show in full text tab
            self.fulltext_tab.set_content(text)
            # Switch to PDF tab
            self.tab_widget.setCurrentIndex(0)
            return text
        else:
            # PDF loading failed, try extracting text manually
            try:
                import fitz
                doc = fitz.open(file_path)
                text = ""
                for page in doc:
                    text += page.get_text()
                doc.close()
                self._current_text = text
                self.fulltext_tab.set_content(text)
                # Switch to full text tab since PDF view failed
                self.tab_widget.setCurrentIndex(1)
                return text
            except Exception as e:
                logger.error(f"Failed to extract PDF text: {e}")
                return ""

    def _load_text(self, file_path: str) -> str:
        """
        Load a text/markdown file.

        Args:
            file_path: Path to text file

        Returns:
            File content
        """
        text = Path(file_path).read_text(encoding='utf-8')
        self._current_text = text
        self.fulltext_tab.set_content(text)
        # Switch to full text tab
        self.tab_widget.setCurrentIndex(1)
        return text

    def get_text(self) -> str:
        """
        Get the current document text.

        Returns:
            Document text content
        """
        return self._current_text

    def set_text(self, text: str, title: str = "") -> None:
        """
        Set document text directly without loading from file.

        Useful for loading text from citations or database records.

        Args:
            text: Document text content
            title: Document title
        """
        self._current_text = text
        self._current_title = title
        self.fulltext_tab.set_content(text)

    def get_title(self) -> str:
        """
        Get the current document title.

        Returns:
            Document title (filename)
        """
        return self._current_title

    def set_title(self, title: str) -> None:
        """
        Set the document title.

        Args:
            title: Document title
        """
        self._current_title = title

    def clear(self) -> None:
        """Clear all displayed content."""
        self._current_text = ""
        self._current_title = ""
        self.pdf_tab.clear()
        self.fulltext_tab.clear()

    def show_pdf_tab(self) -> None:
        """Switch to the PDF tab."""
        self.tab_widget.setCurrentIndex(0)

    def show_fulltext_tab(self) -> None:
        """Switch to the Full Text tab."""
        self.tab_widget.setCurrentIndex(1)
