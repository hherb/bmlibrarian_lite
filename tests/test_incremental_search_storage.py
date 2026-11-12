# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Every document the incremental search finds is stored, not only handed on.

The review that scores them links and scores by id and never stored them, so a
reopened question dropped them.
"""

import sqlite3
from typing import Any
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite import constants, embeddings, pubmed  # noqa: E402
from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import DocumentSource, LiteDocument, ScoredDocument  # noqa: E402
from bmlibrarian_lite.gui import systematic_review_tab  # noqa: E402
from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker  # noqa: E402
from bmlibrarian_lite.gui.workers import IncrementalSearchWorker  # noqa: E402
from bmlibrarian_lite.pubmed.data_types import (  # noqa: E402
    ArticleFetchResult,
    ArticleMetadata,
    SearchResult,
)
from bmlibrarian_lite.storage import LiteStorage  # noqa: E402

QUESTION = "Does aspirin prevent stroke?"
TYPES = ["Randomized Controlled Trial", "Journal Article"]


DIMS = constants.DEFAULT_EMBEDDING_DIMENSIONS


class FakeEmbedder:
    """An embedder whose vector is a function of the text, no model needed."""

    def __init__(self, **_: Any) -> None:
        """Ignore the model name."""

    def embed_single(self, text: str) -> list[float]:
        """A one-hot-ish vector keyed on the text's last character."""
        vector = [0.0] * DIMS
        vector[ord(text[-1]) % DIMS] = 1.0
        return vector

    def embed(self, texts: list[str]) -> list[list[float]]:
        """One vector per text."""
        return [self.embed_single(t) for t in texts]


class BrokenEmbedder:
    """An embedder that cannot be built."""

    def __init__(self, **_: Any) -> None:
        """Fail as a missing model does."""
        raise RuntimeError("model not found")


class StubClient:
    """A PubMed client answering pages of records from a PMID pool."""

    pool = ["1", "2"]

    def __init__(self, **_: Any) -> None:
        """Ignore the credentials."""

    def search_with_offset(self, start_offset: int = 0, max_results: int = 100, **_: Any) -> SearchResult:
        """The page of the pool at the offset."""
        page = self.pool[start_offset : start_offset + max_results]
        return SearchResult(
            query=MagicMock(), total_count=len(self.pool), retrieved_count=len(page), pmids=page
        )

    def fetch_articles(self, pmids: list[str]) -> ArticleFetchResult:
        """One article per PMID, with publication types."""
        return ArticleFetchResult(
            articles=[
                ArticleMetadata(
                    pmid=p,
                    title=f"Title {p}",
                    abstract=f"Abstract {p}",
                    doi=f"10.1/{p}",
                    publication_date="2024-01-02",
                    publication_types=TYPES,
                )
                for p in pmids
            ]
        )


