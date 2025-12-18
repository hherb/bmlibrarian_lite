"""
Pytest configuration and fixtures for BMLibrarian Lite tests.

Provides shared fixtures for testing:
- Temporary directories for file storage tests
- Mock HTTP responses for API tests
- Sample document metadata
"""

import json
import tempfile
from pathlib import Path
from typing import Any, Dict, Generator
from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def temp_dir() -> Generator[Path, None, None]:
    """Create a temporary directory for test files."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


@pytest.fixture
def sample_doc_dict() -> Dict[str, Any]:
    """Sample document dictionary for testing."""
    return {
        "pmid": "39521399",
        "pmcid": "PMC12101959",
        "doi": "10.1053/j.ajkd.2024.08.012",
        "title": "Stopping Versus Continuing Metformin in Patients With Advanced CKD",
        "year": 2025,
        "id": "pmid-39521399",
    }


@pytest.fixture
def sample_doc_dict_no_pmc() -> Dict[str, Any]:
    """Sample document dictionary without PMC ID."""
    return {
        "pmid": "38992869",
        "doi": "10.1007/s11892-024-01550-0",
        "title": "Current type 2 diabetes guidelines",
        "year": 2024,
        "id": "pmid-38992869",
    }


@pytest.fixture
def sample_europepmc_search_response() -> Dict[str, Any]:
    """Sample Europe PMC search API response."""
    return {
        "resultList": {
            "result": [
                {
                    "pmid": "39521399",
                    "pmcid": "PMC12101959",
                    "doi": "10.1053/j.ajkd.2024.08.012",
                    "title": "Stopping Versus Continuing Metformin",
                    "journalTitle": "American Journal of Kidney Diseases",
                    "pubYear": "2025",
                    "abstractText": "Despite a lack of supporting evidence...",
                    "isOpenAccess": "Y",
                    "inEPMC": "Y",
                    "inPMC": "Y",
                    "hasPDF": "N",
                    "authorList": {
                        "author": [
                            {"fullName": "Emilie J. Lambourg"},
                            {"fullName": "Edouard L. Fu"},
                        ]
                    },
                }
            ]
        }
    }


@pytest.fixture
def sample_jats_xml() -> str:
    """Sample JATS XML for testing XML to markdown conversion."""
    return """<?xml version="1.0" encoding="UTF-8"?>
<article>
  <front>
    <journal-meta>
      <journal-title>Test Journal</journal-title>
    </journal-meta>
    <article-meta>
      <title-group>
        <article-title>Test Article Title</article-title>
      </title-group>
      <contrib-group>
        <contrib contrib-type="author">
          <name>
            <given-names>John</given-names>
            <surname>Doe</surname>
          </name>
        </contrib>
      </contrib-group>
      <pub-date>
        <year>2024</year>
      </pub-date>
      <article-id pub-id-type="doi">10.1234/test.2024</article-id>
      <abstract>
        <p>This is the abstract text.</p>
      </abstract>
    </article-meta>
  </front>
  <body>
    <sec>
      <title>Introduction</title>
      <p>This is the introduction paragraph.</p>
    </sec>
    <sec>
      <title>Methods</title>
      <p>This is the methods paragraph.</p>
    </sec>
  </body>
  <back>
    <ref-list>
      <ref id="ref1">
        <mixed-citation>Smith J. et al. (2023) Test Reference.</mixed-citation>
      </ref>
    </ref-list>
  </back>
</article>"""


@pytest.fixture
def mock_requests_session():
    """Mock requests session for HTTP tests."""
    with patch("requests.Session") as mock_session:
        session_instance = MagicMock()
        mock_session.return_value = session_instance
        yield session_instance
