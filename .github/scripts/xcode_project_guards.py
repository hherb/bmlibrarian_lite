#!/usr/bin/env python3
"""Guard the Xcode Cloud build contract (see HANDOVER.md).

Xcode Cloud clones only this repository and can only select shared schemes,
so two things break its builds while staying invisible locally:

- a local Swift package reference that resolves outside the repository
  (it exists on the dev machine, so local builds stay green), and
- the ``MedicalFactChecker`` scheme losing its shared copy under
  ``xcshareddata/xcschemes/``.

Exits non-zero, with GitHub Actions error annotations, when either holds.
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
        if ".build" in pbxproj.parts:
            continue
        rel = pbxproj.relative_to(REPO_ROOT)
        for reference in out_of_repo_references(pbxproj):
            print(f"::error file={rel}::package reference escapes the repository: {reference}")
            status = 1
    if not SHARED_SCHEME.is_file():
        print(f"::error::shared scheme missing: {SHARED_SCHEME.relative_to(REPO_ROOT)}")
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