@pytest.fixture
def storage(tmp_path: Any) -> LiteStorage:
    """A database this test owns."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def search_worker(monkeypatch: pytest.MonkeyPatch, storage: Any) -> tuple[Any, dict[str, list]]:
    """An incremental search over the stub client, recording its signals."""
    monkeypatch.setattr(pubmed, "PubMedSearchClient", StubClient)
    monkeypatch.setattr(embeddings, "LiteEmbedder", FakeEmbedder)
    worker = IncrementalSearchWorker(
        question=QUESTION,
        pubmed_query="aspirin AND stroke",
        target_new_docs=5,
        already_scored_ids=set(),
        config=LiteConfig(),
        storage=storage,
    )
    seen: dict[str, list] = {"batch": [], "finished": [], "error": [], "progress": []}
    worker.batch_complete.connect(lambda docs: seen["batch"].append(docs))
    worker.finished.connect(lambda docs, shortfalls: seen["finished"].append(docs))
    worker.error.connect(lambda message: seen["error"].append(message))
    worker.progress.connect(lambda found, target, text: seen["progress"].append(text))
    return worker, seen


def test_documents_found_incrementally_are_stored_before_they_are_emitted(
    monkeypatch: pytest.MonkeyPatch, storage: LiteStorage
) -> None:
    """Both records are in the database, linked to the question, with their types."""
    worker, seen = search_worker(monkeypatch, storage)

    worker.run()

    assert seen["error"] == []
    for pmid in ("1", "2"):
        stored = storage.get_document(f"pmid-{pmid}")
        assert stored is not None
        assert (stored.title, stored.pmid, stored.doi) == (f"Title {pmid}", pmid, f"10.1/{pmid}")
        assert stored.publication_types == TYPES
    assert set(storage.get_document_ids_for_question(QUESTION)) == {"pmid-1", "pmid-2"}
    assert [d.id for d in seen["finished"][0]] == ["pmid-1", "pmid-2"]


def test_a_storage_failure_is_reported_not_swallowed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The error names the failure, and nothing is presented as stored."""
    storage = MagicMock()
    storage.add_documents.side_effect = sqlite3.OperationalError("disk I/O error")
    worker, seen = search_worker(monkeypatch, storage)

    worker.run()

    [message] = seen["error"]
    assert "disk I/O error" in message
    assert seen["batch"] == []
    assert seen["finished"] == []


def test_a_scored_preloaded_document_survives_a_reopen(
    monkeypatch: pytest.MonkeyPatch, storage: LiteStorage
) -> None:
    """Preloaded documents the review scores are stored, whatever route preloaded them."""
    articles = StubClient().fetch_articles(["1"]).articles
    doc = LiteDocument(
        id="pmid-1",
        title=articles[0].title,
        abstract=articles[0].abstract,
        pmid="1",
        source=DocumentSource.PUBMED,
        publication_types=TYPES,
    )
    scoring_agent = MagicMock()
    scoring_agent.score_document.side_effect = lambda question, d: ScoredDocument(
        document=d, score=5, explanation="Relevant."
    )
    monkeypatch.setattr(systematic_review_tab, "LiteScoringAgent", lambda **_: scoring_agent)
    # Nothing scores relevant, so the review would run a live smart-search
    # round (a real LLM call and PubMed search wherever a key is set).
    monkeypatch.setattr(
        WorkflowWorker, "_smart_search", lambda self, metadata, ids, relevant, cid, meta: ([], meta)
    )
    config = LiteConfig()
    monkeypatch.setattr(config.parallel, "get_scoring_workers", lambda provider: 1)
    worker = WorkflowWorker(
        question=QUESTION,
        config=config,
        storage=storage,
        min_score=6,  # above the score: nothing is relevant
        preloaded_documents=[doc],
    )

    worker.run()

    reopened = storage.get_documents(sorted(storage.get_document_ids_for_question(QUESTION)))
    assert [d.id for d in reopened] == ["pmid-1"]
    assert reopened[0].title == "Title 1"
    assert reopened[0].publication_types == TYPES


def vector_count(storage: LiteStorage) -> int:
    """Rows in the document vector table."""
    with storage._sqlite_connection() as conn:
        return conn.execute("SELECT COUNT(*) FROM vec_documents").fetchone()[0]


def test_incremental_documents_get_vectors_so_semantic_search_finds_them(
    monkeypatch: pytest.MonkeyPatch, storage: LiteStorage
) -> None:
    """The worker embeds what it stores, as the search agent does."""
    worker, _ = search_worker(monkeypatch, storage)

    worker.run()

    assert vector_count(storage) == 2
    found = storage.search_documents("Abstract 1", n_results=1, embedding_function=FakeEmbedder())
    assert [d.id for d in found] == ["pmid-1"]


def test_an_embedder_that_cannot_be_built_stores_without_vectors_and_says_so(
    monkeypatch: pytest.MonkeyPatch, storage: LiteStorage
) -> None:
    """Documents are kept; the progress text the reader sees names the gap."""
    worker, seen = search_worker(monkeypatch, storage)
    monkeypatch.setattr(embeddings, "LiteEmbedder", BrokenEmbedder)

    worker.run()

    assert seen["error"] == []
    assert storage.get_document("pmid-1") is not None
    assert vector_count(storage) == 0
    assert "stored without search vectors" in seen["progress"][-1]


