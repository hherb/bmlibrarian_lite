#!/usr/bin/env python3
"""
Study Transparency Analyzer
===========================

A comprehensive tool for analyzing medical study transparency, including:
- Industry sponsorship detection
- Data disclosure assessment
- Trial registration compliance checking
- Outcome reporting analysis

Author: Medical Research Transparency Tools
License: MIT
"""

import re
import json
import time
import logging
from dataclasses import dataclass, field, asdict
from typing import Optional, List, Dict, Any, Tuple
from datetime import datetime, timedelta
from enum import Enum
import requests

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# =============================================================================
# ENUMS AND DATA CLASSES
# =============================================================================

class SponsorType(Enum):
    """Classification of study sponsor types."""
    INDUSTRY = "industry"
    GOVERNMENT = "government"
    ACADEMIC = "academic"
    NONPROFIT = "nonprofit"
    MIXED = "mixed"
    UNKNOWN = "unknown"


class DataDisclosureLevel(Enum):
    """Classification of data disclosure levels."""
    FULL_OPEN = "full_open"              # Data in public repository
    AVAILABLE_ON_REQUEST = "on_request"   # Available upon reasonable request
    RESTRICTED = "restricted"             # Significant restrictions
    NOT_AVAILABLE = "not_available"       # Explicitly not shared
    NOT_STATED = "not_stated"             # No data availability statement
    UNKNOWN = "unknown"


class ResultsComplianceStatus(Enum):
    """ClinicalTrials.gov results posting compliance."""
    COMPLIANT = "compliant"               # Results posted on time
    LATE = "late"                         # Results posted but late
    MISSING = "missing"                   # Results not posted (should be)
    NOT_REQUIRED = "not_required"         # Not subject to requirements
    UNKNOWN = "unknown"


@dataclass
class FunderInfo:
    """Information about a study funder."""
    name: str
    funder_doi: Optional[str] = None
    award_numbers: List[str] = field(default_factory=list)
    is_industry: bool = False
    confidence: float = 0.0


@dataclass
class TrialRegistration:
    """Clinical trial registration information."""
    registry: str                          # e.g., "ClinicalTrials.gov"
    registration_id: str                   # e.g., "NCT01234567"
    title: Optional[str] = None
    sponsor_class: Optional[str] = None
    lead_sponsor: Optional[str] = None
    results_posted: bool = False
    completion_date: Optional[datetime] = None
    primary_outcomes_registered: List[str] = field(default_factory=list)
    secondary_outcomes_registered: List[str] = field(default_factory=list)


@dataclass
class ConflictOfInterest:
    """Conflict of interest information."""
    statement: str
    has_industry_ties: bool = False
    disclosed_relationships: List[str] = field(default_factory=list)
    confidence: float = 0.0


@dataclass
class DataAvailabilityInfo:
    """Data availability statement analysis."""
    statement: Optional[str] = None
    disclosure_level: DataDisclosureLevel = DataDisclosureLevel.UNKNOWN
    repository_name: Optional[str] = None
    repository_url: Optional[str] = None
    accession_number: Optional[str] = None
    restrictions: List[str] = field(default_factory=list)


@dataclass
class TransparencyReport:
    """Complete transparency analysis report for a study."""
    # Identifiers
    doi: Optional[str] = None
    pmid: Optional[str] = None
    pmcid: Optional[str] = None
    title: Optional[str] = None

    # Publication info
    journal: Optional[str] = None
    publication_date: Optional[datetime] = None
    authors: List[str] = field(default_factory=list)

    # Sponsorship analysis
    sponsor_type: SponsorType = SponsorType.UNKNOWN
    funders: List[FunderInfo] = field(default_factory=list)
    industry_funding_detected: bool = False
    industry_funding_confidence: float = 0.0

    # Trial registration
    trial_registrations: List[TrialRegistration] = field(default_factory=list)
    results_compliance: ResultsComplianceStatus = ResultsComplianceStatus.UNKNOWN

    # Conflicts of interest
    coi_info: Optional[ConflictOfInterest] = None

    # Data availability
    data_availability: Optional[DataAvailabilityInfo] = None

    # Outcome reporting (if trial linked)
    outcome_switching_detected: bool = False
    outcome_switching_details: List[str] = field(default_factory=list)

    # Overall scores
    transparency_score: float = 0.0  # 0-100
    risk_of_bias_indicators: List[str] = field(default_factory=list)

    # Metadata
    analysis_timestamp: datetime = field(default_factory=datetime.now)
    data_sources_used: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    errors: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        """Convert report to dictionary for JSON serialization."""
        d = asdict(self)
        # Convert enums to strings
        d['sponsor_type'] = self.sponsor_type.value
        d['results_compliance'] = self.results_compliance.value
        if self.data_availability:
            d['data_availability']['disclosure_level'] = self.data_availability.disclosure_level.value
        # Convert datetimes to ISO strings
        d['analysis_timestamp'] = self.analysis_timestamp.isoformat()
        if self.publication_date:
            d['publication_date'] = self.publication_date.isoformat()
        for reg in d.get('trial_registrations', []):
            if reg.get('completion_date'):
                reg['completion_date'] = reg['completion_date'].isoformat() if isinstance(reg['completion_date'], datetime) else reg['completion_date']
        return d


# =============================================================================
# KNOWN INDUSTRY FUNDERS DATABASE
# =============================================================================

# CrossRef Funder Registry DOIs for major pharmaceutical companies
KNOWN_INDUSTRY_FUNDER_DOIS = {
    "10.13039/100004319": "Pfizer",
    "10.13039/100004325": "AstraZeneca",
    "10.13039/100004326": "Bayer",
    "10.13039/100004328": "GlaxoSmithKline",
    "10.13039/100004330": "Johnson & Johnson",
    "10.13039/100004331": "Eli Lilly",
    "10.13039/100004334": "Merck",
    "10.13039/100004336": "Novartis",
    "10.13039/100004337": "Novo Nordisk",
    "10.13039/100004339": "Roche",
    "10.13039/100004341": "Sanofi",
    "10.13039/100005564": "Gilead Sciences",
    "10.13039/100006483": "AbbVie",
    "10.13039/100006436": "Celgene",
    "10.13039/100006928": "Amgen",
    "10.13039/100007054": "Bristol-Myers Squibb",
    "10.13039/100008272": "Biogen",
    "10.13039/100008897": "Boehringer Ingelheim",
    "10.13039/100009947": "Takeda",
    "10.13039/100010877": "UCB",
    "10.13039/100014476": "Regeneron",
    "10.13039/100004344": "Teva",
    "10.13039/100007723": "Allergan",
    "10.13039/100004374": "Medtronic",
    "10.13039/100004375": "Boston Scientific",
    "10.13039/100007497": "Abbott",
}

# Keywords indicating industry affiliation in text
INDUSTRY_KEYWORDS = [
    r'\bpharma(?:ceutical)?s?\b',
    r'\bbiotech(?:nology)?\b',
    r'\bmedical device\b',
    r'\bdrug compan(?:y|ies)\b',
    r'\bmanufacturer\b',
    r'\binc\.?\b',
    r'\bcorp(?:oration)?\.?\b',
    r'\bltd\.?\b',
    r'\bgmbh\b',
    r'\bplc\b',
    r'\bemployee of\b',
    r'\bstock(?:holder)?\b',
    r'\bshareholder\b',
    r'\bconsultant for\b',
    r'\badvisory board\b',
    r'\bspeaker(?:\'s)? (?:bureau|fee)\b',
    r'\bhonorari(?:a|um)\b',
    r'\bgrant(?:s)? from\b',
]

# Known pharmaceutical/biotech company names for direct matching in COI text.
# These detect industry ties even when funding is routed through institutions.
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
    r'\btakeda\b', r'\bucb\b', r'\bregeneron\b',
    r'\bteva\b', r'\ballergan\b', r'\bmedtronic\b',
    r'\bboston scientific\b', r'\babbott\b',
    r'\bviatris\b', r'\bcsl behring\b',
    r'\bdaiichi[- ]?sankyo\b', r'\beisai\b',
    r'\bastellas\b', r'\bsumitomo\b',
    r'\bservier\b', r'\bsandoz\b',
    r'\bchugai\b', r'\bkyowa\b', r'\bkowa\b',
    r'\besperion\b', r'\banthos\b',
    r'\bsingulex\b', r'\bcleerly\b',
]

