# Transparency Analyzer Integration - Implementation Plan

## Overview

Integrate the study transparency analyzer into BMLibrarian Lite with:
- Transparency risk badge on document cards
- Transparency score factored into paper quality tier weighting
- Optional automatic filtering (default: on)
- Background batch processing (non-blocking UI)

## Design Decisions

| Decision | Choice |
|----------|--------|
| Analysis timing | Background batch processing after search |
| Badge display | Risk indicator (Low/Medium/High Risk) |
| Quality integration | Tier adjustment (configurable downgrade factor, default 1) |
| Filtering | Optional, default on |
| Thresholds | Hybrid: score-based + specific risk indicators |
| Full-text | Metadata-only now, architected for future enhancement |

## Default Transparency Rules

**High Risk** (tier downgrade applies):
- Score < 40, OR
- Industry funding + restricted/no data access, OR
- Undisclosed conflicts of interest

**Medium Risk** (warning badge, no penalty):
- Score 40-70, OR
- Industry funding with full disclosure

**Low Risk** (no penalty):
- Score > 70
- Transparent funding
- Open data access

## User-Configurable Settings

- `transparency_filtering_enabled`: bool (default: True)
- `transparency_score_threshold`: int 0-100 (default: 40)
- `tier_downgrade_amount`: int 1-4 (default: 1)
- `industry_funding_triggers_downgrade`: bool (default: True, only when combined with restricted data)
- `missing_coi_triggers_downgrade`: bool (default: True)

## Implementation Steps

See individual step files (01-*.md through 08-*.md) for detailed implementation.

| Step | Description | Files |
|------|-------------|-------|
| 01 | Data models & storage | transparency_models.py, storage.py, data_models.py |
| 02 | Settings infrastructure | transparency_settings.py, config.py |
| 03 | Transparency manager | transparency_manager.py |
| 04 | Risk badge widget | transparency_badge.py, constants.py |
| 05 | Document card integration | document_card.py |
| 06 | Quality tier adjustment | quality_manager.py |
| 07 | Filter panel & settings UI | quality_filter_panel.py, transparency_settings_panel.py |
| 08 | Workflow integration | systematic_review_tab.py, audit_literature_tab.py |

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     Systematic Review Workflow                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Search Complete → Queue papers for transparency analysis        │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  TransparencyManager (background thread)                         │
│  ├─ StudyTransparencyAnalyzer.analyze(pmid/doi)                 │
│  ├─ Store TransparencyResult in SQLite                          │
│  └─ Emit transparency_updated signal                            │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
┌──────────────────────────┐  ┌──────────────────────────────────┐
│  QualityManager          │  │  Document Card UI                 │
│  ├─ Get transparency     │  │  ├─ Add TransparencyBadge        │
│  ├─ Apply tier downgrade │  │  ├─ Show risk level + tooltip    │
│  └─ Update quality_tier  │  │  └─ Update on signal             │
└──────────────────────────┘  └──────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────┐
│  Filtering (optional)    │
│  ├─ Exclude high-risk    │
│  └─ User toggle in UI    │
└──────────────────────────┘
```

## Future Enhancement: Full-Text Analysis

The architecture supports future full-text enhancement:
- `TransparencyManager.analyze()` accepts optional `full_text: str` parameter
- When full-text available, pass to enhanced analyzer
- Additional signals extracted: detailed COI statements, data availability sections
- No changes to storage, models, or UI required

## Estimated Total Scope

| Step | New Code | Modifications | Tests |
|------|----------|---------------|-------|
| 01 - Data models & storage | ~150 lines | ~100 lines | ~50 lines |
| 02 - Settings infrastructure | ~100 lines | ~40 lines | ~30 lines |
| 03 - Transparency manager | ~200 lines | - | ~50 lines |
| 04 - Risk badge widget | ~200 lines | ~5 lines | ~40 lines |
| 05 - Document card integration | - | ~50 lines | ~30 lines |
| 06 - Quality tier adjustment | - | ~130 lines | ~60 lines |
| 07 - Filter panel & settings UI | ~180 lines | ~80 lines | ~40 lines |
| 08 - Workflow integration | - | ~160 lines | ~80 lines |
| **Total** | **~830 lines** | **~565 lines** | **~380 lines** |

## Implementation Order

Steps should be implemented in order (01 → 08) as each builds on previous:

1. **01-02**: Foundation (models, storage, settings) - no UI changes yet
2. **03-04**: Core components (manager, badge widget) - can be unit tested
3. **05-06**: Integration (card, quality) - visual changes appear
4. **07-08**: Full integration (settings UI, workflow) - feature complete

Each step is designed to fit within a single context window and can be implemented independently with clear inputs/outputs.
