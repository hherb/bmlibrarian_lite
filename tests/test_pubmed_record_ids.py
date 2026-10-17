"""A PubMed record's own identifiers come from the record asked about.

The transparency analyser took ``.//ArticleId`` with the last match winning,
which walks into ``PubmedData/ReferenceList``: PMID 33301246 yielded a cited
paper's PMC ID and DOI, and its COI and data-availability ratings could come
from another article's full text (bmlib#474 and the neighbouring defect).
The fixture is a trimmed real efetch body for that PMID.
"""

import logging
import xml.etree.ElementTree as ET
from pathlib import Path

from bmlibrarian_lite.data_models import RequestFailureKind
from bmlibrarian_lite.pubmed.record_ids import (
    own_article_ids,
    record_for_pmid,
    served_pmids,
)
from bmlibrarian_lite.pubmed.search_client import PubMedSearchClient
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
    PubMedClient,
)

BODY = (
    Path(__file__).parent / "fixtures" / "pubmed_efetch_33301246.xml"
).read_text(encoding="utf-8")
PMID = "33301246"
OWN_PMC = "PMC7745181"
OWN_DOI = "10.1056/NEJMoa2034577"


def _record(xml: str = BODY) -> ET.Element:
    found = ET.fromstring(xml).find("PubmedArticle")
    assert found is not None
    return found


def _other_record(pmid: str, cites: str = "") -> str:
    """A PubmedArticle for ``pmid``; ``cites`` is a CommentsCorrections PMID."""
    comments = (
        f"<CommentsCorrectionsList><CommentsCorrections RefType='Cites'>"
        f"<PMID>{cites}</PMID></CommentsCorrections></CommentsCorrectionsList>"
        if cites
        else ""
    )
    return (
        f"<PubmedArticle><MedlineCitation><PMID>{pmid}</PMID>"
        "<Article><ArticleTitle>Other</ArticleTitle></Article>"
        f"{comments}</MedlineCitation>"
        "<PubmedData><ArticleIdList>"
        f"<ArticleId IdType='pubmed'>{pmid}</ArticleId>"
        "<ArticleId IdType='pmc'>PMC1</ArticleId>"
        "</ArticleIdList></PubmedData></PubmedArticle>"
    )


def _own_record_after(other: str) -> str:
    """The fixture's own PubmedArticle, preceded by ``other``."""
    own = ET.tostring(_record(), encoding="unicode")
    return f"<PubmedArticleSet>{other}{own}</PubmedArticleSet>"


def test_a_reference_id_is_never_the_articles() -> None:
    """A reference id is never the articles."""
    assert own_article_ids(_record()) == {
        "pubmed": PMID,
        "pmc": OWN_PMC,
        "doi": OWN_DOI,
    }


def test_a_doi_only_a_reference_carries_is_no_doi() -> None:
    """A doi only a reference carries is no doi."""
    record = _record()
    own_list = record.find("PubmedData/ArticleIdList")
    assert own_list is not None
    for elem in own_list.findall("ArticleId[@IdType='doi']"):
        own_list.remove(elem)
    ids = own_article_ids(record)
    assert "doi" not in ids
    assert ids["pmc"] == OWN_PMC


def test_the_first_non_blank_value_per_type_wins_and_is_stripped() -> None:
    """The first non blank value per type wins and is stripped."""
    record = ET.fromstring(
        "<PubmedArticle><PubmedData><ArticleIdList>"
        "<ArticleId IdType='DOI'>   </ArticleId>"
        "<ArticleId IdType='DOI'> 10.1/first </ArticleId>"
        "<ArticleId IdType='doi'>10.1/second</ArticleId>"
        "</ArticleIdList></PubmedData></PubmedArticle>"
    )
    assert own_article_ids(record) == {"doi": "10.1/first"}


def test_a_record_without_pubmed_data_has_no_ids() -> None:
    """A record without pubmed data has no ids."""
    assert own_article_ids(ET.fromstring("<PubmedArticle/>")) == {}


def test_the_transparency_record_keeps_its_own_pmcid_and_doi() -> None:
    """The transparency record keeps its own pmcid and doi."""
    fetch = PubMedClient("t@example.com")._parse_pubmed_xml(BODY, PMID)
    assert fetch.record is not None
    assert fetch.record["pmcid"] == OWN_PMC
    assert fetch.record["doi"] == OWN_DOI


def test_the_matching_record_is_read_not_the_first() -> None:
    """The matching record is read not the first."""
    fetch = PubMedClient("t@example.com")._parse_pubmed_xml(
        _own_record_after(_other_record("2")), PMID
    )
    assert fetch.record is not None
    assert fetch.record["pmid"] == PMID
    assert fetch.record["pmcid"] == OWN_PMC


def test_a_record_for_another_pmid_is_not_this_paper(caplog) -> None:
    """A record for another pmid is not this paper."""
    with caplog.at_level(logging.WARNING):
        fetch = PubMedClient("t@example.com")._parse_pubmed_xml(BODY, "1")
    assert fetch.is_unreachable  # never absent()
    assert fetch.failure is not None
    assert fetch.failure.kind is RequestFailureKind.MALFORMED_RESPONSE
    assert fetch.record is None
    assert PMID in caplog.text  # the WARNING names what was served


def test_pmids_inside_comments_corrections_do_not_match() -> None:
    """Pmids inside comments corrections do not match."""
    root = ET.fromstring(
        f"<PubmedArticleSet>{_other_record('2', cites=PMID)}</PubmedArticleSet>"
    )
    assert record_for_pmid(root, PMID) is None
    assert served_pmids(root) == ["2"]