# Patterns for institutional-intermediary industry funding in COI statements.
# These detect the common pattern where pharma money flows to a university/
# institution rather than directly to the author, often phrased as:
#   "funding to the University of X (but no personal funding) from [pharma]"
INSTITUTIONAL_INTERMEDIARY_PATTERNS = [
    # "funding/grants to [institution] from [company]"
    r'(?:funding|grants?|support|contracts?)\s+(?:to|paid to)\s+(?:the\s+)?(?:university|institution|hospital)',
    # "(but no personal funding) from" - classic intermediary disclaimer
    r'(?:but\s+)?no personal (?:funding|payment|honorari)',
    # "grants or contracts to his/her/their institution"
    r'(?:grants?|contracts?|funding)\s+(?:or\s+\w+\s+)?(?:to|paid to)\s+(?:his|her|their)\s+institution',
    # "research grant support through [institution]"
    r'(?:research\s+)?grant\s+support\s+through\b',
    # "salary support from [center] which gets research grant support from"
    r'salary\s+support\s+from\b',
]

# Known government/academic funder patterns
GOVERNMENT_PATTERNS = [
    r'\bnih\b', r'\bnational institutes? of health\b',
    r'\bniaid\b', r'\bnci\b', r'\bnhlbi\b', r'\bnimh\b',
    r'\bnsf\b', r'\bnational science foundation\b',
    r'\bcdc\b', r'\bcenters? for disease control\b',
    r'\bfda\b', r'\bfood and drug administration\b',
    r'\bva\b', r'\bveterans? (?:affairs|administration)\b',
    r'\bahrq\b', r'\bpcori\b',
    r'\bwellcome\b', r'\bmedical research council\b',
    r'\buniversit(?:y|ies)\b', r'\bcollege\b',
    r'\bhospital\b', r'\bmedical (?:center|school)\b',
    r'\bgovernment\b', r'\bfederal\b', r'\bstate\b',
]

# Data repository indicators
DATA_REPOSITORIES = {
    'full_open': [
        r'zenodo', r'figshare', r'dryad', r'osf\.io', r'open science framework',
        r'github', r'gitlab', r'dataverse', r'mendeley data',
        r'gene expression omnibus', r'\bgeo\b', r'arrayexpress',
        r'protein data bank', r'\bpdb\b', r'genbank', r'\bsra\b',
        r'european nucleotide archive', r'\bena\b',
        r'clinicalstudydatarequest', r'vivli', r'yoda',
    ],
    'restricted': [
        r'upon (?:reasonable )?request',
        r'available from (?:the )?(?:corresponding )?author',
        r'contact (?:the )?(?:corresponding )?author',
        r'data sharing agreement',
        r'institutional review board',
        r'irb approval',
        r'ethics committee',
        r'confidential(?:ity)?',
        r'proprietary',
        r'cannot be shared',
        r'not (?:publicly )?available',
        # Effective refusals dressed as policy
        r'(?:would|will|shall) not be (?:released|shared|disclosed|provided)',
        r'not be released to others',
        r'requests?\s+(?:for\s+)?(?:such\s+)?data\s+should\s+be\s+made\s+(?:directly\s+)?to',
        r'on the understanding that\b.*\bnot\b',
        r'used only for the purpose of\b',
        r'agreements?\s+(?:with\s+)?(?:the\s+)?sponsors?\s+prevent',
        r'confidentiality\s+agreements?\s+(?:with\s+)?sponsors?',
        r'data\s+custodians?\b',
    ],
    # Patterns that indicate an effectively unavailable dataset, where the
    # sharing statement reads like a policy but access is systematically denied.
    'effectively_unavailable': [
        # Data restricted to named collaboration with no external access
        r'(?:provided|available)\s+to\s+the\s+\w+\s+(?:collaboration|consortium|group)\s+on\s+the\s+understanding',
        # Multiple restriction signals in same statement
        r'not be released.*(?:data custodians?|directly to)',
        # Sponsor-gated access
        r'(?:confidentiality|agreement)\s+(?:with\s+)?(?:the\s+)?(?:sponsor|industri|pharma|trial\s+(?:owner|sponsor))',
    ],
}

# Strong-refusal indicators that escalate a statement to NOT_AVAILABLE, even
# when a public repository is also named. A subset of the 'restricted'
# patterns. Mirrors the Swift ``DataRepositoryPatterns.strongRefusalPatterns``.
STRONG_REFUSAL_PATTERNS = [
    r'cannot be shared',
    r'not (?:publicly )?available',
    r'proprietary',
    r'(?:would|will|shall) not be (?:released|shared|disclosed|provided)',
    r'not be released to others',
    r'agreements?\s+(?:with\s+)?(?:the\s+)?sponsors?\s+prevent',
    r'confidentiality\s+agreements?\s+(?:with\s+)?sponsors?',
]


# =============================================================================
# RISK INDICATOR STRINGS
# =============================================================================

# Canonical risk-of-bias indicator strings shown in the UI. The Swift
# implementation (Packages/BioMedLit, TransparencyConstants.swift,
# RiskIndicatorStrings) must keep these byte-identical; cross-platform
# tests pin the literals.
RISK_INDICATOR_INDUSTRY_FUNDING = "Industry funding detected"
RISK_INDICATOR_INDUSTRY_RESTRICTED_DATA = "Industry-funded with restricted data access"
RISK_INDICATOR_RESULTS_NOT_POSTED = "Trial results not posted to ClinicalTrials.gov"
RISK_INDICATOR_INDUSTRY_TIES_DISCLOSED = "Authors have disclosed industry financial ties"
RISK_INDICATOR_INSTITUTIONAL_INTERMEDIARY = (
    "Industry funding routed through institutional intermediaries"
)
RISK_INDICATOR_MISSING_COI_STATEMENT = "No conflict of interest statement found"
RISK_INDICATOR_DATA_EFFECTIVELY_UNAVAILABLE = (
    "Data effectively unavailable despite sharing statement"
)
RISK_INDICATOR_DATA_ACCESS_RESTRICTED = "Data access restricted"
RISK_INDICATOR_OUTCOME_SWITCHING = "Outcome switching detected"
RISK_INDICATOR_COMBINED_INDUSTRY_DATA = (
    "Industry ties combined with restricted/unavailable data"
)
RISK_INDICATOR_MISSING_TRIAL_REGISTRATION = "Clinical trial without detected registration"


# =============================================================================
# API CLIENTS
# =============================================================================

