"""A PubMed record's own identifiers, read from the record asked about.

An efetch ``PubmedArticle`` carries identifiers in more than one place. Its
own sit at ``PubmedData/ArticleIdList``; every cited paper in
``PubmedData/ReferenceList`` carries an ``ArticleIdList`` of its own, and a
``.//ArticleId`` search reaches those too. The transparency analyser took
the last match, so PMID 33301246 yielded a cited paper's PMC ID and DOI and
its conflict-of-interest and data-availability ratings could come from
another article's full text (bmlib#474 and the defect beside it).

A body can also hold records other than the one asked about, or only a
record for another PMID; the record is selected by its own
``MedlineCitation/PMID``, never by position, compared in canonical form:
efetch answers ``id=0033301246`` with ``<PMID>33301246</PMID>``.

These are pure functions over :mod:`xml.etree.ElementTree` elements.
"""

import xml.etree.ElementTree as ET

from .constants import (
    PUBMED_ARTICLE_ID_PATH,
    PUBMED_ARTICLE_TAG,
    PUBMED_RECORD_PMID_PATH,
)


def own_article_ids(pubmed_article: ET.Element) -> dict[str, str]:
    """The identifiers a ``PubmedArticle`` gives itself.

    Reads only ``PubmedData/ArticleIdList/ArticleId``, a fixed path and
    never ``.//``, so the ids of the papers it cites are not reached.

    Args:
        pubmed_article: A ``PubmedArticle`` element.

    Returns:
        The ids keyed by their lower-cased ``IdType`` (``pubmed``, ``pmc``,
        ``doi``...). The first non-blank value of each type wins, stripped.
        A type the record does not carry is absent from the result.
    """
    ids: dict[str, str] = {}
    for id_elem in pubmed_article.findall(PUBMED_ARTICLE_ID_PATH):
        id_type = (id_elem.get("IdType") or "").strip().lower()
        value = (id_elem.text or "").strip()
        if id_type and value and id_type not in ids:
            ids[id_type] = value
    return ids


def served_pmids(root: ET.Element) -> list[str]:
    """The PMIDs of the records an efetch body holds.

    Read from each record's own ``MedlineCitation/PMID``, so a PMID a record
    mentions in ``CommentsCorrections`` is not one it was served as.

    Args:
        root: The parsed efetch body.

    Returns:
        The stripped PMIDs, in document order; records without one are
        skipped.
    """
    pmids: list[str] = []
    for article in root.iter(PUBMED_ARTICLE_TAG):
        text = (article.findtext(PUBMED_RECORD_PMID_PATH) or "").strip()
        if text:
            pmids.append(text)
    return pmids


def _comparable_pmid(pmid: str) -> str:
    """The form in which two PMIDs are compared.

    Stripped; a PMID that is all ASCII digits also loses its leading zeros,
    since efetch serves ``id=0033301246`` as ``<PMID>33301246</PMID>``.
    Anything else is compared as its stripped text, so a malformed PMID is
    never made to match a real one.

    Args:
        pmid: A PMID, asked about or read from a record.

    Returns:
        The PMID in comparable form.
    """
    text = pmid.strip()
    if text.isascii() and text.isdigit():
        return text.lstrip("0")
    return text


def record_for_pmid(root: ET.Element, pmid: str) -> ET.Element | None:
    """The ``PubmedArticle`` that is the record for ``pmid``.

    Args:
        root: The parsed efetch body.
        pmid: The PMID that was asked about.

    Returns:
        The first ``PubmedArticle`` whose direct-child
        ``MedlineCitation/PMID`` equals ``pmid``, both compared stripped
        and, when all ASCII digits, without leading zeros; ``None`` when
        the body holds no record for it.
    """
    wanted = _comparable_pmid(pmid)
    for article in root.iter(PUBMED_ARTICLE_TAG):
        text = article.findtext(PUBMED_RECORD_PMID_PATH) or ""
        if text.strip() and _comparable_pmid(text) == wanted:
            return article
    return None
