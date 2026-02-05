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
    r'\bpharma(?:ceutical)?\b',
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
        r'gene expression omnibus', r'geo', r'arrayexpress',
        r'protein data bank', r'pdb', r'genbank', r'sra',
        r'european nucleotide archive', r'ena',
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
    ]
}


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
    """Analyze conflict of interest statement for industry ties."""
    if not coi_text:
        return ConflictOfInterest(
            statement="",
            has_industry_ties=False,
            confidence=0.0
        )

    coi_lower = coi_text.lower()

    # Check for explicit "no conflicts" statements
    no_conflict_patterns = [
        r'no (?:potential )?conflict',
        r'nothing to (?:disclose|declare)',
        r'no (?:competing|financial) interest',
        r'no relationship',
        r'none (?:declared|to declare)',
    ]

    for pattern in no_conflict_patterns:
        if re.search(pattern, coi_lower):
            return ConflictOfInterest(
                statement=coi_text,
                has_industry_ties=False,
                confidence=0.9
            )

    # Check for industry-related keywords
    industry_matches = []
    for pattern in INDUSTRY_KEYWORDS:
        matches = re.findall(pattern, coi_lower)
        industry_matches.extend(matches)

    has_industry = len(industry_matches) > 0
    confidence = min(0.5 + len(industry_matches) * 0.1, 0.95) if has_industry else 0.5

    # Extract specific relationships mentioned
    relationships = []
    relationship_patterns = [
        r'(?:received|reports?|has|have) (?:grants?|funding|honoraria|fees?|payments?) from ([^.;]+)',
        r'(?:consultant|advisory board|speaker) for ([^.;]+)',
        r'employee of ([^.;]+)',
        r'(?:stock|shares?|equity) in ([^.;]+)',
    ]

    for pattern in relationship_patterns:
        matches = re.findall(pattern, coi_lower)
        relationships.extend(matches)

    return ConflictOfInterest(
        statement=coi_text,
        has_industry_ties=has_industry,
        disclosed_relationships=list(set(relationships)),
        confidence=confidence
    )


def analyze_data_availability(text: Optional[str]) -> DataAvailabilityInfo:
    """Analyze data availability statement."""
    if not text:
        return DataAvailabilityInfo(
            disclosure_level=DataDisclosureLevel.NOT_STATED
        )

    text_lower = text.lower()

    # Check for full open access indicators
    for repo_pattern in DATA_REPOSITORIES['full_open']:
        if re.search(repo_pattern, text_lower):
            # Try to extract repository URL
            url_match = re.search(r'https?://[^\s<>"]+', text)
            accession_match = re.search(r'(?:accession|identifier)[:\s]+([A-Z0-9]+)', text, re.I)

            return DataAvailabilityInfo(
                statement=text,
                disclosure_level=DataDisclosureLevel.FULL_OPEN,
                repository_url=url_match.group(0) if url_match else None,
                accession_number=accession_match.group(1) if accession_match else None
            )

    # Check for restricted access indicators
    restrictions = []
    for pattern in DATA_REPOSITORIES['restricted']:
        if re.search(pattern, text_lower):
            restrictions.append(pattern)

    if restrictions:
        if any(p in ['cannot be shared', 'not (?:publicly )?available', 'proprietary']
               for p in restrictions):
            return DataAvailabilityInfo(
                statement=text,
                disclosure_level=DataDisclosureLevel.NOT_AVAILABLE,
                restrictions=restrictions
            )
        else:
            return DataAvailabilityInfo(
                statement=text,
                disclosure_level=DataDisclosureLevel.AVAILABLE_ON_REQUEST,
                restrictions=restrictions
            )

    return DataAvailabilityInfo(
        statement=text,
        disclosure_level=DataDisclosureLevel.UNKNOWN
    )


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
    """Calculate overall transparency score (0-100)."""
    score = 50.0  # Base score

    # Data availability (+/- 20 points)
    if report.data_availability:
        level = report.data_availability.disclosure_level
        if level == DataDisclosureLevel.FULL_OPEN:
            score += 20
        elif level == DataDisclosureLevel.AVAILABLE_ON_REQUEST:
            score += 10
        elif level == DataDisclosureLevel.RESTRICTED:
            score += 0
        elif level == DataDisclosureLevel.NOT_AVAILABLE:
            score -= 10
        elif level == DataDisclosureLevel.NOT_STATED:
            score -= 5

    # COI disclosure (+/- 10 points)
    if report.coi_info:
        if report.coi_info.statement:
            score += 10  # Has COI statement
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

    # Industry funding without full disclosure
    if report.industry_funding_detected:
        if report.data_availability and report.data_availability.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE:
            score -= 10

    return max(0, min(100, score))