def _embedded(storage: LiteStorage) -> LiteDocument:
    doc = LiteDocument(
        id="pmid-9", title="Old", abstract="Zebra stripe", pmid="9",
        source=DocumentSource.PUBMED, publication_types=TYPES,
    )
    storage.add_documents([doc], embedding_function=FakeEmbedder())
    return doc


def test_a_re_add_without_an_embedder_keeps_the_vector(storage: LiteStorage) -> None:
    """Control: re-storing an embedded document does not orphan its vector."""
    doc = _embedded(storage)

    storage.add_documents(
        [LiteDocument(id=doc.id, title="New", abstract=doc.abstract, pmid="9", source=doc.source)]
    )

    found = storage.search_documents("Zebra stripe", n_results=1, embedding_function=FakeEmbedder())
    assert [d.id for d in found] == ["pmid-9"]
    assert vector_count(storage) == 1


def test_a_re_add_keeps_the_rowid_the_creation_time_and_the_types(storage: LiteStorage) -> None:
    """The upsert updates the row in place."""
    doc = _embedded(storage)

    def row() -> tuple:
        with storage._sqlite_connection() as conn:
            r = conn.execute(
                "SELECT rowid, created_at, title, publication_types FROM documents WHERE id=?",
                (doc.id,),
            ).fetchone()
            return tuple(r)

    before = row()
    changed = LiteDocument(
        id=doc.id, title="New", abstract="Zebra stripe", pmid="9",
        source=DocumentSource.PUBMED, publication_types=None,
    )
    storage.add_document(changed)
    storage.add_documents([changed])
    after = row()

    assert after[:2] == before[:2]
    assert after[2] == "New"
    assert after[3] == before[3]


def test_a_later_batch_failure_leaves_earlier_batches_stored_and_says_how_many(
    monkeypatch: pytest.MonkeyPatch, storage: LiteStorage
) -> None:
    """The run ends in error; the message counts what was saved."""
    monkeypatch.setattr(constants, "INCREMENTAL_SEARCH_BATCH_SIZE", 2)
    monkeypatch.setattr(StubClient, "pool", ["1", "2", "3", "4"])
    worker, seen = search_worker(monkeypatch, storage)
    real = storage.add_documents
    calls = []

    def flaky(documents: Any, embedding_function: Any = None) -> Any:
        calls.append(1)
        if len(calls) == 2:
            raise sqlite3.OperationalError("disk I/O error")
        return real(documents, embedding_function=embedding_function)

    monkeypatch.setattr(storage, "add_documents", flaky)

    worker.run()

    [message] = seen["error"]
    assert "disk I/O error" in message
    assert "2 documents found earlier were saved" in message
    assert seen["finished"] == []
    assert storage.get_document("pmid-2") is not None
    assert storage.get_document("pmid-3") is None


def _stored_row(storage: LiteStorage, doc_id: str) -> Any:
    with storage._sqlite_connection() as conn:
        return conn.execute("SELECT * FROM documents WHERE id = ?", (doc_id,)).fetchone()


