# Study Transparency Analyzer

## Comprehensive Tool for Detecting Industry Sponsorship and Data Disclosure in Medical Research

---

## Table of Contents

1. [Overview](#overview)
2. [Installation](#installation)
3. [Quick Start](#quick-start)
4. [Data Sources & APIs](#data-sources--apis)
5. [Detection Methods](#detection-methods)
6. [API Reference](#api-reference)
7. [Command Line Interface](#command-line-interface)
8. [Batch Processing](#batch-processing)
9. [Interpreting Results](#interpreting-results)
10. [Limitations & Caveats](#limitations--caveats)
11. [Extending the Tool](#extending-the-tool)
12. [References & Further Reading](#references--further-reading)

---

## Overview

The Study Transparency Analyzer is a Python tool designed to automate the detection of:

1. **Industry sponsorship** in medical research publications
2. **Data disclosure levels** (full open, restricted, or withheld)
3. **Clinical trial registration compliance**
4. **Conflict of interest disclosures**
5. **Potential outcome switching** (registered vs. reported outcomes)

### Why This Matters

Research has consistently shown that industry-sponsored studies are more likely to report favorable outcomes for the sponsor's products. Understanding the funding source and data availability is crucial for:

- Evidence-based medicine practitioners
- Systematic review authors
- Journal editors and peer reviewers
- Healthcare policy makers
- Research integrity investigators

### What This Tool Does

Given a **DOI** or **PubMed ID (PMID)**, the analyzer:

1. Queries multiple databases (PubMed, CrossRef, ClinicalTrials.gov, Europe PMC, OpenAlex)
2. Extracts funding/sponsor information
3. Classifies sponsors as industry vs. government/academic
4. Analyzes conflict of interest statements
5. Checks data availability statements
6. Verifies clinical trial registration and results posting compliance
7. Calculates an overall transparency score
8. Identifies risk of bias indicators

---

## Installation

### Requirements

- Python 3.8+
- Internet connection (for API access)
- Valid email address (required by NCBI/CrossRef APIs)

### Setup

```bash
# Clone or download the tool
cd study_transparency_analyzer

# Create virtual environment (recommended)
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

### Optional: NCBI API Key

For higher rate limits with PubMed (10 requests/sec vs 3 requests/sec), obtain a free API key:

1. Register at https://www.ncbi.nlm.nih.gov/account/
2. Go to Settings → API Key Management
3. Generate a new key

---

## Quick Start

### Single Study Analysis (Python)

```python
from study_transparency_analyzer import StudyTransparencyAnalyzer

# Initialize with your email
analyzer = StudyTransparencyAnalyzer(
    email="your.email@example.com",
    pubmed_api_key="optional_api_key"  # Optional
)

# Analyze by DOI
report = analyzer.analyze(doi="10.1056/NEJMoa2034577")

# Or by PMID
report = analyzer.analyze(pmid="33301246")

# Access results
print(f"Title: {report.title}")
print(f"Sponsor Type: {report.sponsor_type.value}")
print(f"Industry Funded: {report.industry_funding_detected}")
print(f"Transparency Score: {report.transparency_score}/100")
print(f"Risk Indicators: {report.risk_of_bias_indicators}")

# Export to JSON
import json
print(json.dumps(report.to_dict(), indent=2))
```

### Command Line Usage

```bash
# Basic analysis
python study_transparency_analyzer.py --pmid 33301246 --email your@email.com

# With JSON output
python study_transparency_analyzer.py --doi "10.1056/NEJMoa2034577" \
    --email your@email.com --output json

# Save to file
python study_transparency_analyzer.py --pmid 33301246 --email your@email.com \
    --output json --output-file report.json
```

---

## Data Sources & APIs

The tool chains multiple APIs to gather comprehensive information:

### 1. PubMed / NCBI E-utilities

**What it provides:**
- Basic article metadata (title, authors, journal, dates)
- Grant/funding information from MEDLINE
- Conflict of interest statements
- Links to trial registrations (DataBank field)
- Publication types and MeSH terms

**API Documentation:** https://www.ncbi.nlm.nih.gov/books/NBK25500/

**Rate Limits:**
- Without API key: 3 requests/second
- With API key: 10 requests/second

### 2. CrossRef

**What it provides:**
- Standardized funder information via the Funder Registry
- Funder DOIs (enabling precise industry classification)
- Award/grant numbers
- License information

**API Documentation:** https://api.crossref.org/swagger-ui/index.html

**Key Feature:** CrossRef's Funder Registry assigns DOIs to funding organizations, making it possible to reliably identify industry funders (e.g., `10.13039/100004319` = Pfizer).

### 3. ClinicalTrials.gov (API v2)

**What it provides:**
- Trial sponsor classification (INDUSTRY, NIH, OTHER, etc.)
- Whether results have been posted
- Registered primary/secondary outcomes
- Trial completion dates (for compliance checking)

**API Documentation:** https://clinicaltrials.gov/data-api/api

**Key Feature:** The `class` field in sponsor information directly indicates if a trial is industry-sponsored.

### 4. Europe PMC

**What it provides:**
- Enhanced funding data
- Full-text access for open access articles
- Data availability statements (from full text)
- Better structured metadata than PubMed for some fields

**API Documentation:** https://europepmc.org/RestfulWebService

### 5. OpenAlex

**What it provides:**
- Aggregated scholarly metadata
- Alternative funder information
- Open access status
- Citation data

**API Documentation:** https://docs.openalex.org/

---

## Detection Methods

### Industry Sponsorship Detection

The tool uses a multi-layered approach:

#### Layer 1: CrossRef Funder Registry DOIs

```python
KNOWN_INDUSTRY_FUNDER_DOIS = {
    "10.13039/100004319": "Pfizer",
    "10.13039/100004325": "AstraZeneca",
    "10.13039/100004334": "Merck",
    # ... 25+ major pharmaceutical companies
}
```

**Confidence Level:** HIGH (1.0) - Funder DOIs are authoritative

#### Layer 2: ClinicalTrials.gov Sponsor Class

```python
if trial_info.sponsor_class == 'INDUSTRY':
    report.industry_funding_detected = True
```

**Confidence Level:** HIGH (0.95) - Official FDA-regulated classification

#### Layer 3: Name Pattern Matching

When DOIs aren't available, the tool uses regex patterns:

```python
INDUSTRY_KEYWORDS = [
    r'\bpharma(?:ceutical)?\b',
    r'\bbiotech(?:nology)?\b',
    r'\binc\.?\b',
    r'\bcorp(?:oration)?\.?\b',
    # ...
]

GOVERNMENT_PATTERNS = [
    r'\bnih\b',
    r'\bnational institutes? of health\b',
    r'\buniversit(?:y|ies)\b',
    # ...
]
```

**Confidence Level:** MEDIUM (0.5-0.8) - Heuristic-based

#### Layer 4: COI Statement Analysis

```python
# Patterns indicating industry ties in COI statements
r'(?:received|reports?) (?:grants?|funding|honoraria) from'
r'(?:consultant|advisory board|speaker) for'
r'employee of'
r'(?:stock|shares?|equity) in'
```

**Confidence Level:** MEDIUM (0.6-0.9) - Dependent on disclosure quality

### Data Disclosure Level Detection

The tool classifies data availability into five levels:

| Level | Description | Detection Method |
|-------|-------------|------------------|
| `FULL_OPEN` | Data in public repository | Repository name detected (Zenodo, Figshare, GEO, etc.) |
| `AVAILABLE_ON_REQUEST` | Available upon request | Phrases like "available upon reasonable request" |
| `RESTRICTED` | Significant restrictions | IRB, ethics, confidentiality mentioned |
| `NOT_AVAILABLE` | Explicitly not shared | "cannot be shared", "proprietary" |
| `NOT_STATED` | No statement found | No data availability section detected |

### Trial Results Compliance

For studies linked to ClinicalTrials.gov:

```python
def check_results_compliance(trial, publication_date):
    # FDAAA 2007 requires results within 12 months of completion
    if trial.results_posted:
        return ResultsComplianceStatus.COMPLIANT

    if trial.completion_date:
        deadline = trial.completion_date + timedelta(days=365)
        if datetime.now() > deadline:
            return ResultsComplianceStatus.MISSING

    return ResultsComplianceStatus.UNKNOWN
```

---

## API Reference

### TransparencyReport

The main output class containing all analysis results:

```python
@dataclass
class TransparencyReport:
    # Identifiers
    doi: Optional[str]
    pmid: Optional[str]
    pmcid: Optional[str]
    title: Optional[str]

    # Publication info
    journal: Optional[str]
    publication_date: Optional[datetime]
    authors: List[str]

    # Sponsorship analysis
    sponsor_type: SponsorType  # INDUSTRY, GOVERNMENT, ACADEMIC, MIXED, UNKNOWN
    funders: List[FunderInfo]
    industry_funding_detected: bool
    industry_funding_confidence: float  # 0.0 to 1.0

    # Trial registration
    trial_registrations: List[TrialRegistration]
    results_compliance: ResultsComplianceStatus

    # Conflicts of interest
    coi_info: Optional[ConflictOfInterest]

    # Data availability
    data_availability: Optional[DataAvailabilityInfo]

    # Scores and indicators
    transparency_score: float  # 0-100
    risk_of_bias_indicators: List[str]

    # Metadata
    analysis_timestamp: datetime
    data_sources_used: List[str]
    warnings: List[str]
    errors: List[str]
```

### SponsorType Enum

```python
class SponsorType(Enum):
    INDUSTRY = "industry"      # Pharmaceutical/device company
    GOVERNMENT = "government"  # NIH, CDC, VA, etc.
    ACADEMIC = "academic"      # University, hospital
    NONPROFIT = "nonprofit"    # Foundation, charity
    MIXED = "mixed"            # Multiple sponsor types
    UNKNOWN = "unknown"        # Could not determine
```

### DataDisclosureLevel Enum

```python
class DataDisclosureLevel(Enum):
    FULL_OPEN = "full_open"              # Data in public repository
    AVAILABLE_ON_REQUEST = "on_request"   # Available upon request
    RESTRICTED = "restricted"             # Significant restrictions
    NOT_AVAILABLE = "not_available"       # Explicitly not shared
    NOT_STATED = "not_stated"             # No statement
    UNKNOWN = "unknown"
```

### Key Methods

```python
class StudyTransparencyAnalyzer:
    def __init__(self, email: str, pubmed_api_key: Optional[str] = None):
        """Initialize with API credentials."""

    def analyze(self, doi: str = None, pmid: str = None) -> TransparencyReport:
        """
        Main analysis method.

        Args:
            doi: Digital Object Identifier
            pmid: PubMed ID

        Returns:
            TransparencyReport with all analysis results
        """
```

---

## Command Line Interface

### Single Study Analysis

```bash
# Basic usage
python study_transparency_analyzer.py --pmid 33301246 --email you@email.com

# By DOI
python study_transparency_analyzer.py --doi "10.1056/NEJMoa2034577" --email you@email.com

# Output formats
python study_transparency_analyzer.py --pmid 33301246 --email you@email.com \
    --output summary   # Human-readable summary (default)
    --output text      # Detailed text report
    --output json      # JSON for programmatic use

# Save to file
python study_transparency_analyzer.py --pmid 33301246 --email you@email.com \
    --output json --output-file analysis.json

# With NCBI API key (faster)
python study_transparency_analyzer.py --pmid 33301246 --email you@email.com \
    --api-key YOUR_NCBI_API_KEY
```

### Example Output

```
============================================================
STUDY TRANSPARENCY ANALYSIS
============================================================
Title: Safety and Efficacy of the BNT162b2 mRNA Covid-19 Vaccine
DOI: 10.1056/NEJMoa2034577
PMID: 33301246

TRANSPARENCY SCORE: 65/100

KEY FINDINGS:
  • Sponsor Type: INDUSTRY
  • Industry Funding: YES (confidence: 100%)
  • Data Availability: Available on Request
  • Trial Registration: YES (1 found)
  • Results Compliance: COMPLIANT
  • COI Disclosed: YES

⚠️  RISK INDICATORS:
  • Industry funding detected
  • Authors have industry financial ties

WARNINGS:
  • Industry funding detected but data not fully open

Data sources: PubMed, CrossRef, ClinicalTrials.gov
============================================================
```

---

## Batch Processing

For analyzing multiple studies:

### Input File Formats

**CSV Format:**
```csv
doi,pmid,title
10.1056/NEJMoa2034577,33301246,BNT162b2 Vaccine Study
10.1016/S0140-6736(20)32661-1,33306989,ChAdOx1 Vaccine Study
```

**Text Format (one ID per line):**
```
33301246
10.1056/NEJMoa2034577
33306989
# Comments are ignored
```

### Running Batch Analysis

```bash
# From CSV
python batch_analyzer.py studies.csv --email you@email.com \
    --output-csv results.csv --output-json results.json

# From text file
python batch_analyzer.py study_ids.txt --email you@email.com \
    --output-csv results.csv

# With custom column names
python batch_analyzer.py studies.csv --email you@email.com \
    --doi-column "DOI" --pmid-column "PubMed_ID"

# Adjust rate limiting
python batch_analyzer.py studies.csv --email you@email.com \
    --delay 2.0  # 2 seconds between studies

# Parallel processing (use with caution)
python batch_analyzer.py studies.csv --email you@email.com \
    --parallel --max-workers 3
```

### Batch Output Example

```
======================================================================
BATCH ANALYSIS SUMMARY
======================================================================

Total studies analyzed: 50
Successful: 47
Failed: 3

AGGREGATE FINDINGS:
----------------------------------------
Industry-funded studies: 23 (48.9%)

Data Availability Breakdown:
  • Full open access: 8 (17.0%)
  • Restricted/Not available: 19 (40.4%)
  • No statement: 20 (42.6%)

Missing trial results (ClinicalTrials.gov): 5

Average Transparency Score: 52.3/100

Transparency Score Distribution:
  • 0-25 (Poor): 5
  • 26-50 (Below Average): 18
  • 51-75 (Average): 19
  • 76-100 (Good): 5

Most Common Risk Indicators:
  • Industry funding detected: 23
  • Authors have industry financial ties: 18
  • No conflict of interest statement found: 12
  • Industry-funded with restricted data access: 11
======================================================================
```

---

## Interpreting Results

### Transparency Score

The transparency score (0-100) is calculated based on:

| Factor | Points |
|--------|--------|
| **Data Availability** | |
| Full open access | +20 |
| Available on request | +10 |
| Restricted | 0 |
| Not available | -10 |
| No statement | -5 |
| **COI Disclosure** | |
| Has COI statement | +10 |
| No COI statement | -5 |
| **Trial Registration** | |
| Has registration | +10 |
| Results posted | +5 |
| Results missing | -10 |
| **Penalties** | |
| Outcome switching detected | -15 |
| Industry + no data sharing | -10 |

**Interpretation:**
- **76-100**: Good transparency
- **51-75**: Average transparency
- **26-50**: Below average transparency
- **0-25**: Poor transparency

### Risk of Bias Indicators

Common indicators and their implications:

| Indicator | Implication |
|-----------|-------------|
| "Industry funding detected" | Potential financial bias; outcomes may favor sponsor |
| "Authors have industry financial ties" | Personal financial interests may influence reporting |
| "Industry-funded with restricted data access" | Cannot independently verify findings |
| "Trial results not posted to ClinicalTrials.gov" | Possible selective reporting; legally required for many trials |
| "Clinical trial without detected registration" | Cannot verify pre-specified outcomes |
| "No conflict of interest statement found" | May have undisclosed conflicts |

### Confidence Scores

- **1.0**: Authoritative source (Funder Registry DOI, official classification)
- **0.7-0.9**: Strong pattern match with corroborating evidence
- **0.5-0.7**: Pattern match without corroboration
- **< 0.5**: Weak evidence, high uncertainty

---

## Limitations & Caveats

### What This Tool Cannot Detect

1. **Indirect Industry Influence**
   - Contract research organizations (CROs) acting as intermediaries
   - Ghost authorship (industry employees writing without attribution)
   - Consultant arrangements not disclosed in COI statements

2. **Selective Outcome Reporting**
   - The tool can detect if trial registration exists but NLP comparison of registered vs. reported outcomes is limited
   - Subtle endpoint modifications may not be detected

3. **Publication Bias**
   - Cannot detect studies that were never published
   - Would require access to trial registries showing completed but unpublished trials

4. **Pre-2005 Studies**
   - ClinicalTrials.gov registration became mandatory in 2007 (FDAAA)
   - Earlier studies often lack structured metadata

5. **Non-Trial Research**
   - Observational studies, case series, etc. may not have trial registrations
   - Industry influence harder to detect without clear funding statements

### Data Quality Considerations

| Data Source | Coverage | Reliability | Notes |
|-------------|----------|-------------|-------|
| CrossRef Funders | ~60% of articles | High | Best for recent publications |
| PubMed Grants | Variable | Medium | Depends on journal indexing |
| ClinicalTrials.gov | Required trials only | High | US-focused; FDAAA scope |
| COI Statements | Variable | Medium | Quality varies by journal |
| Data Availability | ~40% of articles | Medium | Relatively new requirement |

### False Positives/Negatives

**False Positives (Over-detection):**
- Academic medical centers with pharma-sounding names
- Non-profit organizations with industry ties
- Investigator-initiated studies with industry drug supply

**False Negatives (Under-detection):**
- Studies funded through unrestricted educational grants
- Authors with undisclosed conflicts
- Studies in journals not indexed in PubMed

---

## Extending the Tool

### Adding New Industry Funders

```python
# Add to KNOWN_INDUSTRY_FUNDER_DOIS in study_transparency_analyzer.py
KNOWN_INDUSTRY_FUNDER_DOIS["10.13039/XXXXXXXXXX"] = "New Pharma Company"
```

Find Funder Registry DOIs at: https://www.crossref.org/services/funder-registry/

### Custom Classification Rules

```python
# Subclass the analyzer to customize classification
class CustomAnalyzer(StudyTransparencyAnalyzer):

    def _classify_funder(self, name: str, funder_doi: str) -> Tuple[bool, float]:
        # Your custom logic here
        if "my_special_case" in name.lower():
            return True, 0.9
        return super()._classify_funder(name, funder_doi)
```

### Adding New Data Sources

```python
class NewDataSourceClient:
    """Template for adding a new data source."""

    def __init__(self):
        self.session = requests.Session()

    def get_data(self, identifier: str) -> Optional[Dict]:
        # Implementation here
        pass

# Integrate into main analyzer
class ExtendedAnalyzer(StudyTransparencyAnalyzer):

    def __init__(self, email: str, **kwargs):
        super().__init__(email, **kwargs)
        self.new_source = NewDataSourceClient()

    def _fetch_additional_data(self, report: TransparencyReport):
        data = self.new_source.get_data(report.doi)
        # Process and add to report
```

### Async Version for High-Throughput

```python
import aiohttp
import asyncio

class AsyncStudyAnalyzer:
    """Async version for analyzing many studies quickly."""

    async def analyze_batch(self, identifiers: List[str]) -> List[TransparencyReport]:
        async with aiohttp.ClientSession() as session:
            tasks = [self._analyze_single(session, id) for id in identifiers]
            return await asyncio.gather(*tasks)
```

---

## References & Further Reading

### Key Papers on Research Transparency

1. **Lundh A, et al.** "Industry sponsorship and research outcome." *Cochrane Database Syst Rev* 2017. [PMID: 28207928]
   - Meta-analysis showing industry-sponsored trials more likely to report favorable results

2. **Goldacre B, et al.** "COMPare: a prospective cohort study correcting and monitoring 58 misreported trials in real time." *Trials* 2019. [PMID: 31101063]
   - Systematic detection of outcome switching

3. **AllTrials Campaign** - https://www.alltrials.net/
   - Advocacy for trial transparency

4. **FDAAA TrialsTracker** - https://fdaaa.trialstracker.net/
   - Tracking compliance with results reporting laws

### API Documentation

- **PubMed E-utilities**: https://www.ncbi.nlm.nih.gov/books/NBK25500/
- **CrossRef REST API**: https://api.crossref.org/swagger-ui/index.html
- **ClinicalTrials.gov API v2**: https://clinicaltrials.gov/data-api/api
- **Europe PMC REST API**: https://europepmc.org/RestfulWebService
- **OpenAlex API**: https://docs.openalex.org/

### Related Tools

- **TrialsTracker** (EBMDATALAB): Monitors unreported trials
- **OpenTrials**: Aggregated trial database
- **Unpaywall**: Open access availability
- **Retraction Watch Database**: Retracted papers

### Regulatory Background

- **FDAAA 801** (2007): US law requiring clinical trial registration and results reporting
- **ICMJE Policy**: Journals requiring trial registration for publication
- **WHO ICTRP**: International Clinical Trials Registry Platform

---

## License

MIT License - Free for academic and commercial use.

## Contributing

Contributions welcome! Areas of particular interest:
- NLP for outcome switching detection
- Additional regional trial registries (EudraCT, ISRCTN, etc.)
- Machine learning for COI statement analysis
- Integration with Retraction Watch database

---

*Last updated: 2025*
