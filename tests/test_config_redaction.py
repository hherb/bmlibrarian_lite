# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
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

"""Tests that secrets never leave the config file in clear text.

The config file itself is written with 0600 permissions precisely because it
holds an NCBI API key. Anything that renders the configuration for a human --
``bmll config``, ``bmll config --json``, a log line, a pasted bug report -- has
none of that protection, so it must go through the redacted view.
"""

import argparse
import json
from collections.abc import Callable
from pathlib import Path

import pytest

import bmll
from bmlibrarian_lite import cli
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import (
    CONFIG_FILE_PERMISSIONS,
    REDACTED_SECRET_PLACEHOLDER,
)

SECRET = "ncbi-api-key-0123456789abcdef"


def _config_with_key() -> LiteConfig:
    """A configuration carrying a PubMed API key."""
    config = LiteConfig()
    config.pubmed.email = "researcher@example.org"
    config.pubmed.api_key = SECRET
    return config


def test_to_dict_keeps_the_key() -> None:
    """The on-disk form must keep the real key, or saving would destroy it."""
    assert _config_with_key().to_dict()["pubmed"]["api_key"] == SECRET


def test_save_then_load_round_trips_the_real_key(tmp_path: Path) -> None:
    """``save()`` must write the key itself, not the placeholder.

    Guards the likeliest follow-up mistake to this change: pointing ``save()``
    at :meth:`to_redacted_dict`. That would overwrite the user's key on disk
    with the placeholder, and the next ``load()`` would hand a fake credential
    to NCBI.
    """
    config_path = tmp_path / "config.json"
    _config_with_key().save(config_path)

    assert LiteConfig.load(config_path).pubmed.api_key == SECRET
    assert REDACTED_SECRET_PLACEHOLDER not in config_path.read_text()


def test_saved_config_file_is_owner_only(tmp_path: Path) -> None:
    """The 0600 mode is the premise the whole redaction story rests on."""
    config_path = tmp_path / "config.json"
    _config_with_key().save(config_path)

    assert config_path.stat().st_mode & 0o777 == CONFIG_FILE_PERMISSIONS


def test_loading_the_placeholder_does_not_yield_a_key(tmp_path: Path) -> None:
    """Saving ``--json`` output back as config.json must not arm a fake key.

    The placeholder is a truthy string, so without the load-path guard it would
    shadow ``NCBI_API_KEY``, claim the rate limit reserved for real keys, and be
    sent to NCBI as if it authenticated anything.
    """
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps(_config_with_key().to_redacted_dict()))

    assert LiteConfig.load(config_path).pubmed.api_key is None


def test_redacted_dict_replaces_the_key() -> None:
    """The displayable form stands a placeholder in for the key."""
    redacted = _config_with_key().to_redacted_dict()

    assert redacted["pubmed"]["api_key"] == REDACTED_SECRET_PLACEHOLDER


def test_redacted_json_does_not_contain_the_key_anywhere() -> None:
    """Serialised in full, the redacted view leaks the secret nowhere.

    Checking the whole JSON blob rather than the one key catches a secret that
    a future field copies into some other corner of the tree.
    """
    payload = json.dumps(_config_with_key().to_redacted_dict())

    assert SECRET not in payload


@pytest.mark.parametrize("unset", [None, ""], ids=["none", "empty-string"])
def test_redacted_dict_reports_an_unset_key_as_unset(unset: str | None) -> None:
    """No key configured must not look like a key we are hiding."""
    config = LiteConfig()
    config.pubmed.api_key = unset

    assert config.to_redacted_dict()["pubmed"]["api_key"] is None


def test_redacted_dict_matches_to_dict_everywhere_else() -> None:
    """Redaction touches the secret and nothing else.

    ``bmll config --json`` is a diagnostic surface, so the redacted view has to
    stay a faithful picture of the configuration -- including the email address
    the plain-text output already prints.
    """
    config = _config_with_key()
    full = config.to_dict()
    redacted = config.to_redacted_dict()

    full["pubmed"]["api_key"] = redacted["pubmed"]["api_key"]
    assert redacted == full


# The fix is one line, duplicated in two unsynchronised CLI entry points. Both
# are exercised here so reverting either one -- which is all it takes to reopen
# the alert -- cannot leave a green suite behind.
CONFIG_COMMANDS = [
    pytest.param(cli.cmd_config, id="bmlibrarian_lite.cli"),
    pytest.param(bmll.cmd_config, id="bmll"),
]


@pytest.fixture
def _loads_config_with_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make ``LiteConfig.load()`` return a configuration carrying the key."""
    monkeypatch.setattr(
        LiteConfig, "load", classmethod(lambda cls, path=None: _config_with_key())
    )


@pytest.mark.usefixtures("_loads_config_with_key")
@pytest.mark.parametrize("cmd_config", CONFIG_COMMANDS)
def test_config_json_output_does_not_print_the_key(
    cmd_config: Callable[[argparse.Namespace], int],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``config --json`` is the surface the CodeQL alert was raised against."""
    assert cmd_config(argparse.Namespace(json=True)) == 0

    printed = capsys.readouterr().out
    assert SECRET not in printed
    assert json.loads(printed)["pubmed"]["api_key"] == REDACTED_SECRET_PLACEHOLDER


@pytest.mark.usefixtures("_loads_config_with_key")
@pytest.mark.parametrize("cmd_config", CONFIG_COMMANDS)
def test_config_human_output_does_not_print_the_key(
    cmd_config: Callable[[argparse.Namespace], int],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The human-readable branch must run, and must mask the key while doing it.

    It used to raise ``AttributeError`` on a config field that no longer exists,
    so its masking was never reached -- leaving ``--json`` as the only working
    view of the configuration, and the only one that leaked.
    """
    assert cmd_config(argparse.Namespace(json=False)) == 0

    printed = capsys.readouterr().out
    assert SECRET not in printed
    assert REDACTED_SECRET_PLACEHOLDER in printed
