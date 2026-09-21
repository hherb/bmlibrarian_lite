# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Every client that talks to a third party is paced.

The clients here had none at all. Europe PMC is the one with measured harm:
503 after about two rapid requests.

The ``pubmed`` client joined this list in Task 4, once ``PubMedSearchClient``
gained a ``_session`` attribute of its own.
"""

import pytest

from bmlibrarian_lite.europepmc import EuropePMCClient
from bmlibrarian_lite.exceptions import SourceRequestError
from bmlibrarian_lite.pdf_discovery import PDFDiscoverer
from bmlibrarian_lite.polite_session import PoliteAdapter
from bmlibrarian_lite.pubmed.constants import ESEARCH_URL
from bmlibrarian_lite.pubmed.search_client import PubMedSearchClient
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    ClinicalTrialsClient,
    CrossRefClient,
    OpenAlexClient,
    PubMedClient,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    EuropePMCClient as TransparencyEuropePMCClient,
)


def adapters(session: object) -> list[object]:
    """Every adapter a session has mounted.

    Args:
        session: The session to inspect.

    Returns:
        The adapters.
    """
    return list(session.adapters.values())


CLIENTS = [
    pytest.param(lambda: EuropePMCClient()._session, id="europepmc"),
    pytest.param(lambda: PDFDiscoverer()._session, id="pdf_discovery"),
    pytest.param(lambda: PubMedSearchClient()._session, id="pubmed"),
]


@pytest.mark.parametrize("build", CLIENTS)
class TestEveryClientIsPaced:
    """A client that forgot to pace is the defect this prevents."""

    def test_every_adapter_is_polite(self, build: object) -> None:
        """Both schemes, so an http:// redirect is paced too."""
        session = build()

        mounted = adapters(session)
        assert mounted, "the session mounts no adapter at all"
        assert all(isinstance(a, PoliteAdapter) for a in mounted)


class TestTheAdHocLimitersAreGone:
    """One place decides pacing, so there is one place to get it right."""

    def test_the_transparency_analyzer_has_no_private_limiter(self) -> None:
        """It was per-instance and unlocked, under a thread pool."""
        import inspect

        from bmlibrarian_lite.study_transparency_analyzer import (
            study_transparency_analyzer as module,
        )

        assert "_rate_limit" not in inspect.getsource(module)


class TestTheRequestGoesThroughTheMountedSession:
    """Mounting pacing is worth nothing if the call site bypasses it.

    Asserting that the session *has* polite adapters does not test this: the
    PubMed client is the one that used to call ``requests.post`` directly,
    and reverting it to that restored completely unpaced NCBI traffic under
    a thread pool while every test stayed green. A source grep for the old
    attribute name did not catch it either -- a revert need not bring the
    name back.
    """

    def test_the_pubmed_client_posts_through_its_own_session(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A bare ``requests.post`` would be unpaced, and is now a failure."""
        import requests

        client = PubMedSearchClient()
        used: list[str] = []

        def refuse(*args: object, **kwargs: object) -> None:
            """Fail loudly if the module-level requests API is used.

            Args:
                *args: Ignored.
                **kwargs: Ignored.

            Raises:
                AssertionError: Always; this path must not be taken.
            """
            raise AssertionError("the client bypassed its polite session")

        def record(*args: object, **kwargs: object) -> object:
            """Record that the session was used, and stop the request there.

            Args:
                *args: Ignored.
                **kwargs: Ignored.

            Raises:
                requests.ConnectionError: To end the call without a socket.
            """
            used.append("session")
            raise requests.ConnectionError("stopped in the test")

        monkeypatch.setattr(requests, "post", refuse)
        monkeypatch.setattr(client._session, "post", record)
        client.max_retries = 1

        with pytest.raises(SourceRequestError):
            client._make_request(ESEARCH_URL, {"term": "aspirin"})

        assert used == ["session"]


#: The transparency clients, each of which owns its own request loop and so
#: must make exactly one physical request per call, as it did before pacing
#: was mounted on it.
TRANSPARENCY_CLIENTS = [
    pytest.param(
        lambda: PubMedClient(email="researcher@example.org").session, id="pubmed"
    ),
    pytest.param(
        lambda: CrossRefClient(email="researcher@example.org").session, id="crossref"
    ),
    pytest.param(lambda: ClinicalTrialsClient().session, id="clinicaltrials"),
    pytest.param(lambda: TransparencyEuropePMCClient().session, id="europepmc"),
    pytest.param(
        lambda: OpenAlexClient(email="researcher@example.org").session, id="openalex"
    ),
]


@pytest.mark.parametrize("build", TRANSPARENCY_CLIENTS)
class TestTheTransparencyClientsDidNotQuadrupleTheirRequests:
    """Pacing must not multiply the traffic it exists to reduce.

    Left to the adapter's default budget, a persistent 503 from
    ``www.ebi.ac.uk`` -- whose budget the main search path shares -- would
    cost four requests where it used to cost one.
    """

    def test_the_adapter_retries_a_throttle_zero_times(self, build: object) -> None:
        """One call, one physical request, as before the pacing branch."""
        session = build()

        for adapter in adapters(session):
            assert isinstance(adapter, PoliteAdapter)
            assert adapter._max_throttle_retries == 0
