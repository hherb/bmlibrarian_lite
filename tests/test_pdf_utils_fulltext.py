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

"""
Unit tests for PDF utilities full-text functions.

Tests cover:
- get_fulltext_base_dir()
- generate_fulltext_path()
- find_existing_fulltext()
- save_fulltext_markdown()
"""

import os
import pytest
from pathlib import Path
from typing import Dict, Any
from unittest.mock import patch

from bmlibrarian_lite.jats_markdown import JATS_MARKDOWN_CONVERTER_VERSION

from bmlibrarian_lite.pdf_utils import (
    get_fulltext_base_dir,
    generate_fulltext_path,
    find_existing_fulltext,
    fulltext_cache_stamp,
    read_cached_fulltext,
    read_stale_cached_fulltext,
    save_fulltext_markdown,
    split_cache_stamp,
)
from bmlibrarian_lite.constants import DEFAULT_FULLTEXT_BASE_DIR


class TestGetFulltextBaseDir:
    """Tests for get_fulltext_base_dir() function."""

    def test_returns_default_path(self) -> None:
        """Test that default path is returned."""
        base_dir = get_fulltext_base_dir()
        expected = Path.home() / DEFAULT_FULLTEXT_BASE_DIR
        assert base_dir == expected

    def test_returns_path_object(self) -> None:
        """Test that function returns a Path object."""
        base_dir = get_fulltext_base_dir()
        assert isinstance(base_dir, Path)


class TestGenerateFulltextPath:
    """Tests for generate_fulltext_path() function."""

    def test_with_pmcid(self, temp_dir: Path) -> None:
        """Test path generation with PMC ID."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        path = generate_fulltext_path(doc_dict, temp_dir)

        assert path.parent.name == "2025"
        assert path.name == "PMC12101959.md"

    def test_with_pmcid_without_prefix(self, temp_dir: Path) -> None:
        """Test PMC ID normalization (adds PMC prefix)."""
        doc_dict = {"pmcid": "12101959", "year": 2025}
        path = generate_fulltext_path(doc_dict, temp_dir)

        assert path.name == "PMC12101959.md"

    def test_with_pmc_id_key(self, temp_dir: Path) -> None:
        """Test with pmc_id key (alternative naming)."""
        doc_dict = {"pmc_id": "PMC12101959", "year": 2025}
        path = generate_fulltext_path(doc_dict, temp_dir)

        assert path.name == "PMC12101959.md"

    def test_with_pmid_only(self, temp_dir: Path) -> None:
        """Test path generation with PMID only (no PMC ID)."""
        doc_dict = {"pmid": "39521399", "year": 2025}
        path = generate_fulltext_path(doc_dict, temp_dir)

        assert path.name == "pmid_39521399.md"

    def test_with_doi_only(self, temp_dir: Path) -> None:
        """Test path generation with DOI only."""
        doc_dict = {"doi": "10.1053/j.ajkd.2024.08.012", "year": 2025}
        path = generate_fulltext_path(doc_dict, temp_dir)

        # DOI slashes should be replaced
        assert "10.1053_j.ajkd.2024.08.012.md" in path.name

    def test_with_doc_id_only(self, temp_dir: Path) -> None:
        """Test path generation with document ID only."""
        doc_dict = {"id": "test-doc-123", "year": 2025}
        path = generate_fulltext_path(doc_dict, temp_dir)

        assert path.name == "doc_test-doc-123.md"

    def test_unknown_year(self, temp_dir: Path) -> None:
        """Test path generation without year."""
        doc_dict = {"pmcid": "PMC12101959"}
        path = generate_fulltext_path(doc_dict, temp_dir)

        assert path.parent.name == "unknown"

    def test_creates_year_directory(self, temp_dir: Path) -> None:
        """Test that year directory is created."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        path = generate_fulltext_path(doc_dict, temp_dir)

        assert (temp_dir / "2025").exists()

    def test_priority_pmcid_over_pmid(self, temp_dir: Path) -> None:
        """Test that PMC ID takes priority over PMID."""
        doc_dict = {
            "pmcid": "PMC12101959",
            "pmid": "39521399",
            "doi": "10.1234/test",
            "year": 2025,
        }
        path = generate_fulltext_path(doc_dict, temp_dir)

        assert path.name == "PMC12101959.md"


