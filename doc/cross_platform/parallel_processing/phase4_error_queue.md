# Phase 4: Error Queue UI and Result Re-ordering

## Objective

Provide a polished error display and allow users to re-order results after processing completes.

## Terminology Note

The Python desktop app uses `question` (research question context) while the iOS/Android
mobile apps use `claim` (medical fact-checking context). Both refer to the same concept:
the text being evaluated against the document for relevance scoring. This document uses
`question` for Python code and `claim` for Swift/Kotlin code to match each platform's
existing conventions.

## Python Implementation

### 4.1 Error Queue Widget

**File**: `src/bmlibrarian_lite/gui/error_queue_widget.py` (new file)

```python
"""Collapsible error queue widget."""

from dataclasses import dataclass
from datetime import datetime
from typing import List, Optional
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QPushButton, QScrollArea, QFrame,
)
from PySide6.QtCore import Signal

from ..dpi_scale import scaled


@dataclass
class ErrorEntry:
    """Single error entry."""

    pmid: str
    step: str
    message: str
    timestamp: datetime


class ErrorQueueWidget(QWidget):
    """
    Collapsible widget displaying accumulated errors.

    Hidden when empty, expands to show error list when populated.
    """

    retry_requested = Signal(list)  # List of PMIDs to retry

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self._errors: List[ErrorEntry] = []
        self._is_expanded = False
        self._setup_ui()
        self.hide()

    def _setup_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # Header
        self._header = QFrame()
        self._header.setStyleSheet("background-color: #FFEBEE; border-radius: 4px;")
        header_layout = QHBoxLayout(self._header)

        self._header_label = QLabel("Errors (0)")
        self._header_label.setStyleSheet("color: #C62828; font-weight: bold;")

        self._toggle_button = QPushButton("▼")
        self._toggle_button.setFixedWidth(scaled(24))
        self._toggle_button.clicked.connect(self._toggle_expanded)

        self._retry_button = QPushButton("Retry All")
        self._retry_button.clicked.connect(self._handle_retry)

        self._clear_button = QPushButton("Clear")
        self._clear_button.clicked.connect(self.clear)

        header_layout.addWidget(self._header_label)
        header_layout.addStretch()
        header_layout.addWidget(self._retry_button)
        header_layout.addWidget(self._clear_button)
        header_layout.addWidget(self._toggle_button)

        layout.addWidget(self._header)

        # Error list (collapsible)
        self._scroll_area = QScrollArea()
        self._scroll_area.setWidgetResizable(True)
        self._scroll_area.setMaximumHeight(scaled(200))

        self._error_container = QWidget()
        self._error_layout = QVBoxLayout(self._error_container)
        self._scroll_area.setWidget(self._error_container)
        self._scroll_area.hide()

        layout.addWidget(self._scroll_area)

    def add_error(self, pmid: str, step: str, message: str) -> None:
        """Add error to queue and make widget visible."""
        entry = ErrorEntry(
            pmid=pmid,
            step=step,
            message=message,
            timestamp=datetime.now(),
        )
        self._errors.append(entry)
        self._add_error_widget(entry)
        self._update_visibility()

    def _add_error_widget(self, entry: ErrorEntry):
        frame = QFrame()
        frame.setStyleSheet("background-color: white; border: 1px solid #FFCDD2; border-radius: 4px; padding: 4px;")
        layout = QVBoxLayout(frame)

        pmid_label = QLabel(f"PMID: {entry.pmid} ({entry.step})")
        pmid_label.setStyleSheet("font-weight: bold;")

        message_label = QLabel(entry.message)
        message_label.setWordWrap(True)
        message_label.setStyleSheet("color: #666;")

        layout.addWidget(pmid_label)
        layout.addWidget(message_label)

        self._error_layout.addWidget(frame)

    def _update_visibility(self):
        if self._errors:
            self.show()
            self._header_label.setText(f"Errors ({len(self._errors)})")
        else:
            self.hide()

    def _toggle_expanded(self):
        self._is_expanded = not self._is_expanded
        self._scroll_area.setVisible(self._is_expanded)
        self._toggle_button.setText("▲" if self._is_expanded else "▼")

    def clear(self):
        """Clear all errors and hide widget."""
        self._errors.clear()
        # Clear error widgets
        while self._error_layout.count():
            item = self._error_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._update_visibility()

    def _handle_retry(self):
        """Emit retry signal with failed PMIDs."""
        pmids = [e.pmid for e in self._errors]
        self.retry_requested.emit(pmids)
        self.clear()

    def get_failed_pmids(self) -> List[str]:
        """Get list of PMIDs that failed."""
        return [e.pmid for e in self._errors]
```

### 4.2 Result Re-ordering

**File**: `src/bmlibrarian_lite/gui/audit_literature_tab.py`

Add sorting controls:

