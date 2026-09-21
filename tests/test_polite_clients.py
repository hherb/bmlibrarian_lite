# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Every client that talks to a third party is paced.

The clients here had none at all. Europe PMC is the one with measured harm:
503 after about two rapid requests.

The ``pubmed`` client is added in Task 4, once ``PubMedSearchClient`` gets a
``_session`` attribute of its own; including it here would commit a
knowingly-failing test.
"""

import pytest

from bmlibrarian_lite.europepmc import EuropePMCClient
from bmlibrarian_lite.pdf_discovery import PDFDiscoverer
from bmlibrarian_lite.polite_session import PoliteAdapter


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
