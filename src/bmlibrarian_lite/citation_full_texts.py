# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Fetching the full texts that citation extraction reads.

Through the same discovery chain the transparency analysis and the Document
Interrogation tab use, so a text one of them cached is read from the cache.
Nothing here imports Qt.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Sequence
from typing import TYPE_CHECKING, Any

from .elsevier_api import ElsevierCredentials
from .fulltext_discovery import FulltextDiscoverer
from .transparency.assessment import contact_email, unpaywall_contact_email

if TYPE_CHECKING:
    from .config import LiteConfig
    from .data_models import LiteDocument

logger = logging.getLogger(__name__)

#: Fetches one paper's full text, or ``None`` when none was obtained.
FullTextFetch = Callable[["LiteDocument"], "str | None"]


def discovery_identifiers(doc: LiteDocument) -> dict[str, Any]:
    """The identifiers full-text discovery looks a paper up by.

    Args:
        doc: The paper.

    Returns:
        Its id, DOI, PMID (read from a ``pmid-`` id when the field is empty),
        PMC ID under both keys discovery reads, title and year.
    """
    pmid = doc.pmid
    if not pmid and doc.id and doc.id.startswith("pmid-"):
        pmid = doc.id[len("pmid-"):]
    return {
        "id": doc.id,
        "doi": doc.doi,
        "pmid": pmid,
        "pmcid": doc.pmc_id,
        "pmc_id": doc.pmc_id,
        "title": doc.title,
        "year": doc.year,
    }


def full_text_fetcher(config: LiteConfig) -> FullTextFetch:
    """A fetch of full texts with the configured contacts and keys.

    Args:
        config: The configuration.

    Returns:
        The fetch: the full text discovery obtained, or ``None``.
    """
    discoverer = FulltextDiscoverer(
        unpaywall_email=unpaywall_contact_email(config),
        openalex_email=contact_email(config),
        core_api_key=config.discovery.core_api_key or None,
        elsevier_credentials=ElsevierCredentials.from_config(config.discovery),
    )

    def fetch(doc: LiteDocument) -> str | None:
        result = discoverer.discover_fulltext(doc_dict=discovery_identifiers(doc))
        if result.set_aside_pdf_note:
            # Logged only; the paper's transparency analysis, when on, tells the reader
            logger.warning("%s: %s", doc.id, result.set_aside_pdf_note)
        if result.success and result.markdown_content:
            return result.markdown_content
        logger.info(
            "No full text for %s (%s): its abstract is read",
            doc.id,
            result.source_type.value,
        )
        return None

    return fetch


def fetch_full_texts(
    fetch: FullTextFetch,
    documents: Sequence[LiteDocument],
    should_stop: Callable[[], bool],
    progress: Callable[[int, int], None] | None = None,
) -> dict[str, str]:
    """Fetch the full texts of papers, one at a time.

    One at a time: the chain asks rate-limited sources, and a PDF can take
    minutes. A fetch that fails leaves its paper to be read from its
    abstract, which the report's methodology counts.

    Args:
        fetch: Fetches one paper's full text.
        documents: The papers.
        should_stop: Asked before each paper; true stops the fetching.
        progress: Told (position, total) before each paper.

    Returns:
        Each paper's full text by its id, for those that have one.
    """
    texts: dict[str, str] = {}
    for position, doc in enumerate(documents, start=1):
        if should_stop():
            break
        if progress:
            progress(position, len(documents))
        try:
            text = fetch(doc)
        except Exception:
            logger.exception("Full text could not be fetched for %s", doc.id)
            continue
        if text and text.strip():
            texts[doc.id] = text
    return texts
