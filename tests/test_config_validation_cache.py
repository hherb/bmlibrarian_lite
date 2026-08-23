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

"""Tests for the configuration digest behind the validation cache.

``validate()`` is cached on a digest of the configuration. The digest has to
change whenever the configuration does, or a user who fixes a setting keeps
being shown the error they just fixed.
"""

from bmlibrarian_lite.config import LiteConfig

SHA256_HEX_LENGTH = 64


def test_digest_is_sha256_shaped() -> None:
    """MD5 was replaced with SHA-256; the length is what tells them apart."""
    digest = LiteConfig()._compute_config_hash()

    assert len(digest) == SHA256_HEX_LENGTH
    assert int(digest, 16) >= 0


def test_digest_is_stable_for_an_unchanged_configuration() -> None:
    """A cache key that varied per call would never hit."""
    config = LiteConfig()

    assert config._compute_config_hash() == config._compute_config_hash()


def test_digest_changes_when_a_validated_field_changes() -> None:
    """Otherwise the cache serves a stale verdict across a real edit.

    ``pubmed.email`` is checked by ``validate()``, so a configuration whose
    email changed must not reuse the previous result.
    """
    config = LiteConfig()
    before = config._compute_config_hash()

    config.pubmed.email = "someone.else@example.org"

    assert config._compute_config_hash() != before


def test_digest_changes_when_the_api_key_changes() -> None:
    """The digest covers the full view, key included.

    Pins the coupling the docstring describes: switching the hash input to the
    redacted view would collapse two different configurations onto one key.
    """
    config = LiteConfig()
    before = config._compute_config_hash()

    config.pubmed.api_key = "ncbi-api-key-0123456789abcdef"

    assert config._compute_config_hash() != before
