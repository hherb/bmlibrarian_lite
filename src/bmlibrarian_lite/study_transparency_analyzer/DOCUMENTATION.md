# Study Transparency Analyzer

## Comprehensive Tool for Detecting Industry Sponsorship and Data Disclosure in Medical Research

---

## Table of Contents

1. [Overview](#overview)
2. [Installation](#installation)
3. [Quick Start](#quick-start)
4. [Data Sources & APIs](#data-sources--apis)
5. [Detection Methods](#detection-methods)
6. [Full-Text Analysis](#full-text-analysis)
7. [API Reference](#api-reference)
8. [Command Line Interface](#command-line-interface)
9. [Batch Processing](#batch-processing)
10. [Interpreting Results](#interpreting-results)
11. [Limitations & Caveats](#limitations--caveats)
12. [Extending the Tool](#extending-the-tool)
13. [References & Further Reading](#references--further-reading)

---

## Overview

The Study Transparency Analyzer is a Python tool designed to automate the detection of:

1. **Industry sponsorship** in medical research publications
2. **Institutional-intermediary industry funding** (pharma money routed through universities)
3. **Data disclosure levels** (full open, restricted, effectively unavailable, or withheld)
4. **Clinical trial registration compliance**
5. **Conflict of interest disclosures** (including named pharma company detection)
6. **Potential outcome switching** (registered vs. reported outcomes)

### Why This Matters

Research has consistently shown that industry-sponsored studies are more likely to report favorable outcomes for the sponsor's products. Understanding the funding source and data availability is crucial for:

- Evidence-based medicine practitioners
- Systematic review authors
- Journal editors and peer reviewers
- Healthcare policy makers
- Research integrity investigators

### What This Tool Does

Given a **DOI** or **PubMed ID (PMID)**, and optionally **full-text content**, the analyzer:

1. Queries multiple databases (PubMed, CrossRef, ClinicalTrials.gov, Europe PMC, OpenAlex)
2. Extracts funding/sponsor information
3. Classifies sponsors as industry vs. government/academic
4. Analyzes conflict of interest statements using multi-pass pharma name detection
5. Detects institutional-intermediary industry funding patterns
6. Checks data availability statements for effective refusals
7. Verifies clinical trial registration and results posting compliance
8. Calculates an overall transparency score with compound penalties
9. Identifies risk of bias indicators

---

## Installation

### Requirements

- Python 3.8+
- Internet connection (for API access)
- Valid email address (required by NCBI/CrossRef APIs)

### Setup

```bash
# As part of BMLibrarian Lite
cd bmlibrarian_lite
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"

# Standalone usage
cd study_transparency_analyzer
uv venv && source .venv/bin/activate
uv pip install -r requirements.txt
```

### Optional: NCBI API Key

For higher rate limits with PubMed (10 requests/sec vs 3 requests/sec), obtain a free API key:

1. Register at https://www.ncbi.nlm.nih.gov/account/
2. Go to Settings > API Key Management
3. Generate a new key

---

## Quick Start

### Single Study Analysis (Python)

```python
from study_transparency_analyzer import StudyTransparencyAnalyzer

# Initialize — full-text auto-discovery is enabled by default
analyzer = StudyTransparencyAnalyzer(
    email="your.email@example.com",
    pubmed_api_key="optional_api_key",  # Optional
)

# Analyze by DOI — automatically discovers full text via Europe PMC,
# Unpaywall, PMC, cached PDFs, and optionally browser fallback
report = analyzer.analyze(doi="10.1056/NEJMoa2034577")

# Analyze by PMID — also auto-discovers full text
report = analyzer.analyze(pmid="33301246")

# Override with your own full-text content (skips auto-discovery)
with open("article_fulltext.txt") as f:
    fulltext = f.read()
report = analyzer.analyze(doi="10.1056/NEJMoa2034577", fulltext=fulltext)

# Disable browser fallback (for mobile/CI environments)
analyzer_no_browser = StudyTransparencyAnalyzer(
    email="your.email@example.com",
    use_browser_fallback=False,  # No Playwright
)

# Disable auto-discovery entirely (API metadata only)
analyzer_api_only = StudyTransparencyAnalyzer(
    email="your.email@example.com",
    auto_discover_fulltext=False,
)

# Access results
print(f"Title: {report.title}")
print(f"Sponsor Type: {report.sponsor_type.value}")
print(f"Industry Funded: {report.industry_funding_detected}")
print(f"Transparency Score: {report.transparency_score}/100")
print(f"Risk Indicators: {report.risk_of_bias_indicators}")

# COI details
if report.coi_info:
    print(f"Industry Ties: {report.coi_info.has_industry_ties}")
    print(f"COI Confidence: {report.coi_info.confidence}")
    print(f"Relationships: {report.coi_info.disclosed_relationships}")

# Data availability details
if report.data_availability:
    print(f"Data Level: {report.data_availability.disclosure_level.value}")
    print(f"Restrictions: {report.data_availability.restrictions}")

# Export to JSON
import json
print(json.dumps(report.to_dict(), indent=2))
```

### Command Line Usage

```bash
# Full analysis — auto-discovers full text from all available sources
python study_transparency_analyzer.py --pmid 33301246 --email your@email.com

# Without browser fallback (safe for CI/mobile/headless)
python study_transparency_analyzer.py --pmid 33301246 --email your@email.com \
    --no-browser

# With manual full-text file (skips auto-discovery)
python study_transparency_analyzer.py --doi "10.1056/NEJMoa2034577" \
    --email your@email.com --fulltext article.txt

# API metadata only (no full-text discovery at all)
python study_transparency_analyzer.py --doi "10.1056/NEJMoa2034577" \
    --email your@email.com --no-fulltext-discovery

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

### 6. Full-Text Content (Optional)

**What it provides:**
- Complete COI disclosure statements (often truncated in API metadata)
- Data sharing/availability sections
- Funding role sections
- Acknowledgments with detailed industry relationships
- Contributor/author role disclosures

**Sources:** Can be provided from any source (Lancet, BMJ, JAMA, etc.) as plain text or markdown. The analyzer's `extract_fulltext_sections()` function parses standard biomedical section headers.

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

When DOIs aren't available, `classify_funder_name()` matches the funder name.
Government and academic patterns are checked **first** and win outright, so a
university spin-out naming convention cannot flag its parent institution:

```python
# Abridged. Entries chosen to show the surprises, not the head of each list —
# see the source for all 18 + 7, and sponsor_patterns.json for the contract.
GOVERNMENT_PATTERNS = [..., r'\bva\b', r'\bwellcome\b', r'\bmedical research council\b']
ACADEMIC_PATTERNS = [r'\buniversit(?:y|ies)\b', ..., r'\bgovernment\b', r'\bfederal\b', r'\bstate\b']

# The combined vocabulary, NOT the matcher. classify_funder_name() walks the two
# halves separately so each reports its own confidence (#152); that covers exactly
# this concatenation, in this order. This constant is what the drift guard
# compares and what "not industry" means as one list.
NON_INDUSTRY_PATTERNS = GOVERNMENT_PATTERNS + ACADEMIC_PATTERNS
```

Two entries in each half are worth knowing before you edit either:

- `wellcome` is a charitable foundation and `medical research council` a UK
  research council, yet both sit in the **government** half, because Swift tiers
  them there.
- `government`, `federal` and `state` are government words sitting in the
  **academic** half, so "Federal Ministry of Health" tiers `ACADEMIC`. Wrong on
  both platforms; left alone because moving them is a Swift behaviour change too.

`classify_funder_name()` walks the two halves **in order**, government first,
which covers exactly the same patterns as their concatenation — so the split does
not move the industry/non-industry boundary. What it does decide is the
**confidence** each layer reports:

| Layer | Confidence |
| --- | --- |
| known CrossRef industry-funder DOI | 1.00 |
| `GOVERNMENT_PATTERNS` match | 0.85 |
| `ACADEMIC_PATTERNS` match | 0.80 |
| industry stem or whole word | 0.75 |
| nothing matched | 0.30 |

Government outranks academic because that list names specific public bodies,
where "university", "hospital" and "state" appear in far more names than they
identify. Python reported a flat 0.80 for both halves until #152, where Swift had
always distinguished them; the ladder is now asserted from the shared contract on
both platforms, and a name matching both halves reports the government value.

Industry matching then uses two lists that are **different kinds of thing**. A
stem must match *inside* a longer word ("pharmaceutic" reaching
"Pharmaceuticals", the standard company-name plural); a whole word must not
("inc" as a substring matches "Lincoln", "Vincent" and "province"):

```python
FUNDER_NAME_STEMS = ["pharmaceutic", "therapeutics", "laboratories"]

FUNDER_NAME_WORDS = [
    r'\bpharma\b', r'\bbiotech\b', r'\bincorporated\b', r'\binc\b',
    r'\bcorp\b', r'\blimited\b', r'\bltd\b', r'\bgmbh\b',
    r'\bllc\b', r'\bplc\b',
]
```

Both lists are **calibrated against measured data**, not intuition: 417
hand-labelled CrossRef and PubMed funder names in
`doc/cross_platform/transparency_parity/funder_names.json`, where they score
precision 0.909 / recall 0.333. `tests/test_funder_classification.py` re-measures
that on every run and pins which names are matched, missed and wrongly matched.

Membership is therefore evidence-driven, and the exclusions matter as much as the
inclusions — `biotechnology` scored 0 true positives against 4 false positives,
reaching only an Indian ministry and a UK research council, so only the bare word
`biotech` is kept. Adding a term without measuring it is how the list regresses.

Note that `INDUSTRY_KEYWORDS` is **not** used here. It holds conflict-of-interest
*prose* phrases ("advisory board", "employee of") for Layer 4; the generic
corporate suffixes match far too freely in running text, and the disclosure
phrases never occur in an organisation name. Merging the two is a bug.

**Confidence Level:** MEDIUM - 0.8 government/academic, 0.75 industry name,
0.3 unrecognised

#### Layer 4: Named Pharma Company Detection in COI Statements

A curated list of 40+ pharmaceutical and biotech company names is scanned against COI disclosure text:

```python
KNOWN_PHARMA_NAMES = [
    r'\bpfizer\b', r'\bastrazeneca\b', r'\bbayer\b',
    r'\bglaxosmithkline\b', r'\bgsk\b',
    r'\bjohnson\s*&\s*johnson\b', r'\bjanssen\b',
    r'\beli\s+lilly\b', r'\blilly\b',
    r'\bmerck\b', r'\bmsd\b', r'\bmerck sharp\b',
    r'\bnovartis\b', r'\bnovo nordisk\b',
    r'\broche\b', r'\bsanofi\b',
    r'\bgilead\b', r'\babbvie\b', r'\bcelgene\b',
    r'\bamgen\b', r'\bbristol[- ]?myers\b', r'\bbiogen\b',
    r'\bboehringer\s+ingelheim\b',
    r'\btakeda\b', r'\bregeneron\b', r'\bteva\b',
    # ... and more
]
```

**Confidence Level:** HIGH (0.70-0.98) - Direct company name matching. Confidence scales with the number of unique companies found.

#### Layer 5: Institutional Intermediary Detection

Detects the common pattern where pharma money flows through universities or hospitals rather than directly to authors:

```python
INSTITUTIONAL_INTERMEDIARY_PATTERNS = [
    r'(?:funding|grants?|support|contracts?)\s+(?:to|paid to)\s+(?:the\s+)?(?:university|institution|hospital)',
    r'(?:but\s+)?no personal (?:funding|payment|honorari)',
    r'(?:grants?|contracts?|funding)\s+(?:or\s+\w+\s+)?(?:to|paid to)\s+(?:his|her|their)\s+institution',
    r'(?:research\s+)?grant\s+support\s+through\b',
    r'salary\s+support\s+from\b',
]
```

**Purpose:** Many COI statements claim "no personal funding" while the same paragraph names pharmaceutical companies that fund the author's institution. This layer ensures such disclosures are correctly classified as industry ties.

**Confidence Level:** HIGH (0.80-0.98) - When combined with pharma name detection

### Overall Sponsor Type

Once every funder is classified, `determine_sponsor_type()` reduces them to one
tier, in this order:

| Tier | When |
| --- | --- |
| `UNKNOWN` | no funders at all — absence of data is not evidence of a sponsor |
| `INDUSTRY` | every funder is industry |
| `MIXED` | some but not all are industry |
| `GOVERNMENT` | any funder matches `GOVERNMENT_PATTERNS` |
| `ACADEMIC` | otherwise, any funder matches `ACADEMIC_PATTERNS` |
| `NONPROFIT` | otherwise |

One public agency decides the tier however many institutions sit alongside it,
which is why `GOVERNMENT` is tested before `ACADEMIC`.

This mirrors Swift's `FundingAnalyzer.determineSponsorType` tier for tier, and
both pattern lists are byte-identical across the two platforms — **edit them
together or not at all.** That is enforced, not merely asked for:
`doc/cross_platform/transparency_parity/sponsor_patterns.json` is the shared
contract and both suites assert their lists against it.

**`NONPROFIT` means "not recognised", not "philanthropically funded."** It is
reached only by falling through both pattern lists, so it is exactly the set of
non-industry funders that matched nothing. On the shared labelled corpus that is
the majority of names, so `_fetch_funder_info` attaches a warning to the report
whenever the tier is reached, and callers should treat it as unverified. A
misspelled agency, a non-English funder and a genuine foundation are
indistinguishable at this tier.

#### Registered trials can override the tier

`update_sponsor_type()` folds a ClinicalTrials.gov sponsor class into the
funder-derived tier, mirroring Swift's `FundingAnalyzer.updateSponsorType`. An
`INDUSTRY` lead sponsor turns `UNKNOWN` into `INDUSTRY` and **every** non-industry
tier — including `NONPROFIT` — into `MIXED`; `INDUSTRY` and `MIXED` are already
terminal. Any other sponsor class leaves the tier alone, because the funder names
are the better evidence.

### COI Statement Analysis (Multi-Pass)

The `analyze_coi_statement()` function uses a 4-pass approach:

| Pass | Signal | Description |
|------|--------|-------------|
| **1** | Named pharma companies | Scan for 40+ pharma/biotech company names |
| **2** | Institutional intermediaries | Detect "funding to institution from [pharma]" |
| **3** | Generic industry keywords | "grants from", "honoraria", "advisory board", etc. |
| **4** | "No conflict" declarations | Only trusted if statement < 500 chars AND no pharma names found |

**Key design decision:** Long, detailed COI statements that name pharmaceutical companies are *disclosures*, not *denials*, even if they contain phrases like "no personal funding". The blanket denial check in Pass 4 is only applied to short statements that contain no pharma company names.

### Data Disclosure Level Detection

The tool classifies data availability into five levels, using priority-ordered detection:

| Level | Description | Detection Method |
|-------|-------------|------------------|
| `FULL_OPEN` | Data in public repository | Repository name detected (Zenodo, Figshare, GEO, etc.) |
| `NOT_AVAILABLE` | Effectively unavailable | Sponsor confidentiality agreements, data not released, collaboration-locked |
| `RESTRICTED` | Significant restrictions | IRB, ethics, on-request with conditions |
| `AVAILABLE_ON_REQUEST` | Available upon request | "available upon reasonable request" (without restriction signals) |
| `NOT_STATED` | No statement found | No data availability section detected |

#### Effective Refusal Detection

A key improvement is the detection of data sharing statements that *look like policies* but constitute effective refusals. These are now classified as `NOT_AVAILABLE` rather than `RESTRICTED`:

```python
DATA_REPOSITORIES['effectively_unavailable'] = [
    # Data restricted to named collaboration with no external access
    r'(?:provided|available)\s+to\s+the\s+\w+\s+(?:collaboration|consortium|group)\s+on\s+the\s+understanding',
    # Multiple restriction signals in same statement
    r'not be released.*(?:data custodians?|directly to)',
    # Sponsor-gated access
    r'(?:confidentiality|agreement)\s+(?:with\s+)?(?:the\s+)?(?:sponsor|industri|pharma|trial\s+(?:owner|sponsor))',
]
```

Additionally, strong refusal patterns like "data will not be released", "sponsor agreements prevent disclosure", and "confidentiality agreements with sponsors" trigger `NOT_AVAILABLE` classification regardless of other language in the statement.

**Human-readable restriction labels:** When restrictions are detected, the report includes descriptive labels (e.g., "Sponsor confidentiality agreement restricts access") rather than raw regex patterns.

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

## Full-Text Analysis

### Why Full Text Matters

API metadata (PubMed, CrossRef, Europe PMC) provides a starting point, but often contains incomplete or truncated information. Full-text analysis provides:

- **Complete COI statements** - PubMed often truncates long disclosures
- **Data sharing sections** - Not always captured in API metadata
- **Funding role details** - Who designed the study, collected data, etc.
- **Acknowledgments** - Additional industry relationships not in COI

### Automatic Full-Text Discovery

By default, `analyze()` automatically attempts to retrieve full-text content when none is provided. The discovery chain tries sources in order of quality and speed:

| Priority | Source | Description |
|----------|--------|-------------|
| 1 | Cached markdown | Previously retrieved and converted full text |
| 2 | Europe PMC XML | Machine-readable JATS XML, converted to markdown (best quality) |
| 3 | Europe PMC PDF | Free PDF from Europe PMC render endpoint |
| 4 | Cached PDF | Previously downloaded PDF, text extracted |
| 5 | PDF download | Unpaywall, PubMed Central, publisher HTTP, DOI resolution |
| 6 | Browser fallback | Playwright/Chromium for bot-protected sites (optional) |

**Disabling browser fallback:** Set `use_browser_fallback=False` in the constructor for environments without a browser (mobile apps, CI, headless servers). Sources 1-5 still work without a browser.

**Disabling auto-discovery entirely:** Set `auto_discover_fulltext=False` to use only API metadata (equivalent to the old behaviour).

### How Section Extraction Works

Once full text is available (auto-discovered or manually provided), `extract_fulltext_sections()` scans for standard biomedical section headers:

```python
# Sections extracted (canonical key -> header patterns)
section_headers = {
    'coi': ['declaration of interests', 'conflict of interest', 'competing interests', 'disclosures'],
    'data_sharing': ['data sharing', 'data availability', 'data access'],
    'funding': ['funding', 'financial support', 'sources of funding'],
    'funding_role': ['role of the funding source', 'role of the sponsor'],
    'acknowledgments': ['acknowledgments', 'acknowledgements'],
    'contributors': ['contributors', 'author contributions'],
}
```

### Priority Order

Full-text sections take priority over API-sourced data:

1. **COI:** Full-text `coi` section > PubMed COI statement > Europe PMC
2. **Data availability:** Full-text `data_sharing` section > Europe PMC XML extraction

### Example

```python
# Auto-discovery (default) — the analyzer finds full text automatically
analyzer = StudyTransparencyAnalyzer(email="your@email.com")
report = analyzer.analyze(doi="10.1016/S0140-6736(25)01578-8")
# Full text auto-discovered via Europe PMC, Unpaywall, etc.

# Manual override — provide your own full text
with open("lancet_article.txt") as f:
    fulltext = f.read()
report = analyzer.analyze(
    doi="10.1016/S0140-6736(25)01578-8",
    fulltext=fulltext,
)

# Mobile/CI safe — no browser, but still tries API-based sources
analyzer = StudyTransparencyAnalyzer(
    email="your@email.com",
    use_browser_fallback=False,
)
report = analyzer.analyze(doi="10.1016/S0140-6736(25)01578-8")
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
    sponsor_type: SponsorType  # INDUSTRY, GOVERNMENT, ACADEMIC, NONPROFIT, MIXED, UNKNOWN
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
    NOT_AVAILABLE = "not_available"       # Effectively unavailable
    NOT_STATED = "not_stated"             # No statement
    UNKNOWN = "unknown"
```

### ConflictOfInterest

```python
@dataclass
class ConflictOfInterest:
    statement: str                         # Raw COI statement text
    has_industry_ties: bool                # Whether industry ties detected
    disclosed_relationships: List[str]     # Extracted relationship descriptions
    confidence: float                      # 0.0 to 1.0
```

### DataAvailabilityInfo

```python
@dataclass
class DataAvailabilityInfo:
    statement: Optional[str]               # Raw data availability statement
    disclosure_level: DataDisclosureLevel   # Classification
    repository_url: Optional[str]          # URL if open access
    accession_number: Optional[str]        # Accession number if available
    restrictions: List[str]                # Human-readable restriction descriptions
```

### Key Methods

```python
class StudyTransparencyAnalyzer:
    def __init__(
        self,
        email: str,
        pubmed_api_key: Optional[str] = None,
        unpaywall_email: Optional[str] = None,
        use_browser_fallback: bool = True,
        browser_headless: bool = False,
        auto_discover_fulltext: bool = True,
    ):
        """
        Initialize the analyzer.

        Args:
            email: Contact email (required by APIs)
            pubmed_api_key: Optional NCBI API key for higher rate limits
            unpaywall_email: Email for Unpaywall API (defaults to email)
            use_browser_fallback: If True, use Playwright browser for
                bot-protected downloads. Set to False for mobile/CI.
            browser_headless: If True, run browser without visible window
            auto_discover_fulltext: If True, automatically discover
                full text when none is provided to analyze().
        """

    def analyze(
        self,
        doi: str = None,
        pmid: str = None,
        fulltext: str = None,
    ) -> TransparencyReport:
        """
        Main analysis method.

        When fulltext is not provided and auto_discover_fulltext is
        enabled, automatically tries: cached markdown, Europe PMC XML,
        Europe PMC PDF, cached PDF, Unpaywall/PMC/publisher downloads,
        and optionally browser fallback.

        Args:
            doi: Digital Object Identifier
            pmid: PubMed ID
            fulltext: Optional full-text content. When provided,
                auto-discovery is skipped.

        Returns:
            TransparencyReport with all analysis results
        """
```

### Standalone Functions

```python
def analyze_coi_statement(coi_text: Optional[str]) -> ConflictOfInterest:
    """Analyze a COI statement for industry ties using multi-pass detection."""

def analyze_data_availability(text: Optional[str]) -> DataAvailabilityInfo:
    """Analyze a data availability statement with effective refusal detection."""

def extract_fulltext_sections(fulltext: str) -> Dict[str, str]:
    """Extract transparency-relevant sections from full-text content.

    Returns dict with keys: 'coi', 'data_sharing', 'funding',
    'funding_role', 'acknowledgments', 'contributors'.
    """
```

---

## Command Line Interface

### Single Study Analysis

```bash
# Full analysis — auto-discovers full text from all sources
python study_transparency_analyzer.py --pmid 33301246 --email you@email.com

# Without browser fallback (safe for CI/mobile/headless servers)
python study_transparency_analyzer.py --pmid 33301246 --email you@email.com \
    --no-browser

# With manual full-text file (skips auto-discovery)
python study_transparency_analyzer.py --doi "10.1056/NEJMoa2034577" \
    --email you@email.com --fulltext article.txt

# API metadata only (no full-text discovery at all)
python study_transparency_analyzer.py --pmid 33301246 --email you@email.com \
    --no-fulltext-discovery

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

# Custom Unpaywall email
python study_transparency_analyzer.py --pmid 33301246 --email you@email.com \
    --unpaywall-email your-unpaywall@email.com
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
| `--no-browser` | No | Disable Playwright browser fallback (for CI/mobile) |
| `--no-fulltext-discovery` | No | Skip auto full-text discovery entirely |
| `--output` | No | Output format: `summary`, `text`, or `json` (default: `summary`) |
| `--output-file` | No | Write output to file instead of stdout |

### Example Output

```
============================================================
STUDY TRANSPARENCY ANALYSIS
============================================================
Title: Efficacy and safety of statin therapy in older people...
DOI: 10.1016/S0140-6736(25)01578-8
PMID: N/A

TRANSPARENCY SCORE: 25/100

KEY FINDINGS:
  * Sponsor Type: ACADEMIC
  * Industry Funding: NO
  * Data Availability: Not Available
  * Trial Registration: None found
  * COI Disclosed: YES (confidence: 98%)

RISK INDICATORS:
  * Authors have disclosed industry financial ties
  * Industry funding routed through institutional intermediaries
  * Data effectively unavailable despite sharing statement
  * Industry ties combined with restricted/unavailable data
  * Clinical trial without detected registration

Data sources: PubMed, CrossRef, Europe PMC, Full-text
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
  * Full open access: 8 (17.0%)
  * Effectively unavailable: 4 (8.5%)
  * Restricted/Not available: 19 (40.4%)
  * No statement: 20 (42.6%)

Missing trial results (ClinicalTrials.gov): 5

Average Transparency Score: 52.3/100

Transparency Score Distribution:
  * 0-25 (Poor): 5
  * 26-50 (Below Average): 18
  * 51-75 (Average): 19
  * 76-100 (Good): 5

Most Common Risk Indicators:
  * Industry funding detected: 23
  * Authors have industry financial ties: 18
  * No conflict of interest statement found: 12
  * Industry ties combined with restricted/unavailable data: 11
  * Industry funding routed through institutional intermediaries: 7
======================================================================
```

---

## Interpreting Results

### Transparency Score

The transparency score (0-100) is calculated from a base of 50 points:

| Factor | Points | Notes |
|--------|--------|-------|
| **Data Availability** | | |
| Full open access | +20 | Data in a public repository |
| Available on request | +5 | Reduced from +10; "on request" often means no access |
| Restricted | -5 | IRB, ethics committee, or other restrictions |
| Not available | -15 | Effectively unavailable or explicitly denied |
| No statement | -5 | No data availability section found |
| **COI Disclosure** | | |
| Has COI statement (no industry ties) | +5 | Credit for disclosure |
| Has COI statement (with industry ties) | 0 | +5 for disclosure, -5 for industry ties |
| No COI statement | -5 | |
| **Trial Registration** | | |
| Has registration | +10 | |
| Results posted (compliant) | +5 | |
| Results missing (overdue) | -10 | |
| **Penalties** | | |
| Outcome switching detected | -15 | |
| Industry ties + restricted/unavailable data | -10 | Compound penalty |

**Scoring philosophy:**
- Having a COI statement is valued (disclosure), but disclosed industry ties still reduce the score because the underlying situation carries bias risk regardless of disclosure quality.
- "Available on request" receives only +5 points (not +10) because research shows these requests are frequently denied.
- Industry ties through institutional intermediaries are scored identically to direct ties.
- The compound penalty for industry ties + restricted data reflects the particularly concerning situation where independent verification is impossible.

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
| "Authors have disclosed industry financial ties" | Personal financial interests may influence reporting |
| "Industry funding routed through institutional intermediaries" | Pharma money flows through universities; bias risk same as direct funding |
| "Industry-funded with restricted data access" | Cannot independently verify findings |
| "Data effectively unavailable despite sharing statement" | Statement exists but data is systematically denied |
| "Industry ties combined with restricted/unavailable data" | Most concerning combination: industry influence + no independent verification |
| "Data access restricted" | Data available but with significant barriers |
| "Trial results not posted to ClinicalTrials.gov" | Possible selective reporting; legally required for many trials |
| "Clinical trial without detected registration" | Cannot verify pre-specified outcomes |
| "No conflict of interest statement found" | May have undisclosed conflicts |

### Confidence Scores

- **1.0**: Authoritative source (Funder Registry DOI, official classification)
- **0.7-0.98**: Named pharma company detection (scales with number of unique companies)
- **0.5-0.7**: Generic industry keyword match without corroboration
- **0.3**: Statement present but no clear signals
- **0.0**: No statement available

---

## Limitations & Caveats

### What This Tool Can Now Detect

1. **Institutional-Intermediary Industry Funding** - Pharma money routed through universities is now detected via `INSTITUTIONAL_INTERMEDIARY_PATTERNS` and `KNOWN_PHARMA_NAMES`

2. **Effective Data Refusals** - Data sharing statements that sound like policies but constitute refusals (e.g., "confidentiality agreements with sponsors prevent disclosure") are now classified as `NOT_AVAILABLE`

3. **Long COI Statements with Blanket Phrasing** - A 10,000-character COI naming 20 pharma companies is correctly identified as an industry-tied disclosure, even if it contains "no personal funding"

### What This Tool Cannot Detect

1. **Undisclosed Industry Relationships**
   - Ghost authorship (industry employees writing without attribution)
   - Consultant arrangements not mentioned in COI statements
   - Relationships disclosed only in supplementary materials not in the full text

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

6. **Novel Pharma Companies**
   - The `KNOWN_PHARMA_NAMES` list covers 40+ major companies but cannot detect every startup or regional pharmaceutical company

### Data Quality Considerations

| Data Source | Coverage | Reliability | Notes |
|-------------|----------|-------------|-------|
| CrossRef Funders | ~60% of articles | High | Best for recent publications |
| PubMed Grants | Variable | Medium | Depends on journal indexing |
| ClinicalTrials.gov | Required trials only | High | US-focused; FDAAA scope |
| COI Statements (API) | Variable | Medium | Often truncated |
| COI Statements (Full Text) | High | High | Complete text; best signal source |
| Data Availability | ~40% of articles | Medium | Relatively new requirement |
| Full-Text Sections | Depends on access | High | Best results with complete text |

### False Positives/Negatives

**False Positives (Over-detection):**
- Academic medical centers with pharma-sounding names
- Non-profit organizations with industry ties
- Investigator-initiated studies with industry drug supply
- Legitimate data protection requirements (rare diseases, identifiable patients)

**False Negatives (Under-detection):**
- Studies funded through unrestricted educational grants
- Authors with undisclosed conflicts
- Studies in journals not indexed in PubMed
- Novel or small pharmaceutical companies not in `KNOWN_PHARMA_NAMES`
- Data restrictions described only in supplementary files

---

## Extending the Tool

### Adding New Pharma Companies

```python
# Add to KNOWN_PHARMA_NAMES in study_transparency_analyzer.py
KNOWN_PHARMA_NAMES.append(r'\bnew pharma name\b')
```

### Adding New Industry Funders

```python
# Add to KNOWN_INDUSTRY_FUNDER_DOIS in study_transparency_analyzer.py
KNOWN_INDUSTRY_FUNDER_DOIS["10.13039/XXXXXXXXXX"] = "New Pharma Company"
```

Find Funder Registry DOIs at: https://www.crossref.org/services/funder-registry/

### Adding New Effective Refusal Patterns

```python
# Add to DATA_REPOSITORIES['effectively_unavailable']
DATA_REPOSITORIES['effectively_unavailable'].append(
    r'new pattern for detecting data refusals'
)
```

### Adding New Intermediary Patterns

```python
# Add to INSTITUTIONAL_INTERMEDIARY_PATTERNS
INSTITUTIONAL_INTERMEDIARY_PATTERNS.append(
    r'new pattern for institutional intermediary funding'
)
```

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

GNU Affero General Public License v3.0 (AGPL-3.0) - Part of BMLibrarian Lite.

## Contributing

Contributions welcome! Areas of particular interest:
- NLP for outcome switching detection
- Additional regional trial registries (EudraCT, ISRCTN, etc.)
- Machine learning for COI statement analysis
- Integration with Retraction Watch database
- Expansion of `KNOWN_PHARMA_NAMES` for regional pharmaceutical companies
- Additional effective refusal patterns for data availability statements

---

*Last updated: 2025*