class PubMedClient:
    """Client for NCBI PubMed E-utilities API."""

    BASE_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

    def __init__(self, email: str, api_key: Optional[str] = None):
        self.email = email
        self.api_key = api_key
        self.session = requests.Session()
        self._last_request_time = 0

    def _rate_limit(self):
        """Enforce rate limiting (3 requests/sec without API key, 10 with)."""
        min_interval = 0.1 if self.api_key else 0.34
        elapsed = time.time() - self._last_request_time
        if elapsed < min_interval:
            time.sleep(min_interval - elapsed)
        self._last_request_time = time.time()

    def _make_request(self, endpoint: str, params: Dict) -> requests.Response:
        """Make rate-limited request to PubMed API."""
        self._rate_limit()
        params['email'] = self.email
        if self.api_key:
            params['api_key'] = self.api_key
        url = f"{self.BASE_URL}/{endpoint}"
        response = self.session.get(url, params=params, timeout=30)
        response.raise_for_status()
        return response

    def search(self, query: str, max_results: int = 20) -> List[str]:
        """Search PubMed and return list of PMIDs."""
        params = {
            'db': 'pubmed',
            'term': query,
            'retmax': max_results,
            'retmode': 'json',
        }
        response = self._make_request('esearch.fcgi', params)
        data = response.json()
        return data.get('esearchresult', {}).get('idlist', [])

    def fetch_article(self, pmid: str) -> Optional[Dict]:
        """Fetch full article metadata for a PMID."""
        params = {
            'db': 'pubmed',
            'id': pmid,
            'retmode': 'xml',
        }
        response = self._make_request('efetch.fcgi', params)
        return self._parse_pubmed_xml(response.text)

    def convert_ids(self, ids: List[str], from_type: str, to_type: str) -> Dict[str, str]:
        """Convert between ID types (pmid, pmcid, doi)."""
        params = {
            'ids': ','.join(ids),
            'idtype': from_type,
            'format': 'json',
        }
        # Use ID converter API
        url = "https://www.ncbi.nlm.nih.gov/pmc/utils/idconv/v1.0/"
        response = self.session.get(url, params=params, timeout=30)
        data = response.json()

        result = {}
        for record in data.get('records', []):
            source_id = record.get(from_type)
            target_id = record.get(to_type)
            if source_id and target_id:
                result[source_id] = target_id
        return result

    def _parse_pubmed_xml(self, xml_text: str) -> Optional[Dict]:
        """Parse PubMed XML response into structured data."""
        import xml.etree.ElementTree as ET

        try:
            root = ET.fromstring(xml_text)
            article = root.find('.//PubmedArticle')
            if article is None:
                return None

            medline = article.find('MedlineCitation')
            article_elem = medline.find('Article')

            result = {
                'pmid': medline.findtext('PMID'),
                'title': article_elem.findtext('ArticleTitle'),
                'abstract': article_elem.findtext('.//AbstractText'),
                'journal': article_elem.findtext('.//Journal/Title'),
                'pub_date': self._extract_pub_date(article_elem),
                'authors': self._extract_authors(article_elem),
                'grants': self._extract_grants(article_elem),
                'coi_statement': medline.findtext('CoiStatement'),
                'databanks': self._extract_databanks(article_elem),
                'publication_types': self._extract_pub_types(article_elem),
                'mesh_terms': self._extract_mesh_terms(medline),
            }

            # Try to get PMC ID and DOI from article IDs
            for id_elem in article.findall('.//ArticleId'):
                id_type = id_elem.get('IdType')
                if id_type == 'pmc':
                    result['pmcid'] = id_elem.text
                elif id_type == 'doi':
                    result['doi'] = id_elem.text

            return result

        except ET.ParseError as e:
            logger.error(f"Failed to parse PubMed XML: {e}")
            return None

    def _extract_pub_date(self, article_elem) -> Optional[str]:
        """Extract publication date from article element."""
        pub_date = article_elem.find('.//PubDate')
        if pub_date is not None:
            year = pub_date.findtext('Year')
            month = pub_date.findtext('Month', '01')
            day = pub_date.findtext('Day', '01')
            if year:
                # Convert month name to number if needed
                month_map = {'jan': '01', 'feb': '02', 'mar': '03', 'apr': '04',
                            'may': '05', 'jun': '06', 'jul': '07', 'aug': '08',
                            'sep': '09', 'oct': '10', 'nov': '11', 'dec': '12'}
                if month.lower()[:3] in month_map:
                    month = month_map[month.lower()[:3]]
                return f"{year}-{month.zfill(2)}-{day.zfill(2)}"
        return None

    def _extract_authors(self, article_elem) -> List[str]:
        """Extract author names from article element."""
        authors = []
        for author in article_elem.findall('.//Author'):
            lastname = author.findtext('LastName', '')
            forename = author.findtext('ForeName', '')
            if lastname:
                authors.append(f"{lastname}, {forename}".strip(', '))
        return authors

    def _extract_grants(self, article_elem) -> List[Dict]:
        """Extract grant information from article element."""
        grants = []
        for grant in article_elem.findall('.//Grant'):
            grants.append({
                'grant_id': grant.findtext('GrantID'),
                'agency': grant.findtext('Agency'),
                'country': grant.findtext('Country'),
            })
        return grants

    def _extract_databanks(self, article_elem) -> List[Dict]:
        """Extract data bank (trial registry) links."""
        databanks = []
        for databank in article_elem.findall('.//DataBank'):
            db_name = databank.findtext('DataBankName')
            accessions = [acc.text for acc in databank.findall('.//AccessionNumber')]
            databanks.append({
                'name': db_name,
                'accession_numbers': accessions,
            })
        return databanks

    def _extract_pub_types(self, article_elem) -> List[str]:
        """Extract publication types."""
        return [pt.text for pt in article_elem.findall('.//PublicationType')]

    def _extract_mesh_terms(self, medline) -> List[str]:
        """Extract MeSH terms."""
        return [mesh.findtext('DescriptorName')
                for mesh in medline.findall('.//MeshHeading')]


class CrossRefClient:
    """Client for CrossRef API."""

    BASE_URL = "https://api.crossref.org"

    def __init__(self, email: str):
        self.email = email
        self.session = requests.Session()
        self.session.headers.update({
            'User-Agent': f'StudyTransparencyAnalyzer/1.0 (mailto:{email})'
        })
        self._last_request_time = 0

    def _rate_limit(self):
        """Enforce polite rate limiting."""
        elapsed = time.time() - self._last_request_time
        if elapsed < 0.1:
            time.sleep(0.1 - elapsed)
        self._last_request_time = time.time()

    def get_work(self, doi: str) -> Optional[Dict]:
        """Get work metadata by DOI."""
        self._rate_limit()
        # Clean DOI
        doi = doi.replace('https://doi.org/', '').replace('http://doi.org/', '')

        url = f"{self.BASE_URL}/works/{doi}"
        try:
            response = self.session.get(url, timeout=30)
            response.raise_for_status()
            return response.json().get('message')
        except requests.RequestException as e:
            logger.error(f"CrossRef API error for DOI {doi}: {e}")
            return None

    def extract_funders(self, work: Dict) -> List[FunderInfo]:
        """Extract funder information from CrossRef work."""
        funders = []
        for funder in work.get('funder', []):
            funder_doi = funder.get('DOI')
            funder_name = funder.get('name', '')
            award_numbers = funder.get('award', [])

            # Check if known industry funder
            is_industry = funder_doi in KNOWN_INDUSTRY_FUNDER_DOIS
            confidence = 1.0 if is_industry else 0.0

            # Check name patterns if DOI not recognized
            if not is_industry:
                is_industry, confidence = self._classify_funder_by_name(funder_name)

            funders.append(FunderInfo(
                name=funder_name,
                funder_doi=funder_doi,
                award_numbers=award_numbers,
                is_industry=is_industry,
                confidence=confidence
            ))

        return funders

    def _classify_funder_by_name(self, name: str) -> Tuple[bool, float]:
        """Classify funder as industry/non-industry based on name."""
        name_lower = name.lower()

        # Check government/academic patterns first
        for pattern in GOVERNMENT_PATTERNS:
            if re.search(pattern, name_lower):
                return False, 0.8

        # Check industry patterns
        for pattern in INDUSTRY_KEYWORDS[:6]:  # Basic corporate indicators
            if re.search(pattern, name_lower):
                return True, 0.7

        return False, 0.3  # Unknown - low confidence


class ClinicalTrialsClient:
    """Client for ClinicalTrials.gov API v2."""

    BASE_URL = "https://clinicaltrials.gov/api/v2"

    def __init__(self):
        self.session = requests.Session()
        self._last_request_time = 0

    def _rate_limit(self):
        """Enforce rate limiting."""
        elapsed = time.time() - self._last_request_time
        if elapsed < 0.2:
            time.sleep(0.2 - elapsed)
        self._last_request_time = time.time()

    def get_study(self, nct_id: str) -> Optional[Dict]:
        """Get study by NCT ID."""
        self._rate_limit()

        # Normalize NCT ID
        nct_id = nct_id.upper()
        if not nct_id.startswith('NCT'):
            nct_id = f'NCT{nct_id}'

        url = f"{self.BASE_URL}/studies/{nct_id}"
        try:
            response = self.session.get(url, timeout=30)
            response.raise_for_status()
            return response.json()
        except requests.RequestException as e:
            logger.error(f"ClinicalTrials.gov API error for {nct_id}: {e}")
            return None

    def search_by_publication(self, pmid: str = None, doi: str = None) -> List[str]:
        """Search for trials linked to a publication."""
        self._rate_limit()

        # ClinicalTrials.gov doesn't have direct PMID/DOI search in v2
        # This would require scraping or using alternative APIs
        # Returning empty for now - we rely on PubMed DataBank links
        return []

    def extract_trial_info(self, study: Dict) -> TrialRegistration:
        """Extract structured trial information."""
        protocol = study.get('protocolSection', {})

        # Get identification
        id_module = protocol.get('identificationModule', {})
        nct_id = id_module.get('nctId', '')
        title = id_module.get('officialTitle') or id_module.get('briefTitle', '')

        # Get sponsor info
        sponsor_module = protocol.get('sponsorCollaboratorsModule', {})
        lead_sponsor = sponsor_module.get('leadSponsor', {})
        sponsor_name = lead_sponsor.get('name', '')
        sponsor_class = lead_sponsor.get('class', '')  # INDUSTRY, NIH, OTHER, etc.

        # Get outcomes
        outcomes_module = protocol.get('outcomesModule', {})
        primary_outcomes = [
            o.get('measure', '')
            for o in outcomes_module.get('primaryOutcomes', [])
        ]
        secondary_outcomes = [
            o.get('measure', '')
            for o in outcomes_module.get('secondaryOutcomes', [])
        ]

        # Get completion date
        status_module = protocol.get('statusModule', {})
        completion_date = None
        completion_str = status_module.get('completionDateStruct', {}).get('date')
        if completion_str:
            try:
                completion_date = datetime.strptime(completion_str, '%Y-%m-%d')
            except ValueError:
                try:
                    completion_date = datetime.strptime(completion_str, '%Y-%m')
                except ValueError:
                    pass

        # Check if results posted
        has_results = study.get('hasResults', False)

        return TrialRegistration(
            registry='ClinicalTrials.gov',
            registration_id=nct_id,
            title=title,
            sponsor_class=sponsor_class,
            lead_sponsor=sponsor_name,
            results_posted=has_results,
            completion_date=completion_date,
            primary_outcomes_registered=primary_outcomes,
            secondary_outcomes_registered=secondary_outcomes,
        )


