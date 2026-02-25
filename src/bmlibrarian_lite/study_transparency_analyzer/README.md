# Study Transparency Analyzer

Automated detection of industry sponsorship, data disclosure practices, and conflict of interest in medical research publications. Part of [BMLibrarian Lite](https://github.com/hherb/bmlibrarian_lite).

## Features

- **Multi-source API analysis** - Queries PubMed, CrossRef, ClinicalTrials.gov, Europe PMC, and OpenAlex
- **Named pharma company detection** - 40+ pharmaceutical/biotech company names matched against COI statements
- **Institutional intermediary detection** - Identifies industry money routed through universities and hospitals
- **Effective refusal detection** - Classifies data sharing statements that amount to systematic denials
- **Full-text analysis** - Extracts and analyzes COI, data sharing, funding, and acknowledgment sections from article text
- **Multi-pass COI analysis** - 4-pass approach: pharma names > intermediary patterns > industry keywords > blanket denials
- **Transparency scoring** - 0-100 score with compound penalties for industry ties + restricted data
- **Risk indicators** - Automatically identifies risk of bias signals
- **Batch processing** - Analyze multiple studies from CSV or text files
- **CLI and Python API** - Use from command line or integrate into your own code

## Quick Start

### Python API

```python
from study_transparency_analyzer import StudyTransparencyAnalyzer

analyzer = StudyTransparencyAnalyzer(email="your@email.com")

# Basic analysis (API metadata only)
report = analyzer.analyze(doi="10.1056/NEJMoa2034577")

# Deep analysis with full-text content
with open("article.txt") as f:
    fulltext = f.read()
report = analyzer.analyze(doi="10.1056/NEJMoa2034577", fulltext=fulltext)

print(f"Score: {report.transparency_score}/100")
print(f"Industry ties: {report.coi_info.has_industry_ties}")
print(f"Data level: {report.data_availability.disclosure_level.value}")
print(f"Risk indicators: {report.risk_of_bias_indicators}")
```

### Command Line

```bash
# Basic analysis
python study_transparency_analyzer.py --pmid 33301246 --email your@email.com

# With full-text for deeper analysis
python study_transparency_analyzer.py --doi "10.1016/S0140-6736(25)01578-8" \
    --email your@email.com --fulltext article.txt --output json
```

### CLI Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--doi` | One of doi/pmid | Digital Object Identifier |
| `--pmid` | One of doi/pmid | PubMed ID |
| `--email` | Yes | Contact email (required by APIs) |
| `--api-key` | No | NCBI API key for higher rate limits |
| `--fulltext` | No | Path to full-text file (plain text or markdown) |
| `--output` | No | `summary` (default), `text`, or `json` |
| `--output-file` | No | Write output to file |

## How It Works

### Detection Layers

1. **CrossRef Funder DOIs** (confidence: 1.0) - Authoritative industry funder identification
2. **ClinicalTrials.gov sponsor class** (confidence: 0.95) - FDA-regulated classification
3. **Named pharma companies** (confidence: 0.70-0.98) - Direct regex matching of 40+ company names in COI text
4. **Institutional intermediaries** (confidence: 0.80-0.98) - "Funding to [university] from [pharma]" patterns
5. **Generic industry keywords** (confidence: 0.50-0.90) - "Grants from", "honoraria", "advisory board"

### COI Analysis (4-Pass)

| Pass | Signal | Logic |
|------|--------|-------|
| 1 | Named pharma companies | Scan for Pfizer, AstraZeneca, Novartis, etc. |
| 2 | Institutional intermediaries | Detect "funding to institution from [pharma]" |
| 3 | Generic industry keywords | "Grants from", "consultant for", etc. |
| 4 | "No conflict" declarations | Only trusted if < 500 chars AND no pharma names |

### Data Availability Classification

| Level | Description |
|-------|-------------|
| `FULL_OPEN` | Data in public repository (Zenodo, GEO, etc.) |
| `NOT_AVAILABLE` | Effective refusal: sponsor confidentiality, not released |
| `RESTRICTED` | IRB, ethics committee, or conditional access |
| `AVAILABLE_ON_REQUEST` | "Upon reasonable request" without restriction signals |
| `NOT_STATED` | No data availability section found |

### Transparency Score (0-100)

Base score of 50, modified by:
- Data availability: +20 (open) to -15 (unavailable)
- COI disclosure: +5 (statement present) to -5 (missing/industry ties)
- Trial registration: +10 (registered) to -10 (results missing)
- Compound penalty: -10 for industry ties + restricted/unavailable data
- Outcome switching: -15

## Full-Text Analysis

When full-text content is provided, the analyzer extracts sections using standard biomedical headers:

- **COI/Disclosures** - Complete conflict of interest statements
- **Data Sharing** - Data availability policies
- **Funding** - Funding sources and grant details
- **Funding Role** - What role the funder played in the study
- **Acknowledgments** - Additional industry relationships
- **Contributors** - Author roles and contributions

Full-text sections take priority over API metadata, which is often truncated or incomplete.

## Key Constants

### `KNOWN_PHARMA_NAMES`

40+ pharmaceutical/biotech company name patterns including Pfizer, AstraZeneca, Novartis, Roche, Sanofi, Merck, Gilead, AbbVie, Amgen, Bristol-Myers Squibb, and more. These are matched case-insensitively against COI text.

### `INSTITUTIONAL_INTERMEDIARY_PATTERNS`

Patterns detecting industry funding routed through academic institutions:
- "Funding/grants to [institution] from [company]"
- "No personal funding" disclaimers alongside pharma names
- "Grants to his/her/their institution"

### `DATA_REPOSITORIES['effectively_unavailable']`

Patterns for data sharing statements that constitute effective refusals:
- Data restricted to named collaboration
- Sponsor confidentiality agreements
- Systematic gatekeeping with data custodians

## API Reference

See [DOCUMENTATION.md](DOCUMENTATION.md) for complete API reference, including all classes, enums, methods, batch processing, and extension points.

## License

GNU Affero General Public License v3.0 (AGPL-3.0)