@pytest.mark.parametrize("many", [False, True])
def test_a_poorer_re_add_never_erases_a_stored_fact(storage: LiteStorage, many: bool) -> None:
    """None, '' and [] keep what is stored; a non-empty value corrects it."""
    rich = LiteDocument(
        id="pmid-5", title="Old title", abstract="Zebra stripe", authors=["A B"],
        year=2020, journal="J", doi="10.1/x", pmid="5", pmc_id="PMC1", url="http://u",
        mesh_terms=["M"], source=DocumentSource.EUROPEPMC,
    )
    storage.add_documents([rich], embedding_function=FakeEmbedder())
    poor = LiteDocument(
        id="pmid-5", title="New title", abstract="", authors=[], year=None, journal=None,
        doi=None, pmid="5", pmc_id=None, url=None, mesh_terms=[], source=DocumentSource.PUBMED,
    )

    storage.add_documents([poor]) if many else storage.add_document(poor)

    row = _stored_row(storage, "pmid-5")
    assert row["title"] == "New title"
    assert (row["doi"], row["abstract"], row["journal"], row["year"]) == (
        "10.1/x", "Zebra stripe", "J", 2020)
    assert (row["pmc_id"], row["url"]) == ("PMC1", "http://u")
    assert (row["authors"], row["mesh_terms"]) == ('["A B"]', '["M"]')
    found = storage.search_documents("Zebra stripe", n_results=1, embedding_function=FakeEmbedder())
    assert [d.id for d in found] == ["pmid-5"]


def test_the_sweep_removes_only_orphaned_vectors(storage: LiteStorage) -> None:
    """Vectors left under a vanished rowid go; attached ones stay; a rerun is a no-op."""
    _embedded(storage)
    with storage._sqlite_connection() as conn:
        conn.execute(
            "INSERT INTO vec_documents(rowid, embedding) VALUES (?, ?)",
            (9999, storage._serialize_embedding([0.5] * DIMS)),
        )
        conn.commit()
    assert vector_count(storage) == 2

    storage._sweep_orphaned_document_vectors()
    storage._sweep_orphaned_document_vectors()

    assert vector_count(storage) == 1


def test_embedding_happens_before_the_write_transaction(
    storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Another connection can write while the (slow) embedder runs."""
    seen: list[bool] = []

    class Probe(FakeEmbedder):
        def embed(self, texts: list[str]) -> list[list[float]]:
            other = sqlite3.connect(storage._storage_config.sqlite_path, timeout=0.1)
            try:
                other.execute("BEGIN IMMEDIATE")
                seen.append(True)
                other.rollback()
            finally:
                other.close()
            return super().embed(texts)

    storage.add_documents(
        [LiteDocument(id="pmid-7", title="T", abstract="Abc", pmid="7")], embedding_function=Probe()
    )
    assert seen == [True]


def test_an_embed_failure_stores_without_vectors_and_says_so(
    monkeypatch: pytest.MonkeyPatch, storage: LiteStorage
) -> None:
    """A model that loads but fails to embed is treated as one that did not load."""
    class FailingEmbed(FakeEmbedder):
        def embed(self, texts: list[str]) -> list[list[float]]:
            raise RuntimeError("model broke")

    worker, seen = search_worker(monkeypatch, storage)
    monkeypatch.setattr(embeddings, "LiteEmbedder", FailingEmbed)

    worker.run()

    assert seen["error"] == []
    assert storage.get_document("pmid-1") is not None
    assert vector_count(storage) == 0
    assert "stored without search vectors" in seen["progress"][-1]
    assert [d.id for d in seen["finished"][0]] == ["pmid-1", "pmid-2"]
    assert any("Loading the embedding model" in t for t in seen["progress"])


def test_already_scored_and_past_target_articles_are_stored_but_not_emitted(
    monkeypatch: pytest.MonkeyPatch, storage: LiteStorage
) -> None:
    """A scored paper with no documents row is stored by a rerun; one past the target too."""
    monkeypatch.setattr(StubClient, "pool", ["1", "2", "3"])
    worker, seen = search_worker(monkeypatch, storage)
    worker.already_scored_ids = {"pmid-1"}
    worker.target_new_docs = 1

    worker.run()

    assert [d.id for d in seen["finished"][0]] == ["pmid-2"]
    assert [d.id for b in seen["batch"] for d in b] == ["pmid-2"]
    for pmid in ("1", "2", "3"):
        assert storage.get_document(f"pmid-{pmid}") is not None
    assert storage.get_document_ids_for_question(QUESTION) == {"pmid-2"}