class TestFindExistingFulltext:
    """Tests for find_existing_fulltext() function."""

    def test_finds_existing_by_pmcid(self, temp_dir: Path) -> None:
        """Test finding existing fulltext by PMC ID."""
        # Create the file
        year_dir = temp_dir / "2025"
        year_dir.mkdir()
        test_file = year_dir / "PMC12101959.md"
        test_file.write_text("# Test")

        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        found = find_existing_fulltext(doc_dict, temp_dir)

        assert found is not None
        assert found == test_file

    def test_finds_existing_in_different_year(self, temp_dir: Path) -> None:
        """Test finding fulltext in unexpected year directory."""
        # Create file in 2024 directory
        year_dir = temp_dir / "2024"
        year_dir.mkdir()
        test_file = year_dir / "PMC12101959.md"
        test_file.write_text("# Test")

        # Search with 2025 year
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        found = find_existing_fulltext(doc_dict, temp_dir)

        assert found is not None
        assert found == test_file

    def test_finds_by_pmid(self, temp_dir: Path) -> None:
        """Test finding fulltext by PMID."""
        year_dir = temp_dir / "2025"
        year_dir.mkdir()
        test_file = year_dir / "pmid_39521399.md"
        test_file.write_text("# Test")

        doc_dict = {"pmid": "39521399", "year": 2025}
        found = find_existing_fulltext(doc_dict, temp_dir)

        assert found is not None
        assert found == test_file

    def test_returns_none_when_not_found(self, temp_dir: Path) -> None:
        """Test returns None when fulltext doesn't exist."""
        doc_dict = {"pmcid": "PMC99999999", "year": 2025}
        found = find_existing_fulltext(doc_dict, temp_dir)

        assert found is None

    def test_returns_none_for_empty_dir(self, temp_dir: Path) -> None:
        """Test returns None when base directory is empty."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        found = find_existing_fulltext(doc_dict, temp_dir)

        assert found is None


class TestSaveFulltextMarkdown:
    """Tests for save_fulltext_markdown() function."""

    def test_saves_content(self, temp_dir: Path) -> None:
        """Test that content is saved correctly."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        content = "# Test Article\n\nThis is the content."

        path = save_fulltext_markdown(doc_dict, content, temp_dir)

        assert path.exists()
        assert read_cached_fulltext(path) == content

    def test_the_file_is_stamped_with_its_converter(self, temp_dir: Path) -> None:
        """#420: the stamp is what lets a converter fix reach cached articles."""
        path = save_fulltext_markdown({"pmcid": "PMC1", "year": 2025}, "# T", temp_dir)

        first_line = path.read_text(encoding="utf-8").split("\n", 1)[0]
        assert first_line == fulltext_cache_stamp()
        assert str(JATS_MARKDOWN_CONVERTER_VERSION) in first_line

    def test_the_stamp_is_an_html_comment(self) -> None:
        """It must render as nothing where the file is opened as markdown."""
        stamp = fulltext_cache_stamp()
        assert stamp.startswith("<!--") and stamp.endswith("-->")

    def test_creates_directories(self, temp_dir: Path) -> None:
        """Test that necessary directories are created."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}

        save_fulltext_markdown(doc_dict, "# Test", temp_dir)

        assert (temp_dir / "2025").exists()

    def test_returns_path(self, temp_dir: Path) -> None:
        """Test that function returns the file path."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}

        path = save_fulltext_markdown(doc_dict, "# Test", temp_dir)

        assert isinstance(path, Path)
        assert path.suffix == ".md"

    def test_overwrites_existing(self, temp_dir: Path) -> None:
        """Test that existing files are overwritten."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}

        save_fulltext_markdown(doc_dict, "Version 1", temp_dir)
        path = save_fulltext_markdown(doc_dict, "Version 2", temp_dir)

        assert read_cached_fulltext(path) == "Version 2"

    def test_handles_unicode(self, temp_dir: Path) -> None:
        """Test that unicode content is handled correctly."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        content = "# Test with Unicode: café, naïve, 日本語"

        path = save_fulltext_markdown(doc_dict, content, temp_dir)

        assert read_cached_fulltext(path) == content