def test_record_for_pmid_strips_the_text_it_compares() -> None:
    """Record for pmid strips the text it compares."""
    root = ET.fromstring(
        "<PubmedArticleSet><PubmedArticle><MedlineCitation>"
        "<PMID>\n  7 </PMID></MedlineCitation></PubmedArticle>"
        "</PubmedArticleSet>"
    )
    assert record_for_pmid(root, "7") is not None
    assert record_for_pmid(root, " 7\n") is not None  # the asked PMID too
    assert served_pmids(root) == ["7"]


def test_a_zero_padded_pmid_finds_its_record() -> None:
    """A zero-padded PMID finds the record efetch serves for it.

    efetch answers ``id=0033301246`` with ``<PMID>33301246</PMID>``; a
    textual comparison read that as a record for another PMID.
    """
    root = ET.fromstring(BODY)
    found = record_for_pmid(root, "0033301246")
    assert found is not None
    assert found.findtext("MedlineCitation/PMID") == PMID
    assert record_for_pmid(root, " 0033301246\n") is not None  # stripped too


def test_a_zero_padded_record_pmid_matches_the_plain_one() -> None:
    """Leading zeros on the record's own PMID are not a different paper."""
    root = ET.fromstring(
        "<PubmedArticleSet><PubmedArticle><MedlineCitation>"
        "<PMID>007</PMID></MedlineCitation></PubmedArticle>"
        "</PubmedArticleSet>"
    )
    assert record_for_pmid(root, "7") is not None
    assert record_for_pmid(root, "70") is None  # only leading zeros go


def test_zeros_are_dropped_only_from_ascii_digit_pmids() -> None:
    """A PMID that is not all ASCII digits is compared as text, zeros kept."""
    root = ET.fromstring(
        "<PubmedArticleSet><PubmedArticle><MedlineCitation>"
        "<PMID>0A7</PMID></MedlineCitation></PubmedArticle>"
        "<PubmedArticle><MedlineCitation>"
        "<PMID>\u0667</PMID></MedlineCitation></PubmedArticle>"
        "</PubmedArticleSet>"
    )
    assert record_for_pmid(root, "A7") is None
    assert record_for_pmid(root, "0A7") is not None
    # ARABIC-INDIC DIGIT SEVEN is a digit to str.isdigit, but not ASCII.
    assert record_for_pmid(root, "7") is None
    assert record_for_pmid(root, "0\u0667") is None


def test_an_all_zero_pmid_does_not_match_a_record_without_one() -> None:
    """"000" canonicalises to nothing, but a missing PMID is not a match."""
    root = ET.fromstring(
        "<PubmedArticleSet><PubmedArticle><MedlineCitation>"
        "<PMID>  </PMID></MedlineCitation></PubmedArticle>"
        "<PubmedArticle><MedlineCitation/></PubmedArticle>"
        "</PubmedArticleSet>"
    )
    assert record_for_pmid(root, "000") is None


def test_the_transparency_parser_serves_a_zero_padded_pmid() -> None:
    """_parse_pubmed_xml serves the record for a zero-padded PMID."""
    fetch = PubMedClient("t@example.com")._parse_pubmed_xml(BODY, "0033301246")
    assert not fetch.is_unreachable
    assert fetch.record is not None
    assert fetch.record["pmcid"] == OWN_PMC
    assert fetch.record["doi"] == OWN_DOI


def test_a_record_without_its_own_pmid_is_not_matched_by_a_cited_one() -> None:
    """A record without its own pmid is not matched by a cited one."""
    root = ET.fromstring(
        "<PubmedArticleSet><PubmedArticle><MedlineCitation>"
        "<CommentsCorrectionsList><CommentsCorrections RefType='Cites'>"
        "<PMID>7</PMID></CommentsCorrections></CommentsCorrectionsList>"
        "</MedlineCitation></PubmedArticle></PubmedArticleSet>"
    )
    assert record_for_pmid(root, "7") is None
    assert served_pmids(root) == []


def test_served_pmids_lists_each_record_asked() -> None:
    """Served pmids lists each record asked."""
    root = ET.fromstring(_own_record_after(_other_record("2")))
    assert served_pmids(root) == ["2", PMID]


def test_no_pubmed_article_is_still_absent() -> None:
    """The control: PubMed answered, and holds no such article."""
    fetch = PubMedClient("t@example.com")._parse_pubmed_xml(
        "<PubmedArticleSet/>", "1"
    )
    assert fetch.record is None
    assert not fetch.is_unreachable


def test_the_search_client_reads_the_articles_own_ids() -> None:
    """The search client reads the articles own ids."""
    articles, unreadable = PubMedSearchClient()._parse_articles_xml(
        BODY.encode("utf-8")
    )
    assert unreadable == 0
    assert articles[0].doi == OWN_DOI
    assert articles[0].pmc_id == OWN_PMC


def test_the_search_client_takes_no_reference_id_for_a_missing_own_one() -> None:
    """The search client takes no reference id for a missing own one."""
    body = BODY.replace(
        f'<ArticleId IdType="doi">{OWN_DOI}</ArticleId></ArticleIdList><ReferenceList>',
        "</ArticleIdList><ReferenceList>",
    )
    assert body != BODY
    articles, _ = PubMedSearchClient()._parse_articles_xml(body.encode("utf-8"))
    assert articles[0].doi is None
    assert articles[0].pmc_id == OWN_PMC
