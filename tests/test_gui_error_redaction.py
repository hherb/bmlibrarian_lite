# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A worker's error signal carries no credential (#330).

A provider prints the request, key and all, in its error. Each worker below
puts that text on a signal the tab shows the reader, so each redacts it.
"""

from typing import Any
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.gui import workers  # noqa: E402

SECRET = "SECRET123"
LEAKY = f"Client error for url 'https://h/p?key={SECRET}'"


def collect(signal: Any) -> list[tuple[Any, ...]]:
    """Connect a recorder to a signal; the list fills as it is emitted."""
    got: list[tuple[Any, ...]] = []
    signal.connect(lambda *args: got.append(args))
    return got


def test_the_shared_unexpected_error_path_redacts() -> None:
    """``SingleOutcome._run_once`` hands its fallback redacted text."""
    worker = workers.AnswerWorker(MagicMock(), "q")
    seen: list[str] = []

    def body() -> None:
        raise RuntimeError(LEAKY)

    worker._run_once(body, seen.append)

    [text] = seen
    assert SECRET not in text
    assert "Client error" in text


def test_the_interrogation_answer_error_redacts() -> None:
    """The error shown in the chat carries no key."""
    agent = MagicMock()
    agent.ask.side_effect = RuntimeError(LEAKY)
    worker = workers.AnswerWorker(agent, "q")
    errors = collect(worker.error)

    worker.run()

    [(text,)] = errors
    assert SECRET not in text


def test_the_quality_filter_error_redacts() -> None:
    """The quality filter's error signal carries no key."""
    manager = MagicMock()
    manager.filter_documents.side_effect = RuntimeError(LEAKY)
    worker = workers.QualityFilterWorker(manager, [], MagicMock())
    errors = collect(worker.error)

    worker.run()

    [(text,)] = errors
    assert SECRET not in text


@pytest.mark.parametrize(
    ("module", "worker_name", "runner_name"),
    [
        ("benchmark_dialog", "BenchmarkWorker", "BenchmarkRunner"),
        ("quality_benchmark_dialog", "QualityBenchmarkWorker", "QualityBenchmarkRunner"),
    ],
)
def test_a_benchmark_error_redacts(
    monkeypatch: pytest.MonkeyPatch, module: str, worker_name: str, runner_name: str
) -> None:
    """Both benchmark dialogs' error signals carry no key."""
    import importlib

    import bmlibrarian_lite.benchmarking as benchmarking

    runner = MagicMock()
    runner.run_quick_benchmark.side_effect = RuntimeError(LEAKY)
    monkeypatch.setattr(benchmarking, runner_name, lambda *a, **k: runner)
    dialog = importlib.import_module(f"bmlibrarian_lite.gui.{module}")
    worker = getattr(dialog, worker_name)(MagicMock(), MagicMock(), "q", [], ["m"])
    errors = collect(worker.error)

    worker.run()

    [(text,)] = errors
    assert SECRET not in text
