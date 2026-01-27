# Phase 4: Error Queue UI and Result Re-ordering (Python)

## Objective

Provide a polished error display with persistence, categorization, and accessibility support. Allow users to re-order results after processing completes.

## Phase Integration Notes

Phase 4 builds on all previous phases:

### Dependencies from Phase 1 (Parallel Requests)

- **`ScoringResult`**: Contains `is_error` and `error_message` fields. Phase 4 displays these errors in the queue.
- **`score_documents_parallel`**: Errors from concurrent requests feed into the error queue.

### Dependencies from Phase 2 (Checkpointing)

- **`LiteStorage`**: Used for error persistence via the checkpoint system.
- **`save_checkpoint`/`load_checkpoint`**: Can be used to persist error state.
- **`ProgressMessage`**: Error events flow through the progress system.

### Dependencies from Phase 3 (Cancellation)

- **`CancellationToken`**: Cancellation may leave documents in an error state.
- **`on_cancelled` callback**: When processing is cancelled, accumulated errors should be preserved.

### Key Integration Points

| Component | Phase | Integration |
|-----------|-------|-------------|
| `ScoringResult.error_message` | 1 | Source of error messages |
| `LiteStorage` | 2 | Persistence for errors |
| `ProgressMessage` | 2 | Error propagation |
| `CancellationToken` | 3 | Errors during cancellation |

## 4.1 Error Types and Categorization

**File**: `src/bmlibrarian_lite/utils/error_types.py` (new file)

```python
"""Error categorization for processing failures."""

from enum import Enum
import re


class ErrorCategory(Enum):
    """Categories of errors that can occur during document processing."""

    NETWORK = "Network"
    LLM = "LLM"
    PARSING = "Parsing"
    TIMEOUT = "Timeout"
    UNKNOWN = "Unknown"

    @property
    def icon(self) -> str:
        """Qt icon name for the category."""
        icons = {
            ErrorCategory.NETWORK: "network-offline",
            ErrorCategory.LLM: "dialog-scripts",
            ErrorCategory.PARSING: "document-preview",
            ErrorCategory.TIMEOUT: "clock",
            ErrorCategory.UNKNOWN: "dialog-question",
        }
        return icons.get(self, "dialog-question")

    @property
    def color(self) -> str:
        """Hex color for the category."""
        colors = {
            ErrorCategory.NETWORK: "#FF9800",  # Orange
            ErrorCategory.LLM: "#9C27B0",      # Purple
            ErrorCategory.PARSING: "#2196F3",  # Blue
            ErrorCategory.TIMEOUT: "#FFC107",  # Amber
            ErrorCategory.UNKNOWN: "#9E9E9E",  # Gray
        }
        return colors.get(self, "#9E9E9E")


# Patterns for error categorization
_NETWORK_PATTERNS = [
    r"network",
    r"connection",
    r"offline",
    r"internet",
    r"unreachable",
    r"socket",
    r"dns",
    r"host",
    r"refused",
]

_TIMEOUT_PATTERNS = [
    r"timeout",
    r"timed?\s*out",
    r"deadline",
]

_PARSING_PATTERNS = [
    r"parse",
    r"decode",
    r"json",
    r"xml",
    r"invalid\s*format",
    r"malformed",
    r"syntax",
]

_LLM_PATTERNS = [
    r"llm",
    r"model",
    r"api\s*key",
    r"rate\s*limit",
    r"token",
    r"openai",
    r"anthropic",
    r"claude",
    r"ollama",
    r"context\s*length",
]


def categorize_error(error: Exception) -> ErrorCategory:
    """
    Categorize an error based on its type and message.

    Args:
        error: The exception to categorize.

    Returns:
        The appropriate ErrorCategory.
    """
    # Check exception type first
    error_type = type(error).__name__.lower()

    if "timeout" in error_type:
        return ErrorCategory.TIMEOUT
    if any(t in error_type for t in ["connection", "socket", "network", "url"]):
        return ErrorCategory.NETWORK
    if any(t in error_type for t in ["json", "parse", "decode"]):
        return ErrorCategory.PARSING

    # Fall back to message-based categorization
    return categorize_error_message(str(error))


def categorize_error_message(message: str) -> ErrorCategory:
    """
    Categorize an error based on its message string.

    Args:
        message: The error message to categorize.

    Returns:
        The appropriate ErrorCategory.
    """
    lowercased = message.lower()

    # Check each category's patterns
    for pattern in _NETWORK_PATTERNS:
        if re.search(pattern, lowercased):
            return ErrorCategory.NETWORK

    for pattern in _TIMEOUT_PATTERNS:
        if re.search(pattern, lowercased):
            return ErrorCategory.TIMEOUT

    for pattern in _PARSING_PATTERNS:
        if re.search(pattern, lowercased):
            return ErrorCategory.PARSING

    for pattern in _LLM_PATTERNS:
        if re.search(pattern, lowercased):
            return ErrorCategory.LLM

    return ErrorCategory.UNKNOWN
```