class EuropePMCClient:
    """Client for Europe PMC API - better structured data than PubMed."""

    BASE_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest"

    def __init__(self):
        self.session = requests.Session()
        self._last_request_time = 0

    def _rate_limit(self):
        elapsed = time.time() - self._last_request_time
        if elapsed < 0.2:
            time.sleep(0.2 - elapsed)
        self._last_request_time = time.time()

    def get_article(self, pmid: str = None, pmcid: str = None, doi: str = None) -> Optional[Dict]:
        """Get article by various IDs."""
        self._rate_limit()

        if pmid:
            query = f"ext_id:{pmid} src:med"
        elif pmcid:
            pmcid = pmcid.upper().replace('PMC', '')
            query = f"PMCID:PMC{pmcid}"
        elif doi:
            query = f'DOI:"{doi}"'
        else:
            return None

        url = f"{self.BASE_URL}/search"
        params = {
            'query': query,
            'format': 'json',
            'resultType': 'core',
        }

        try:
            response = self.session.get(url, params=params, timeout=30)
            response.raise_for_status()
            data = response.json()
            results = data.get('resultList', {}).get('result', [])
            return results[0] if results else None
        except (requests.RequestException, IndexError) as e:
            logger.error(f"Europe PMC API error: {e}")
            return None

    def get_full_text_xml(self, pmcid: str) -> Optional[str]:
        """Get full text XML for open access articles."""
        self._rate_limit()

        pmcid = pmcid.upper()
        if not pmcid.startswith('PMC'):
            pmcid = f'PMC{pmcid}'

        url = f"{self.BASE_URL}/{pmcid}/fullTextXML"
        try:
            response = self.session.get(url, timeout=30)
            response.raise_for_status()
            return response.text
        except requests.RequestException:
            return None


class OpenAlexClient:
    """Client for OpenAlex API - comprehensive scholarly metadata."""

    BASE_URL = "https://api.openalex.org"

    def __init__(self, email: str):
        self.email = email
        self.session = requests.Session()
        self._last_request_time = 0

    def _rate_limit(self):
        elapsed = time.time() - self._last_request_time
        if elapsed < 0.1:
            time.sleep(0.1 - elapsed)
        self._last_request_time = time.time()

    def get_work(self, doi: str = None, pmid: str = None) -> Optional[Dict]:
        """Get work by DOI or PMID."""
        self._rate_limit()

        if doi:
            doi = doi.replace('https://doi.org/', '')
            url = f"{self.BASE_URL}/works/doi:{doi}"
        elif pmid:
            url = f"{self.BASE_URL}/works/pmid:{pmid}"
        else:
            return None

        params = {'mailto': self.email}

        try:
            response = self.session.get(url, params=params, timeout=30)
            response.raise_for_status()
            return response.json()
        except requests.RequestException as e:
            logger.error(f"OpenAlex API error: {e}")
            return None


# =============================================================================
# ANALYSIS FUNCTIONS
# =============================================================================

def analyze_coi_statement(coi_text: Optional[str]) -> ConflictOfInterest:
    """Analyze conflict of interest statement for industry ties.

    Uses a multi-pass approach:
    1. Scan for named pharmaceutical companies (highest signal).
    2. Detect institutional-intermediary funding patterns where industry
       money flows to a university/institution rather than the author.
    3. Check generic industry keywords.
    4. Only then check for "no conflict" declarations — and only if
       the statement is short and contains no pharma company names.
       Long, detailed COI statements that name pharma companies are
       disclosures, not denials, even if they contain phrases like
       "no personal funding".
    """
    if not coi_text:
        return ConflictOfInterest(
            statement="",
            has_industry_ties=False,
            confidence=0.0
        )

    coi_lower = coi_text.lower()

    # --- Pass 1: Named pharmaceutical company detection ---
    pharma_companies_found = []
    for pattern in KNOWN_PHARMA_NAMES:
        matches = re.findall(pattern, coi_lower)
        if matches:
            pharma_companies_found.extend(matches)

    # --- Pass 2: Institutional intermediary patterns ---
    intermediary_signals = []
    for pattern in INSTITUTIONAL_INTERMEDIARY_PATTERNS:
        if re.search(pattern, coi_lower):
            intermediary_signals.append(pattern)

    # --- Pass 3: Generic industry keywords ---
    industry_keyword_matches = []
    for pattern in INDUSTRY_KEYWORDS:
        matches = re.findall(pattern, coi_lower)
        industry_keyword_matches.extend(matches)

    # --- Pass 4: "No conflict" declarations ---
    # Only trust these if the statement is short (< 500 chars) AND
    # no pharma companies were named. Long COI statements that name
    # specific companies are disclosures, not blanket denials.
    no_conflict_patterns = [
        r'no (?:potential )?conflicts?(?:\s+of\s+interest)?',
        r'nothing to (?:disclose|declare)',
        r'no (?:competing|financial) interests?',
        r'no relationships?(?:\s+to\s+disclose)?',
        r'none (?:declared|to declare)',
        r'no competing interests',
        r'declare no competing interests',
    ]

    blanket_denial = False
    if len(coi_text) < 500 and not pharma_companies_found:
        for pattern in no_conflict_patterns:
            if re.search(pattern, coi_lower):
                blanket_denial = True
                break

    if blanket_denial:
        return ConflictOfInterest(
            statement=coi_text,
            has_industry_ties=False,
            confidence=0.9
        )

    # --- Determine industry ties and confidence ---
    has_industry = False
    confidence = 0.3  # baseline for any statement without clear signals

    # Pharma company names are the strongest signal
    if pharma_companies_found:
        has_industry = True
        n = len(set(pharma_companies_found))
        confidence = min(0.7 + n * 0.03, 0.98)

    # Intermediary patterns boost confidence further
    if intermediary_signals:
        has_industry = True
        confidence = min(confidence + 0.1, 0.98)

    # Generic keywords as fallback
    if industry_keyword_matches and not pharma_companies_found:
        has_industry = True
        confidence = min(0.5 + len(industry_keyword_matches) * 0.1, 0.90)

    # --- Extract specific relationships mentioned ---
    relationships = []
    relationship_patterns = [
        # Direct grants/funding from companies
        r'(?:received|reports?|has|have|declares?|discloses?)\s+'
        r'(?:grants?|funding|honoraria|fees?|payments?|support)\s+'
        r'(?:from|by)\s+([^.;]+)',
        # Institutional grants from companies (the intermediary pattern)
        r'(?:funding|grants?|contracts?|support)\s+'
        r'(?:to\s+(?:the\s+)?(?:university|institution)\s+(?:of\s+)?\w+\s+)?'
        r'(?:\([^)]*\)\s*)?from\s+([^.;]+)',
        # Consulting/advisory roles
        r'(?:consult(?:ant|ing)|advisory board|speaker)\s+(?:for|with)\s+([^.;]+)',
        # Employment
        r'(?:employee|employed)\s+(?:of|by|at)\s+([^.;]+)',
        # Stock/equity
        r'(?:stock|shares?|equity|stock options?)\s+(?:in|of)\s+([^.;]+)',
        # DSMB/steering committee roles for pharma trials
        r'(?:dsmb|data\s+(?:and\s+)?safety\s+monitoring|steering\s+committee)\s+'
        r'(?:for|of|member\s+for)\s+(?:the\s+)?(?:\w+\s+){0,3}(?:trial|study)\s+'
        r'(?:of\s+\w+\s+)?(?:supported\s+by|funded\s+by|from)\s+([^.;]+)',
    ]

    for pattern in relationship_patterns:
        matches = re.findall(pattern, coi_lower)
        relationships.extend(m.strip() for m in matches if len(m.strip()) > 2)

    # Deduplicate and clean
    clean_relationships = []
    seen = set()
    for rel in relationships:
        # Trim overly long captures
        rel = rel[:200].strip().rstrip(',')
        if rel not in seen and len(rel) > 2:
            seen.add(rel)
            clean_relationships.append(rel)

    return ConflictOfInterest(
        statement=coi_text,
        has_industry_ties=has_industry,
        disclosed_relationships=clean_relationships,
        confidence=confidence
    )


