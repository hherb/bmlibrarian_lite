"""A settings dialog built by a test starts no provider thread.

Each ``SettingsDialog`` asks every enabled provider for its models on a
thread of its own. In a test the dialog has no parent and is collected
while those threads run, which crashed the interpreter in CI. The autouse
``_no_live_model_fetch`` fixture in ``tests/conftest.py`` keeps them from
starting; this pins that it does.
"""

import pytest


@pytest.fixture
def qapp():
    """A QApplication for the dialog test."""
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def test_the_dialog_queues_its_fetches_but_runs_none(qapp) -> None:
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