## 4.2 Error Entry Model with Persistence

**File**: `src/bmlibrarian_lite/models/error_entry.py` (new file)

```python
"""Error entry model for tracking processing failures."""

from dataclasses import dataclass, field
from datetime import datetime
from typing import List, Dict, Any

from ..utils.error_types import ErrorCategory, categorize_error_message


@dataclass
class ErrorEntry:
    """Single error entry for display and persistence."""

    pmid: str
    step: str
    message: str
    category: ErrorCategory = field(default=ErrorCategory.UNKNOWN)
    timestamp: datetime = field(default_factory=datetime.now)
    session_id: str = ""
    retry_count: int = 0

    def __post_init__(self):
        """Auto-categorize if not specified."""
        if self.category == ErrorCategory.UNKNOWN:
            self.category = categorize_error_message(self.message)

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for persistence."""
        return {
            "pmid": self.pmid,
            "step": self.step,
            "message": self.message,
            "category": self.category.value,
            "timestamp": self.timestamp.isoformat(),
            "session_id": self.session_id,
            "retry_count": self.retry_count,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ErrorEntry":
        """Create from dictionary."""
        return cls(
            pmid=data["pmid"],
            step=data["step"],
            message=data["message"],
            category=ErrorCategory(data["category"]),
            timestamp=datetime.fromisoformat(data["timestamp"]),
            session_id=data.get("session_id", ""),
            retry_count=data.get("retry_count", 0),
        )

    @classmethod
    def from_exception(
        cls,
        pmid: str,
        step: str,
        error: Exception,
        session_id: str = "",
    ) -> "ErrorEntry":
        """Create from an exception with automatic categorization."""
        from ..utils.error_types import categorize_error

        return cls(
            pmid=pmid,
            step=step,
            message=str(error),
            category=categorize_error(error),
            session_id=session_id,
        )
```

## 4.3 Error Persistence Manager

**File**: `src/bmlibrarian_lite/storage/error_storage.py` (new file)

```python
"""Error persistence using LiteStorage."""

from typing import List, Dict

from ..models.error_entry import ErrorEntry
from ..utils.error_types import ErrorCategory
from .storage import LiteStorage


class ErrorStorageManager:
    """
    Manages persistence of processing errors.

    Uses LiteStorage's checkpoint system for persistence.
    """

    STEP_NAME = "errors"

    def __init__(self, storage: LiteStorage):
        """
        Initialize error storage manager.

        Args:
            storage: LiteStorage instance for persistence.
        """
        self._storage = storage

    def save_error(self, error: ErrorEntry) -> None:
        """
        Save an error to persistent storage.

        Args:
            error: The error entry to save.
        """
        # Load existing errors
        errors = self.load_errors(error.session_id)

        # Add new error
        errors.append(error)

        # Save back
        self._save_errors(error.session_id, errors)

    def save_errors(self, errors: List[ErrorEntry]) -> None:
        """
        Save multiple errors.

        Args:
            errors: List of error entries to save.
        """
        if not errors:
            return

        session_id = errors[0].session_id

        # Load existing
        existing = self.load_errors(session_id)

        # Merge (avoid duplicates by PMID)
        existing_pmids = {e.pmid for e in existing}
        for error in errors:
            if error.pmid not in existing_pmids:
                existing.append(error)
                existing_pmids.add(error.pmid)

        self._save_errors(session_id, existing)

    def load_errors(self, session_id: str) -> List[ErrorEntry]:
        """
        Load all errors for a session.

        Args:
            session_id: Session identifier.

        Returns:
            List of error entries, sorted by timestamp (newest first).
        """
        data = self._storage.load_checkpoint(
            session_id=session_id,
            pmid="_errors",  # Special key for error list
            step=self.STEP_NAME,
        )

        if not data:
            return []

        errors = [ErrorEntry.from_dict(e) for e in data.get("errors", [])]
        return sorted(errors, key=lambda e: e.timestamp, reverse=True)

    def load_errors_by_category(
        self,
        session_id: str,
        category: ErrorCategory,
    ) -> List[ErrorEntry]:
        """
        Load errors filtered by category.

        Args:
            session_id: Session identifier.
            category: Category to filter by.

        Returns:
            Filtered list of error entries.
        """
        errors = self.load_errors(session_id)
        return [e for e in errors if e.category == category]

    def get_error_counts_by_category(
        self,
        session_id: str,
    ) -> Dict[ErrorCategory, int]:
        """
        Get error counts grouped by category.

        Args:
            session_id: Session identifier.

        Returns:
            Dictionary mapping categories to counts.
        """
        errors = self.load_errors(session_id)
        counts: Dict[ErrorCategory, int] = {}

        for error in errors:
            counts[error.category] = counts.get(error.category, 0) + 1

        return counts

    def increment_retry_count(
        self,
        session_id: str,
        pmids: List[str],
    ) -> None:
        """
        Increment retry count for specific PMIDs.

        Args:
            session_id: Session identifier.
            pmids: List of PMIDs to update.
        """
        pmid_set = set(pmids)
        errors = self.load_errors(session_id)

        for error in errors:
            if error.pmid in pmid_set:
                error.retry_count += 1

        self._save_errors(session_id, errors)

    def remove_errors(self, session_id: str, pmids: List[str]) -> None:
        """
        Remove errors for successfully retried PMIDs.

        Args:
            session_id: Session identifier.
            pmids: List of PMIDs to remove.
        """
        pmid_set = set(pmids)
        errors = self.load_errors(session_id)
        errors = [e for e in errors if e.pmid not in pmid_set]
        self._save_errors(session_id, errors)

    def clear_session(self, session_id: str) -> None:
        """
        Clear all errors for a session.

        Args:
            session_id: Session identifier.
        """
        self._save_errors(session_id, [])

    def _save_errors(self, session_id: str, errors: List[ErrorEntry]) -> None:
        """Save errors list to storage."""
        data = {"errors": [e.to_dict() for e in errors]}
        self._storage.save_checkpoint(
            session_id=session_id,
            pmid="_errors",
            step=self.STEP_NAME,
            result=data,
        )
```

