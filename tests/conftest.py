# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""
Pytest configuration and fixtures for BMLibrarian Lite tests.

Provides shared fixtures for testing:
- Temporary directories for file storage tests
- Mock HTTP responses for API tests
- Sample document metadata
"""

import importlib.util
import json
import tempfile
from pathlib import Path
from typing import Any, Dict, Generator
from unittest.mock import MagicMock, patch

import pytest

from bmlibrarian_lite.rate_limit import reset_limiters


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
        "hitCount": 1,
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


@pytest.fixture(autouse=True)
def _forget_pacing_state() -> Generator[None, None, None]:
    """Give every test an empty limiter registry.

    The registry is process-wide, so a limiter one test penalised -- or one
    built over a no-sleep fake -- otherwise leaks into every test that runs
    after it. Both directions are bad: a real limiter left at a 20s interval
    makes some later, unrelated test sleep for 20 real seconds with no
    obvious cause, and a fake one silently disables the pacing a later test
    means to assert. Autouse, because the tests that need this are exactly
    the ones that have not thought about it.
    """
    reset_limiters()
    yield
    reset_limiters()


class _OpenAlexKnowsNoWork:
    """OpenAlex knowing no work by any DOI: the answer that adds nothing."""

    mailto = None

    def fetch_pdf_urls(self, doi: str) -> Any:
        """Answer every DOI as unknown, without a request."""
        from bmlibrarian_lite.openalex import OpenAlexWorkFetch

        return OpenAlexWorkFetch.absent()


@pytest.fixture(autouse=True)
def _no_live_openalex(
    request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Keep every PDF discovery off the real OpenAlex (#480, stage B).

    A discovery that exhausts its sources now asks OpenAlex; dozens of
    existing tests end there with a DOI. They get OpenAlex's "no such work",
    which records nothing, so their outcomes are what they were. A test that
    injects its own client is unaffected; one that needs the real default
    marks itself ``real_openalex_client``.
    """
    if request.node.get_closest_marker("real_openalex_client"):
        return
    monkeypatch.setattr(
        "bmlibrarian_lite.pdf_discovery.default_openalex_client",
        lambda mailto: _OpenAlexKnowsNoWork(),
    )


@pytest.fixture(autouse=True)
def _no_live_core(
    request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Keep every discovery off the real CORE (#480, stage C).

    No key means no client, which is what a user without one has; a test
    that wants CORE passes its own client. A CORE_API_KEY in the developer's
    environment must not reach the network from the suite.
    """
    from bmlibrarian_lite.core_api import reset_core_throttle

    reset_core_throttle()
    monkeypatch.delenv("CORE_API_KEY", raising=False)
    if request.node.get_closest_marker("real_core_client"):
        return
    monkeypatch.setattr(
        "bmlibrarian_lite.fulltext_discovery.default_core_client",
        lambda api_key: None,
    )


@pytest.fixture(autouse=True)
def _no_live_elsevier(
    request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Keep every discovery off the real Elsevier (#480, stage C2).

    No key means no client, which is what a user without one has; a test
    that wants Elsevier passes its own client. An ELSEVIER_API_KEY or
    ELSEVIER_INSTTOKEN in the developer's environment must not reach the
    network from the suite, and each test starts with a fresh session (no
    pause, nothing refused). A test that needs the real default marks itself
    ``real_elsevier_client``.
    """
    from bmlibrarian_lite import elsevier_api

    elsevier_api.reset_elsevier_session()
    monkeypatch.delenv("ELSEVIER_API_KEY", raising=False)
    monkeypatch.delenv("ELSEVIER_INSTTOKEN", raising=False)
    if request.node.get_closest_marker("real_elsevier_client"):
        return
    monkeypatch.setattr(
        elsevier_api, "default_elsevier_client", lambda api_key, insttoken: None
    )


@pytest.fixture(autouse=True)
def _no_live_model_fetch(
    request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Keep every settings dialog off the real providers.

    Building a ``SettingsDialog`` starts a thread per enabled provider that
    asks Anthropic or Ollama for its models, and a Test Connection click
    starts another. In a test those threads reached the live endpoints and
    outlived the test: the dialog is never collected, since its buttons hold
    lambdas that capture it. The PySide6 6.12 segfault at exit is a separate
    matter, which this fixture does not prevent (#516). Nothing is started
    here; the dialog keeps the models it starts with. A test that needs the
    real threads marks itself ``real_model_fetch``.
    """
    if request.node.get_closest_marker("real_model_fetch"):
        return
    if importlib.util.find_spec("PySide6") is None:
        return
    try:
        from bmlibrarian_lite.gui import settings_dialog
    except ImportError:
        # Qt is installed but cannot load (no libGL on a bare machine, say):
        # no test can build a dialog then, and the GUI tests fail on their own.
        return

    for worker in (
        settings_dialog.ModelFetchWorker,
        settings_dialog.ProviderConnectionTestWorker,
    ):
        monkeypatch.setattr(worker, "start", lambda self, *args, **kwargs: None)
