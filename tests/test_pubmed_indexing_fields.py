# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
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

"""PubMed's MEDLINE status and indexing method: parse, storage, config."""

from __future__ import annotations

import xml.etree.ElementTree as ET

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import LiteDocument
from bmlibrarian_lite.pubmed.search_client import PubMedSearchClient
from bmlibrarian_lite.storage import LiteStorage

XML = (
    '<PubmedArticle><MedlineCitation Status="{status}"{method}><PMID>1</PMID>'
    "<Article><ArticleTitle>T</ArticleTitle></Article></MedlineCitation></PubmedArticle>"
)


def _parse(status: str, method: str):
    client = PubMedSearchClient.__new__(PubMedSearchClient)
    return client._parse_single_article(ET.fromstring(XML.format(status=status, method=method)))


def test_parse_keeps_status_and_method():
    """The attributes are read as given; an absent one is None."""
    art = _parse("MEDLINE", ' IndexingMethod="Automated"')
    assert (art.medline_status, art.indexing_method) == ("MEDLINE", "Automated")
    art = _parse("PubMed-not-MEDLINE", "")
    assert (art.medline_status, art.indexing_method) == ("PubMed-not-MEDLINE", None)


def test_document_round_trip_keeps_indexing(tmp_path):
    """Dict and storage round trips keep both fields; a later NULL keeps them."""
    doc = LiteDocument(
        id="pmid-1",
        title="T",
        abstract="",
        pmid="1",
        medline_status="MEDLINE",
        indexing_method="Automated",
    )
    assert LiteDocument.from_dict(doc.to_dict()).indexing_method == "Automated"
    cfg = LiteConfig()
    cfg.storage.data_dir = tmp_path
    storage = LiteStorage(cfg)
    storage.add_document(doc)
    storage.add_document(LiteDocument(id="pmid-1", title="T", abstract="", pmid="1"))
    got = storage.get_document("pmid-1")
    assert (got.medline_status, got.indexing_method) == ("MEDLINE", "Automated")


def test_an_old_database_gains_the_columns_on_open(tmp_path):
    """Opening an old-shape database adds both columns; its rows read None."""
    cfg = LiteConfig()
    cfg.storage.data_dir = tmp_path
    storage = LiteStorage(cfg)
    storage.add_document(LiteDocument(id="pmid-1", title="T", abstract="", pmid="1"))
    with storage._sqlite_connection() as conn:
        conn.execute("ALTER TABLE documents DROP COLUMN medline_status")
        conn.execute("ALTER TABLE documents DROP COLUMN indexing_method")
        conn.execute("DROP TABLE manta_judgements")
        conn.commit()
    reopened = LiteStorage(cfg)
    got = reopened.get_document("pmid-1")
    assert (got.medline_status, got.indexing_method) == (None, None)
    reopened.add_documents(
        [
            LiteDocument(
                id="pmid-2", title="T", abstract="", pmid="2",
                medline_status="MEDLINE", indexing_method="Automated",
            )
        ]
    )
    (got,) = reopened.get_documents(["pmid-2"])
    assert (got.medline_status, got.indexing_method) == ("MEDLINE", "Automated")
    assert reopened.manta_judgements("pmid-1") == []
    LiteStorage(cfg)  # a second open is a no-op


def test_a_new_status_brings_its_own_method(tmp_path):
    """A later MEDLINE status with no method (manual) clears a stored Automated."""
    cfg = LiteConfig()
    cfg.storage.data_dir = tmp_path
    storage = LiteStorage(cfg)

    def doc(status, method):
        return LiteDocument(
            id="pmid-1", title="T", abstract="", pmid="1",
            medline_status=status, indexing_method=method,
        )

    storage.add_document(doc("In-Process", "Automated"))
    storage.add_document(doc("MEDLINE", None))
    got = storage.get_document("pmid-1")
    assert (got.medline_status, got.indexing_method) == ("MEDLINE", None)
    storage.add_document(doc(None, None))  # a record that carries no indexing keeps it
    got = storage.get_document("pmid-1")
    assert (got.medline_status, got.indexing_method) == ("MEDLINE", None)


def test_merge_takes_pubmeds_indexing_as_a_pair():
    """Merged in either order, PubMed's status and method survive, as a pair."""
    from bmlibrarian_lite.europepmc import ArticleInfo
    from bmlibrarian_lite.pubmed.data_types import ArticleMetadata
    from bmlibrarian_lite.search_merger import SearchResultMerger

    for prefer_pubmed in (True, False):
        merged = SearchResultMerger.merge(
            [ArticleMetadata(
                pmid="1", title="A trial", medline_status="MEDLINE", indexing_method="Automated"
            )],
            [ArticleInfo(pmid="1", title="A trial")],
            prefer_pubmed=prefer_pubmed,
        )
        doc = merged[0].to_lite_document()
        assert (doc.medline_status, doc.indexing_method) == ("MEDLINE", "Automated")


def test_manta_config_round_trip():
    """Default url is empty; it survives to_dict/_from_dict; absent key = default."""
    cfg = LiteConfig()
    assert cfg.manta.url == ""
    cfg.manta.url = "http://127.0.0.1:8765"
    assert LiteConfig._from_dict(cfg.to_dict()).manta.url == "http://127.0.0.1:8765"
    assert LiteConfig._from_dict({}).manta.url == ""
