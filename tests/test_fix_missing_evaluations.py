# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The scoring scripts re-score a failure without losing it (#306 review).

``scripts/fix_missing_evaluations.py`` finds a model's failed scorings and
scores them again. It deleted the failure before re-scoring, so a re-score
that raised left no trace of the document ever having failed; its DELETE
spanned every question, so a failure under a question the run was filtered
away from was erased and never retried; and a failure already scored since was
re-scored and paid for again. ``scripts/run_benchmark.py`` read an older
build's failure, stored as a 1, as already scored and never retried it.
"""

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    DocumentSource,
    EvaluationErrorCode,
    Evaluator,
    LiteDocument,
    ScoredDocument,
)
from bmlibrarian_lite.storage import LiteStorage

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
QUESTION = "Does aspirin prevent stroke?"
OTHER_QUESTION = "Does aspirin prevent migraine?"
TIMED_OUT = EvaluationErrorCode.API_TIMEOUT


def _load_script(name: str) -> ModuleType:
    """Load a script as a module (scripts/ is not a package).

    Args:
        name: The script's file name, without ``.py``.

    Returns:
        The loaded module.
    """
    spec = importlib.util.spec_from_file_location(name, SCRIPTS_DIR / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


fix = _load_script("fix_missing_evaluations")
run_benchmark = _load_script("run_benchmark")
JUDGE = Evaluator.from_model_config(provider="ollama", model_name="judge")


@pytest.fixture
def storage(tmp_path: Any) -> LiteStorage:
    """A database this test owns, knowing the judge."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    storage = LiteStorage(config)
    storage.upsert_evaluator(JUDGE)
    return storage


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin reduced stroke incidence.",
        authors=["Smith J"],
        year=2024,
        journal="Journal",
        pmid=pmid,
        source=DocumentSource.PUBMED,
    )


def store(
    storage: LiteStorage,
    question: str,
    pmid: str,
    score: int,
    explanation: str = "Read and judged.",
) -> None:
    """Store one row by the judge, in a checkpoint of its own."""
    document = make_document(pmid)
    storage.upsert_document(document)
    checkpoint = storage.create_checkpoint(research_question=question)
    storage.save_scored_document(
        ScoredDocument(
            document=document,
            score=score,
            explanation=explanation,
            evaluator_id=JUDGE.id,
            evaluator=JUDGE,
        ),
        checkpoint.id,
    )


def stored_scores(storage: LiteStorage, question: str, pmid: str) -> list[int]:
    """Every score the judge has stored for the document under the question."""
    with storage._sqlite_connection() as conn:
        rows = conn.execute(
            """
            SELECT sd.score FROM scored_documents sd
            JOIN review_checkpoints rc ON sd.checkpoint_id = rc.id
            WHERE sd.document_id = ? AND sd.evaluator_id = ?
              AND rc.research_question = ?
            ORDER BY sd.score
            """,
            (f"doc-{pmid}", JUDGE.id, question),
        ).fetchall()
    return [row["score"] for row in rows]


class TestWhatIsListed:
    """Only what is still failing is re-scored."""

    def test_both_forms_of_a_failure_are_listed(self, storage: LiteStorage) -> None:
        """A negative code, and the 1 older builds stored in its place."""
        store(storage, QUESTION, "1", TIMED_OUT.value)
        store(storage, QUESTION, "2", 1, "Scoring failed: Connection refused")
        store(storage, QUESTION, "3", 1, "Not relevant at all.")

        listed = fix.get_failed_evaluations(storage, JUDGE.id)

        assert sorted(f["document_id"] for f in listed) == ["doc-1", "doc-2"]

    def test_a_failure_scored_since_is_not_listed(self, storage: LiteStorage) -> None:
        """Re-scoring it only cost money."""
        store(storage, QUESTION, "1", TIMED_OUT.value)
        store(storage, QUESTION, "1", 4)

        assert fix.get_failed_evaluations(storage, JUDGE.id) == []


