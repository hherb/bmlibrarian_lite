# Step 08: Workflow Integration

## Goal

Wire transparency analysis into the systematic review workflow so papers are analyzed automatically after search, and UI updates when results arrive.

## Files to Modify

### `src/bmlibrarian_lite/gui/systematic_review_tab.py`

**Changes:**

1. Create TransparencyManager instance
2. Connect to analysis signals
3. Queue papers for analysis after search completes
4. Update document cards when analysis completes
5. Apply filtering when transparency filter is enabled

```python
# Add imports:
from ..transparency import TransparencyManager, TransparencyResult, TransparencyRisk

class SystematicReviewTab(QWidget):
    """Main systematic review workflow tab."""

    def __init__(self, storage: LiteStorage, config: LiteConfig, ...):
        super().__init__()
        self.storage = storage
        self.config = config

        # Initialize transparency manager
        self._transparency_manager = TransparencyManager(
            storage=storage,
            config=config,
            email=config.ncbi_email or "user@example.com",
            pubmed_api_key=config.ncbi_api_key,
        )

        # Connect signals
        self._transparency_manager.analysis_complete.connect(
            self._on_transparency_complete
        )
        self._transparency_manager.analysis_failed.connect(
            self._on_transparency_failed
        )
        self._transparency_manager.progress_updated.connect(
            self._on_transparency_progress
        )

        # ... rest of init ...

    def _on_search_complete(self, documents: list[LiteDocument]) -> None:
        """Handle search completion - queue transparency analysis."""
        # ... existing document processing ...

        # Queue documents for transparency analysis
        if self.config.transparency_settings.enabled:
            self._queue_transparency_analysis(documents)

    def _queue_transparency_analysis(self, documents: list[LiteDocument]) -> None:
        """Queue documents for background transparency analysis."""
        docs_to_analyze = []
        for doc in documents:
            if doc.pmid or doc.doi:
                docs_to_analyze.append({
                    "id": doc.id,
                    "pmid": doc.pmid,
                    "doi": doc.doi,
                })

        if docs_to_analyze:
            self._transparency_manager.analyze_batch(docs_to_analyze)
            self._show_transparency_progress(len(docs_to_analyze))

    def _show_transparency_progress(self, total: int) -> None:
        """Show transparency analysis progress indicator."""
        # Could be a status bar message or progress indicator
        self._status_label.setText(f"Analyzing transparency: 0/{total}")

    def _on_transparency_complete(
        self,
        document_id: str,
        result: TransparencyResult,
    ) -> None:
        """Handle completed transparency analysis."""
        # Update the document card
        self._audit_literature_tab.update_transparency(document_id, result)

        # Apply filtering if enabled
        if self.config.transparency_settings.filtering_enabled:
            if result.risk_level == TransparencyRisk.HIGH:
                self._audit_literature_tab.filter_document(document_id)

        # Update quality tier if needed
        self._apply_transparency_to_quality(document_id, result)

    def _on_transparency_failed(self, document_id: str, error: str) -> None:
        """Handle transparency analysis failure."""
        logger.warning(f"Transparency analysis failed for {document_id}: {error}")
        # Optionally show in UI or just log

    def _on_transparency_progress(self, current: int, total: int) -> None:
        """Update progress indicator."""
        self._status_label.setText(f"Analyzing transparency: {current}/{total}")
        if current == total:
            self._status_label.setText("Transparency analysis complete")

    def _apply_transparency_to_quality(
        self,
        document_id: str,
        result: TransparencyResult,
    ) -> None:
        """Apply transparency adjustment to quality assessment."""
        assessment = self.storage.get_quality_assessment(document_id)
        if assessment:
            adjusted = self._quality_manager.apply_transparency_adjustment(
                assessment, result
            )
            if adjusted.transparency_adjusted:
                # Save adjusted assessment
                self.storage.save_quality_assessment(adjusted)
                # Update card display
                self._audit_literature_tab.update_quality(document_id, adjusted)

    def closeEvent(self, event) -> None:
        """Clean up on close."""
        self._transparency_manager.stop()
        super().closeEvent(event)
```

### `src/bmlibrarian_lite/gui/audit_literature_tab.py`

**Changes:**

1. Add method to update transparency badge on document card
2. Add method to filter/hide high-risk documents
3. Track filtered documents for toggle