def analyze_data_availability(text: Optional[str]) -> DataAvailabilityInfo:
    """Analyze data availability statement.

    Uses a priority-ordered approach:
    1. Check for genuinely open data (public repositories) — but only when the
       statement does not also refuse access. A repository *name* appearing in
       a statement does not by itself prove open access: a statement may name a
       repository while denying access ("genomic data could not be deposited in
       GEO for privacy reasons; the data are not publicly available"). Explicit
       unavailability/refusal signals therefore take precedence over a
       co-occurring repository mention.
    2. Check for effectively unavailable data — statements that read
       like policies but constitute refusals (e.g., "data will not be
       released to others", "confidentiality agreements with sponsors
       prevent disclosure").
    3. Check for restricted/on-request access.
    4. Fall back to UNKNOWN if no patterns match.

    Note: A repository mention combined with a *soft* restriction (e.g. "raw
    data available from the corresponding author upon request") is genuinely
    ambiguous and is deterministically kept as FULL_OPEN here; optional
    LLM-assisted disambiguation of that case is tracked in issue #109.
    """
    if not text:
        return DataAvailabilityInfo(
            disclosure_level=DataDisclosureLevel.NOT_STATED
        )

    text_lower = text.lower()

    # A refusal/unavailability signal anywhere in the statement overrides a
    # co-occurring repository mention, so detect it up front and skip Step 1
    # when present (Step 2 then classifies it as NOT_AVAILABLE).
    has_unavailability_signal = any(
        re.search(pattern, text_lower)
        for pattern in (
            DATA_REPOSITORIES['effectively_unavailable'] + STRONG_REFUSAL_PATTERNS
        )
    )

    # --- Step 1: Check for full open access indicators ---
    if not has_unavailability_signal:
        for repo_pattern in DATA_REPOSITORIES['full_open']:
            if re.search(repo_pattern, text_lower):
                url_match = re.search(r'https?://[^\s<>"]+', text)
                accession_match = re.search(
                    r'(?:accession|identifier)[:\s]+([A-Z0-9]+)', text, re.I
                )

                return DataAvailabilityInfo(
                    statement=text,
                    disclosure_level=DataDisclosureLevel.FULL_OPEN,
                    repository_url=url_match.group(0) if url_match else None,
                    accession_number=(
                        accession_match.group(1) if accession_match else None
                    ),
                )

    # --- Step 2: Check for effectively unavailable data ---
    # These are statements that look like sharing policies but amount
    # to a refusal — data locked behind collaborations, sponsor
    # confidentiality agreements, or systematic gatekeeping.

    # Map patterns to human-readable descriptions for the restrictions list
    _restriction_labels = {
        r'cannot be shared': "Data cannot be shared",
        r'not (?:publicly )?available': "Data not publicly available",
        r'proprietary': "Data described as proprietary",
        r'(?:would|will|shall) not be (?:released|shared|disclosed|provided)':
            "Data will not be released",
        r'not be released to others': "Data will not be released to others",
        r'agreements?\s+(?:with\s+)?(?:the\s+)?sponsors?\s+prevent':
            "Sponsor agreements prevent disclosure",
        r'confidentiality\s+agreements?\s+(?:with\s+)?sponsors?':
            "Confidentiality agreements with sponsors",
        r'upon (?:reasonable )?request': "Available upon request",
        r'available from (?:the )?(?:corresponding )?author':
            "Available from author",
        r'contact (?:the )?(?:corresponding )?author':
            "Contact corresponding author",
        r'data sharing agreement': "Requires data sharing agreement",
        r'institutional review board': "Requires IRB approval",
        r'irb approval': "Requires IRB approval",
        r'ethics committee': "Requires ethics committee approval",
        r'confidential(?:ity)?': "Confidentiality restrictions",
        r'requests?\s+(?:for\s+)?(?:such\s+)?data\s+should\s+be\s+made\s+(?:directly\s+)?to':
            "Data requests redirected to third party",
        r'on the understanding that\b.*\bnot\b':
            "Data provided under restrictive understanding",
        r'used only for the purpose of\b':
            "Data restricted to specific purpose",
        r'data\s+custodians?\b': "Data held by custodians (not authors)",
        r'(?:provided|available)\s+to\s+the\s+\w+\s+(?:collaboration|consortium|group)\s+on\s+the\s+understanding':
            "Data restricted to named collaboration",
        r'not be released.*(?:data custodians?|directly to)':
            "Data will not be released; requests redirected",
        r'(?:confidentiality|agreement)\s+(?:with\s+)?(?:the\s+)?(?:sponsor|industri|pharma|trial\s+(?:owner|sponsor))':
            "Sponsor confidentiality agreement restricts access",
    }

    def _label_for_pattern(pattern: str) -> str:
        return _restriction_labels.get(pattern, pattern)

    effectively_unavailable_signals = []
    for pattern in DATA_REPOSITORIES.get('effectively_unavailable', []):
        if re.search(pattern, text_lower):
            effectively_unavailable_signals.append(_label_for_pattern(pattern))

    strong_refusal_found = any(
        re.search(pattern, text_lower) for pattern in STRONG_REFUSAL_PATTERNS
    )

    if effectively_unavailable_signals or strong_refusal_found:
        restrictions = list(effectively_unavailable_signals)
        for pattern in DATA_REPOSITORIES['restricted']:
            if re.search(pattern, text_lower):
                label = _label_for_pattern(pattern)
                if label not in restrictions:
                    restrictions.append(label)

        return DataAvailabilityInfo(
            statement=text,
            disclosure_level=DataDisclosureLevel.NOT_AVAILABLE,
            restrictions=restrictions,
        )

    # --- Step 3: Check for restricted/on-request access ---
    restrictions = []
    for pattern in DATA_REPOSITORIES['restricted']:
        if re.search(pattern, text_lower):
            restrictions.append(_label_for_pattern(pattern))

    if restrictions:
        return DataAvailabilityInfo(
            statement=text,
            disclosure_level=DataDisclosureLevel.RESTRICTED,
            restrictions=restrictions,
        )

    return DataAvailabilityInfo(
        statement=text,
        disclosure_level=DataDisclosureLevel.UNKNOWN,
    )


def extract_fulltext_sections(fulltext: str) -> Dict[str, str]:
    """Extract transparency-relevant sections from full-text content.

    Scans for common section headers used in biomedical articles and
    returns the text content following each header until the next
    recognised section begins.

    Args:
        fulltext: Plain-text (or simple markdown) article content.

    Returns:
        Dictionary mapping section names to their text content.
        Keys may include: 'coi', 'data_sharing', 'funding',
        'funding_role', 'acknowledgments', 'contributors'.
    """
    # Map of canonical key -> list of header patterns (case-insensitive)
    section_headers: Dict[str, List[str]] = {
        'coi': [
            'declaration of interests',
            'declarations? of interest',
            'conflict of interest',
            'conflicts? of interest',
            'competing interests?',
            'disclosures?',
        ],
        'data_sharing': [
            'data sharing',
            'data availability',
            'data access',
            'availability of data',
        ],
        'funding': [
            'funding',
            'financial support',
            'grant support',
            'sources? of (?:support|funding)',
        ],
        'funding_role': [
            'role of the funding source',
            'role of the funder',
            'role of the sponsor',
            'funder role',
        ],
        'acknowledgments': [
            'acknowledgm?ents?',
        ],
        'contributors': [
            'contributors?',
            'author contributions?',
        ],
    }

    # All possible headers as a flat list (for detecting section boundaries)
    all_header_patterns = []
    for patterns in section_headers.values():
        all_header_patterns.extend(patterns)

    lines = fulltext.split('\n')
    sections: Dict[str, str] = {}

    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or len(stripped) > 120:
            continue

        stripped_lower = stripped.lower()

        for key, patterns in section_headers.items():
            if key in sections:
                continue  # Already found this section

            for pattern in patterns:
                if re.search(
                    rf'^(?:#*\s*)?{pattern}\s*:?\s*$',
                    stripped_lower,
                ):
                    # Found a header — collect content until next section
                    content_lines = []
                    for j in range(i + 1, len(lines)):
                        next_stripped = lines[j].strip()
                        if not next_stripped:
                            content_lines.append('')
                            continue

                        # Stop at next recognised section header
                        if len(next_stripped) <= 120:
                            next_lower = next_stripped.lower()
                            is_next_header = False
                            for hp in all_header_patterns:
                                if re.search(
                                    rf'^(?:#*\s*)?{hp}\s*:?\s*$',
                                    next_lower,
                                ):
                                    is_next_header = True
                                    break
                            # Also stop at references section
                            if re.search(
                                r'^(?:#*\s*)?(?:references?|bibliography|supplementary)\s*',
                                next_lower,
                            ):
                                is_next_header = True

                            if is_next_header:
                                break

                        content_lines.append(next_stripped)

                    text = ' '.join(
                        ln for ln in content_lines if ln
                    ).strip()
                    if text:
                        sections[key] = text
                    break  # Done with this header pattern set

    return sections


