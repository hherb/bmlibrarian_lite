# Study Transparency Analysis

Medical Fact Checker automatically analyzes research papers for transparency indicators that may affect the reliability of their findings. This feature helps you evaluate the quality and potential biases in the evidence presented in your fact-check reports.

## How It Works

When you run a fact-check, the app follows these steps:

1. **Search** for relevant papers on PubMed and Europe PMC
2. **Score** each paper for relevance to your claim
3. **Extract citations** — key passages from high-scoring papers
4. **Analyze transparency** of all papers that meet the relevance threshold
5. **Generate report** incorporating transparency findings

Transparency analysis runs automatically after scoring. Each qualifying document is checked against multiple external data sources including CrossRef (funding metadata), ClinicalTrials.gov (trial registration), and PubMed (publication metadata). No additional configuration is needed beyond having an email address set in Settings.

## What Gets Analyzed

### Funding Disclosure

The system identifies who funded the research:

- **Sponsor type**: Public/government, academic, industry, non-profit, mixed, or unknown
- **Industry funding detection**: Flags studies with pharmaceutical or medical device industry sponsorship
- **Funder list**: Names of all identified funding organizations
- **Confidence level**: How certain the system is about industry involvement

Studies with industry funding are not automatically discounted, but the system flags them so you can consider potential conflicts when evaluating the evidence.

### Conflicts of Interest

The analysis looks for:

- **COI statements**: Whether authors declared any conflicts
- **Industry ties**: Disclosed relationships with commercial entities (consulting, advisory, speaking fees, stock ownership)
- **Missing declarations**: When no COI statement is found at all, which itself is a transparency concern

### Data Availability

Checks whether the underlying research data is accessible:

| Level | Meaning |
|-------|---------|
| Full Open | Data publicly available in a repository |
| Available on Request | Authors will share data if asked |
| Restricted | Data available under specific conditions |
| Not Available | Authors explicitly state data is not available |
| Not Stated | No data availability statement found |

Studies that share their data openly score higher on transparency because their results can be independently verified.

### Trial Registration

For clinical studies, the system checks:

- **Registration IDs**: Links to ClinicalTrials.gov (NCT numbers) or other registries
- **Results posting**: Whether results have been uploaded to the registry
- **Compliance status**: Whether the study meets reporting requirements
- **Outcome switching**: Detects when primary outcomes in the publication differ from those registered in the trial protocol, which can indicate selective reporting

## Understanding the Results

### Transparency Score

Each analyzed document receives a score from 0 to 100:

| Range | Risk Level | Meaning |
|-------|-----------|---------|
| 70-100 | Low | Good transparency practices |
| 40-69 | Medium | Some transparency gaps |
| 0-39 | High | Significant transparency concerns |

The score considers all factors: funding disclosure, COI statements, data availability, and trial registration compliance. A low score does not mean the research is wrong, but it means there is less transparency about potential biases.

### Risk Badges

In the report, each document card shows a small colored badge next to the relevance score:

- **Green shield** (Low): Good transparency
- **Orange triangle** (Med): Moderate concerns
- **Red shield** (High): Significant concerns
- **Gray circle** (?): Could not be assessed

Tap a document to see the full transparency breakdown.

### Report Summary

When transparency analysis has been performed, the report includes a summary section showing:

- **Average transparency score** across all analyzed documents
- **Industry funding percentage**: How many of the reviewed studies have industry sponsorship
- **Number analyzed**: How many documents were assessed
- **Risk distribution**: Count of low, medium, and high risk documents
- **Warning banner**: Appears if any documents are flagged as high risk

## On-Demand Analysis

Documents that were not automatically analyzed (for example, those below the relevance score threshold) can still be analyzed manually:

1. Open the report
2. Tap on a document to view its details
3. Scroll to the "Transparency Analysis" section
4. Tap "Analyze Transparency"

The analysis typically takes a few seconds per document as it queries multiple external APIs.

## Impact on Reports

Transparency findings influence the fact-check report in several ways:

- **Risk warnings** appear when high-risk documents are among the evidence
- **Industry-funded studies** are flagged so their conclusions can be weighed appropriately
- **PDF exports** include transparency summaries and per-document risk labels
- Documents with high transparency risk cannot be weighted as strong evidence

The transparency analysis adds context to help you make informed judgments about the reliability of the evidence. It does not suppress or hide any research findings.

## Data Sources

The transparency analysis draws on these external services:

| Source | What It Provides |
|--------|-----------------|
| CrossRef | Funder information, license type, publisher metadata |
| ClinicalTrials.gov | Trial registration, results posting, outcome data |
| PubMed | Publication metadata, MeSH terms, grant information |
| Europe PMC | Full-text content for COI and data availability extraction |

All queries respect API rate limits. If a particular data source is temporarily unavailable, the analysis continues with whatever information is available, and a warning is included in the results.

## Settings

No special configuration is required for transparency analysis. The system uses the same NCBI email and API key configured in Settings for PubMed access. Setting an email address is recommended as it improves API rate limits for all external services.

## Limitations

- Transparency analysis depends on the availability and accuracy of metadata from external sources. Not all journals deposit complete funding information with CrossRef.
- COI and data availability extraction works best when full text is available. Abstract-only analysis has reduced accuracy.
- The system analyzes what is disclosed, not what is true. A study may have undisclosed conflicts that cannot be detected.
- Trial registration checks are limited to ClinicalTrials.gov. Studies registered in other registries (ISRCTN, EU Clinical Trials Register, etc.) may not be fully recognized.
- The transparency score is an automated assessment. It should inform your evaluation but not replace critical reading of the research.
