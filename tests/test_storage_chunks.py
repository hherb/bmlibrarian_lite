# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Re-adding a chunk keeps its rowid and vector; orphaned vectors are swept (#592)."""

from pathlib import Path

from bmlibrarian_lite import constants
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import LiteChunk
from bmlibrarian_lite.storage import LiteStorage

DIMS = constants.DEFAULT_EMBEDDING_DIMENSIONS


class FakeEmbedder:
    """Fixed-dimension vectors, no model needed."""

    def embed(self, texts: list[str]) -> list[list[float]]:
        """One vector per text."""
        return [[1.0] * DIMS for _ in texts]


def _store(tmp_path: Path) -> LiteStorage:
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def _chunk() -> LiteChunk:
    return LiteChunk(id="d_0", document_id="d", text="x", chunk_index=0,
                     start_char=0, end_char=1)


def _rowid(storage: LiteStorage) -> int:
    with storage._sqlite_connection() as conn:
        return conn.execute("SELECT rowid FROM chunks WHERE id='d_0'").fetchone()[0]


def _vec_rowids(storage: LiteStorage) -> list[int]:
    with storage._sqlite_connection() as conn:
        return [r[0] for r in conn.execute("SELECT rowid FROM vec_chunks")]


def test_readding_a_chunk_keeps_its_rowid_and_one_vector(tmp_path: Path) -> None:
    """A re-add updates the row in place, so one vector remains at the same rowid."""
    storage = _store(tmp_path)
    storage.add_chunks([_chunk()], FakeEmbedder())
    first = _rowid(storage)
    storage.add_chunks([_chunk()], FakeEmbedder())
    assert _rowid(storage) == first
    assert _vec_rowids(storage) == [first]


def test_readding_without_an_embedder_keeps_the_existing_vector(tmp_path: Path) -> None:
    """A re-add with no embedder leaves the stored vector alone."""
    storage = _store(tmp_path)
    storage.add_chunks([_chunk()], FakeEmbedder())
    storage.add_chunks([_chunk()])
    assert _vec_rowids(storage) == [_rowid(storage)]


def test_opening_a_store_sweeps_orphan_vectors(tmp_path: Path) -> None:
    """Opening the store removes a vector with no chunk, not a real one."""
    storage = _store(tmp_path)
    storage.add_chunks([_chunk()], FakeEmbedder())
    with storage._sqlite_connection() as conn:
        conn.execute(
            "INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)",
            (999, storage._serialize_embedding([1.0] * DIMS)),
        )
        conn.commit()
    reopened = _store(tmp_path)
    assert _vec_rowids(reopened) == [_rowid(reopened)]
