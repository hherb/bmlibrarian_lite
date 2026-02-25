# Study Transparency Analyzer

Automated detection of industry sponsorship, data disclosure practices, and conflict of interest in medical research publications. Part of [BMLibrarian Lite](https://github.com/hherb/bmlibrarian_lite).

## Features

- **Automatic full-text discovery** - Retrieves full text from Europe PMC, Unpaywall, PubMed Central, publisher sites, and cached files before analysis
- **Multi-source API analysis** - Queries PubMed, CrossRef, ClinicalTrials.gov, Europe PMC, and OpenAlex
- **Named pharma company detection** - 40+ pharmaceutical/biotech company names matched against COI statements
- **Institutional intermediary detection** - Identifies industry money routed through universities and hospitals
- **Effective refusal detection** - Classifies data sharing statements that amount to systematic denials
- **Multi-pass COI analysis** - 4-pass approach: pharma names > intermediary patterns > industry keywords > blanket denials
- **Transparency scoring** - 0-100 score with compound penalties for industry ties + restricted data
- **Risk indicators** - Automatically identifies risk of bias signals
- **Mobile/CI safe mode** - `use_browser_fallback=False` disables Playwright for headless environments
- **Batch processing** - Analyze multiple studies from CSV or text files
- **CLI and Python API** - Use from command line or integrate into your own code

## Quick Start

### Python API

```python
from study_transparency_analyzer import StudyTransparencyAnalyzer

# Full analysis — auto-discovers full text from all sources
analyzer = StudyTransparencyAnalyzer(email="your@email.com")
report = analyzer.analyze(doi="10.1056/NEJMoa2034577")

# Mobile/CI safe — no browser, but still tries API-based full-text sources
analyzer = StudyTransparencyAnalyzer(
    email="your@email.com",
    use_browser_fallback=False,
)
report = analyzer.analyze(doi="10.1056/NEJMoa2034577")

# Manual full-text override (skips auto-discovery)
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
# Full analysis with automatic full-text discovery
python study_transparency_analyzer.py --pmid 33301246 --email your@email.com

# Without browser fallback (safe for CI/mobile/headless)
python study_transparency_analyzer.py --pmid 33301246 --email your@email.com \
    --no-browser

# With manual full-text file (skips auto-discovery)
python study_transparency_analyzer.py --doi "10.1016/S0140-6736(25)01578-8" \
    --email your@email.com --fulltext article.txt --output json

# API metadata only (no full-text discovery)
python study_transparency_analyzer.py --pmid 33301246 --email your@email.com \
    --no-fulltext-discovery
```

### CLI Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--doi` | One of doi/pmid | Digital Object Identifier |
| `--pmid` | One of doi/pmid | PubMed ID |
| `--email` | Yes | Contact email (required by APIs) |
| `--api-key` | No | NCBI API key for higher rate limits |
| `--fulltext` | No | Path to full-text file (skips auto-discovery) |
| `--unpaywall-email` | No | Email for Unpaywall API (defaults to `--email`) |
| `--no-browser` | No | Disable Playwright browser fallback |
| `--no-fulltext-discovery` | No | Skip auto full-text discovery entirely |
| `--output` | No | `summary` (default), `text`, or `json` |
| `--output-file` | No | Write output to file |

## Full-Text Discovery Chain

When no `fulltext` is provided, the analyzer automatically tries these sources (in order):

| Priority | Source | Requires Browser |
|----------|--------|:---:|
| 1 | Cached markdown | No |
| 2 | Europe PMC XML (JATS → markdown) | No |
| 3 | Europe PMC PDF render | No |
| 4 | Cached PDF | No |
| 5 | Unpaywall / PMC / publisher HTTP | No |
| 6 | Playwright browser fallback | **Yes** |

Set `use_browser_fallback=False` (or `--no-browser`) to skip step 6 — all other sources still work. This is the recommended setting for mobile apps, CI pipelines, and headless servers.

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

## API Reference

See [DOCUMENTATION.md](DOCUMENTATION.md) for complete API reference, including all classes, enums, methods, batch processing, and extension points.

## License

GNU Affero General Public License v3.0 (AGPL-3.0)
