#!/usr/bin/env python3
"""
Set version across all version-containing files.

Updates version strings in:
- src/bmlibrarian_lite/__init__.py
- bmll.py
- bmlibrarian_lite.spec (3 locations)
- CLAUDE.md (documented current version)

Also promotes the CHANGELOG.md "[Unreleased]" section into a dated release
section and rewrites the compare links at the bottom of the file.

Usage:
    python scripts/set_version.py 0.2.0
    python scripts/set_version.py --show  # Show current versions
"""

import argparse
import re
import sys
from datetime import date
from pathlib import Path

# Project root is parent of scripts directory
PROJECT_ROOT = Path(__file__).parent.parent

CHANGELOG_PATH = PROJECT_ROOT / "CHANGELOG.md"
REPO_URL = "https://github.com/hherb/bmlibrarian_lite"

# Matches a released-version heading, e.g. "## [0.4.0] - 2026-07-19"
VERSION_HEADING_PATTERN = r"^## \[(\d+\.\d+\.\d+[^\]]*)\]"
# Matches the start of the link-reference block, e.g. "[0.4.0]: https://..."
LINK_DEFINITION_PATTERN = r"^\[[^\]]+\]:"

# Files and patterns to update
VERSION_FILES = [
    {
        "path": PROJECT_ROOT / "src" / "bmlibrarian_lite" / "__init__.py",
        "pattern": r'^__version__\s*=\s*["\']([^"\']+)["\']',
        "replacement": '__version__ = "{version}"',
        "description": "Package __version__",
    },
    {
        "path": PROJECT_ROOT / "bmll.py",
        "pattern": r'^__version__\s*=\s*["\']([^"\']+)["\']',
        "replacement": '__version__ = "{version}"',
        "description": "CLI entry point __version__",
    },
    {
        "path": PROJECT_ROOT / "bmlibrarian_lite.spec",
        "pattern": r'(version=")(\d+\.\d+\.\d+)(")',
        "replacement": r'\g<1>{version}\g<3>',
        "description": "PyInstaller BUNDLE version",
    },
    {
        "path": PROJECT_ROOT / "bmlibrarian_lite.spec",
        "pattern": r'("CFBundleShortVersionString":\s*")(\d+\.\d+\.\d+)(")',
        "replacement": r'\g<1>{version}\g<3>',
        "description": "macOS CFBundleShortVersionString",
    },
    {
        "path": PROJECT_ROOT / "bmlibrarian_lite.spec",
        "pattern": r'("CFBundleVersion":\s*")(\d+\.\d+\.\d+)(")',
        "replacement": r'\g<1>{version}\g<3>',
        "description": "macOS CFBundleVersion",
    },
    {
        "path": PROJECT_ROOT / "CLAUDE.md",
        "pattern": r"^(\*\*Current version:\*\*\s+)(\d+\.\d+\.\d+)",
        "replacement": r"\g<1>{version}",
        "description": "Documented current version",
    },
]


def validate_version(version: str) -> bool:
    """
    Validate version string format.

    Args:
        version: Version string to validate

    Returns:
        True if valid semver-like format
    """
    # Allow versions like 0.1.0, 0.1.0-beta, 0.1.0.dev1, etc.
    pattern = r"^\d+\.\d+\.\d+(-[a-zA-Z0-9]+(\.\d+)?)?$"
    return bool(re.match(pattern, version))


def get_current_version(file_config: dict) -> str | None:
    """
    Extract current version from a file.

    Args:
        file_config: Configuration dict with path and pattern

    Returns:
        Current version string or None if not found
    """
    path = file_config["path"]
    if not path.exists():
        return None

    content = path.read_text()
    match = re.search(file_config["pattern"], content, re.MULTILINE)
    if match:
        # For patterns with 3 groups (prefix, version, suffix), version is group 2
        # For patterns with 1 group (version only), version is group 1
        if match.lastindex and match.lastindex >= 2:
            return match.group(2)
        return match.group(1)
    return None


def show_versions() -> None:
    """Display current versions in all files."""
    print("Current versions:\n")

    for config in VERSION_FILES:
        path = config["path"]
        rel_path = path.relative_to(PROJECT_ROOT)
        version = get_current_version(config)

        if version:
            print(f"  {rel_path}")
            print(f"    {config['description']}: {version}")
        else:
            print(f"  {rel_path}: NOT FOUND")
        print()


def _find_unreleased_body(content: str) -> tuple[int, int] | None:
    """
    Locate the body of the "[Unreleased]" section.

    Args:
        content: Full changelog text

    Returns:
        (start, end) offsets of the section body, or None if there is no
        "[Unreleased]" heading.
    """
    heading = re.search(r"^## \[Unreleased\][^\n]*\n", content, re.MULTILINE)
    if not heading:
        return None

    start = heading.end()
    # The body runs until the next release section, or until the link-reference
    # block if this is the first release.
    tail = content[start:]
    ends = [
        match.start()
        for match in (
            re.search(VERSION_HEADING_PATTERN, tail, re.MULTILINE),
            re.search(LINK_DEFINITION_PATTERN, tail, re.MULTILINE),
        )
        if match
    ]
    end = start + min(ends) if ends else len(content)
    return start, end


