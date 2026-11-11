"""The published privacy page must match the policy bundled in the apps."""

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def test_privacy_page_is_generated_from_current_policy() -> None:
    """website/public/privacy.html is the current render of PRIVACY.md."""
    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "website" / "build_privacy.py"), "--check"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
