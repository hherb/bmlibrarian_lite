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
from bmlibrarian_lite.pdf_discovery import PDFDiscoverer
from bmlibrarian_lite.polite_session import PoliteAdapter
from bmlibrarian_lite.pubmed.search_client import PubMedSearchClient


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

    def test_the_pubmed_client_has_no_private_delay(self) -> None:
        """Its 0.34s was right, and right per instance only."""
        import inspect

        from bmlibrarian_lite.pubmed import search_client

        assert "self.request_delay" not in inspect.getsource(search_client)
