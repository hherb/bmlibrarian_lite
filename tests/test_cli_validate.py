"""``bmll -v validate``: the verbose details name the configured models."""

from pathlib import Path

import pytest

from bmlibrarian_lite import LiteConfig
from bmlibrarian_lite.cli import create_parser


def test_verbose_validate_prints_the_configured_models(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A valid configuration exits 0 and its verbose details name the default provider and model."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    config.models.default_provider = "anthropic"
    config.models.default_model = "claude-x"
    monkeypatch.setattr(LiteConfig, "load", classmethod(lambda cls, config_path=None: config))

    args = create_parser().parse_args(["-v", "validate"])
    assert int(args.func(args)) == 0

    out = capsys.readouterr().out
    assert "Configuration is valid." in out
    assert "anthropic" in out
    assert "claude-x" in out
