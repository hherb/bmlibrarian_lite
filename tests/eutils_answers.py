# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""E-utilities answers for the scripted test server, shaped like NCBI's real ones."""

from tests.scripted_http_server import ScriptedAnswer, json_answer, xml_answer

ESEARCH_PATH = "/esearch.fcgi"
EFETCH_PATH = "/efetch.fcgi"


def esearch_hits(pmids: list[str], count: int | None = None, **extra: str) -> ScriptedAnswer:
    """An esearch answer listing PMIDs, shaped like NCBI's.

    Args:
        pmids: The PMIDs in ``idlist``.
        count: The total ``count``; defaults to the number of PMIDs.
        **extra: Further ``esearchresult`` fields, such as ``webenv``.

    Returns:
        The scripted answer.
    """
    total = len(pmids) if count is None else count
    return json_answer(
        {
            "header": {"type": "esearch", "version": "0.3"},
            "esearchresult": {
                "count": str(total),
                "retmax": str(len(pmids)),
                "retstart": "0",
                "idlist": pmids,
                **extra,
            },
        }
    )


def pubmed_articles(pmids: list[str]) -> ScriptedAnswer:
    """An efetch answer holding one minimal article per PMID.

    Args:
        pmids: The PMIDs to include.

    Returns:
        The scripted answer.
    """
    articles = "".join(
        "<PubmedArticle><MedlineCitation>"
        f"<PMID>{pmid}</PMID><Article><ArticleTitle>Title {pmid}</ArticleTitle>"
        f"<Abstract><AbstractText>Abstract {pmid}</AbstractText></Abstract>"
        "</Article></MedlineCitation></PubmedArticle>"
        for pmid in pmids
    )
    return xml_answer(f'<?xml version="1.0" ?><PubmedArticleSet>{articles}</PubmedArticleSet>')