class TestReadCachedFulltext:
    """Tests for read_cached_fulltext() function."""

    def test_an_unstamped_file_is_stale(self, temp_dir: Path) -> None:
        """Every file cached before #420 carries no stamp."""
        path = temp_dir / "PMC1.md"
        path.write_text("# Old markdown", encoding="utf-8")
        assert read_cached_fulltext(path) is None

    def test_an_older_converters_file_is_stale(self, temp_dir: Path) -> None:
        """A file an earlier converter stamped is converted again too."""
        path = temp_dir / "PMC1.md"
        older = fulltext_cache_stamp(JATS_MARKDOWN_CONVERTER_VERSION - 1)
        path.write_text(f"{older}\n# Old markdown", encoding="utf-8")
        assert read_cached_fulltext(path) is None

    def test_a_current_file_is_read_without_its_stamp(self, temp_dir: Path) -> None:
        """Control: the current converter's file is served, stamp removed."""
        path = temp_dir / "PMC1.md"
        path.write_text(f"{fulltext_cache_stamp()}\n# Current\n\nBody.", encoding="utf-8")
        assert read_cached_fulltext(path) == "# Current\n\nBody."

    @pytest.mark.parametrize(
        "rest", ["", "\n", "\n   \n"], ids=["stamp-only", "newline", "whitespace"]
    )
    def test_a_stamped_file_with_nothing_after_it_is_stale(
        self, temp_dir: Path, rest: str
    ) -> None:
        """#426 review: a damaged file must not stop the article being fetched.

        A cached file is never written empty, and served as a hit it made
        discovery return an empty document for good.
        """
        path = temp_dir / "PMC1.md"
        path.write_text(f"{fulltext_cache_stamp()}{rest}", encoding="utf-8")
        assert read_cached_fulltext(path) is None

    def test_an_empty_file_is_stale(self, temp_dir: Path) -> None:
        """An empty file carries no stamp."""
        path = temp_dir / "PMC1.md"
        path.write_text("", encoding="utf-8")
        assert read_cached_fulltext(path) is None

    def test_a_newer_converters_file_is_stale(self, temp_dir: Path) -> None:
        """After a downgrade, a file a later converter wrote is not trusted."""
        path = temp_dir / "PMC1.md"
        newer = fulltext_cache_stamp(JATS_MARKDOWN_CONVERTER_VERSION + 1)
        path.write_text(f"{newer}\n# Newer", encoding="utf-8")
        assert read_cached_fulltext(path) is None


class TestReadStaleCachedFulltext:
    """The reader's fallback: an earlier converter's text, stamp removed."""

    def test_an_unstamped_file_is_read_whole(self, temp_dir: Path) -> None:
        """Every file cached before #420 is all markdown."""
        path = temp_dir / "PMC1.md"
        path.write_text("# Old markdown\n\nBody.", encoding="utf-8")
        assert read_stale_cached_fulltext(path) == "# Old markdown\n\nBody."

    def test_an_older_stamp_is_removed(self, temp_dir: Path) -> None:
        """The stamp is an HTML comment, but it is not the article's text."""
        path = temp_dir / "PMC1.md"
        older = fulltext_cache_stamp(JATS_MARKDOWN_CONVERTER_VERSION - 1)
        path.write_text(f"{older}\n# Old", encoding="utf-8")
        assert read_stale_cached_fulltext(path) == "# Old"

    def test_a_blank_file_yields_nothing(self, temp_dir: Path) -> None:
        """Nothing to show is not a document to show."""
        path = temp_dir / "PMC1.md"
        path.write_text(f"{fulltext_cache_stamp()}\n  ", encoding="utf-8")
        assert read_stale_cached_fulltext(path) is None


class TestSplitCacheStamp:
    """split_cache_stamp() recognises a stamp of any version."""

    @pytest.mark.parametrize("version", [1, JATS_MARKDOWN_CONVERTER_VERSION, 99])
    def test_a_stamp_of_any_version_is_split_off(self, version: int) -> None:
        """Any version's stamp is split off."""
        stamp = fulltext_cache_stamp(version)
        assert split_cache_stamp(f"{stamp}\n# T") == (stamp, "# T")

    def test_a_file_without_one_is_all_markdown(self) -> None:
        """A heading on the first line is not a stamp."""
        assert split_cache_stamp("# T\n\nBody") == (None, "# T\n\nBody")


class TestSaveIsAtomic:
    """#426 review: a write cut short must not leave a stamped half-article."""

    def test_no_partial_file_is_left_behind(self, temp_dir: Path) -> None:
        """The file is written aside and moved into place."""
        path = save_fulltext_markdown({"pmcid": "PMC1", "year": 2025}, "# T", temp_dir)
        assert [p.name for p in path.parent.iterdir()] == [path.name]

    def test_a_failed_write_leaves_the_old_file(self, temp_dir: Path) -> None:
        """A write that fails midway does not replace what was cached."""
        doc = {"pmcid": "PMC1", "year": 2025}
        path = save_fulltext_markdown(doc, "# Complete", temp_dir)
        with patch("pathlib.Path.write_text", side_effect=OSError("disk full")):
            with pytest.raises(OSError):
                save_fulltext_markdown(doc, "# Half", temp_dir)
        assert read_cached_fulltext(path) == "# Complete"

    def test_a_failed_move_leaves_no_partial_file(self, temp_dir: Path) -> None:
        """The aside copy is removed when it cannot be moved into place."""
        doc = {"pmcid": "PMC1", "year": 2025}
        path = save_fulltext_markdown(doc, "# Complete", temp_dir)
        with patch("bmlibrarian_lite.pdf_utils.os.replace", side_effect=OSError("busy")):
            with pytest.raises(OSError):
                save_fulltext_markdown(doc, "# New", temp_dir)
        assert [p.name for p in path.parent.iterdir()] == [path.name]
        assert read_cached_fulltext(path) == "# Complete"
