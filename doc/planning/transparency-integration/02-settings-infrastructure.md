# Step 02: Settings Infrastructure

## Goal

Create user-configurable transparency settings with sensible defaults.

## Files to Create

### `src/bmlibrarian_lite/transparency/transparency_settings.py`

```python
"""User-configurable transparency analysis settings."""

from dataclasses import dataclass, field
from typing import Optional
import json
from pathlib import Path


@dataclass
class TransparencySettings:
    """Configuration for transparency analysis and filtering."""

    # Master toggle
    enabled: bool = True
    filtering_enabled: bool = True  # Whether to filter out high-risk papers

    # Threshold settings
    score_threshold: int = 40  # Score below this = high risk
    tier_downgrade_amount: int = 1  # How many tiers to downgrade for high risk

    # Specific risk indicator toggles
    industry_funding_triggers_downgrade: bool = True  # Only with restricted data
    missing_coi_triggers_downgrade: bool = True
    missing_trial_results_triggers_downgrade: bool = False  # Off by default, strict

    # Analysis settings
    analyze_in_background: bool = True
    max_concurrent_analyses: int = 3  # Rate limiting for APIs
    cache_results: bool = True  # Reuse results for same PMID/DOI

    # Display settings
    show_badge_on_cards: bool = True
    show_detailed_tooltip: bool = True

    def to_dict(self) -> dict:
        """Serialize to dictionary."""
        return {
            "enabled": self.enabled,
            "filtering_enabled": self.filtering_enabled,
            "score_threshold": self.score_threshold,
            "tier_downgrade_amount": self.tier_downgrade_amount,
            "industry_funding_triggers_downgrade": self.industry_funding_triggers_downgrade,
            "missing_coi_triggers_downgrade": self.missing_coi_triggers_downgrade,
            "missing_trial_results_triggers_downgrade": self.missing_trial_results_triggers_downgrade,
            "analyze_in_background": self.analyze_in_background,
            "max_concurrent_analyses": self.max_concurrent_analyses,
            "cache_results": self.cache_results,
            "show_badge_on_cards": self.show_badge_on_cards,
            "show_detailed_tooltip": self.show_detailed_tooltip,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "TransparencySettings":
        """Deserialize from dictionary."""
        return cls(
            enabled=data.get("enabled", True),
            filtering_enabled=data.get("filtering_enabled", True),
            score_threshold=data.get("score_threshold", 40),
            tier_downgrade_amount=data.get("tier_downgrade_amount", 1),
            industry_funding_triggers_downgrade=data.get("industry_funding_triggers_downgrade", True),
            missing_coi_triggers_downgrade=data.get("missing_coi_triggers_downgrade", True),
            missing_trial_results_triggers_downgrade=data.get("missing_trial_results_triggers_downgrade", False),
            analyze_in_background=data.get("analyze_in_background", True),
            max_concurrent_analyses=data.get("max_concurrent_analyses", 3),
            cache_results=data.get("cache_results", True),
            show_badge_on_cards=data.get("show_badge_on_cards", True),
            show_detailed_tooltip=data.get("show_detailed_tooltip", True),
        )

    def validate(self) -> list[str]:
        """Validate settings, return list of errors."""
        errors = []
        if not 0 <= self.score_threshold <= 100:
            errors.append("score_threshold must be 0-100")
        if not 1 <= self.tier_downgrade_amount <= 4:
            errors.append("tier_downgrade_amount must be 1-4")
        if not 1 <= self.max_concurrent_analyses <= 10:
            errors.append("max_concurrent_analyses must be 1-10")
        return errors


def get_default_settings() -> TransparencySettings:
    """Return default transparency settings."""
    return TransparencySettings()
```

## Files to Modify

### `src/bmlibrarian_lite/config.py`

Add transparency settings to LiteConfig:

```python
# In LiteConfig class, add:

def __init__(self, ...):
    # ... existing init ...
    self._transparency_settings: Optional[TransparencySettings] = None

@property
def transparency_settings(self) -> TransparencySettings:
    """Get transparency settings, loading from disk if needed."""
    if self._transparency_settings is None:
        self._transparency_settings = self._load_transparency_settings()
    return self._transparency_settings

def _load_transparency_settings(self) -> TransparencySettings:
    """Load transparency settings from config file."""
    settings_path = self.config_dir / "transparency_settings.json"
    if settings_path.exists():
        try:
            with open(settings_path) as f:
                data = json.load(f)
            return TransparencySettings.from_dict(data)
        except (json.JSONDecodeError, KeyError) as e:
            logger.warning(f"Failed to load transparency settings: {e}")
    return get_default_settings()

def save_transparency_settings(self, settings: TransparencySettings) -> None:
    """Save transparency settings to config file."""
    errors = settings.validate()
    if errors:
        raise ValueError(f"Invalid settings: {errors}")

    settings_path = self.config_dir / "transparency_settings.json"
    with open(settings_path, "w") as f:
        json.dump(settings.to_dict(), f, indent=2)
    self._transparency_settings = settings
```

### `src/bmlibrarian_lite/transparency/__init__.py`

Update exports:

```python
from .transparency_models import (
    TransparencyResult,
    TransparencyRisk,
    calculate_risk_level,
)
from .transparency_settings import (
    TransparencySettings,
    get_default_settings,
)

__all__ = [
    "TransparencyResult",
    "TransparencyRisk",
    "calculate_risk_level",
    "TransparencySettings",
    "get_default_settings",
]
```

## Testing

Add to `tests/test_transparency_models.py`:
- Test TransparencySettings serialization/deserialization
- Test validation (boundary values)
- Test config integration (save/load cycle)

## Dependencies

None - uses only stdlib.

## Estimated Scope

- ~100 lines new code (settings)
- ~40 lines config modifications
- ~30 lines tests