# =============================================================================
# MAIN ANALYZER CLASS
# =============================================================================

class StudyTransparencyAnalyzer:
    """Main class for analyzing study transparency."""

    def __init__(self, email: str, pubmed_api_key: Optional[str] = None):
        """
        Initialize the analyzer.

        Args:
            email: Contact email (required by APIs)
            pubmed_api_key: Optional NCBI API key for higher rate limits
        """
        self.pubmed = PubMedClient(email, pubmed_api_key)
        self.crossref = CrossRefClient(email)
        self.clinicaltrials = ClinicalTrialsClient()
        self.europepmc = EuropePMCClient()
        self.openalex = OpenAlexClient(email)

    def analyze(self, doi: str = None, pmid: str = None) -> TransparencyReport:
        """
        Analyze a study for transparency indicators.

        Args:
            doi: Digital Object Identifier
            pmid: PubMed ID

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

        # Step 2: Get funder information
        self._fetch_funder_info(report)

        # Step 3: Get trial registration info
        self._fetch_trial_info(report)

        # Step 4: Analyze COI statement
        self._analyze_conflicts(report)

        # Step 5: Analyze data availability
        self._analyze_data_availability(report)

        # Step 6: Calculate transparency score
        report.transparency_score = calculate_transparency_score(report)

        # Step 7: Generate risk of bias indicators
        self._identify_risk_indicators(report)

        return report

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

    def _analyze_conflicts(self, report: TransparencyReport):
        """Analyze conflict of interest disclosures."""

        coi_text = getattr(report, '_coi_statement', None)

        # Try to get from Europe PMC if not in PubMed
        if not coi_text and (report.pmid or report.pmcid):
            europepmc_data = self.europepmc.get_article(
                pmid=report.pmid,
                pmcid=report.pmcid
            )
            if europepmc_data:
                report.data_sources_used.append("Europe PMC")
                # Europe PMC may have COI in full text

        report.coi_info = analyze_coi_statement(coi_text)

        # Cross-check COI with funding
        if report.industry_funding_detected and report.coi_info:
            if not report.coi_info.has_industry_ties:
                report.warnings.append(
                    "Industry funding detected but COI statement does not mention industry ties"
                )

    def _analyze_data_availability(self, report: TransparencyReport):
        """Analyze data availability and sharing."""

        # Try to get data availability statement from full text
        data_statement = None

        # Check Europe PMC for open access full text
        if report.pmcid:
            full_text = self.europepmc.get_full_text_xml(report.pmcid)
            if full_text:
                # Extract data availability section
                import xml.etree.ElementTree as ET
                try:
                    root = ET.fromstring(full_text)
                    # Look for data availability in various locations
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
            indicators.append("Industry funding detected")

            if report.data_availability:
                if report.data_availability.disclosure_level in [
                    DataDisclosureLevel.NOT_AVAILABLE,
                    DataDisclosureLevel.RESTRICTED
                ]:
                    indicators.append("Industry-funded with restricted data access")

        # Missing results on ClinicalTrials.gov
        if report.results_compliance == ResultsComplianceStatus.MISSING:
            indicators.append("Trial results not posted to ClinicalTrials.gov")

        # COI concerns
        if report.coi_info:
            if report.coi_info.has_industry_ties:
                indicators.append("Authors have industry financial ties")
            if not report.coi_info.statement:
                indicators.append("No conflict of interest statement found")

        # No trial registration for clinical study
        if not report.trial_registrations:
            # Check if this appears to be a clinical trial
            if report.title and any(kw in report.title.lower() for kw in
                ['trial', 'randomized', 'randomised', 'rct', 'phase i', 'phase ii', 'phase iii']):
                indicators.append("Clinical trial without detected registration")

        report.risk_of_bias_indicators = indicators


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

    args = parser.parse_args()

    if not args.doi and not args.pmid:
        parser.error("Must provide either --doi or --pmid")

    # Run analysis
    analyzer = StudyTransparencyAnalyzer(args.email, args.api_key)
    report = analyzer.analyze(doi=args.doi, pmid=args.pmid)

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