def check_results_compliance(trial: TrialRegistration, publication_date: Optional[datetime]) -> ResultsComplianceStatus:
    """Check if trial results posting is compliant with regulations."""

    # FDAAA 2007 requires results within 12 months of completion
    # for applicable clinical trials

    if trial.results_posted:
        # Results are posted - check timing if we have dates
        if trial.completion_date and publication_date:
            deadline = trial.completion_date + timedelta(days=365)
            # This is a simplification - actual compliance is complex
            return ResultsComplianceStatus.COMPLIANT
        return ResultsComplianceStatus.COMPLIANT

    # No results posted
    if trial.completion_date:
        deadline = trial.completion_date + timedelta(days=365)
        if datetime.now() > deadline:
            return ResultsComplianceStatus.MISSING

    return ResultsComplianceStatus.UNKNOWN


def calculate_transparency_score(report: TransparencyReport) -> float:
    """Calculate overall transparency score (0-100).

    Scoring philosophy:
    - Having a COI statement is good (disclosure is valued), but industry
      ties disclosed via COI reduce the score because the underlying
      situation carries bias risk regardless of disclosure quality.
    - Effectively unavailable data is worse than restricted access.
    - Industry ties through institutional intermediaries are scored the
      same as direct ties — the bias risk is the same even if the money
      doesn't reach the author's personal bank account.
    """
    score = 50.0  # Base score

    # Data availability (+/- 20 points)
    if report.data_availability:
        level = report.data_availability.disclosure_level
        if level == DataDisclosureLevel.FULL_OPEN:
            score += 20
        elif level == DataDisclosureLevel.AVAILABLE_ON_REQUEST:
            score += 5
        elif level == DataDisclosureLevel.RESTRICTED:
            score -= 5
        elif level == DataDisclosureLevel.NOT_AVAILABLE:
            score -= 15
        elif level == DataDisclosureLevel.NOT_STATED:
            score -= 5

    # COI disclosure (+/- 15 points)
    if report.coi_info:
        if report.coi_info.statement:
            score += 5  # Credit for having a statement at all
            if report.coi_info.has_industry_ties:
                # Disclosed industry ties: credit for transparency,
                # but the underlying situation carries bias risk
                score -= 5
        else:
            score -= 5  # No COI statement

    # Trial registration (+/- 15 points)
    if report.trial_registrations:
        score += 10  # Has trial registration
        if report.results_compliance == ResultsComplianceStatus.COMPLIANT:
            score += 5
        elif report.results_compliance == ResultsComplianceStatus.MISSING:
            score -= 10

    # Outcome switching penalty
    if report.outcome_switching_detected:
        score -= 15

    # Industry ties combined with restricted data is especially concerning
    has_industry_ties = (
        report.industry_funding_detected
        or (report.coi_info and report.coi_info.has_industry_ties)
    )
    if has_industry_ties:
        if report.data_availability:
            if report.data_availability.disclosure_level in (
                DataDisclosureLevel.NOT_AVAILABLE,
                DataDisclosureLevel.RESTRICTED,
            ):
                score -= 10  # Industry ties + restricted data

    return max(0, min(100, score))


# =============================================================================
# MAIN ANALYZER CLASS
# =============================================================================

