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

"""A file holding a credential is never readable by anyone but its owner.

``config.json`` holds the NCBI API key and ``.env`` the Anthropic key. Both
used to be written with ``open(path, "w")`` and chmod-ed afterwards, so each
spent a moment with whatever the umask allowed, and when ``chmod`` failed -- as
it can on a filesystem without POSIX modes -- that moment never ended: the
config file logged a warning and ``.env`` said nothing at all.
"""

import os
import stat
from collections.abc import Iterator
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import CONFIG_DIR_PERMISSIONS, CONFIG_FILE_PERMISSIONS

SECRET = "ncbi-api-key-0123456789abcdef"
ENV_KEY = "ANTHROPIC_API_KEY"
# Group and others may read: what a fresh file gets on a typical system.
PERMISSIVE_UMASK = 0o022


def _config_with_key() -> LiteConfig:
    """A configuration carrying a PubMed API key."""
    config = LiteConfig()
    config.pubmed.email = "researcher@example.org"
    config.pubmed.api_key = SECRET
    return config


def _mode(path: Path) -> int:
    """The permission bits of ``path``."""
    return stat.S_IMODE(path.stat().st_mode)


def _refuse_chmod(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make every chmod fail, as on a filesystem without POSIX modes."""

    def refuse(*args: object, **kwargs: object) -> None:
        """Fail the way an unsupported chmod does."""
        raise PermissionError("chmod is not supported on this filesystem")

    monkeypatch.setattr(os, "chmod", refuse)


def _save_api_key(env_file: Path, key: str, value: str) -> None:
    """Save a key through the Settings dialog's own method.

    The method reads nothing from the dialog but its configuration, so a
    stand-in carrying a real one exercises the real code without a window.
    """
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    config = LiteConfig()
    config.storage.data_dir = env_file.parent
    SettingsDialog._save_api_key(SimpleNamespace(config=config), key, value)  # type: ignore[arg-type]


def _unserialisable(self: LiteConfig) -> dict[str, Any]:
    """A configuration that ``json`` fails on part-way through."""
    return {"pubmed": {"email": "researcher@example.org"}, "broken": object()}


@pytest.fixture
def permissive_umask() -> Iterator[None]:
    """Create files as a typical system would: readable by group and others."""
    previous = os.umask(PERMISSIVE_UMASK)
    try:
        yield
    finally:
        os.umask(previous)


class TestConfigFile:
    """``LiteConfig.save``, which writes the NCBI API key."""

    @pytest.mark.parametrize("already_there", [False, True], ids=["new", "rewritten"])
    def test_is_owner_only_even_when_chmod_fails(
        self,
        already_there: bool,
        tmp_path: Path,
        permissive_umask: None,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """No window in which the key is readable, and none left open by a failure."""
        config_path = tmp_path / "config.json"
        if already_there:
            config_path.write_text("{}", encoding="utf-8")
        _refuse_chmod(monkeypatch)

        _config_with_key().save(config_path)

        assert _mode(config_path) == CONFIG_FILE_PERMISSIONS
        assert LiteConfig.load(config_path).pubmed.api_key == SECRET

    def test_a_directory_created_for_it_is_owner_only(
        self, tmp_path: Path, permissive_umask: None
    ) -> None:
        """What the save creates to hold the file is private too."""
        config_path = tmp_path / "new" / "config.json"

        _config_with_key().save(config_path)

        assert _mode(config_path.parent) == CONFIG_DIR_PERMISSIONS

    def test_a_save_that_fails_keeps_the_saved_key(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A failure part-way through must not cost the user the key already on disk."""
        config_path = tmp_path / "config.json"
        _config_with_key().save(config_path)
        monkeypatch.setattr(LiteConfig, "to_dict", _unserialisable)

        with pytest.raises(TypeError):
            LiteConfig().save(config_path)

        assert LiteConfig.load(config_path).pubmed.api_key == SECRET

    def test_a_write_that_fails_leaves_no_copy_of_the_key_behind(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A half-finished save leaves the directory exactly as it found it."""
        config_path = tmp_path / "config.json"
        config_path.write_text("{}", encoding="utf-8")

        def refuse(*args: object, **kwargs: object) -> None:
            """Fail the way a full or read-only disk does."""
            raise OSError("No space left on device")

        monkeypatch.setattr(os, "replace", refuse)

        with pytest.raises(OSError):
            _config_with_key().save(config_path)

        assert [path.name for path in tmp_path.iterdir()] == ["config.json"]
        assert config_path.read_text(encoding="utf-8") == "{}"

    def test_a_symlinked_config_file_stays_a_symlink(self, tmp_path: Path) -> None:
        """Replacing the file must not replace a link the user made to it."""
        real_path = tmp_path / "dotfiles" / "config.json"
        real_path.parent.mkdir()
        real_path.write_text("{}", encoding="utf-8")
        link_path = tmp_path / "config.json"
        link_path.symlink_to(real_path)

        _config_with_key().save(link_path)

        assert link_path.is_symlink()
        assert LiteConfig.load(real_path).pubmed.api_key == SECRET


class TestEnvFile:
    """The Settings dialog's ``.env``, which holds the Anthropic API key."""

    @pytest.mark.parametrize("already_there", [False, True], ids=["new", "rewritten"])
    def test_is_owner_only_even_when_chmod_fails(
        self,
        already_there: bool,
        tmp_path: Path,
        permissive_umask: None,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """The key is private, and the file's other entries survive the rewrite."""
        env_file = tmp_path / ".env"
        if already_there:
            env_file.write_text(f"OTHER=kept\n{ENV_KEY}=old\n", encoding="utf-8")
        _refuse_chmod(monkeypatch)

        _save_api_key(env_file, ENV_KEY, SECRET)

        assert _mode(env_file) == CONFIG_FILE_PERMISSIONS
        expected = f"OTHER=kept\n{ENV_KEY}={SECRET}\n" if already_there else f"{ENV_KEY}={SECRET}\n"
        assert env_file.read_text(encoding="utf-8") == expected
