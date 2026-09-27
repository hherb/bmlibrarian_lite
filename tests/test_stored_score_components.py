# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A result's score terms survive the store, and a damaged column is named (#386)."""

import sqlite3
from datetime import datetime
from typing import Any

import pytest

from bmlibrarian_lite.transparency import TransparencyResult, TransparencyRisk
from bmlibrarian_lite.transparency_terms import ScoreComponent

COMPONENTS = (
    ScoreComponent("Starting score", 50),
    ScoreComponent("No conflict of interest statement found", -5, True),
)


@pytest.fixture
def storage(tmp_path: Any) -> Any:
    """A database this test owns, built the way other storage tests do."""
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.storage import LiteStorage

    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def _result(components: Any = COMPONENTS) -> TransparencyResult:
    return TransparencyResult(
        document_id="doc-1",
        transparency_score=45,
        risk_level=TransparencyRisk.HIGH,
        analyzed_at=datetime(2026, 9, 27),
        score_components=components,
    )


def _set_column(storage: Any, value: Any) -> None:
    with storage._sqlite_connection() as conn:
        conn.execute(
            "UPDATE transparency_results SET score_components = ? WHERE document_id = ?",
            (value, "doc-1"),
        )
        conn.commit()


class TestTheTermsAreStored:
    """A score's terms round-trip through the store like the rest of a row."""

    def test_round_trip(self, storage: Any) -> None:
        """What was saved is what comes back."""
        storage.save_transparency_result(_result())
        assert storage.get_transparency_result("doc-1").score_components == COMPONENTS

    def test_not_recorded_stays_not_recorded(self, storage: Any) -> None:
        """``None`` means never recorded, not an empty breakdown."""
        storage.save_transparency_result(_result(components=None))
        assert storage.get_transparency_result("doc-1").score_components is None

    def test_the_batch_reader_agrees(self, storage: Any) -> None:
        """The batch reader and the single reader share one mapper."""
        storage.save_transparency_result(_result())
        rows = storage.get_transparency_results_batch(["doc-1"])
        assert rows["doc-1"].score_components == COMPONENTS


class TestADamagedColumn:
    """Unreadable is not absent: the row is shown, and says what it lost."""

    @pytest.mark.parametrize(
        "raw", ["not json", '{"label": "x"}', '[{"label": "x"}]', "[1, 2]"]
    )
    def test_is_named_not_hidden(self, storage: Any, raw: str) -> None:
        """None of these shapes are silently swallowed as an empty list."""
        storage.save_transparency_result(_result())
        _set_column(storage, raw)
        row = storage.get_transparency_result("doc-1")
        assert isinstance(row, TransparencyResult)
        assert row.score_components is None
        assert any("score breakdown could not be read" in w for w in row.warnings)

    def test_null_is_not_damage(self, storage: Any) -> None:
        """NULL is "not recorded", not corruption -- no caveat is owed for it."""
        storage.save_transparency_result(_result())
        _set_column(storage, None)
        row = storage.get_transparency_result("doc-1")
        assert row.score_components is None
        assert not any("could not be read" in w for w in row.warnings)


class TestTheMigration:
    """A table built before #386 gains the column without losing its rows."""

    def test_an_older_table_gains_the_column(self, tmp_path: Any) -> None:
        """A table built before #386 is given the column, NULL for old rows.

        Build the pre-#386 ``transparency_results`` table by hand (the exact
        CREATE statement from ``storage.py``, minus ``score_components``),
        insert one row with a current ``analyzer_version`` so it is
        decodable, then construct ``LiteStorage`` over the same directory the
        way every other test here does. The column must exist afterwards,
        and the old row must read back with ``score_components is None`` and
        no unreadable-column caveat -- NULL from a migration is not damage.
        """
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.constants import SQLITE_DATABASE_NAME
        from bmlibrarian_lite.storage import LiteStorage
        from bmlibrarian_lite.transparency import TRANSPARENCY_ANALYZER_VERSION

        db_path = tmp_path / SQLITE_DATABASE_NAME
        conn = sqlite3.connect(db_path)
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS transparency_results (
                document_id TEXT PRIMARY KEY,
                transparency_score INTEGER NOT NULL,
                risk_level TEXT NOT NULL,
                industry_funding_detected INTEGER NOT NULL DEFAULT 0,
                industry_funding_confidence REAL DEFAULT 0.0,
                data_availability_level TEXT DEFAULT 'unknown',
                coi_disclosure TEXT DEFAULT 'not_assessed',
                trial_registered INTEGER DEFAULT 0,
                trial_results_compliant INTEGER DEFAULT 0,
                outcome_switching_detected INTEGER DEFAULT 0,
                risk_indicators TEXT,  -- JSON array
                warnings TEXT,  -- JSON array
                tier_downgrade_applied INTEGER DEFAULT 0,
                analyzed_at TEXT NOT NULL,
                analyzer_version TEXT DEFAULT '1.0',
                sources_unreachable INTEGER DEFAULT 0,
                full_text_analyzed INTEGER DEFAULT 0,
                FOREIGN KEY (document_id) REFERENCES documents(id)
            )
            """
        )
        conn.execute(
            "INSERT INTO transparency_results ("
            "document_id, transparency_score, risk_level, analyzed_at, "
            "analyzer_version"
            ") VALUES (?, ?, ?, ?, ?)",
            (
                "old-doc",
                80,
                "low",
                datetime(2026, 1, 1).isoformat(),
                TRANSPARENCY_ANALYZER_VERSION,
            ),
        )
        conn.commit()
        conn.close()

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        storage = LiteStorage(config)

        with storage._sqlite_connection() as sqlite_conn:
            columns = [
                row["name"]
                for row in sqlite_conn.execute(
                    "PRAGMA table_info(transparency_results)"
                ).fetchall()
            ]
        assert "score_components" in columns

        row = storage.get_transparency_result("old-doc")
        assert isinstance(row, TransparencyResult)
        assert row.score_components is None
        assert not any("could not be read" in w for w in row.warnings)
