#!/usr/bin/env python3
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
BMLibrarian Lite CLI - Command line interface.

A simplified interface for:
- Systematic literature review (search, score, extract, report)
- Document interrogation (Q&A with loaded documents)

Features:
- SQLite with sqlite-vec for storage and vector search
- FastEmbed for local embeddings (CPU-optimized, no PyTorch)
- Anthropic Claude for LLM inference (online)
- NCBI E-utilities for PubMed search (online)

Usage:
    # Launch GUI (default)
    bmll

    # Show storage statistics
    bmll stats

    # Validate configuration
    bmll validate

    # Keep a PDF the title check set aside as its article's
    bmll keep-pdf ~/knowledgebase/pdf/2016/10.3945_ajcn.115.120147.pdf.mismatch

    # Refresh the local Retraction Watch copy (exit 1 if it could not be refreshed)
    bmll retractions-update

    # Show version
    bmll --version

Requirements:
    - Python 3.12+
    - Anthropic API key (set ANTHROPIC_API_KEY or configure in Settings)
    - Internet connection for PubMed search and Claude API

First-time setup:
    1. Run the application
    2. Go to Settings
    3. Enter your Anthropic API key
    4. Optionally enter your email for PubMed (recommended)
"""

import argparse
import json
import logging
import os
import sys
from pathlib import Path

# Suppress tokenizers parallelism warning when forking for Qt threads
# This must be set before importing any HuggingFace/FastEmbed modules
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

# Disable all telemetry - privacy is paramount
# HuggingFace telemetry
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("DO_NOT_TRACK", "1")

from . import __version__


def setup_logging(verbose: bool = False) -> None:
    """
    Configure logging based on verbosity level.

    Args:
        verbose: If True, set DEBUG level; otherwise INFO
    """
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )

    # Suppress noisy httpx INFO messages (HTTP Request logs)
    logging.getLogger("httpx").setLevel(logging.WARNING)


def cmd_gui(args: argparse.Namespace) -> int:
    """
    Launch the GUI application.

    Args:
        args: Parsed command line arguments

    Returns:
        Application exit code
    """
    from .gui.app import run_lite_app
    return run_lite_app()


def cmd_stats(args: argparse.Namespace) -> int:
    """
    Show storage statistics.

    Args:
        args: Parsed command line arguments

    Returns:
        Exit code (0 for success)
    """
    from . import LiteConfig, LiteStorage

    config = LiteConfig.load()
    storage = LiteStorage(config)
    stats = storage.get_statistics()

    print("=== BMLibrarian Lite Storage Statistics ===")
    print(f"\nData directory: {stats['data_dir']}")
    print(f"\nDocuments:        {stats['documents']:,}")
    print(f"Chunks:           {stats['chunks']:,}")
    print(f"Search sessions:  {stats['search_sessions']:,}")
    print(f"Checkpoints:      {stats['checkpoints']:,}")

    if args.json:
        print(f"\n{json.dumps(stats, indent=2)}")

    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    """
    Validate configuration.

    Args:
        args: Parsed command line arguments

    Returns:
        Exit code (0 if valid, 1 if invalid)
    """
    from . import LiteConfig

    config = LiteConfig.load()
    errors = config.validate()

    if errors:
        print("Configuration validation FAILED:")
        for error in errors:
            print(f"  - {error}")
        return 1
    else:
        print("Configuration is valid.")

        if args.verbose:
            print("\nConfiguration details:")
            print(f"  Default Provider: {config.models.default_provider}")
            print(f"  Default Model: {config.models.default_model or '(provider default)'}")
            print(f"  Default Temperature: {config.models.default_temperature}")
            print(f"  Embedding Model: {config.embeddings.model}")
            print(f"  Data Directory: {config.storage.data_dir}")
            print(f"  PubMed Email: {config.pubmed.email or '(not set)'}")

        return 0


def cmd_clear(args: argparse.Namespace) -> int:
    """
    Clear all stored data.

    Args:
        args: Parsed command line arguments

    Returns:
        Exit code (0 for success)
    """
    from . import LiteConfig, LiteStorage

    if not args.force:
        confirm = input("This will DELETE ALL stored data. Type 'yes' to confirm: ")
        if confirm.lower() != "yes":
            print("Aborted.")
            return 1

    config = LiteConfig.load()
    storage = LiteStorage(config)
    storage.clear_all(confirm=True)

    print("All data has been cleared.")
    return 0


def cmd_keep_pdf(args: argparse.Namespace) -> int:
    """Keep a PDF as its article's though its first page lacks the title (#541).

    A PDF set aside (``<pdf>.mismatch``) is renamed back; either way a
    marker beside it vouches for its bytes, so the cached-PDF tier reads it.

    Args:
        args: Parsed command line arguments (``path``)

    Returns:
        Exit code (0 for success, 1 when it could not be kept)
    """
    from .pdf_library_check import keep_pdf

    path = Path(args.path).expanduser()
    if not path.is_file():
        print(f"No such file: {path}", file=sys.stderr)
        return 1
    try:
        kept = keep_pdf(path)
    except (ValueError, OSError) as e:
        # FileExistsError is an OSError: another PDF has the name to go back to
        print(f"Could not keep {path.name}: {e}", file=sys.stderr)
        return 1
    print(f"Kept {kept} as its article's PDF.")
    return 0


def cmd_retractions_update(args: argparse.Namespace) -> int:
    """Refresh the local Retraction Watch copy.

    Args:
        args: Parsed command line arguments

    Returns:
        Exit code (0 when this run built a new copy, 1 otherwise; a copy an
        earlier run built today is not this run's success)
    """
    from datetime import UTC, datetime

    import requests

    from . import LiteConfig
    from .constants import RETRACTION_WATCH_DB_NAME
    from .polite_session import mount_politely
    from .retraction_export import ExportState, export_copy, refresh_export
    from .retraction_text import (
        export_not_refreshed_line,
        export_refreshed_line,
        refresh_failed_line,
    )
    from .transparency.assessment import contact_email

    config = LiteConfig.load()
    data_dir = config.storage.data_dir
    path = data_dir / RETRACTION_WATCH_DB_NAME

    def stamp() -> int | None:
        """The copy file's modification time; a new copy is swapped in whole, so it changes."""
        return path.stat().st_mtime_ns if path.exists() else None

    before = stamp()
    today = datetime.now(UTC).date()
    session = mount_politely(requests.Session())
    try:
        copy = refresh_export(data_dir, session, mailto=contact_email(config), today=today)
    except Exception as e:  # noqa: BLE001 - only the exception's type is reported
        print(refresh_failed_line(e))
        copy = export_copy(data_dir, today=today)
    finally:
        session.close()

    if copy.state is ExportState.CURRENT and copy.data_as_of == today and stamp() != before:
        print(export_refreshed_line(copy))
        return 0
    print(export_not_refreshed_line(copy))
    return 1


def cmd_config(args: argparse.Namespace) -> int:
    """
    Show or export configuration.

    Args:
        args: Parsed command line arguments

    Returns:
        Exit code (0 for success)
    """
    from . import LiteConfig
    from .constants import REDACTED_SECRET_PLACEHOLDER

    config = LiteConfig.load()

    if args.json:
        print(json.dumps(config.to_redacted_dict(), indent=2))
    else:
        print("=== BMLibrarian Lite Configuration ===")
        print(f"\nConfig file: {config.storage.data_dir / 'config.json'}")
        print("\n[LLM]")
        print(f"  Provider: {config.models.default_provider}")
        print(f"  Model: {config.models.default_model}")
        print(f"  Temperature: {config.models.default_temperature}")
        print(f"  Max tokens: {config.models.default_max_tokens}")
        print("\n[Embeddings]")
        print(f"  Model: {config.embeddings.model}")
        print(f"  Cache dir: {config.embeddings.cache_dir or '(auto)'}")
        print("\n[PubMed]")
        print(f"  Email: {config.pubmed.email or '(not set)'}")
        print(f"  API key: {REDACTED_SECRET_PLACEHOLDER if config.pubmed.api_key else '(not set)'}")
        print(f"  CORE API key: {REDACTED_SECRET_PLACEHOLDER if config.discovery.core_api_key else '(not set)'}")
        print(f"  Elsevier API key: {REDACTED_SECRET_PLACEHOLDER if config.discovery.elsevier_api_key else '(not set)'}")
        print(f"  Elsevier institutional token: {REDACTED_SECRET_PLACEHOLDER if config.discovery.elsevier_insttoken else '(not set)'}")
        print("\n[Search]")
        print(f"  Chunk size: {config.search.chunk_size}")
        print(f"  Chunk overlap: {config.search.chunk_overlap}")
        print(f"  Similarity threshold: {config.search.similarity_threshold}")
        print(f"  Max results: {config.search.max_results}")
        print("\n[Storage]")
        print(f"  Data directory: {config.storage.data_dir}")

    return 0


def create_parser() -> argparse.ArgumentParser:
    """
    Create the argument parser.

    Returns:
        Configured ArgumentParser
    """
    parser = argparse.ArgumentParser(
        prog="bmll",
        description="BMLibrarian Lite - Lightweight biomedical literature research tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Launch the GUI
    bmll

    # Show storage statistics
    bmll stats

    # Validate configuration
    bmll validate --verbose

    # Show configuration
    bmll config --json

    # Clear all data (with confirmation)
    bmll clear
""",
    )

    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {__version__}",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose output",
    )

    subparsers = parser.add_subparsers(
        title="commands",
        dest="command",
        help="Available commands",
    )

    # GUI command (default)
    gui_parser = subparsers.add_parser(
        "gui",
        help="Launch the graphical user interface (default)",
    )
    gui_parser.set_defaults(func=cmd_gui)

    # Stats command
    stats_parser = subparsers.add_parser(
        "stats",
        help="Show storage statistics",
    )
    stats_parser.add_argument(
        "--json",
        action="store_true",
        help="Output as JSON",
    )
    stats_parser.set_defaults(func=cmd_stats)

    # Validate command
    validate_parser = subparsers.add_parser(
        "validate",
        help="Validate configuration",
    )
    validate_parser.set_defaults(func=cmd_validate)

    # Clear command
    clear_parser = subparsers.add_parser(
        "clear",
        help="Clear all stored data (requires confirmation)",
    )
    clear_parser.add_argument(
        "-f", "--force",
        action="store_true",
        help="Skip confirmation prompt",
    )
    clear_parser.set_defaults(func=cmd_clear)

    # Keep-PDF command
    keep_parser = subparsers.add_parser(
        "keep-pdf",
        help="Keep a PDF the title check set aside as its article's",
    )
    keep_parser.add_argument(
        "path",
        help="The set-aside PDF (<name>.pdf.mismatch) or a PDF in the library",
    )
    keep_parser.set_defaults(func=cmd_keep_pdf)

    # Retractions update command
    retractions_parser = subparsers.add_parser(
        "retractions-update",
        help="Refresh the local Retraction Watch copy",
    )
    retractions_parser.set_defaults(func=cmd_retractions_update)

    # Config command
    config_parser = subparsers.add_parser(
        "config",
        help="Show current configuration",
    )
    config_parser.add_argument(
        "--json",
        action="store_true",
        help="Output as JSON",
    )
    config_parser.set_defaults(func=cmd_config)

    return parser


def main() -> int:
    """
    Main entry point for BMLibrarian Lite CLI.

    Returns:
        Application exit code
    """
    parser = create_parser()
    args = parser.parse_args()

    # Set up logging
    setup_logging(getattr(args, "verbose", False))

    # Default to GUI if no command specified
    if args.command is None:
        args.func = cmd_gui

    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("\nAborted.")
        return 130
    except Exception as e:
        logging.error(f"Error: {e}")
        if getattr(args, "verbose", False):
            logging.exception("Full traceback:")
        return 1


if __name__ == "__main__":
    sys.exit(main())
