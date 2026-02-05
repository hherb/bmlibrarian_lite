# Step 01: Data Models & Storage

## Goal

Create data models for transparency results and extend storage to persist them.

## Files to Create

### `src/bmlibrarian_lite/transparency/transparency_models.py`

```python
"""Data models for transparency analysis results."""

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional
from datetime import datetime


class TransparencyRisk(Enum):
    """Risk level based on transparency analysis."""
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    UNKNOWN = "unknown"


@dataclass
class TransparencyResult:
    """Stores transparency analysis results for a document."""

    document_id: str
    transparency_score: int  # 0-100
    risk_level: TransparencyRisk

    # Specific indicators
    industry_funding_detected: bool = False
    industry_funding_confidence: float = 0.0
    data_availability_level: str = "unknown"  # full_open, on_request, restricted, not_available, not_stated
    coi_disclosed: bool = True
    trial_registered: bool = False
    trial_results_compliant: bool = False
    outcome_switching_detected: bool = False

    # Risk indicators list (human-readable)
    risk_indicators: list[str] = field(default_factory=list)

    # Tier adjustment applied
    tier_downgrade_applied: int = 0

    # Metadata
    analyzed_at: datetime = field(default_factory=datetime.now)
    analyzer_version: str = "1.0"

    # For future full-text enhancement
    full_text_analyzed: bool = False

    def to_dict(self) -> dict:
        """Serialize to dictionary for storage."""
        return {
            "document_id": self.document_id,
            "transparency_score": self.transparency_score,
            "risk_level": self.risk_level.value,
            "industry_funding_detected": self.industry_funding_detected,
            "industry_funding_confidence": self.industry_funding_confidence,
            "data_availability_level": self.data_availability_level,
            "coi_disclosed": self.coi_disclosed,
            "trial_registered": self.trial_registered,
            "trial_results_compliant": self.trial_results_compliant,
            "outcome_switching_detected": self.outcome_switching_detected,
            "risk_indicators": self.risk_indicators,
            "tier_downgrade_applied": self.tier_downgrade_applied,
            "analyzed_at": self.analyzed_at.isoformat(),
            "analyzer_version": self.analyzer_version,
            "full_text_analyzed": self.full_text_analyzed,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "TransparencyResult":
        """Deserialize from dictionary."""
        return cls(
            document_id=data["document_id"],
            transparency_score=data["transparency_score"],
            risk_level=TransparencyRisk(data["risk_level"]),
            industry_funding_detected=data.get("industry_funding_detected", False),
            industry_funding_confidence=data.get("industry_funding_confidence", 0.0),
            data_availability_level=data.get("data_availability_level", "unknown"),
            coi_disclosed=data.get("coi_disclosed", True),
            trial_registered=data.get("trial_registered", False),
            trial_results_compliant=data.get("trial_results_compliant", False),
            outcome_switching_detected=data.get("outcome_switching_detected", False),
            risk_indicators=data.get("risk_indicators", []),
            tier_downgrade_applied=data.get("tier_downgrade_applied", 0),
            analyzed_at=datetime.fromisoformat(data["analyzed_at"]),
            analyzer_version=data.get("analyzer_version", "1.0"),
            full_text_analyzed=data.get("full_text_analyzed", False),
        )


def calculate_risk_level(
    score: int,
    industry_funding: bool,
    data_availability: str,
    coi_disclosed: bool,
    settings: "TransparencySettings",  # Forward reference
) -> TransparencyRisk:
    """
    Determine risk level from transparency metrics.

    High Risk: score < threshold OR (industry + restricted data) OR missing COI
    Medium Risk: score 40-70 OR industry with disclosure
    Low Risk: score > 70, transparent
    """
    # High risk conditions
    if score < settings.score_threshold:
        return TransparencyRisk.HIGH

    if settings.industry_funding_triggers_downgrade:
        if industry_funding and data_availability in ("restricted", "not_available", "not_stated"):
            return TransparencyRisk.HIGH

    if settings.missing_coi_triggers_downgrade and not coi_disclosed:
        return TransparencyRisk.HIGH

    # Medium risk conditions
    if score <= 70:
        return TransparencyRisk.MEDIUM

    if industry_funding:
        return TransparencyRisk.MEDIUM

    return TransparencyRisk.LOW
```

### `src/bmlibrarian_lite/transparency/__init__.py`

```python
"""Transparency analysis integration for BMLibrarian Lite."""

from .transparency_models import (
    TransparencyResult,
    TransparencyRisk,
    calculate_risk_level,
)

__all__ = [
    "TransparencyResult",
    "TransparencyRisk",
    "calculate_risk_level",
]
```

## Files to Modify

### `src/bmlibrarian_lite/storage.py`

Add transparency results table and methods:

```python
# In _init_database(), add new table:
CREATE TABLE IF NOT EXISTS transparency_results (
    document_id TEXT PRIMARY KEY,
    transparency_score INTEGER NOT NULL,
    risk_level TEXT NOT NULL,
    industry_funding_detected INTEGER NOT NULL DEFAULT 0,
    industry_funding_confidence REAL DEFAULT 0.0,
    data_availability_level TEXT DEFAULT 'unknown',
    coi_disclosed INTEGER DEFAULT 1,
    trial_registered INTEGER DEFAULT 0,
    trial_results_compliant INTEGER DEFAULT 0,
    outcome_switching_detected INTEGER DEFAULT 0,
    risk_indicators TEXT,  -- JSON array
    tier_downgrade_applied INTEGER DEFAULT 0,
    analyzed_at TEXT NOT NULL,
    analyzer_version TEXT DEFAULT '1.0',
    full_text_analyzed INTEGER DEFAULT 0,
    FOREIGN KEY (document_id) REFERENCES documents(id)
);

# Add methods:
def save_transparency_result(self, result: TransparencyResult) -> None:
    """Save or update transparency analysis result."""

def get_transparency_result(self, document_id: str) -> Optional[TransparencyResult]:
    """Retrieve transparency result for a document."""

def get_transparency_results_batch(self, document_ids: list[str]) -> dict[str, TransparencyResult]:
    """Retrieve transparency results for multiple documents."""

def get_documents_pending_transparency(self, session_id: str) -> list[str]:
    """Get document IDs that haven't been analyzed for transparency."""
```

### `src/bmlibrarian_lite/quality/data_models.py`

Add transparency reference to QualityAssessment:

```python
@dataclass
class QualityAssessment:
    # ... existing fields ...

    # Transparency integration
    transparency_result: Optional["TransparencyResult"] = None
    original_quality_tier: Optional[QualityTier] = None  # Before transparency adjustment
    transparency_adjusted: bool = False
```

## Testing

Create `tests/test_transparency_models.py`:
- Test TransparencyResult serialization/deserialization
- Test calculate_risk_level with various inputs
- Test edge cases (missing data, boundary scores)

## Dependencies

None - uses only stdlib and existing project imports.

## Estimated Scope

- ~150 lines new code (models)
- ~100 lines storage modifications
- ~50 lines tests