## 4.4 Error Queue Widget with Accessibility

**File**: `src/bmlibrarian_lite/gui/error_queue_widget.py` (new file)

```python
"""Collapsible error queue widget with accessibility support."""

from typing import List, Optional, Dict
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QPushButton, QScrollArea, QFrame, QButtonGroup,
)
from PySide6.QtCore import Signal, Qt

from ..dpi_scale import scaled
from ..models.error_entry import ErrorEntry
from ..utils.error_types import ErrorCategory


class CategoryFilterButton(QPushButton):
    """Filter button for error categories."""

    def __init__(
        self,
        category: Optional[ErrorCategory],
        count: int,
        parent: Optional[QWidget] = None,
    ):
        label = "All" if category is None else category.value
        super().__init__(f"{label} ({count})", parent)

        self._category = category
        self._count = count

        self.setCheckable(True)
        self.setFlat(True)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

        # Accessibility
        self.setAccessibleName(f"{label} errors: {count}")
        self.setAccessibleDescription(
            f"Filter to show {'all' if category is None else category.value.lower()} errors"
        )

        # Styling
        color = "#666" if category is None else category.color
        self.setStyleSheet(f"""
            QPushButton {{
                border: 1px solid {color};
                border-radius: {scaled(12)}px;
                padding: {scaled(4)}px {scaled(12)}px;
                background-color: transparent;
                color: {color};
                font-size: {scaled(12)}px;
            }}
            QPushButton:checked {{
                background-color: {color}20;
                font-weight: bold;
            }}
            QPushButton:hover {{
                background-color: {color}10;
            }}
        """)

    @property
    def category(self) -> Optional[ErrorCategory]:
        return self._category


class ErrorCardWidget(QFrame):
    """Individual error card with full details."""

    def __init__(self, error: ErrorEntry, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self._error = error
        self._setup_ui()

    def _setup_ui(self):
        self.setFrameStyle(QFrame.Shape.StyledPanel)
        self.setStyleSheet(f"""
            QFrame {{
                background-color: #FFF;
                border: 1px solid #FFCDD2;
                border-radius: {scaled(8)}px;
                padding: {scaled(8)}px;
            }}
        """)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(scaled(8), scaled(8), scaled(8), scaled(8))
        layout.setSpacing(scaled(4))

        # Header row: PMID, step, category badge
        header = QHBoxLayout()

        # Category icon/badge
        category_badge = QLabel(self._error.category.value)
        category_badge.setStyleSheet(f"""
            QLabel {{
                background-color: {self._error.category.color}20;
                color: {self._error.category.color};
                border-radius: {scaled(4)}px;
                padding: {scaled(2)}px {scaled(6)}px;
                font-size: {scaled(10)}px;
                font-weight: bold;
            }}
        """)

        pmid_label = QLabel(f"PMID: {self._error.pmid}")
        pmid_label.setStyleSheet("font-weight: bold;")

        step_label = QLabel(f"({self._error.step})")
        step_label.setStyleSheet("color: #666;")

        header.addWidget(category_badge)
        header.addWidget(pmid_label)
        header.addWidget(step_label)
        header.addStretch()

        if self._error.retry_count > 0:
            retry_label = QLabel(f"Retries: {self._error.retry_count}")
            retry_label.setStyleSheet(f"color: #C62828; font-size: {scaled(10)}px;")
            header.addWidget(retry_label)

        layout.addLayout(header)

        # Message
        message_label = QLabel(self._error.message)
        message_label.setWordWrap(True)
        message_label.setStyleSheet("color: #666;")
        layout.addWidget(message_label)

        # Accessibility
        self.setAccessibleName(
            f"Error for PMID {self._error.pmid}"
        )
        self.setAccessibleDescription(
            f"{self._error.category.value} error during {self._error.step}: {self._error.message}"
        )


class ErrorQueueWidget(QWidget):
    """
    Collapsible widget displaying accumulated errors.

    Hidden when empty, expands to show categorized error list when populated.
    Includes accessibility support for screen readers.
    """

    retry_requested = Signal(list)  # List of PMIDs to retry
    errors_cleared = Signal()

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self._errors: List[ErrorEntry] = []
        self._is_expanded = False
        self._selected_category: Optional[ErrorCategory] = None
        self._setup_ui()
        self.hide()

    def _setup_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Header
        self._header = QFrame()
        self._header.setStyleSheet(f"""
            QFrame {{
                background-color: #FFEBEE;
                border-radius: {scaled(8)}px;
            }}
        """)
        header_layout = QHBoxLayout(self._header)
        header_layout.setContentsMargins(scaled(12), scaled(8), scaled(12), scaled(8))

        self._header_label = QLabel("Errors (0)")
        self._header_label.setStyleSheet("color: #C62828; font-weight: bold;")
        self._header_label.setAccessibleName("Error queue")

        self._toggle_button = QPushButton("▼")
        self._toggle_button.setFixedWidth(scaled(24))
        self._toggle_button.setFlat(True)
        self._toggle_button.clicked.connect(self._toggle_expanded)
        self._toggle_button.setAccessibleName("Expand error list")
        self._toggle_button.setAccessibleDescription("Show or hide error details")

        self._retry_button = QPushButton("Retry All")
        self._retry_button.clicked.connect(self._handle_retry)
        self._retry_button.setAccessibleName("Retry all failed documents")
        self._retry_button.setAccessibleDescription(
            "Re-process all documents that encountered errors"
        )

        self._clear_button = QPushButton("Clear")
        self._clear_button.clicked.connect(self.clear)
        self._clear_button.setAccessibleName("Clear all errors")
        self._clear_button.setAccessibleDescription(
            "Dismiss all errors without retrying"
        )

        header_layout.addWidget(self._header_label)
        header_layout.addStretch()
        header_layout.addWidget(self._retry_button)
        header_layout.addWidget(self._clear_button)
        header_layout.addWidget(self._toggle_button)

        layout.addWidget(self._header)

        # Category filters (collapsible)
        self._filter_container = QWidget()
        filter_layout = QHBoxLayout(self._filter_container)
        filter_layout.setContentsMargins(scaled(12), scaled(8), scaled(12), scaled(4))
        self._filter_button_group = QButtonGroup(self)
        self._filter_button_group.setExclusive(True)
        self._filter_buttons: Dict[Optional[ErrorCategory], CategoryFilterButton] = {}
        self._filter_container.hide()

        layout.addWidget(self._filter_container)

        # Error list (collapsible)
        self._scroll_area = QScrollArea()
        self._scroll_area.setWidgetResizable(True)
        self._scroll_area.setMaximumHeight(scaled(200))
        self._scroll_area.setHorizontalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        )

        self._error_container = QWidget()
        self._error_layout = QVBoxLayout(self._error_container)
        self._error_layout.setContentsMargins(scaled(12), scaled(8), scaled(12), scaled(8))
        self._error_layout.setSpacing(scaled(8))
        self._scroll_area.setWidget(self._error_container)
        self._scroll_area.hide()

        layout.addWidget(self._scroll_area)

        # Accessibility for the whole widget
        self.setAccessibleName("Error queue")

    def add_error(self, error: ErrorEntry) -> None:
        """Add error to queue and make widget visible."""
        self._errors.append(error)
        self._rebuild_ui()

    def add_errors(self, errors: List[ErrorEntry]) -> None:
        """Add multiple errors at once."""
        self._errors.extend(errors)
        self._rebuild_ui()

    def set_errors(self, errors: List[ErrorEntry]) -> None:
        """Replace all errors with new list."""
        self._errors = list(errors)
        self._rebuild_ui()

    def _rebuild_ui(self):
        """Rebuild the filter buttons and error cards."""
        self._rebuild_filters()
        self._rebuild_error_cards()
        self._update_visibility()

    def _rebuild_filters(self):
        """Rebuild category filter buttons."""
        # Clear existing
        for btn in self._filter_buttons.values():
            self._filter_button_group.removeButton(btn)
            btn.deleteLater()
        self._filter_buttons.clear()

        # Clear layout
        layout = self._filter_container.layout()
        while layout.count():
            item = layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        # Count by category
        counts: Dict[Optional[ErrorCategory], int] = {None: len(self._errors)}
        for error in self._errors:
            counts[error.category] = counts.get(error.category, 0) + 1

        # Create buttons
        # "All" button first
        all_btn = CategoryFilterButton(None, len(self._errors))
        all_btn.setChecked(self._selected_category is None)
        all_btn.clicked.connect(lambda: self._select_category(None))
        self._filter_button_group.addButton(all_btn)
        self._filter_buttons[None] = all_btn
        layout.addWidget(all_btn)

        # Category buttons
        for category in ErrorCategory:
            count = counts.get(category, 0)
            if count > 0:
                btn = CategoryFilterButton(category, count)
                btn.setChecked(self._selected_category == category)
                btn.clicked.connect(lambda checked, c=category: self._select_category(c))
                self._filter_button_group.addButton(btn)
                self._filter_buttons[category] = btn
                layout.addWidget(btn)

        layout.addStretch()

    def _select_category(self, category: Optional[ErrorCategory]):
        """Select a category filter."""
        self._selected_category = category
        self._rebuild_error_cards()

    def _rebuild_error_cards(self):
        """Rebuild error cards based on selected filter."""
        # Clear existing
        while self._error_layout.count():
            item = self._error_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        # Filter errors
        filtered = self._errors
        if self._selected_category is not None:
            filtered = [e for e in self._errors if e.category == self._selected_category]

        # Add cards
        for error in filtered:
            card = ErrorCardWidget(error)
            self._error_layout.addWidget(card)

        self._error_layout.addStretch()

    def _update_visibility(self):
        """Update widget visibility and header text."""
        if self._errors:
            self.show()
            self._header_label.setText(f"Errors ({len(self._errors)})")
            self.setAccessibleDescription(
                f"{len(self._errors)} errors occurred during processing"
            )
        else:
            self.hide()

    def _toggle_expanded(self):
        """Toggle expanded/collapsed state."""
        self._is_expanded = not self._is_expanded
        self._scroll_area.setVisible(self._is_expanded)
        self._filter_container.setVisible(self._is_expanded)
        self._toggle_button.setText("▲" if self._is_expanded else "▼")
        self._toggle_button.setAccessibleName(
            "Collapse error list" if self._is_expanded else "Expand error list"
        )

    def clear(self):
        """Clear all errors and hide widget."""
        self._errors.clear()
        self._selected_category = None
        self._rebuild_ui()
        self.errors_cleared.emit()

    def _handle_retry(self):
        """Emit retry signal with failed PMIDs."""
        pmids = [e.pmid for e in self._errors]
        self.retry_requested.emit(pmids)
        self.clear()

    def get_failed_pmids(self) -> List[str]:
        """Get list of PMIDs that failed."""
        return [e.pmid for e in self._errors]

    def get_errors(self) -> List[ErrorEntry]:
        """Get all errors."""
        return list(self._errors)
```

