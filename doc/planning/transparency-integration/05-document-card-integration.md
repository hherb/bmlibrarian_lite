# Step 05: Document Card Integration

## Goal

Add the transparency badge to DocumentCard and handle dynamic updates when analysis completes.

## Files to Modify

### `src/bmlibrarian_lite/gui/document_card.py`

**Changes:**

1. Import TransparencyBadge and TransparencyResult
2. Add transparency_result parameter to DocumentCard.__init__
3. Add _transparency_badge attribute
4. Insert badge in header layout (after quality badge, before score badge)
5. Add set_transparency_result() method for dynamic updates
6. Update _setup_header() to include transparency badge slot

```python
# At top of file, add imports:
from .transparency_badge import TransparencyBadge
from ..transparency import TransparencyResult

# In DocumentCard class:

class DocumentCard(QFrame):
    """Collapsible card displaying document information."""

    def __init__(
        self,
        document: LiteDocument,
        score: Optional[float] = None,
        quality_assessment: Optional[QualityAssessment] = None,
        transparency_result: Optional[TransparencyResult] = None,  # NEW
        rationale: Optional[str] = None,
        parent: Optional[QWidget] = None,
    ):
        super().__init__(parent)
        self.document = document
        self._score = score
        self._quality_assessment = quality_assessment
        self._transparency_result = transparency_result  # NEW
        self._rationale = rationale

        # Badge widgets (created in _setup_header)
        self._quality_badge: Optional[QualityBadge] = None
        self._transparency_badge: Optional[TransparencyBadge] = None  # NEW
        self._score_badge: Optional[ScoreBadge] = None
        self._source_badge: Optional[SourceBadge] = None

        self._setup_ui()

    def _setup_header(self) -> QWidget:
        """Create the header section with badges and metadata."""
        header = QWidget()
        header_layout = QVBoxLayout(header)
        header_layout.setContentsMargins(scaled(12), scaled(8), scaled(12), scaled(8))
        header_layout.setSpacing(scaled(4))

        # Top row: badges + title
        top_row = QHBoxLayout()
        top_row.setSpacing(scaled(6))

        # Badge container (left side)
        self._badge_container = QHBoxLayout()
        self._badge_container.setSpacing(scaled(4))

        # Quality badge (if available)
        if self._quality_assessment:
            self._quality_badge = QualityBadge(self._quality_assessment)
            self._badge_container.addWidget(self._quality_badge)

        # Transparency badge (if available) - NEW
        if self._transparency_result:
            self._transparency_badge = TransparencyBadge(
                self._transparency_result,
                compact=True,  # Use compact mode in card header
            )
            self._badge_container.addWidget(self._transparency_badge)

        # Score badge (if available)
        if self._score is not None:
            self._score_badge = ScoreBadge(self._score)
            self._badge_container.addWidget(self._score_badge)

        # Source badge (Europe PMC or preprints only)
        if self.document.source in (DocumentSource.EUROPEPMC,) or self.document.is_preprint:
            self._source_badge = SourceBadge(self.document.source, self.document.is_preprint)
            self._badge_container.addWidget(self._source_badge)

        top_row.addLayout(self._badge_container)

        # ... rest of existing header setup ...

    def set_transparency_result(self, result: TransparencyResult) -> None:
        """
        Update the transparency result and badge.

        Called when background analysis completes.
        """
        self._transparency_result = result

        if self._transparency_badge:
            # Update existing badge
            self._transparency_badge.update_result(result)
        else:
            # Create new badge and insert after quality badge
            self._transparency_badge = TransparencyBadge(result, compact=True)

            # Find insertion point (after quality badge if present, else at start)
            insert_index = 0
            if self._quality_badge:
                insert_index = 1

            self._badge_container.insertWidget(insert_index, self._transparency_badge)

    def get_transparency_result(self) -> Optional[TransparencyResult]:
        """Return current transparency result."""
        return self._transparency_result

    @property
    def transparency_risk(self) -> Optional[str]:
        """Return risk level string for filtering."""
        if self._transparency_result:
            return self._transparency_result.risk_level.value
        return None
```

**Badge Order in Header:**
1. Quality Badge (study design tier)
2. **Transparency Badge (risk level)** ← NEW
3. Score Badge (relevance score)
4. Source Badge (provider)

## Visual Layout

```
┌─────────────────────────────────────────────────────────────┐
│ [RCT] [Med Risk] [4/5] [Europe PMC]  Paper Title Here...   │
│ Authors | Journal (Year) | PMID: xxx | DOI: xxx            │
├─────────────────────────────────────────────────────────────┤
│ Abstract text (collapsed by default)...                     │
└─────────────────────────────────────────────────────────────┘
```

## Testing

Add to `tests/gui/test_document_card.py`:
- Test card creation with transparency result
- Test card creation without transparency result (no badge shown)
- Test set_transparency_result() adds badge dynamically
- Test set_transparency_result() updates existing badge
- Test badge order is correct

## Dependencies

- transparency_badge.py (from Step 04)
- transparency_models.py (from Step 01)

## Notes

- Compact mode used in card header to save space
- Badge inserted dynamically when analysis completes
- Tooltip provides full details on hover
- Badge container uses QHBoxLayout for easy insertion

## Estimated Scope

- ~50 lines modifications to document_card.py
- ~30 lines tests