```python
class AuditLiteratureTab(QWidget):
    def __init__(self, ...):
        # ... existing init ...
        self._setup_sort_controls()

    def _setup_sort_controls(self):
        sort_layout = QHBoxLayout()

        sort_label = QLabel("Sort by:")
        self._sort_combo = QComboBox()
        self._sort_combo.addItems([
            "Score (High to Low)",
            "Score (Low to High)",
            "Title (A-Z)",
            "Year (Newest First)",
            "Year (Oldest First)",
        ])
        self._sort_combo.currentIndexChanged.connect(self._apply_sort)

        sort_layout.addWidget(sort_label)
        sort_layout.addWidget(self._sort_combo)
        sort_layout.addStretch()

        # Add to main layout

    def _apply_sort(self, index: int):
        sort_key = [
            lambda d: -(d.score or 0),
            lambda d: d.score or 0,
            lambda d: (d.title or "").lower(),
            lambda d: -(d.year or 0),
            lambda d: d.year or 0,
        ][index]

        self._documents.sort(key=sort_key)
        self._refresh_document_cards()
```

## Swift Implementation (iOS/macOS)

### 4.1 Error Queue View

**File**: `ios/MedicalFactChecker/Sources/Views/Components/ErrorQueueView.swift`

```swift
import SwiftUI

struct ErrorEntry: Identifiable {
    let id = UUID()
    let pmid: String
    let step: String
    let message: String
    let timestamp: Date
}

struct ErrorQueueView: View {
    @Binding var errors: [ErrorEntry]
    @State private var isExpanded = false
    var onRetry: ([String]) -> Void

    var body: some View {
        if !errors.isEmpty {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Label("Errors (\(errors.count))", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.headline)

                    Spacer()

                    Button("Retry All") {
                        let pmids = errors.map { $0.pmid }
                        onRetry(pmids)
                        errors.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Button("Clear") {
                        errors.removeAll()
                    }
                    .buttonStyle(.bordered)

                    Button {
                        withAnimation { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)

                // Error list
                if isExpanded {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(errors) { error in
                                ErrorCardView(error: error)
                            }
                        }
                        .padding()
                    }
                    .frame(maxHeight: 200)
                    .background(Color(.systemBackground))
                }
            }
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(radius: 2)
        }
    }
}

struct ErrorCardView: View {
    let error: ErrorEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("PMID: \(error.pmid)")
                    .font(.caption.bold())
                Text("(\(error.step))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(error.message)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.2), lineWidth: 1)
        )
    }
}
```

### 4.2 Sorting Controls

**File**: `ios/MedicalFactChecker/Sources/Views/Components/SortingControlsView.swift`

```swift
import SwiftUI

enum SortOption: String, CaseIterable {
    case scoreHighToLow = "Score (High to Low)"
    case scoreLowToHigh = "Score (Low to High)"
    case titleAZ = "Title (A-Z)"
    case yearNewest = "Year (Newest First)"
    case yearOldest = "Year (Oldest First)"
}

struct SortingControlsView: View {
    @Binding var selectedSort: SortOption

    var body: some View {
        HStack {
            Text("Sort by:")
                .font(.subheadline)

            Picker("Sort", selection: $selectedSort) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)

            Spacer()
        }
        .padding(.horizontal)
    }
}

extension Array where Element == Document {
    func sorted(by option: SortOption) -> [Document] {
        switch option {
        case .scoreHighToLow:
            return sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        case .scoreLowToHigh:
            return sorted { ($0.score ?? 0) < ($1.score ?? 0) }
        case .titleAZ:
            return sorted { ($0.title ?? "").lowercased() < ($1.title ?? "").lowercased() }
        case .yearNewest:
            return sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .yearOldest:
            return sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        }
    }
}
```

### 4.3 Integration in Fact Check View

**File**: `ios/MedicalFactChecker/Sources/Views/FactCheck/ScoredDocumentsView.swift`

```swift
import SwiftUI

struct ScoredDocumentsView: View {
    @State var documents: [Document]
    @State private var sortOption: SortOption = .scoreHighToLow
    @State private var errors: [ErrorEntry] = []

    var onRetry: ([String]) -> Void

    var sortedDocuments: [Document] {
        documents.sorted(by: sortOption)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Error queue at top
            ErrorQueueView(errors: $errors, onRetry: onRetry)
                .padding()

            // Sort controls
            SortingControlsView(selectedSort: $sortOption)

            // Document list
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(sortedDocuments) { document in
                        DocumentCardView(document: document)
                    }
                }
                .padding()
            }
        }
    }

    func addError(pmid: String, step: String, message: String) {
        errors.append(ErrorEntry(
            pmid: pmid,
            step: step,
            message: message,
            timestamp: Date()
        ))
    }
}
```

## Kotlin Implementation (Android)

### 4.1 Error Queue Composable

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/components/ErrorQueueView.kt`

```kotlin
package com.bmlibrarian.factchecker.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.time.Instant

data class ErrorEntry(
    val pmid: String,
    val step: String,
    val message: String,
    val timestamp: Instant = Instant.now()
)

