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

import json

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import REDACTED_SECRET_PLACEHOLDER

SECRET = "ncbi-api-key-0123456789abcdef"


def _config_with_key() -> LiteConfig:
    """A configuration carrying a PubMed API key."""
    config = LiteConfig()
    config.pubmed.email = "researcher@example.org"
    config.pubmed.api_key = SECRET
    return config


def test_to_dict_keeps_the_key_so_save_can_round_trip() -> None:
    """The on-disk form must keep the real key, or saving would destroy it."""
    assert _config_with_key().to_dict()["pubmed"]["api_key"] == SECRET


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


def test_redacted_dict_reports_an_unset_key_as_unset() -> None:
    """No key configured must not look like a key we are hiding."""
    config = LiteConfig()
    config.pubmed.api_key = None

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
