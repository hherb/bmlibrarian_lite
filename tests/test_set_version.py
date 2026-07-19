"""Tests for the release version script (scripts/set_version.py)."""

import importlib.util
import sys
from datetime import date
from pathlib import Path
from types import ModuleType

import pytest

PROJECT_ROOT = Path(__file__).parent.parent
SCRIPT_PATH = PROJECT_ROOT / "scripts" / "set_version.py"

REPO_COMPARE = "https://github.com/hherb/bmlibrarian_lite/compare"
REPO_TAG = "https://github.com/hherb/bmlibrarian_lite/releases/tag"


def _load_script() -> ModuleType:
    """Load set_version.py as a module (scripts/ is not an importable package).

    Returns:
        The loaded set_version module.
    """
    spec = importlib.util.spec_from_file_location("set_version", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["set_version"] = module
    spec.loader.exec_module(module)
    return module


set_version = _load_script()


CHANGELOG_TEMPLATE = f"""# Changelog

Preamble text.

## [Unreleased]

### Added

- A shiny new thing.

### Fixed

- An embarrassing bug.

## [0.4.0] - 2026-07-19

### Added

- The previous release.

## [0.3.0] - 2026-02-10

### Added

- An older release.

[Unreleased]: {REPO_COMPARE}/0.4.0...HEAD
[0.4.0]: {REPO_COMPARE}/0.3.0...0.4.0
[0.3.0]: {REPO_COMPARE}/0.2.0...0.3.0
"""


@pytest.fixture
def changelog(tmp_path: Path) -> Path:
    """Write a representative CHANGELOG.md to a temp dir.

    Args:
        tmp_path: pytest temp directory.

    Returns:
        Path to the written changelog.
    """
    path = tmp_path / "CHANGELOG.md"
    path.write_text(CHANGELOG_TEMPLATE)
    return path


class TestClaudeMdVersion:
    """CLAUDE.md must be part of the managed version files."""

    def test_claude_md_is_a_managed_version_file(self) -> None:
        """CLAUDE.md appears in VERSION_FILES so a bump updates it."""
        managed = {config["path"].name for config in set_version.VERSION_FILES}
        assert "CLAUDE.md" in managed

    def test_claude_md_current_version_is_readable(self) -> None:
        """The CLAUDE.md pattern extracts the documented current version."""
        config = next(
            c for c in set_version.VERSION_FILES if c["path"].name == "CLAUDE.md"
        )
        assert set_version.get_current_version(config) is not None

    def test_claude_md_pattern_rewrites_only_the_version(self, tmp_path: Path) -> None:
        """Applying the pattern bumps the version and leaves prose intact."""
        import re

        config = next(
            c for c in set_version.VERSION_FILES if c["path"].name == "CLAUDE.md"
        )
        content = "# CLAUDE.md\n\n**Current version:** 0.4.0\n\nRequires 0.4.0 of nothing.\n"
        updated, count = re.subn(
            config["pattern"],
            config["replacement"].format(version="0.5.0"),
            content,
            count=1,
            flags=re.MULTILINE,
        )
        assert count == 1
        assert "**Current version:** 0.5.0" in updated
        assert "Requires 0.4.0 of nothing." in updated


class TestChangelogStamping:
    """update_changelog() promotes [Unreleased] into a dated release section."""

    def test_unreleased_body_moves_into_dated_section(self, changelog: Path) -> None:
        """Entries under [Unreleased] end up under the new version heading."""
        set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=changelog
        )
        text = changelog.read_text()

        assert "## [0.5.0] - 2026-08-01" in text
        released = text.split("## [0.5.0]")[1].split("## [0.4.0]")[0]
        assert "A shiny new thing." in released
        assert "An embarrassing bug." in released

    def test_unreleased_section_is_emptied_but_kept(self, changelog: Path) -> None:
        """[Unreleased] survives as an empty section ready for the next cycle."""
        set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=changelog
        )
        text = changelog.read_text()

        unreleased = text.split("## [Unreleased]")[1].split("## [0.5.0]")[0]
        assert "A shiny new thing." not in unreleased
        assert unreleased.strip() == ""

    def test_new_section_precedes_the_previous_release(self, changelog: Path) -> None:
        """Releases stay in reverse-chronological order."""
        set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=changelog
        )
        text = changelog.read_text()

        assert text.index("## [0.5.0]") < text.index("## [0.4.0]")

    def test_compare_links_are_rewritten(self, changelog: Path) -> None:
        """Unreleased repoints at the new tag and the new version gets a link."""
        set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=changelog
        )
        text = changelog.read_text()

        assert f"[Unreleased]: {REPO_COMPARE}/0.5.0...HEAD" in text
        assert f"[0.5.0]: {REPO_COMPARE}/0.4.0...0.5.0" in text
        assert f"[0.4.0]: {REPO_COMPARE}/0.3.0...0.4.0" in text

    def test_preamble_is_preserved(self, changelog: Path) -> None:
        """Text above [Unreleased] is untouched."""
        set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=changelog
        )
        assert "Preamble text." in changelog.read_text()

    def test_dry_run_leaves_the_file_alone(self, changelog: Path) -> None:
        """--dry-run reports without writing."""
        before = changelog.read_text()
        set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=changelog, dry_run=True
        )
        assert changelog.read_text() == before

    def test_existing_version_section_is_not_duplicated(self, changelog: Path) -> None:
        """Re-running for an already-stamped version is a no-op."""
        set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=changelog
        )
        once = changelog.read_text()
        set_version.update_changelog(
            "0.5.0", release_date=date(2026, 9, 9), path=changelog
        )

        assert changelog.read_text() == once
        assert once.count("## [0.5.0]") == 1

    def test_first_release_links_to_the_tag(self, tmp_path: Path) -> None:
        """With no prior release, the version links to its tag, not a compare."""
        path = tmp_path / "CHANGELOG.md"
        path.write_text(
            "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- First thing.\n\n"
            f"[Unreleased]: {REPO_COMPARE}/HEAD\n"
        )
        set_version.update_changelog(
            "0.1.0", release_date=date(2026, 8, 1), path=path
        )
        text = path.read_text()

        assert f"[0.1.0]: {REPO_TAG}/0.1.0" in text

    def test_missing_changelog_is_skipped(self, tmp_path: Path) -> None:
        """A missing CHANGELOG.md is reported, not fatal."""
        assert set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=tmp_path / "nope.md"
        )

    def test_missing_unreleased_heading_fails(self, tmp_path: Path) -> None:
        """A changelog without [Unreleased] cannot be stamped."""
        path = tmp_path / "CHANGELOG.md"
        path.write_text("# Changelog\n\n## [0.4.0] - 2026-07-19\n\n- Old.\n")

        assert not set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=path
        )

    def test_empty_unreleased_still_stamps(self, tmp_path: Path) -> None:
        """An empty [Unreleased] produces a section; the caller is warned."""
        path = tmp_path / "CHANGELOG.md"
        path.write_text(
            "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-07-19\n\n- Old.\n\n"
            f"[Unreleased]: {REPO_COMPARE}/0.4.0...HEAD\n"
        )
        set_version.update_changelog(
            "0.5.0", release_date=date(2026, 8, 1), path=path
        )

        assert "## [0.5.0] - 2026-08-01" in path.read_text()