## 4.5 Sorting Controls Widget

**File**: `src/bmlibrarian_lite/gui/sorting_controls_widget.py` (new file)

```python
"""Sorting controls widget for document results."""

from enum import Enum
from typing import Optional, Callable, List, TypeVar
from PySide6.QtWidgets import (
    QWidget, QHBoxLayout, QLabel, QComboBox,
)
from PySide6.QtCore import Signal

from ..dpi_scale import scaled


class SortOption(Enum):
    """Sort options for document results."""

    SCORE_HIGH_TO_LOW = "Score (High to Low)"
    SCORE_LOW_TO_HIGH = "Score (Low to High)"
    TITLE_AZ = "Title (A-Z)"
    TITLE_ZA = "Title (Z-A)"
    YEAR_NEWEST = "Year (Newest First)"
    YEAR_OLDEST = "Year (Oldest First)"

    @property
    def accessibility_description(self) -> str:
        """Description for screen readers."""
        descriptions = {
            SortOption.SCORE_HIGH_TO_LOW: "Sort by score, highest first",
            SortOption.SCORE_LOW_TO_HIGH: "Sort by score, lowest first",
            SortOption.TITLE_AZ: "Sort by title, A to Z",
            SortOption.TITLE_ZA: "Sort by title, Z to A",
            SortOption.YEAR_NEWEST: "Sort by year, newest first",
            SortOption.YEAR_OLDEST: "Sort by year, oldest first",
        }
        return descriptions.get(self, "Unknown sort order")


T = TypeVar("T")


def sort_documents(documents: List[T], option: SortOption) -> List[T]:
    """
    Sort documents by the selected option.

    Args:
        documents: List of document objects with score, title, year attributes.
        option: Sort option to apply.

    Returns:
        Sorted list of documents.
    """
    if option == SortOption.SCORE_HIGH_TO_LOW:
        return sorted(documents, key=lambda d: -(getattr(d, "score", 0) or 0))
    elif option == SortOption.SCORE_LOW_TO_HIGH:
        return sorted(documents, key=lambda d: getattr(d, "score", 0) or 0)
    elif option == SortOption.TITLE_AZ:
        return sorted(documents, key=lambda d: (getattr(d, "title", "") or "").lower())
    elif option == SortOption.TITLE_ZA:
        return sorted(
            documents,
            key=lambda d: (getattr(d, "title", "") or "").lower(),
            reverse=True,
        )
    elif option == SortOption.YEAR_NEWEST:
        return sorted(documents, key=lambda d: -(getattr(d, "year", 0) or 0))
    elif option == SortOption.YEAR_OLDEST:
        return sorted(documents, key=lambda d: getattr(d, "year", 0) or 0)
    return documents


class SortingControlsWidget(QWidget):
    """
    Widget for sorting document results.

    Emits sort_changed signal when user selects a different sort option.
    """

    sort_changed = Signal(SortOption)

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self._current_option = SortOption.SCORE_HIGH_TO_LOW
        self._setup_ui()

    def _setup_ui(self):
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        label = QLabel("Sort by:")
        label.setStyleSheet("color: #666;")

        self._combo = QComboBox()
        for option in SortOption:
            self._combo.addItem(option.value, option)

        self._combo.setCurrentIndex(0)
        self._combo.currentIndexChanged.connect(self._on_selection_changed)

        # Accessibility
        self._combo.setAccessibleName("Sort order")
        self._combo.setAccessibleDescription(
            self._current_option.accessibility_description
        )

        layout.addWidget(label)
        layout.addWidget(self._combo)
        layout.addStretch()

    def _on_selection_changed(self, index: int):
        """Handle combo box selection change."""
        option = self._combo.itemData(index)
        if option and option != self._current_option:
            self._current_option = option
            self._combo.setAccessibleDescription(option.accessibility_description)
            self.sort_changed.emit(option)

    def get_current_option(self) -> SortOption:
        """Get the currently selected sort option."""
        return self._current_option

    def set_option(self, option: SortOption):
        """Set the sort option programmatically."""
        index = list(SortOption).index(option)
        self._combo.setCurrentIndex(index)
```

