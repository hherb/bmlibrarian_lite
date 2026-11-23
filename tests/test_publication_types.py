"""Publication types are kept from the record through storage."""

import sqlite3
import xml.etree.ElementTree as ET
from pathlib import Path

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import LiteDocument
from bmlibrarian_lite.europepmc import ArticleInfo, _article_info_from_result
from bmlibrarian_lite.pubmed import PubMedSearchClient
from bmlibrarian_lite.search_merger import MergedArticle, SearchResultMerger
from bmlibrarian_lite.storage import LiteStorage

RETRACTED = "Retracted Publication"
ARTICLE = "Journal Article"


def _storage(tmp_path: Path) -> LiteStorage:
    """Open a storage over a temporary directory."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def _doc(types: list[str] | None, doc_id: str = "pmid-1") -> LiteDocument:
    """Make a document carrying the given publication types."""
    return LiteDocument(id=doc_id, title="T", abstract="A", publication_types=types)


def test_pubmed_record_keeps_publication_types() -> None:
    """Pubmed record keeps publication types."""
    xml = f"""<PubmedArticle><MedlineCitation><PMID>1</PMID><Article>
    <ArticleTitle>T</ArticleTitle><PublicationTypeList>
    <PublicationType UI="D016441">{RETRACTED}</PublicationType>
    <PublicationType UI="D016428">{ARTICLE}</PublicationType>
    </PublicationTypeList></Article></MedlineCitation></PubmedArticle>"""
    meta = PubMedSearchClient()._parse_single_article(ET.fromstring(xml))
    assert meta is not None
    assert meta.publication_types == [RETRACTED, ARTICLE]


def test_pubmed_record_without_a_list_gives_none() -> None:
    """Pubmed record without a list gives none."""
    xml = ("<PubmedArticle><MedlineCitation><PMID>1</PMID><Article>"
           "<ArticleTitle>T</ArticleTitle></Article></MedlineCitation></PubmedArticle>")
    meta = PubMedSearchClient()._parse_single_article(ET.fromstring(xml))
    assert meta is not None and meta.publication_types is None


def test_europepmc_result_keeps_publication_types() -> None:
    """Europepmc result keeps publication types."""
    both = _article_info_from_result(
        {"pubTypeList": {"pubType": ["retracted publication", "research-article"]}}
    )
    assert both.publication_types == ["retracted publication", "research-article"]
    one = _article_info_from_result({"pubTypeList": {"pubType": "research-article"}})
    assert one.publication_types == ["research-article"]
    assert _article_info_from_result({}).publication_types is None


def test_merged_article_unions_both_sources_types() -> None:
    """Merged article unions both sources types."""
    from bmlibrarian_lite.pubmed import ArticleMetadata

    pm = ArticleMetadata(pmid="1", title="Same title here", publication_types=[RETRACTED, ARTICLE])
    ep = ArticleInfo(pmid="1", title="Same title here", publication_types=[ARTICLE, "preprint"])
    merged = SearchResultMerger.merge([pm], [ep])
    assert merged[0].publication_types == [RETRACTED, ARTICLE, "preprint"]
    none = SearchResultMerger.merge(
        [ArticleMetadata(pmid="2", title="Other one")], [ArticleInfo(pmid="2", title="Other one")]
    )
    assert none[0].publication_types is None


def test_lite_document_round_trips_publication_types() -> None:
    """Lite document round trips publication types."""
    for types in ([RETRACTED], [], None):
        assert LiteDocument.from_dict(_doc(types).to_dict()).publication_types == types


def test_metadata_filter_still_sees_no_publication_types() -> None:
    """Metadata filter still sees no publication types."""
    doc = MergedArticle(pmid="1", title="T", publication_types=[RETRACTED]).to_lite_document()
    assert "publication_types" not in doc.metadata
    assert doc.publication_types == [RETRACTED]


def test_storage_round_trips_publication_types(tmp_path: Path) -> None:
    """Storage round trips publication types."""
    storage = _storage(tmp_path)
    storage.add_documents([_doc([RETRACTED], "a"), _doc([], "b"), _doc(None, "c")])
    assert storage.get_document("a").publication_types == [RETRACTED]
    assert storage.get_document("b").publication_types == []
    assert storage.get_document("c").publication_types is None
    by_id = {d.id: d.publication_types for d in storage.get_documents(["a", "b", "c"])}
    assert by_id == {"a": [RETRACTED], "b": [], "c": None}


def test_a_pre_column_database_migrates_and_reads_none(tmp_path: Path) -> None:
    """A pre column database migrates and reads none."""
    storage = _storage(tmp_path)
    storage.add_document(_doc(None))
    path = next(tmp_path.rglob("metadata.db"))
    with sqlite3.connect(path) as conn:
        conn.execute("ALTER TABLE documents DROP COLUMN publication_types")
    reopened = _storage(tmp_path)
    assert reopened.get_document("pmid-1").publication_types is None
    columns = [r[1] for r in sqlite3.connect(path).execute("PRAGMA table_info(documents)")]
    assert columns.count("publication_types") == 1
    _storage(tmp_path)  # a second open is a no-op


def test_a_later_search_fills_types_but_never_erases_them(tmp_path: Path) -> None:
    """A later search fills types but never erases them."""
    storage = _storage(tmp_path)
    storage.add_documents([_doc(None)])
    storage.add_documents([_doc([RETRACTED])])
    assert storage.get_document("pmid-1").publication_types == [RETRACTED]
    storage.add_documents([_doc(None)])
    assert storage.get_document("pmid-1").publication_types == [RETRACTED]
    storage.add_document(_doc(None))
    assert storage.get_document("pmid-1").publication_types == [RETRACTED]


def test_search_service_conversions_carry_publication_types() -> None:
    """Both providers' conversions keep the record's types."""
    from types import SimpleNamespace

    from bmlibrarian_lite.search_service import SearchService

    svc = SearchService.__new__(SearchService)
    types = [RETRACTED, ARTICLE]
    pm = SimpleNamespace(
        pmid="1", pmc_id=None, doi=None, title="T", abstract="A", authors=[],
        publication="J", publication_date="2020-01-01", mesh_terms=[], url=None,
        publication_types=types, medline_status="MEDLINE", indexing_method=None,
    )
    ep = SimpleNamespace(
        pmid="1", pmcid=None, doi=None, title="T", abstract="A", authors=[],
        journal="J", year=2020, is_preprint=False, has_fulltext_xml=False,
        publication_types=types,
    )
    assert svc._pubmed_to_merged(pm).publication_types == types
    assert svc._europepmc_to_merged(ep).publication_types == types
