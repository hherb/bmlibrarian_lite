# Step 06: Quality Tier Adjustment

## Goal

Integrate transparency analysis into QualityManager to apply tier downgrades for high-risk papers.

## Files to Modify

### `src/bmlibrarian_lite/quality/quality_manager.py`

**Changes:**

1. Import transparency types
2. Add transparency_manager parameter to __init__ (optional)
3. Add method to apply tier adjustment
4. Modify assess_quality() to check for transparency result and apply adjustment
5. Store original tier before adjustment for audit trail

```python
# Add imports at top:
from ..transparency import TransparencyResult, TransparencyRisk, TransparencySettings

class QualityManager:
    """Manages quality assessment with optional transparency adjustment."""

    def __init__(
        self,
        storage: LiteStorage,
        config: LiteConfig,
        llm_client: Optional[LLMClient] = None,
    ):
        self.storage = storage
        self.config = config
        self.llm_client = llm_client
        self._transparency_settings = config.transparency_settings

    def apply_transparency_adjustment(
        self,
        assessment: QualityAssessment,
        transparency_result: TransparencyResult,
    ) -> QualityAssessment:
        """
        Apply tier downgrade based on transparency analysis.

        Args:
            assessment: Original quality assessment
            transparency_result: Transparency analysis result

        Returns:
            Modified assessment with tier adjustment (if applicable)
        """
        if not self._transparency_settings.enabled:
            return assessment

        if transparency_result.risk_level != TransparencyRisk.HIGH:
            return assessment

        # Store original tier for audit trail
        original_tier = assessment.quality_tier
        downgrade_amount = self._transparency_settings.tier_downgrade_amount

        # Calculate new tier (minimum is TIER_1_ANECDOTAL or UNCLASSIFIED)
        new_tier_value = max(
            0,  # UNCLASSIFIED
            original_tier.value - downgrade_amount
        )

        # Get the new tier enum
        new_tier = QualityTier(new_tier_value)

        # Create modified assessment
        adjusted = QualityAssessment(
            # Copy all original fields
            assessment_tier=assessment.assessment_tier,
            extraction_method=assessment.extraction_method,
            study_design=assessment.study_design,
            quality_tier=new_tier,  # ADJUSTED
            quality_score=assessment.quality_score,
            is_randomized=assessment.is_randomized,
            is_controlled=assessment.is_controlled,
            is_blinded=assessment.is_blinded,
            is_prospective=assessment.is_prospective,
            is_multicenter=assessment.is_multicenter,
            sample_size=assessment.sample_size,
            confidence=assessment.confidence,
            bias_risk=assessment.bias_risk,
            strengths=assessment.strengths,
            limitations=assessment.limitations,
            extraction_details=assessment.extraction_details,
            # NEW transparency fields
            transparency_result=transparency_result,
            original_quality_tier=original_tier,
            transparency_adjusted=True,
        )

        return adjusted

    def get_adjusted_quality(
        self,
        document_id: str,
        assessment: Optional[QualityAssessment] = None,
    ) -> Optional[QualityAssessment]:
        """
        Get quality assessment with transparency adjustment applied.

        If transparency result exists and indicates high risk,
        returns adjusted assessment with tier downgrade.

        Args:
            document_id: Document ID to look up transparency
            assessment: Optional pre-fetched assessment

        Returns:
            Adjusted quality assessment, or original if no adjustment needed
        """
        if assessment is None:
            assessment = self.storage.get_quality_assessment(document_id)

        if assessment is None:
            return None

        # Check for transparency result
        transparency = self.storage.get_transparency_result(document_id)
        if transparency is None:
            return assessment

        # Apply adjustment if needed
        return self.apply_transparency_adjustment(assessment, transparency)

    def should_filter_document(
        self,
        document_id: str,
        transparency_result: Optional[TransparencyResult] = None,
    ) -> bool:
        """
        Check if document should be filtered out due to transparency.

        Args:
            document_id: Document ID
            transparency_result: Optional pre-fetched result

        Returns:
            True if document should be excluded from results
        """
        if not self._transparency_settings.filtering_enabled:
            return False

        if transparency_result is None:
            transparency_result = self.storage.get_transparency_result(document_id)

        if transparency_result is None:
            return False  # Don't filter if not yet analyzed

        return transparency_result.risk_level == TransparencyRisk.HIGH

    def update_transparency_settings(self, settings: TransparencySettings) -> None:
        """Update transparency settings."""
        self._transparency_settings = settings
```

### `src/bmlibrarian_lite/quality/data_models.py`

**Changes to QualityAssessment dataclass:**

```python
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ..transparency import TransparencyResult

@dataclass
class QualityAssessment:
    """Quality assessment for a document."""

    # ... existing fields ...

    # Transparency integration (NEW)
    transparency_result: Optional["TransparencyResult"] = None
    original_quality_tier: Optional[QualityTier] = None
    transparency_adjusted: bool = False

    def get_effective_tier(self) -> QualityTier:
        """Return the effective quality tier (after any adjustments)."""
        return self.quality_tier

    def get_tier_adjustment(self) -> int:
        """Return the tier adjustment amount (0 if not adjusted)."""
        if self.transparency_adjusted and self.original_quality_tier:
            return self.original_quality_tier.value - self.quality_tier.value
        return 0

    def to_dict(self) -> dict:
        """Serialize to dictionary."""
        data = {
            # ... existing serialization ...
        }
        # Add transparency fields
        if self.transparency_result:
            data["transparency_result"] = self.transparency_result.to_dict()
        if self.original_quality_tier:
            data["original_quality_tier"] = self.original_quality_tier.value
        data["transparency_adjusted"] = self.transparency_adjusted
        return data

    @classmethod
    def from_dict(cls, data: dict) -> "QualityAssessment":
        """Deserialize from dictionary."""
        # ... existing deserialization ...

        # Handle transparency fields
        transparency_result = None
        if "transparency_result" in data:
            from ..transparency import TransparencyResult
            transparency_result = TransparencyResult.from_dict(data["transparency_result"])

        original_tier = None
        if "original_quality_tier" in data:
            original_tier = QualityTier(data["original_quality_tier"])

        return cls(
            # ... existing fields ...
            transparency_result=transparency_result,
            original_quality_tier=original_tier,
            transparency_adjusted=data.get("transparency_adjusted", False),
        )
```

## Integration Points

**Where tier adjustment is applied:**

1. **On-demand in UI**: When displaying document cards, call `get_adjusted_quality()`
2. **In filtering**: Call `should_filter_document()` before including in results
3. **In export/reports**: Use adjusted tiers for evidence synthesis

**Audit Trail:**

- `original_quality_tier` preserves the pre-adjustment tier
- `transparency_adjusted` flag indicates adjustment was applied
- `transparency_result` stored for full traceability

## Testing

Add to `tests/quality/test_quality_manager.py`:
- Test apply_transparency_adjustment with high risk result
- Test no adjustment for low/medium risk
- Test tier downgrade amount is respected
- Test minimum tier boundary (can't go below UNCLASSIFIED)
- Test filtering logic
- Test settings toggle disables adjustment

## Dependencies

- transparency_models.py (TransparencyResult, TransparencyRisk)
- transparency_settings.py (TransparencySettings)
- storage.py (get_transparency_result method from Step 01)

## Estimated Scope

- ~100 lines modifications to quality_manager.py
- ~30 lines modifications to data_models.py
- ~60 lines tests