## 4.6 Integration in Audit Literature Tab

**File**: `src/bmlibrarian_lite/gui/audit_literature_tab.py`

Add error queue and sorting controls:

```python
from typing import List, Optional
from PySide6.QtWidgets import QWidget, QVBoxLayout, QScrollArea, QLabel
from PySide6.QtCore import Signal

from .error_queue_widget import ErrorQueueWidget
from .sorting_controls_widget import SortingControlsWidget, SortOption, sort_documents
from .document_card import DocumentCard  # Existing component
from ..models.error_entry import ErrorEntry
from ..models.lite_document import LiteDocument
from ..storage.error_storage import ErrorStorageManager
from ..storage import LiteStorage


class AuditLiteratureTab(QWidget):
    """Tab for reviewing scored literature results."""

    # Signal emitted when retry is requested for specific PMIDs
    retry_documents_requested = Signal(list)

    def __init__(
        self,
        storage: LiteStorage,
        session_id: str,
        parent: Optional[QWidget] = None,
    ):
        super().__init__(parent)
        self._storage = storage
        self._session_id = session_id
        self._error_storage = ErrorStorageManager(storage)
        self._documents: List[LiteDocument] = []
        self._current_sort = SortOption.SCORE_HIGH_TO_LOW
        self._setup_ui()
        self._load_persisted_errors()

    def _setup_ui(self):
        layout = QVBoxLayout(self)

        # Error queue at top (Phase 4)
        self._error_queue = ErrorQueueWidget()
        self._error_queue.retry_requested.connect(self._handle_retry)
        self._error_queue.errors_cleared.connect(self._handle_errors_cleared)
        layout.addWidget(self._error_queue)

        # Sorting controls (Phase 4)
        self._sorting_controls = SortingControlsWidget()
        self._sorting_controls.sort_changed.connect(self._apply_sort)
        layout.addWidget(self._sorting_controls)

        # Results summary
        self._summary_label = QLabel()
        self._summary_label.setAccessibleName("Results summary")
        layout.addWidget(self._summary_label)

        # Document list
        self._scroll_area = QScrollArea()
        self._scroll_area.setWidgetResizable(True)

        self._document_container = QWidget()
        self._document_layout = QVBoxLayout(self._document_container)
        self._scroll_area.setWidget(self._document_container)

        layout.addWidget(self._scroll_area)

    def _load_persisted_errors(self):
        """Load errors from storage on startup."""
        errors = self._error_storage.load_errors(self._session_id)
        if errors:
            self._error_queue.set_errors(errors)
            self._update_summary()

    def set_documents(self, documents: List[LiteDocument]):
        """Set documents and refresh display."""
        self._documents = documents
        self._refresh_document_cards()
        self._update_summary()

    def add_error(self, pmid: str, step: str, message: str):
        """
        Add an error from processing.

        Called by the scoring workflow when a document fails.
        """
        error = ErrorEntry(
            pmid=pmid,
            step=step,
            message=message,
            session_id=self._session_id,
        )
        self._error_queue.add_error(error)
        self._error_storage.save_error(error)
        self._update_summary()

    def _apply_sort(self, option: SortOption):
        """Apply new sort order to documents."""
        self._current_sort = option
        self._refresh_document_cards()

        # Persist preference
        self._storage.save_user_preference(
            "sort_option",
            option.value,
        )

    def _refresh_document_cards(self):
        """Refresh document card display with current sort."""
        # Clear existing
        while self._document_layout.count():
            item = self._document_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        # Sort and display
        sorted_docs = sort_documents(self._documents, self._current_sort)
        for doc in sorted_docs:
            card = DocumentCard(doc)
            self._document_layout.addWidget(card)

        self._document_layout.addStretch()

    def _update_summary(self):
        """Update the results summary label."""
        scored = len([d for d in self._documents if d.score is not None])
        failed = len(self._error_queue.get_errors())

        text = f"{scored} documents scored"
        if failed > 0:
            text += f", {failed} failed"

        self._summary_label.setText(text)
        self._summary_label.setAccessibleDescription(
            f"{scored} documents scored successfully, {failed} failed"
        )

    def _handle_retry(self, pmids: List[str]):
        """Handle retry request from error queue."""
        # Increment retry counts
        self._error_storage.increment_retry_count(self._session_id, pmids)

        # Emit signal for parent to re-process
        self.retry_documents_requested.emit(pmids)

    def _handle_errors_cleared(self):
        """Handle errors cleared from queue."""
        self._error_storage.clear_session(self._session_id)
        self._update_summary()

    def on_document_scored_successfully(self, pmid: str):
        """
        Called when a previously-failed document is successfully scored.

        Removes the error from storage and queue.
        """
        self._error_storage.remove_errors(self._session_id, [pmid])

        # Refresh error queue
        errors = self._error_storage.load_errors(self._session_id)
        self._error_queue.set_errors(errors)
        self._update_summary()
```

