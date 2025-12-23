#!/usr/bin/env python3
"""
Set version across all version-containing files.

Updates version strings in:
- src/bmlibrarian_lite/__init__.py
- bmll.py
- bmlibrarian_lite.spec (3 locations)

Usage:
    python scripts/set_version.py 0.2.0
    python scripts/set_version.py --show  # Show current versions
"""

import argparse
import re
import sys
from pathlib import Path

# Project root is parent of scripts directory
PROJECT_ROOT = Path(__file__).parent.parent

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


def update_version(new_version: str, dry_run: bool = False) -> bool:
    """
    Update version in all files.

    Args:
        new_version: New version string
        dry_run: If True, show changes without applying

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

    args = parser.parse_args()

    if args.show:
        show_versions()
        return 0

    if not args.version:
        parser.print_help()
        return 1

    success = update_version(args.version, dry_run=args.dry_run)
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
