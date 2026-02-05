# Report Risk Warnings Design

**Date:** 2026-02-06
**Status:** Approved
**Feature:** Surface transparency/risk concerns for citations in generated reports

## Overview

Enhance the report generator to explicitly mention risk factors when citing high-risk studies (industry funding, undisclosed COI, missing trial results, etc.).

### Goals
- Inline warnings in narrative text give readers immediate context
- Annotated references provide full risk details
- Configurable threshold lets users choose sensitivity
- LLM-aware generation produces balanced assessments

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Report Generation                         │
├─────────────────────────────────────────────────────────────┤
│  1. Gather citations + transparency results (existing)       │
│                          ↓                                   │
│  2. Identify high-risk citations based on threshold setting  │
│                          ↓                                   │
│  3. Build LLM prompt with risk context for awareness         │
│                          ↓                                   │
│  4. LLM generates narrative (can mention concerns naturally) │
│                          ↓                                   │
│  5. Post-process: inject inline warning markers at citations │
│                          ↓                                   │
│  6. Generate annotated references with risk sub-items        │
│                          ↓                                   │
│  7. Final report with inline flags + detailed references     │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

New settings in `TransparencySettings`:

```python
# Risk threshold for report warnings
report_risk_threshold: RiskLevel = RiskLevel.HIGH  # HIGH, MEDIUM, or LOW

# Inline warning text (short, for narrative)
inline_warning_templates: dict = {
    "industry_funding": "⚠️ funding concerns",
    "missing_coi": "⚠️ COI not disclosed",
    "missing_results": "⚠️ results not posted",
    "data_not_available": "⚠️ data not shared",
    "multiple_risks": "⚠️ transparency concerns",  # when >1 risk factor
}
```

**Behavior:**
- When a citation meets or exceeds the threshold, it gets flagged
- If a study has multiple risk factors, use generic "transparency concerns" inline
- Users can adjust threshold via settings UI or config file

## LLM Prompt Enhancement

Add risk context section to prompt:

```
Here are passages with citations...

## Studies with Transparency Concerns
The following cited studies have elevated risk factors that readers should be aware of:
- [Citation 3] Smith et al.: Industry-funded by Pfizer, results not posted to registry
- [Citation 7] Jones et al.: Conflicts of interest not disclosed

When discussing findings from these studies, consider their limitations in context.
Do not add warning markers yourself - these will be added automatically.

Generate a flowing narrative...
```

**Rationale:**
- LLM can write balanced assessments acknowledging limitations
- Won't over-rely on high-risk studies for key conclusions
- Explicit instruction prevents duplication with post-processing

## Post-Processing Injection

```python
def inject_risk_warnings(narrative: str, risky_citations: dict[int, TransparencyResult]) -> str:
    """
    Scan narrative for citation markers [N] and append inline warning if citation is risky.

    Example: "[3]" becomes "[3] (⚠️ funding concerns)" if citation 3 is high-risk
    """
    for citation_num, transparency_result in risky_citations.items():
        pattern = f"[{citation_num}]"
        warning = _select_inline_warning(transparency_result)
        replacement = f"[{citation_num}] ({warning})"
        # Only inject on first occurrence to avoid cluttering repeated citations
        narrative = narrative.replace(pattern, replacement, 1)
    return narrative
```

**Warning selection priority:**
1. Multiple risk factors → "⚠️ transparency concerns"
2. Single factor → specific template (funding/COI/results/data)

**First occurrence only** - repeated citations not re-warned to keep text readable.

## Annotated References Format

**Current format:**
```
## References

[1] Smith J, et al. (2024) "Study Title." NEJM. PMID: 12345678
[2] Jones A, et al. (2023) "Another Study." Lancet. DOI: 10.1016/xxx
```

**Enhanced format for risky citations:**
```
## References

[1] Smith J, et al. (2024) "Study Title." NEJM. PMID: 12345678
    ⚠️ HIGH RISK
    • Funding: Pfizer (pharmaceutical industry)
    • Trial results: Not posted to ClinicalTrials.gov
    • COI disclosure: Not stated

[2] Jones A, et al. (2023) "Another Study." Lancet. DOI: 10.1016/xxx

[3] Brown B, et al. (2024) "Third Study." BMJ. PMID: 87654321
    ⚠️ MEDIUM RISK
    • Funding: Industry-funded (AstraZeneca)
```

**Details shown (only non-passing factors):**
- Risk level (HIGH/MEDIUM)
- Funding source and sponsor type
- Trial registration & results posting status
- COI disclosure status
- Data sharing status

## Implementation Scope

### Files to Modify

1. **`transparency/transparency_settings.py`**
   - Add `report_risk_threshold: RiskLevel` setting
   - Add `inline_warning_templates: dict` setting

2. **`agents/reporting_agent.py`**
   - Fetch transparency results for cited documents
   - Filter by threshold to identify risky citations
   - Build risk context section for LLM prompt
   - Post-process narrative to inject inline warnings
   - Generate annotated references with risk sub-items

3. **`data_models.py`** (if needed)
   - Helper for mapping citation numbers to transparency results

### No Changes Needed
- Transparency analyzer (already produces all needed data)
- Quality manager (integration already exists)
- Storage layer (transparency results already persisted)
- GUI (report display handles markdown already)

### Estimated Scope
~150-200 lines of new/modified code, concentrated in `reporting_agent.py`