## 4.7 Parallel Scoring Integration

**File**: `src/bmlibrarian_lite/agents/parallel_scoring.py`

Add error reporting integration:

```python
import asyncio
from typing import List, Optional, Callable, Tuple

from ..models.error_entry import ErrorEntry
from ..models.lite_document import LiteDocument
from ..models.scoring_result import ScoringResult
from ..utils.error_types import categorize_error
from ..utils.cancellation import CancellationToken
from ..utils.progress import ProgressMessage
from ..storage import LiteStorage
from ..agents.scoring_agent import ScoringAgent


async def score_single_document_async(
    agent: ScoringAgent,
    doc: LiteDocument,
    question: str,
) -> ScoringResult:
    """
    Score a single document asynchronously.

    Args:
        agent: The scoring agent instance.
        doc: Document to score.
        question: Research question.

    Returns:
        ScoringResult with score or error information.
    """
    # Implementation delegates to agent
    return await agent.score_async(doc, question)


async def score_documents_with_errors(
    documents: List[LiteDocument],
    question: str,
    session_id: str,
    storage: LiteStorage,
    agent_factory: Callable[[], ScoringAgent],
    max_concurrent: int,
    cancellation_token: Optional[CancellationToken] = None,
    on_progress: Optional[Callable[[ProgressMessage], None]] = None,
    on_error: Optional[Callable[[ErrorEntry], None]] = None,
) -> Tuple[List[ScoringResult], List[ErrorEntry]]:
    """
    Score documents with comprehensive error tracking.

    Extends Phase 3's cancellable scoring with Phase 4 error collection.

    Args:
        documents: List of documents to score.
        question: The research question.
        session_id: Session identifier.
        storage: Storage instance.
        agent_factory: Factory for creating scoring agents.
        max_concurrent: Max concurrent requests.
        cancellation_token: Optional cancellation token (Phase 3).
        on_progress: Progress callback.
        on_error: Error callback for each failed document.

    Returns:
        Tuple of (successful results, error entries).
    """
    results: List[ScoringResult] = []
    errors: List[ErrorEntry] = []

    semaphore = asyncio.Semaphore(max_concurrent)

    async def process_document(doc: LiteDocument) -> Optional[ScoringResult]:
        if cancellation_token and cancellation_token.is_cancelled():
            return None

        async with semaphore:
            try:
                agent = agent_factory()
                result = await score_single_document_async(agent, doc, question)

                if result.is_error:
                    # Create error entry
                    error = ErrorEntry(
                        pmid=doc.pmid,
                        step="scoring",
                        message=result.error_message or "Unknown error",
                        session_id=session_id,
                    )
                    errors.append(error)

                    if on_error:
                        on_error(error)
                else:
                    # Save checkpoint (Phase 2)
                    storage.save_checkpoint(
                        session_id,
                        doc.pmid,
                        "scoring",
                        {"score": result.score, "rationale": result.rationale},
                    )

                return result

            except Exception as e:
                # Unexpected error
                error = ErrorEntry.from_exception(
                    pmid=doc.pmid,
                    step="scoring",
                    error=e,
                    session_id=session_id,
                )
                errors.append(error)

                if on_error:
                    on_error(error)

                return ScoringResult(
                    pmid=doc.pmid,
                    score=None,
                    rationale=None,
                    is_error=True,
                    error_message=str(e),
                )

    # Process all documents
    tasks = [process_document(doc) for doc in documents]
    task_results = await asyncio.gather(*tasks, return_exceptions=True)

    for result in task_results:
        if isinstance(result, ScoringResult) and not result.is_error:
            results.append(result)

    return results, errors
```

