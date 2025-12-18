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

from bmlibrarian_lite.pdf_utils import (
    get_fulltext_base_dir,
    generate_fulltext_path,
    find_existing_fulltext,
    save_fulltext_markdown,
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
        assert path.read_text(encoding="utf-8") == content

    def test_creates_directories(self, temp_dir: Path) -> None:
        """Test that necessary directories are created."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        content = "# Test"

        path = save_fulltext_markdown(doc_dict, content, temp_dir)

        assert (temp_dir / "2025").exists()

    def test_returns_path(self, temp_dir: Path) -> None:
        """Test that function returns the file path."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        content = "# Test"

        path = save_fulltext_markdown(doc_dict, content, temp_dir)

        assert isinstance(path, Path)
        assert path.suffix == ".md"

    def test_overwrites_existing(self, temp_dir: Path) -> None:
        """Test that existing files are overwritten."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}

        # Save first version
        save_fulltext_markdown(doc_dict, "Version 1", temp_dir)

        # Save second version
        path = save_fulltext_markdown(doc_dict, "Version 2", temp_dir)

        assert path.read_text(encoding="utf-8") == "Version 2"

    def test_handles_unicode(self, temp_dir: Path) -> None:
        """Test that unicode content is handled correctly."""
        doc_dict = {"pmcid": "PMC12101959", "year": 2025}
        content = "# Test with Unicode: café, naïve, 日本語"

        path = save_fulltext_markdown(doc_dict, content, temp_dir)

        assert path.read_text(encoding="utf-8") == content
