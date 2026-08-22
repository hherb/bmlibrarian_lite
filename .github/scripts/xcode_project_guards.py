#!/usr/bin/env python3
"""Guard the Xcode Cloud build contract (see HANDOVER.md).

Xcode Cloud clones only this repository and can only select shared schemes,
so these break its builds while staying invisible locally:

- a local Swift package reference that resolves outside the repository
  (it exists on the dev machine, so local builds stay green),
- the ``MedicalFactChecker`` scheme losing its shared copy under
  ``xcshareddata/xcschemes/``, and
- a duplicate object identifier in a ``project.pbxproj``, which drops a file
  from some targets and not others. This one hides from ``swift test`` as well,
  because the SPM targets do not read the Xcode project at all — PR #182 lost
  ``ParseWarningBanner.swift`` from the macOS build this way, and the only
  symptom was "cannot find in scope" in an unrelated file.

Exits non-zero, with GitHub Actions error annotations, when any holds.
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SHARED_SCHEME = (
    REPO_ROOT
    / "ios/MedicalFactChecker/MedicalFactChecker.xcodeproj"
    / "xcshareddata/xcschemes/MedicalFactChecker.xcscheme"
)
RELATIVE_PATH_RE = re.compile(r'^\s*relativePath\s*=\s*"?([^";]+)"?\s*;')
# An object's definition line: the identifier, then `= {`, optionally with the
# `/* comment */` Xcode writes between them. Only meaningful inside a
# `/* Begin X section */` block, at the two-tab indent Xcode writes them at —
# deeper in, the same shape is a dictionary key (`buildSettings = {`) or a
# reference keyed by target id (`TargetAttributes`), neither of which is a
# definition.
OBJECT_DEF_RE = re.compile(r"^\t\t([0-9A-F]{8,32})\s*(?:/\*.*?\*/\s*)?=\s*\{")
SECTION_BEGIN_RE = re.compile(r"^/\* Begin \w+ section \*/")
SECTION_END_RE = re.compile(r"^/\* End \w+ section \*/")


def duplicate_object_ids(pbxproj: Path) -> list[str]:
    """Return object identifiers defined more than once in a pbxproj.

    Reusing an existing identifier for a new object silently drops a file from
    some targets while compiling fine in others: the second definition wins for
    every reference, so the file builds where the winner is a member and vanishes
    where it is not. The only symptom is an unrelated "cannot find in scope", and
    ``swift test`` cannot see it at all because the SPM targets do not read this
    file.

    Args:
        pbxproj: Path to a project.pbxproj file inside the repository.

    Returns:
        The identifiers defined more than once, empty when all are unique.
    """
    seen: set[str] = set()
    duplicates: list[str] = []
    in_section = False
    for line in pbxproj.read_text().splitlines():
        if SECTION_BEGIN_RE.match(line):
            in_section = True
            continue
        if SECTION_END_RE.match(line):
            in_section = False
            continue
        if not in_section:
            continue
        match = OBJECT_DEF_RE.match(line)
        if match is None:
            continue
        identifier = match.group(1)
        if identifier in seen and identifier not in duplicates:
            duplicates.append(identifier)
        seen.add(identifier)
    return duplicates


def out_of_repo_references(pbxproj: Path) -> list[str]:
    """Return relativePath values in a pbxproj that escape the repository.

    Args:
        pbxproj: Path to a project.pbxproj file inside the repository.

    Returns:
        The offending ``relativePath`` values, empty if all stay in-repo.
    """
    # relativePath entries resolve against the .xcodeproj bundle's parent.
    project_dir = pbxproj.parent.parent
    escaped = []
    for line in pbxproj.read_text().splitlines():
        match = RELATIVE_PATH_RE.match(line)
        if match is None:
            continue
        target = (project_dir / match.group(1)).resolve()
        if not target.is_relative_to(REPO_ROOT):
            escaped.append(match.group(1))
    return escaped


def main() -> int:
    """Check every pbxproj and the shared scheme; return the exit status."""
    status = 0
    for pbxproj in sorted(REPO_ROOT.rglob("project.pbxproj")):
        # Worktrees hold copies of the same projects; guarding the checkout
        # itself is the point, and a stale copy is not this run's business.
        if ".build" in pbxproj.parts or ".claude" in pbxproj.parts:
            continue
        rel = pbxproj.relative_to(REPO_ROOT)
        for reference in out_of_repo_references(pbxproj):
            print(f"::error file={rel}::package reference escapes the repository: {reference}")
            status = 1
        for identifier in duplicate_object_ids(pbxproj):
            print(
                f"::error file={rel}::duplicate object identifier {identifier}: "
                "one definition wins for every reference, so a file silently "
                "leaves the targets the loser belonged to"
            )
            status = 1
    if not SHARED_SCHEME.is_file():
        print(f"::error::shared scheme missing: {SHARED_SCHEME.relative_to(REPO_ROOT)}")
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