## Key Python Patterns

### Qt Accessibility

PySide6/Qt provides accessibility through:

- `setAccessibleName()` - Screen reader label
- `setAccessibleDescription()` - Additional context
- Proper widget focus order (tab navigation)
- High contrast color support

### Dataclasses for Models

Python dataclasses provide:

- Automatic `__init__`, `__repr__`, `__eq__`
- Type hints for documentation
- `asdict()` for serialization
- `field()` for default factories

### Signal/Slot Pattern

Qt signals for loose coupling:

- `Signal(type)` - Declare signal with parameter types
- `.connect(callback)` - Connect handlers
- `.emit(value)` - Emit signal with value

### Enum for Type Safety

Python Enum for sort options:

- Type-safe option values
- Iteration with `for option in SortOption`
- Properties for metadata (accessibility descriptions)

## Testing

```bash
# Unit tests
pytest tests/test_error_types.py -v
pytest tests/test_error_entry.py -v
pytest tests/test_error_storage.py -v
pytest tests/test_sorting.py -v

# Widget tests
pytest tests/test_error_queue_widget.py -v
pytest tests/test_sorting_controls_widget.py -v

# Integration tests
pytest tests/test_error_queue_integration.py -v
```

### Test Cases

```python
# test_error_types.py
def test_categorize_network_errors():
    assert categorize_error_message("Network connection failed") == ErrorCategory.NETWORK
    assert categorize_error_message("Unable to reach server") == ErrorCategory.NETWORK
    assert categorize_error_message("Socket timeout") == ErrorCategory.TIMEOUT

def test_categorize_llm_errors():
    assert categorize_error_message("API key invalid") == ErrorCategory.LLM
    assert categorize_error_message("Rate limit exceeded") == ErrorCategory.LLM
    assert categorize_error_message("Anthropic service unavailable") == ErrorCategory.LLM

def test_categorize_from_exception():
    import socket
    assert categorize_error(socket.timeout("timed out")) == ErrorCategory.TIMEOUT
    assert categorize_error(ConnectionRefusedError()) == ErrorCategory.NETWORK


# test_sorting.py
def test_sort_by_score_high_to_low():
    docs = [
        MockDocument(pmid="1", score=5),
        MockDocument(pmid="2", score=10),
        MockDocument(pmid="3", score=3),
    ]

    sorted_docs = sort_documents(docs, SortOption.SCORE_HIGH_TO_LOW)
    assert [d.pmid for d in sorted_docs] == ["2", "1", "3"]

def test_sort_by_title():
    docs = [
        MockDocument(pmid="1", title="Zebra"),
        MockDocument(pmid="2", title="Apple"),
        MockDocument(pmid="3", title="Mango"),
    ]

    sorted_docs = sort_documents(docs, SortOption.TITLE_AZ)
    assert [d.pmid for d in sorted_docs] == ["2", "3", "1"]


# test_error_queue_widget.py
def test_error_queue_hidden_when_empty(qtbot):
    widget = ErrorQueueWidget()
    qtbot.addWidget(widget)
    assert not widget.isVisible()

def test_error_queue_shows_on_add(qtbot):
    widget = ErrorQueueWidget()
    qtbot.addWidget(widget)

    error = ErrorEntry(pmid="123", step="scoring", message="Test error")
    widget.add_error(error)

    assert widget.isVisible()
    assert "1" in widget._header_label.text()

def test_error_category_filtering(qtbot):
    widget = ErrorQueueWidget()
    qtbot.addWidget(widget)

    widget.add_errors([
        ErrorEntry(pmid="1", step="s", message="Network error"),
        ErrorEntry(pmid="2", step="s", message="LLM failed"),
        ErrorEntry(pmid="3", step="s", message="Network timeout"),
    ])

    # Should have filter buttons for Network, LLM, Timeout
    assert len(widget._filter_buttons) >= 3
```

## Acceptance Criteria

- [ ] Error queue hidden when empty
- [ ] Error queue appears when first error occurs
- [ ] Errors show PMID, step, message, and category with color-coded badge
- [ ] Error categorization correctly identifies network/LLM/parsing/timeout errors
- [ ] Category filter buttons allow filtering by error type
- [ ] "Retry All" button re-queues failed documents
- [ ] "Clear" button dismisses errors
- [ ] Errors persist across application restarts (via LiteStorage)
- [ ] Retry count tracked and displayed on error cards
- [ ] Sort dropdown available after processing
- [ ] Sorting updates document card order immediately
- [ ] Sort preference persisted via storage
- [ ] All interactive elements have accessible names
- [ ] Screen readers correctly announce error counts and categories
- [ ] Keyboard navigation works through all controls
