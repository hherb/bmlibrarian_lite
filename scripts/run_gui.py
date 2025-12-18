#!/usr/bin/env python3
"""
Entry point script for BMLibrarian Lite GUI (used by PyInstaller).

This script serves as the main entry point for the bundled macOS application.
It imports and runs the GUI from the bmlibrarian_lite package.
"""

import os
import sys

# Suppress tokenizers parallelism warning
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

# Disable all telemetry - privacy is paramount
# ChromaDB telemetry
os.environ.setdefault("ANONYMIZED_TELEMETRY", "false")
os.environ.setdefault("CHROMA_TELEMETRY", "false")
# Posthog (used by ChromaDB)
os.environ.setdefault("POSTHOG_DISABLED", "true")
# HuggingFace telemetry
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("DO_NOT_TRACK", "1")


def main() -> int:
    """
    Launch the BMLibrarian Lite GUI.

    Returns:
        Application exit code
    """
    from bmlibrarian_lite.gui.app import run_lite_app
    return run_lite_app()


if __name__ == "__main__":
    sys.exit(main())