```python
# Add imports:
from ..transparency import TransparencyResult, TransparencyRisk

class AuditLiteratureTab(QWidget):
    """Tab displaying documents with quality and transparency info."""

    def __init__(self, ...):
        # ... existing init ...
        self._filtered_documents: set[str] = set()  # Track filtered doc IDs

    def update_transparency(
        self,
        document_id: str,
        result: TransparencyResult,
    ) -> None:
        """Update document card with transparency result."""
        with self._lock:
            card = self._document_cards.get(document_id)
            if card:
                card.set_transparency_result(result)

    def filter_document(self, document_id: str) -> None:
        """Hide a document card (filtered out)."""
        with self._lock:
            card = self._document_cards.get(document_id)
            if card:
                card.hide()
                self._filtered_documents.add(document_id)

    def unfilter_document(self, document_id: str) -> None:
        """Show a previously filtered document card."""
        with self._lock:
            card = self._document_cards.get(document_id)
            if card and document_id in self._filtered_documents:
                card.show()
                self._filtered_documents.discard(document_id)

    def set_transparency_filtering(self, enabled: bool) -> None:
        """Toggle transparency filtering for all documents."""
        with self._lock:
            for doc_id, card in self._document_cards.items():
                result = card.get_transparency_result()
                if result and result.risk_level == TransparencyRisk.HIGH:
                    if enabled:
                        card.hide()
                        self._filtered_documents.add(doc_id)
                    else:
                        card.show()
                        self._filtered_documents.discard(doc_id)

    def get_visible_count(self) -> int:
        """Return count of visible (not filtered) documents."""
        return len(self._document_cards) - len(self._filtered_documents)

    def get_filtered_count(self) -> int:
        """Return count of filtered documents."""
        return len(self._filtered_documents)
```

## Integration Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    User Starts Search                            │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Search Agent returns documents                                  │
│  → Documents displayed in AuditLiteratureTab                    │
│  → Cards shown with quality badges (no transparency yet)        │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  _queue_transparency_analysis() called                          │
│  → TransparencyManager.analyze_batch() starts background work   │
│  → Progress indicator shown                                     │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │   For each document   │
                    └───────────┬───────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Background thread: StudyTransparencyAnalyzer.analyze()         │
│  → Fetches from PubMed, CrossRef, ClinicalTrials.gov, etc.     │
│  → Calculates transparency score                                │
│  → Determines risk level                                        │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Signal: analysis_complete(document_id, result)                 │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
┌──────────────────────────┐  ┌──────────────────────────────────┐
│  Update Document Card    │  │  Apply Quality Adjustment        │
│  ├─ Add transparency     │  │  ├─ If high risk:               │
│  │   badge               │  │  │   Apply tier downgrade       │
│  └─ Rich tooltip         │  │  └─ Save adjusted assessment    │
└──────────────────────────┘  └──────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  If filtering enabled AND high risk:                            │
│  → Hide document card                                           │
│  → Update visible/filtered counts                               │
└─────────────────────────────────────────────────────────────────┘
```

## Signal Connections Summary

| Signal | Source | Handler | Effect |
|--------|--------|---------|--------|
| `analysis_complete` | TransparencyManager | `_on_transparency_complete` | Update card, apply filter/adjustment |
| `analysis_failed` | TransparencyManager | `_on_transparency_failed` | Log warning |
| `progress_updated` | TransparencyManager | `_on_transparency_progress` | Update status |
| `transparency_filter_changed` | QualityFilterPanel | `_on_filter_toggle` | Show/hide filtered cards |

## Testing

Create `tests/gui/test_workflow_integration.py`:
- Test transparency analysis queued after search
- Test document cards updated when analysis completes
- Test filtering hides high-risk documents
- Test filter toggle shows/hides documents
- Test quality tier adjustment applied
- Mock TransparencyManager to avoid real API calls

## Dependencies

- All previous steps (01-07)
- systematic_review_tab.py
- audit_literature_tab.py

## Error Handling

- Analysis failures logged but don't block workflow
- Missing PMID/DOI skips analysis (no error)
- API rate limiting handled by TransparencyManager
- Cached results used when available

## Performance Considerations

- Background thread pool prevents UI blocking
- Rate limiting (500ms between requests) prevents API abuse
- Batch processing with progress updates
- Caching prevents redundant analysis

## Estimated Scope

- ~100 lines modifications to systematic_review_tab.py
- ~60 lines modifications to audit_literature_tab.py
- ~80 lines tests