def _rewrite_link_definitions(content: str, new_version: str, previous: str | None) -> str:
    """
    Point "[Unreleased]" at the new tag and add a link for the new version.

    Args:
        content: Changelog text with the new section already inserted
        new_version: Version being released
        previous: Preceding released version, or None for a first release

    Returns:
        Changelog text with updated link definitions.
    """
    if previous:
        version_link = f"[{new_version}]: {REPO_URL}/compare/{previous}...{new_version}"
    else:
        version_link = f"[{new_version}]: {REPO_URL}/releases/tag/{new_version}"

    unreleased_link = f"[Unreleased]: {REPO_URL}/compare/{new_version}...HEAD"
    existing = re.search(r"^\[Unreleased\]:[^\n]*$", content, re.MULTILINE)

    if existing:
        return (
            content[: existing.start()]
            + unreleased_link
            + "\n"
            + version_link
            + content[existing.end() :]
        )

    separator = "" if content.endswith("\n") else "\n"
    return f"{content}{separator}\n{unreleased_link}\n{version_link}\n"


def update_changelog(
    new_version: str,
    release_date: date | None = None,
    path: Path | None = None,
    dry_run: bool = False,
) -> bool:
    """
    Promote the "[Unreleased]" section into a dated release section.

    Leaves an empty "[Unreleased]" heading behind for the next cycle and
    rewrites the compare links at the bottom of the file. Re-running for a
    version that already has a section is a no-op.

    Args:
        new_version: Version being released
        release_date: Date to stamp (defaults to today)
        path: Changelog to update (defaults to CHANGELOG.md in the project root)
        dry_run: If True, report changes without writing

    Returns:
        True if the changelog was stamped, already up to date, or absent;
        False if it exists but has no "[Unreleased]" section to promote.
    """
    path = path or CHANGELOG_PATH
    release_date = release_date or date.today()
    label = path.name

    if not path.exists():
        print(f"  SKIP: {label} (file not found)")
        return True

    content = path.read_text()

    if re.search(rf"^## \[{re.escape(new_version)}\]", content, re.MULTILINE):
        print(f"  SKIP: {label} (already has a {new_version} section)")
        return True

    bounds = _find_unreleased_body(content)
    if bounds is None:
        print(f"  WARN: {label} - no '## [Unreleased]' section found")
        return False

    start, end = bounds
    body = content[start:end].strip("\n")
    previous_match = re.search(VERSION_HEADING_PATTERN, content[start:], re.MULTILINE)
    previous = previous_match.group(1) if previous_match else None

    if not body:
        print(f"  WARN: {label} - '[Unreleased]' is empty; stamping an empty section")

    section = f"## [{new_version}] - {release_date.isoformat()}\n"
    if body:
        section += f"\n{body}\n"

    updated = f"{content[:start]}\n{section}\n{content[end:]}"
    updated = _rewrite_link_definitions(updated, new_version, previous)

    print(f"  {label}")
    print(f"    [Unreleased] -> [{new_version}] - {release_date.isoformat()}")

    if not dry_run:
        path.write_text(updated)

    return True


def update_version(new_version: str, dry_run: bool = False, skip_changelog: bool = False) -> bool:
    """
    Update version in all files.

    Args:
        new_version: New version string
        dry_run: If True, show changes without applying
        skip_changelog: If True, leave CHANGELOG.md untouched

    Returns:
        True if all updates successful
    """
    if not validate_version(new_version):
        print(f"Error: Invalid version format '{new_version}'")
        print("Expected format: X.Y.Z or X.Y.Z-suffix (e.g., 0.2.0, 0.2.0-beta)")
        return False

    print(f"{'[DRY RUN] ' if dry_run else ''}Updating to version {new_version}\n")

    all_success = True

    for config in VERSION_FILES:
        path = config["path"]
        rel_path = path.relative_to(PROJECT_ROOT)

        if not path.exists():
            print(f"  SKIP: {rel_path} (file not found)")
            continue

        content = path.read_text()
        old_version = get_current_version(config)

        # Build replacement with version inserted
        replacement = config["replacement"].format(version=new_version)

        # Perform replacement
        new_content, count = re.subn(
            config["pattern"],
            replacement,
            content,
            count=1,
            flags=re.MULTILINE,
        )

        if count == 0:
            print(f"  WARN: {rel_path} - pattern not found")
            all_success = False
            continue

        status = f"{old_version} -> {new_version}" if old_version else f"-> {new_version}"
        print(f"  {rel_path}")
        print(f"    {config['description']}: {status}")

        if not dry_run:
            path.write_text(new_content)

    if not skip_changelog:
        all_success &= update_changelog(new_version, dry_run=dry_run)

    print()
    if dry_run:
        print("Dry run complete. Use without --dry-run to apply changes.")
    else:
        print("Version update complete!")

    return all_success


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Update version across all project files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python scripts/set_version.py 0.2.0           # Update to 0.2.0
    python scripts/set_version.py 0.2.0 --dry-run # Preview changes
    python scripts/set_version.py --show          # Show current versions
        """,
    )
    parser.add_argument(
        "version",
        nargs="?",
        help="New version string (e.g., 0.2.0)",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="Show current versions in all files",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be changed without modifying files",
    )
    parser.add_argument(
        "--skip-changelog",
        action="store_true",
        help="Do not promote the CHANGELOG.md [Unreleased] section",
    )

    args = parser.parse_args()

    if args.show:
        show_versions()
        return 0

    if not args.version:
        parser.print_help()
        return 1

    success = update_version(
        args.version, dry_run=args.dry_run, skip_changelog=args.skip_changelog
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