@Composable
fun ErrorQueueView(
    errors: List<ErrorEntry>,
    onRetry: (List<String>) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier
) {
    if (errors.isEmpty()) return

    var isExpanded by remember { mutableStateOf(false) }

    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.3f)
        )
    ) {
        Column {
            // Header
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { isExpanded = !isExpanded }
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Warning,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "Errors (${errors.size})",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.error
                )
                Spacer(modifier = Modifier.weight(1f))

                TextButton(onClick = { onRetry(errors.map { it.pmid }) }) {
                    Text("Retry All")
                }
                TextButton(onClick = onClear) {
                    Text("Clear")
                }
                Icon(
                    imageVector = if (isExpanded) Icons.Default.KeyboardArrowUp
                                  else Icons.Default.KeyboardArrowDown,
                    contentDescription = if (isExpanded) "Collapse" else "Expand"
                )
            }

            // Error list
            AnimatedVisibility(visible = isExpanded) {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 200.dp)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(errors) { error ->
                        ErrorCard(error = error)
                    }
                }
            }
        }
    }
}

@Composable
private fun ErrorCard(error: ErrorEntry) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.3f))
    ) {
        Column(
            modifier = Modifier.padding(12.dp)
        ) {
            Row {
                Text(
                    text = "PMID: ${error.pmid}",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "(${error.step})",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = error.message,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2
            )
        }
    }
}
```

### 4.2 Sorting Controls

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/components/SortingControls.kt`

```kotlin
package com.bmlibrarian.factchecker.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

enum class SortOption(val label: String) {
    SCORE_HIGH_TO_LOW("Score (High to Low)"),
    SCORE_LOW_TO_HIGH("Score (Low to High)"),
    TITLE_AZ("Title (A-Z)"),
    YEAR_NEWEST("Year (Newest First)"),
    YEAR_OLDEST("Year (Oldest First)")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SortingControls(
    selectedSort: SortOption,
    onSortSelected: (SortOption) -> Unit,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = "Sort by:",
            style = MaterialTheme.typography.bodyMedium
        )
        Spacer(modifier = Modifier.width(8.dp))

        ExposedDropdownMenuBox(
            expanded = expanded,
            onExpandedChange = { expanded = !expanded }
        ) {
            OutlinedTextField(
                value = selectedSort.label,
                onValueChange = {},
                readOnly = true,
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                modifier = Modifier.menuAnchor()
            )

            ExposedDropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false }
            ) {
                SortOption.values().forEach { option ->
                    DropdownMenuItem(
                        text = { Text(option.label) },
                        onClick = {
                            onSortSelected(option)
                            expanded = false
                        }
                    )
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))
    }
}

fun <T> List<T>.sortedBy(option: SortOption, scoreSelector: (T) -> Int?, titleSelector: (T) -> String?, yearSelector: (T) -> Int?): List<T> {
    return when (option) {
        SortOption.SCORE_HIGH_TO_LOW -> sortedByDescending { scoreSelector(it) ?: 0 }
        SortOption.SCORE_LOW_TO_HIGH -> sortedBy { scoreSelector(it) ?: 0 }
        SortOption.TITLE_AZ -> sortedBy { (titleSelector(it) ?: "").lowercase() }
        SortOption.YEAR_NEWEST -> sortedByDescending { yearSelector(it) ?: 0 }
        SortOption.YEAR_OLDEST -> sortedBy { yearSelector(it) ?: 0 }
    }
}
```

### 4.3 Integration in Fact Check Screen

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/factcheck/ScoredDocumentsScreen.kt`

```kotlin
package com.bmlibrarian.factchecker.ui.factcheck

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.Document
import com.bmlibrarian.factchecker.ui.components.*

@Composable
fun ScoredDocumentsScreen(
    documents: List<Document>,
    errors: List<ErrorEntry>,
    onRetry: (List<String>) -> Unit,
    onClearErrors: () -> Unit,
    modifier: Modifier = Modifier
) {
    var sortOption by remember { mutableStateOf(SortOption.SCORE_HIGH_TO_LOW) }

    val sortedDocuments = remember(documents, sortOption) {
        documents.sortedBy(
            option = sortOption,
            scoreSelector = { it.score },
            titleSelector = { it.title },
            yearSelector = { it.year }
        )
    }

    Column(modifier = modifier.fillMaxSize()) {
        // Error queue at top
        ErrorQueueView(
            errors = errors,
            onRetry = onRetry,
            onClear = onClearErrors,
            modifier = Modifier.padding(16.dp)
        )

        // Sort controls
        SortingControls(
            selectedSort = sortOption,
            onSortSelected = { sortOption = it }
        )

        // Document list
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            items(sortedDocuments, key = { it.pmid ?: it.hashCode() }) { document ->
                DocumentCard(document = document)
            }
        }
    }
}
```

## Testing Phase 4

```bash
# Python tests
pytest tests/test_error_queue_widget.py -v
pytest tests/test_sorting.py -v

# UI tests
pytest tests/test_error_queue_integration.py -v
```

## Acceptance Criteria

- [ ] Error queue hidden when empty
- [ ] Error queue appears when first error occurs
- [ ] Errors show PMID, step, and message
- [ ] "Retry All" button re-queues failed documents
- [ ] "Clear" button dismisses errors
- [ ] Sort dropdown available after processing
- [ ] Sorting updates document card order immediately
- [ ] Sort preference persisted in session
