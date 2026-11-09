"""``bmll -v validate``: the verbose details name the configured models."""

import importlib.util
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite import LiteConfig, cli

ROOT = Path(__file__).resolve().parent.parent


def _dev_cli() -> Any:
    """The development entry point at the repository root, ``bmll.py``."""
    spec = importlib.util.spec_from_file_location("bmll_dev", ROOT / "bmll.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize("entry", [lambda: cli, _dev_cli], ids=["bmll", "bmll.py"])
@pytest.mark.parametrize(
    ("model", "shown"),
    [("claude-x", "Default Model: claude-x"), ("", "Default Model: (provider default)")],
    ids=["model", "no-model"],
)
def test_verbose_validate_prints_the_configured_models(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    entry: Callable[[], Any],
    model: str,
    shown: str,
) -> None:
    """A valid configuration exits 0 and its verbose details name the default provider and model.

    With no model configured, the details say the provider's default is used.
    """
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    config.models.default_provider = "anthropic"
    config.models.default_model = model
    monkeypatch.setattr(LiteConfig, "load", classmethod(lambda cls, config_path=None: config))

    args = entry().create_parser().parse_args(["-v", "validate"])
    assert int(args.func(args)) == 0

    out = capsys.readouterr().out
    assert "Configuration is valid." in out
    assert "Default Provider: anthropic" in out
    assert shown in out