class StudyTransparencyAnalyzer:
    """Main class for analyzing study transparency."""

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
                bot-protected downloads. Set to False for mobile/CI
                environments where a browser is unavailable.
            browser_headless: If True, run browser without visible window
            auto_discover_fulltext: If True, automatically attempt full-text
                discovery when no fulltext is provided to analyze().
                Tries cached markdown, Europe PMC XML, Europe PMC PDF,
                cached PDF, and PDF download (with optional browser fallback).
        """
        self.email = email
        self.pubmed = PubMedClient(email, pubmed_api_key)
        self.crossref = CrossRefClient(email)
        self.clinicaltrials = ClinicalTrialsClient()
        self.europepmc = EuropePMCClient()
        self.openalex = OpenAlexClient(email)

        self._unpaywall_email = unpaywall_email or email
        self._use_browser_fallback = use_browser_fallback
        self._browser_headless = browser_headless
        self._auto_discover_fulltext = auto_discover_fulltext

    def analyze(
        self,
        doi: str = None,
        pmid: str = None,
        fulltext: str = None,
    ) -> TransparencyReport:
        """
        Analyze a study for transparency indicators.

        When ``fulltext`` is not provided and ``auto_discover_fulltext``
        is enabled, the analyzer automatically tries to retrieve full-text
        content via:
        1. Cached full-text markdown
        2. Europe PMC XML (converted to markdown)
        3. Europe PMC PDF render
        4. Cached PDF (text extracted)
        5. PDF download via Unpaywall/PMC/publisher (optionally with
           browser fallback, controlled by ``use_browser_fallback``)

        Args:
            doi: Digital Object Identifier
            pmid: PubMed ID
            fulltext: Optional full-text content (plain text or markdown).
                When provided, automatic discovery is skipped.

        Returns:
            TransparencyReport with analysis results
        """
        report = TransparencyReport()

        if not doi and not pmid:
            report.errors.append("Must provide either DOI or PMID")
            return report

        # Store initial identifiers
        report.doi = doi
        report.pmid = pmid

        # Step 1: Get basic metadata and resolve IDs
        self._fetch_basic_metadata(report)

        # Step 2: Auto-discover full text if not provided
        if not fulltext and self._auto_discover_fulltext:
            fulltext = self._discover_fulltext(report)

        # Extract sections from full text
        fulltext_sections = {}
        if fulltext:
            fulltext_sections = extract_fulltext_sections(fulltext)
            if "Full-text" not in report.data_sources_used:
                report.data_sources_used.append("Full-text")
            if fulltext_sections:
                logger.info(
                    "Extracted full-text sections: %s",
                    list(fulltext_sections.keys()),
                )

        # Step 3: Get funder information
        self._fetch_funder_info(report)

        # Step 4: Get trial registration info
        self._fetch_trial_info(report)

        # Step 5: Analyze COI statement (full text overrides API data)
        self._analyze_conflicts(report, fulltext_sections)

        # Step 6: Analyze data availability (full text overrides API data)
        self._analyze_data_availability(report, fulltext_sections)

        # Step 7: Calculate transparency score
        report.transparency_score = calculate_transparency_score(report)

        # Step 8: Generate risk of bias indicators
        self._identify_risk_indicators(report)

        return report

    def _discover_fulltext(self, report: TransparencyReport) -> Optional[str]:
        """Attempt to discover and retrieve full-text content.

        Uses the project's FulltextDiscoverer to try multiple sources
        (cached markdown, Europe PMC XML/PDF, cached PDF, Unpaywall,
        PMC, publisher HTTP, and optionally browser fallback).

        Args:
            report: TransparencyReport with resolved identifiers
                (doi, pmid, pmcid populated by _fetch_basic_metadata).

        Returns:
            Full-text content as string, or None if unavailable.
        """
        try:
            from ..fulltext_discovery import FulltextDiscoverer
        except ImportError:
            logger.debug(
                "fulltext_discovery module not available; "
                "skipping automatic full-text retrieval"
            )
            return None

        doi = report.doi
        pmid = report.pmid
        pmcid = getattr(report, 'pmcid', None)

        if not doi and not pmid and not pmcid:
            return None

        logger.info(
            "Auto-discovering full text: doi=%s, pmid=%s, pmcid=%s",
            doi, pmid, pmcid,
        )

        try:
            discoverer = FulltextDiscoverer(
                unpaywall_email=self._unpaywall_email,
                use_browser_fallback=self._use_browser_fallback,
                browser_headless=self._browser_headless,
            )

            result = discoverer.discover_fulltext(
                pmid=pmid,
                pmcid=pmcid,
                doi=doi,
                title=report.title,
            )

            if result.success and result.markdown_content:
                source = result.source_type.value
                logger.info(
                    "Full-text discovered via %s (%d chars)",
                    source,
                    len(result.markdown_content),
                )
                report.data_sources_used.append(f"Full-text ({source})")
                return result.markdown_content

            if result.is_paywall:
                logger.info(
                    "Full text behind paywall: %s",
                    result.paywall_url or "unknown URL",
                )
                report.warnings.append(
                    f"Full text behind paywall"
                    + (f": {result.paywall_url}" if result.paywall_url else "")
                )
            else:
                logger.info(
                    "Full-text discovery failed: %s",
                    result.error or "unknown reason",
                )

        except Exception as e:
            logger.warning("Full-text discovery error: %s", e)

        return None

    def _fetch_basic_metadata(self, report: TransparencyReport):
        """Fetch and consolidate basic article metadata."""

        # Try PubMed first if we have PMID
        if report.pmid:
            logger.info(f"Fetching PubMed data for PMID {report.pmid}")
            pubmed_data = self.pubmed.fetch_article(report.pmid)

            if pubmed_data:
                report.data_sources_used.append("PubMed")
                report.title = pubmed_data.get('title')
                report.journal = pubmed_data.get('journal')
                report.authors = pubmed_data.get('authors', [])

                if pubmed_data.get('pub_date'):
                    try:
                        report.publication_date = datetime.strptime(
                            pubmed_data['pub_date'], '%Y-%m-%d'
                        )
                    except ValueError:
                        pass

                # Get DOI if not provided
                if not report.doi and pubmed_data.get('doi'):
                    report.doi = pubmed_data['doi']

                # Get PMCID
                if pubmed_data.get('pmcid'):
                    report.pmcid = pubmed_data['pmcid']

                # Store grants for later analysis
                report._pubmed_grants = pubmed_data.get('grants', [])

                # Store COI statement
                report._coi_statement = pubmed_data.get('coi_statement')

                # Store databank links (trial registrations)
                report._databanks = pubmed_data.get('databanks', [])

        # Try CrossRef if we have DOI
        if report.doi:
            logger.info(f"Fetching CrossRef data for DOI {report.doi}")
            crossref_data = self.crossref.get_work(report.doi)

            if crossref_data:
                report.data_sources_used.append("CrossRef")

                # Fill in missing data from CrossRef
                if not report.title:
                    titles = crossref_data.get('title', [])
                    report.title = titles[0] if titles else None

                if not report.journal:
                    containers = crossref_data.get('container-title', [])
                    report.journal = containers[0] if containers else None

                # Store funders for later analysis
                report._crossref_funders = crossref_data.get('funder', [])

        # Try to get PMID from DOI if we don't have it
        if not report.pmid and report.doi:
            try:
                id_mapping = self.pubmed.convert_ids([report.doi], 'doi', 'pmid')
                if report.doi in id_mapping:
                    report.pmid = id_mapping[report.doi]
            except Exception as e:
                logger.warning(f"Could not convert DOI to PMID: {e}")

    def _fetch_funder_info(self, report: TransparencyReport):
        """Analyze funding sources."""

        # Analyze CrossRef funders
        if hasattr(report, '_crossref_funders') and report._crossref_funders:
            for funder_data in report._crossref_funders:
                funder_doi = funder_data.get('DOI')
                funder_name = funder_data.get('name', '')
                award_numbers = funder_data.get('award', [])

                # Check against known industry funders
                is_industry = funder_doi in KNOWN_INDUSTRY_FUNDER_DOIS
                confidence = 1.0 if is_industry else 0.0

                if not is_industry:
                    is_industry, confidence = self.crossref._classify_funder_by_name(funder_name)

                report.funders.append(FunderInfo(
                    name=funder_name,
                    funder_doi=funder_doi,
                    award_numbers=award_numbers,
                    is_industry=is_industry,
                    confidence=confidence
                ))

        # Analyze PubMed grants
        if hasattr(report, '_pubmed_grants') and report._pubmed_grants:
            for grant in report._pubmed_grants:
                agency = grant.get('agency', '')

                # Skip if already have this funder
                if any(f.name.lower() == agency.lower() for f in report.funders):
                    continue

                is_industry, confidence = self.crossref._classify_funder_by_name(agency)

                report.funders.append(FunderInfo(
                    name=agency,
                    award_numbers=[grant.get('grant_id')] if grant.get('grant_id') else [],
                    is_industry=is_industry,
                    confidence=confidence
                ))

        # Determine overall sponsor type
        industry_funders = [f for f in report.funders if f.is_industry]
        gov_academic_funders = [f for f in report.funders if not f.is_industry]

        if industry_funders and not gov_academic_funders:
            report.sponsor_type = SponsorType.INDUSTRY
        elif industry_funders and gov_academic_funders:
            report.sponsor_type = SponsorType.MIXED
        elif gov_academic_funders:
            # Check if academic or government
            has_gov = any(
                any(re.search(p, f.name.lower()) for p in GOVERNMENT_PATTERNS[:10])
                for f in gov_academic_funders
            )
            report.sponsor_type = SponsorType.GOVERNMENT if has_gov else SponsorType.ACADEMIC
        else:
            report.sponsor_type = SponsorType.UNKNOWN

        # Set industry funding flags
        report.industry_funding_detected = len(industry_funders) > 0
        if industry_funders:
            report.industry_funding_confidence = max(f.confidence for f in industry_funders)

    def _fetch_trial_info(self, report: TransparencyReport):
        """Fetch and analyze clinical trial registration information."""

        # Get trial IDs from PubMed databank links
        trial_ids = []
        if hasattr(report, '_databanks'):
            for databank in report._databanks:
                if databank.get('name') in ['ClinicalTrials.gov', 'ISRCTN', 'EudraCT']:
                    trial_ids.extend(databank.get('accession_numbers', []))

        # Fetch each trial
        for trial_id in trial_ids:
            if 'NCT' in trial_id.upper():
                logger.info(f"Fetching ClinicalTrials.gov data for {trial_id}")
                study = self.clinicaltrials.get_study(trial_id)

                if study:
                    report.data_sources_used.append("ClinicalTrials.gov")
                    trial_info = self.clinicaltrials.extract_trial_info(study)
                    report.trial_registrations.append(trial_info)

                    # Update sponsor type if industry
                    if trial_info.sponsor_class == 'INDUSTRY':
                        report.industry_funding_detected = True
                        if report.sponsor_type == SponsorType.UNKNOWN:
                            report.sponsor_type = SponsorType.INDUSTRY
                        elif report.sponsor_type in [SponsorType.GOVERNMENT, SponsorType.ACADEMIC]:
                            report.sponsor_type = SponsorType.MIXED

                    # Check results compliance
                    compliance = check_results_compliance(trial_info, report.publication_date)
                    if compliance != ResultsComplianceStatus.UNKNOWN:
                        report.results_compliance = compliance

    def _analyze_conflicts(
        self,
        report: TransparencyReport,
        fulltext_sections: Optional[Dict[str, str]] = None,
    ):
        """Analyze conflict of interest disclosures.

        Args:
            report: TransparencyReport being built.
            fulltext_sections: Optional dict from extract_fulltext_sections().
                The 'coi' key, if present, takes priority over API data
                because it contains the complete disclosure text.
        """
        # Priority: full-text COI section > PubMed COI statement > Europe PMC
        coi_text = None

        if fulltext_sections and fulltext_sections.get('coi'):
            coi_text = fulltext_sections['coi']
            logger.info("Using COI statement from full-text (%d chars)", len(coi_text))
        else:
            coi_text = getattr(report, '_coi_statement', None)

        # Try to get from Europe PMC if still missing
        if not coi_text and (report.pmid or report.pmcid):
            europepmc_data = self.europepmc.get_article(
                pmid=report.pmid,
                pmcid=report.pmcid
            )
            if europepmc_data:
                report.data_sources_used.append("Europe PMC")

        report.coi_info = analyze_coi_statement(coi_text)

        # Cross-check COI with funding
        if report.industry_funding_detected and report.coi_info:
            if not report.coi_info.has_industry_ties:
                report.warnings.append(
                    "Industry funding detected but COI statement does not mention industry ties"
                )

    def _analyze_data_availability(
        self,
        report: TransparencyReport,
        fulltext_sections: Optional[Dict[str, str]] = None,
    ):
        """Analyze data availability and sharing.

        Args:
            report: TransparencyReport being built.
            fulltext_sections: Optional dict from extract_fulltext_sections().
                The 'data_sharing' key, if present, takes priority over
                Europe PMC XML extraction.
        """
        data_statement = None

        # Priority: full-text data sharing section > Europe PMC XML
        if fulltext_sections and fulltext_sections.get('data_sharing'):
            data_statement = fulltext_sections['data_sharing']
            logger.info("Using data sharing statement from full-text (%d chars)", len(data_statement))
        elif report.pmcid:
            # Fallback: Check Europe PMC for open access full text
            full_text = self.europepmc.get_full_text_xml(report.pmcid)
            if full_text:
                import xml.etree.ElementTree as ET
                try:
                    root = ET.fromstring(full_text)
                    for section in root.findall('.//sec'):
                        title = section.findtext('title', '').lower()
                        if 'data' in title and ('avail' in title or 'shar' in title or 'access' in title):
                            data_statement = ' '.join(section.itertext())
                            break
                except ET.ParseError:
                    pass

        report.data_availability = analyze_data_availability(data_statement)

    def _identify_risk_indicators(self, report: TransparencyReport):
        """Identify potential risk of bias indicators."""

        indicators = []

        # Industry funding without full data sharing
        if report.industry_funding_detected:
            indicators.append(RISK_INDICATOR_INDUSTRY_FUNDING)

            if report.data_availability:
                if report.data_availability.disclosure_level in [
                    DataDisclosureLevel.NOT_AVAILABLE,
                    DataDisclosureLevel.RESTRICTED
                ]:
                    indicators.append(RISK_INDICATOR_INDUSTRY_RESTRICTED_DATA)

        # Missing results on ClinicalTrials.gov
        if report.results_compliance == ResultsComplianceStatus.MISSING:
            indicators.append(RISK_INDICATOR_RESULTS_NOT_POSTED)

        # COI concerns
        if report.coi_info:
            if report.coi_info.has_industry_ties:
                indicators.append(RISK_INDICATOR_INDUSTRY_TIES_DISCLOSED)
                # Check for institutional intermediary pattern
                coi_lower = report.coi_info.statement.lower()
                for pattern in INSTITUTIONAL_INTERMEDIARY_PATTERNS:
                    if re.search(pattern, coi_lower):
                        indicators.append(RISK_INDICATOR_INSTITUTIONAL_INTERMEDIARY)
                        break
            if not report.coi_info.statement:
                indicators.append(RISK_INDICATOR_MISSING_COI_STATEMENT)

        # Data availability concerns
        if report.data_availability:
            if report.data_availability.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE:
                indicators.append(RISK_INDICATOR_DATA_EFFECTIVELY_UNAVAILABLE)
            elif report.data_availability.disclosure_level == DataDisclosureLevel.RESTRICTED:
                indicators.append(RISK_INDICATOR_DATA_ACCESS_RESTRICTED)

        # Outcome switching (kept aligned with the Swift implementation in
        # Packages/BioMedLit TransparencyScorer.identifyRiskIndicators)
        if report.outcome_switching_detected:
            indicators.append(RISK_INDICATOR_OUTCOME_SWITCHING)

        # Combined risk: industry ties + unavailable data
        has_industry_ties = (
            report.industry_funding_detected
            or (report.coi_info and report.coi_info.has_industry_ties)
        )
        if has_industry_ties and report.data_availability:
            if report.data_availability.disclosure_level in (
                DataDisclosureLevel.NOT_AVAILABLE,
                DataDisclosureLevel.RESTRICTED,
            ):
                indicators.append(RISK_INDICATOR_COMBINED_INDUSTRY_DATA)

        # No trial registration for clinical study
        if not report.trial_registrations:
            if report.title and any(kw in report.title.lower() for kw in
                ['trial', 'randomized', 'randomised', 'rct', 'phase i', 'phase ii', 'phase iii']):
                indicators.append(RISK_INDICATOR_MISSING_TRIAL_REGISTRATION)

        # Deduplicate while preserving order
        seen = set()
        unique = []
        for ind in indicators:
            if ind not in seen:
                seen.add(ind)
                unique.append(ind)
        report.risk_of_bias_indicators = unique


# =============================================================================
# COMMAND LINE INTERFACE
# =============================================================================

def main():
    """Command-line interface for the analyzer."""
    import argparse

    parser = argparse.ArgumentParser(
        description='Analyze medical study transparency and industry sponsorship'
    )
    parser.add_argument(
        '--doi',
        help='Digital Object Identifier of the study'
    )
    parser.add_argument(
        '--pmid',
        help='PubMed ID of the study'
    )
    parser.add_argument(
        '--email',
        required=True,
        help='Your email address (required by APIs)'
    )
    parser.add_argument(
        '--api-key',
        help='NCBI API key for higher rate limits'
    )
    parser.add_argument(
        '--output',
        choices=['json', 'text', 'summary'],
        default='summary',
        help='Output format'
    )
    parser.add_argument(
        '--output-file',
        help='Write output to file'
    )
    parser.add_argument(
        '--fulltext',
        help='Path to full-text file (plain text or markdown). '
             'When provided, automatic full-text discovery is skipped.'
    )
    parser.add_argument(
        '--unpaywall-email',
        help='Email for Unpaywall API (defaults to --email)'
    )
    parser.add_argument(
        '--no-browser',
        action='store_true',
        help='Disable Playwright browser fallback for PDF downloads. '
             'Use this in headless/CI/mobile environments.'
    )
    parser.add_argument(
        '--no-fulltext-discovery',
        action='store_true',
        help='Skip automatic full-text discovery entirely. '
             'Only use API metadata (and --fulltext if provided).'
    )

    args = parser.parse_args()

    if not args.doi and not args.pmid:
        parser.error("Must provide either --doi or --pmid")

    # Load full text if provided
    fulltext = None
    if args.fulltext:
        with open(args.fulltext, 'r', encoding='utf-8') as f:
            fulltext = f.read()

    # When fulltext is provided manually, skip auto-discovery
    auto_discover = not args.no_fulltext_discovery and not args.fulltext

    # Run analysis
    analyzer = StudyTransparencyAnalyzer(
        email=args.email,
        pubmed_api_key=args.api_key,
        unpaywall_email=args.unpaywall_email,
        use_browser_fallback=not args.no_browser,
        auto_discover_fulltext=auto_discover,
    )
    report = analyzer.analyze(doi=args.doi, pmid=args.pmid, fulltext=fulltext)

    # Format output
    if args.output == 'json':
        output = json.dumps(report.to_dict(), indent=2)
    elif args.output == 'text':
        output = format_report_text(report)
    else:
        output = format_report_summary(report)

    # Write output
    if args.output_file:
        with open(args.output_file, 'w') as f:
            f.write(output)
        print(f"Report written to {args.output_file}")
    else:
        print(output)


def format_report_summary(report: TransparencyReport) -> str:
    """Format report as brief summary."""
    lines = [
        "=" * 60,
        "STUDY TRANSPARENCY ANALYSIS",
        "=" * 60,
        f"Title: {report.title or 'Unknown'}",
        f"DOI: {report.doi or 'N/A'}",
        f"PMID: {report.pmid or 'N/A'}",
        "",
        f"TRANSPARENCY SCORE: {report.transparency_score:.0f}/100",
        "",
        "KEY FINDINGS:",
        f"  • Sponsor Type: {report.sponsor_type.value.upper()}",
        f"  • Industry Funding: {'YES' if report.industry_funding_detected else 'NO'}"
           + (f" (confidence: {report.industry_funding_confidence:.0%})" if report.industry_funding_detected else ""),
    ]

    if report.data_availability:
        lines.append(f"  • Data Availability: {report.data_availability.disclosure_level.value.replace('_', ' ').title()}")

    if report.trial_registrations:
        lines.append(f"  • Trial Registration: YES ({len(report.trial_registrations)} found)")
        lines.append(f"  • Results Compliance: {report.results_compliance.value.upper()}")
    else:
        lines.append("  • Trial Registration: None found")

    if report.coi_info:
        lines.append(f"  • COI Disclosed: {'YES' if report.coi_info.has_industry_ties else 'NO/None stated'}")

    if report.risk_of_bias_indicators:
        lines.append("")
        lines.append("⚠️  RISK INDICATORS:")
        for indicator in report.risk_of_bias_indicators:
            lines.append(f"  • {indicator}")

    if report.warnings:
        lines.append("")
        lines.append("WARNINGS:")
        for warning in report.warnings:
            lines.append(f"  • {warning}")

    lines.append("")
    lines.append(f"Data sources: {', '.join(report.data_sources_used)}")
    lines.append("=" * 60)

    return "\n".join(lines)


def format_report_text(report: TransparencyReport) -> str:
    """Format report as detailed text."""
    lines = [format_report_summary(report), "", "DETAILED ANALYSIS", "-" * 40]

    if report.funders:
        lines.append("\nFUNDERS:")
        for funder in report.funders:
            industry_tag = " [INDUSTRY]" if funder.is_industry else ""
            lines.append(f"  • {funder.name}{industry_tag}")
            if funder.award_numbers:
                lines.append(f"    Awards: {', '.join(funder.award_numbers)}")

    if report.trial_registrations:
        lines.append("\nTRIAL REGISTRATIONS:")
        for trial in report.trial_registrations:
            lines.append(f"  • {trial.registration_id} ({trial.registry})")
            lines.append(f"    Sponsor: {trial.lead_sponsor} [{trial.sponsor_class}]")
            lines.append(f"    Results Posted: {'Yes' if trial.results_posted else 'No'}")
            if trial.primary_outcomes_registered:
                lines.append(f"    Primary Outcomes: {len(trial.primary_outcomes_registered)}")

    if report.coi_info and report.coi_info.statement:
        lines.append("\nCONFLICT OF INTEREST STATEMENT:")
        lines.append(f"  {report.coi_info.statement[:500]}...")
        if report.coi_info.disclosed_relationships:
            lines.append("  Relationships mentioned:")
            for rel in report.coi_info.disclosed_relationships[:5]:
                lines.append(f"    • {rel}")

    if report.data_availability and report.data_availability.statement:
        lines.append("\nDATA AVAILABILITY:")
        lines.append(f"  Level: {report.data_availability.disclosure_level.value}")
        if report.data_availability.repository_url:
            lines.append(f"  Repository: {report.data_availability.repository_url}")
        if report.data_availability.restrictions:
            lines.append(f"  Restrictions noted: {len(report.data_availability.restrictions)}")

    return "\n".join(lines)


if __name__ == '__main__':
    main()
