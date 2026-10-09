"""A settings dialog built by a test starts no provider thread.

Each ``SettingsDialog`` asks every enabled provider for its models on a
thread of its own, and a Test Connection click starts another. In a test
those threads reached the live providers and outlived the test. The autouse
``_no_live_model_fetch`` fixture in ``tests/conftest.py`` keeps them from
starting; this pins that it does, and that a test marked
``real_model_fetch`` is left alone.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from PySide6.QtWidgets import QApplication


@pytest.fixture
def qapp() -> QApplication:
    """A QApplication for the dialog test."""
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def test_the_dialog_queues_its_fetches_but_runs_none(qapp: QApplication) -> None:
    """Both providers are asked for, and neither thread runs."""
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    config = LiteConfig()
    for name in ("anthropic", "ollama"):
        config.models.providers[name].enabled = True
    dialog = SettingsDialog(config)

    workers = dialog._model_fetch_workers
    assert {worker.provider for worker in workers} == {"anthropic", "ollama"}
    assert not any(worker.isRunning() or worker.isFinished() for worker in workers)
    dialog.close()


def test_a_connection_test_click_runs_no_thread(qapp: QApplication) -> None:
    """Both Test Connection buttons queue a test, and neither thread runs."""
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    dialog = SettingsDialog(LiteConfig())
    dialog.anthropic_test_btn.click()
    dialog.ollama_test_btn.click()

    workers = dialog._connection_test_workers
    assert {worker.provider for worker in workers} == {"anthropic", "ollama"}
    assert not any(worker.isRunning() or worker.isFinished() for worker in workers)
    dialog.close()


@pytest.mark.real_model_fetch
def test_the_marker_leaves_the_threads_real() -> None:
    """A ``real_model_fetch`` test gets QThread's own ``start``.

    Nothing is built or started here, so no thread runs.
    """
    pytest.importorskip("PySide6")
    from PySide6.QtCore import QThread

    from bmlibrarian_lite.gui import settings_dialog

    assert settings_dialog.ModelFetchWorker.start is QThread.start
    assert settings_dialog.ProviderConnectionTestWorker.start is QThread.start