class TestWhatIsDeleted:
    """A failure is retired only for its question, and only once replaced."""

    def test_only_that_questions_failure_is_deleted(self, storage: LiteStorage) -> None:
        """Across every question, a failure under another one was erased."""
        store(storage, QUESTION, "1", TIMED_OUT.value)
        store(storage, OTHER_QUESTION, "1", TIMED_OUT.value)

        fix.delete_failed_evaluation(storage, "doc-1", JUDGE.id, QUESTION)

        assert stored_scores(storage, QUESTION, "1") == []
        assert stored_scores(storage, OTHER_QUESTION, "1") == [TIMED_OUT.value]

    def test_a_judged_one_is_never_deleted(self, storage: LiteStorage) -> None:
        """Only a failure's 1 is a failure; a model's own 1 is its verdict."""
        store(storage, QUESTION, "1", 1, "Scoring failed: Connection refused")
        store(storage, QUESTION, "2", 1, "Not relevant at all.")

        fix.delete_failed_evaluation(storage, "doc-1", JUDGE.id, QUESTION)
        fix.delete_failed_evaluation(storage, "doc-2", JUDGE.id, QUESTION)

        assert stored_scores(storage, QUESTION, "1") == []
        assert stored_scores(storage, QUESTION, "2") == [1]

    def test_a_judgement_retires_the_failure(self, storage: LiteStorage) -> None:
        """The ordinary case: the new score replaces the failure."""
        store(storage, QUESTION, "1", TIMED_OUT.value)
        checkpoint = storage.create_checkpoint(research_question=QUESTION)
        rescored = ScoredDocument(
            make_document("1"), 4, "On topic.", evaluator_id=JUDGE.id, evaluator=JUDGE
        )

        assert fix.record_rescore(storage, rescored, QUESTION, JUDGE.id, checkpoint.id)
        assert stored_scores(storage, QUESTION, "1") == [4]

    def test_a_second_failure_keeps_the_first(self, storage: LiteStorage) -> None:
        """Nothing replaced it, so nothing is retired."""
        store(storage, QUESTION, "1", TIMED_OUT.value)
        checkpoint = storage.create_checkpoint(research_question=QUESTION)
        again = ScoredDocument(
            make_document("1"),
            EvaluationErrorCode.API_CONNECTION_ERROR.value,
            "Scoring failed: Failed to connect to API",
            evaluator_id=JUDGE.id,
            evaluator=JUDGE,
        )

        assert not fix.record_rescore(storage, again, QUESTION, JUDGE.id, checkpoint.id)
        assert stored_scores(storage, QUESTION, "1") == sorted(
            [TIMED_OUT.value, EvaluationErrorCode.API_CONNECTION_ERROR.value]
        )

    def test_a_save_that_raises_keeps_the_failure(
        self, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Deleted first, the document was left with no record it ever failed."""
        store(storage, QUESTION, "1", TIMED_OUT.value)
        checkpoint = storage.create_checkpoint(research_question=QUESTION)
        rescored = ScoredDocument(
            make_document("1"), 4, "On topic.", evaluator_id=JUDGE.id, evaluator=JUDGE
        )

        def broken_save(*_: Any) -> None:
            raise OSError("disk full")

        monkeypatch.setattr(storage, "save_scored_document", broken_save)

        with pytest.raises(OSError):
            fix.record_rescore(storage, rescored, QUESTION, JUDGE.id, checkpoint.id)
        assert stored_scores(storage, QUESTION, "1") == [TIMED_OUT.value]


class TestTheBenchmarkScriptRetriesFailures:
    """A failure is not "already scored", in either form."""

    def test_only_a_judgement_is_already_scored(self, storage: LiteStorage) -> None:
        """The older 1 read as done and was never retried."""
        store(storage, QUESTION, "1", TIMED_OUT.value)
        store(storage, QUESTION, "2", 1, "Scoring failed: Connection refused")
        store(storage, QUESTION, "3", 1, "Not relevant at all.")

        done = run_benchmark.get_already_scored_doc_ids(
            storage, JUDGE.id, ["doc-1", "doc-2", "doc-3"], QUESTION
        )

        assert done == {"doc-3"}
