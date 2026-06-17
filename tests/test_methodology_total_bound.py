# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Tests for the "Total Results Available" figure in report methodology.

Covers the lower-bound qualifier (used for "Both" mode, where the union size
is unknowable) and round-tripping the flag through ReportMetadata
serialization.
"""

from unittest.mock import MagicMock

from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.data_models import ReportMetadata


def _methodology(metadata: ReportMetadata) -> str:
    """Render the methodology section for the given metadata."""
    agent = LiteReportingAgent(config=MagicMock())
    return agent.format_methodology_section(metadata)


def test_exact_total_has_no_prefix():
    """A precise count (single-provider search) renders without a qualifier."""
    metadata = ReportMetadata(
        total_results_available=1234,
        total_is_lower_bound=False,
    )

    section = _methodology(metadata)

    assert "**Total Results Available:** 1,234" in section
    # The ≥ qualifier must not leak onto the total (it legitimately appears
    # elsewhere, e.g. the scoring threshold line).
    assert "**Total Results Available:** ≥" not in section


def test_lower_bound_total_is_prefixed():
    """A "Both"-mode lower bound is qualified with a ≥ prefix."""
    metadata = ReportMetadata(
        total_results_available=1234,
        total_is_lower_bound=True,
    )

    section = _methodology(metadata)

    assert "**Total Results Available:** ≥1,234" in section


def test_lower_bound_flag_round_trips_through_dict():
    """The flag survives to_dict/from_dict serialization."""
    metadata = ReportMetadata(
        total_results_available=500,
        total_is_lower_bound=True,
    )

    restored = ReportMetadata.from_dict(metadata.to_dict())

    assert restored.total_is_lower_bound is True
    assert restored.total_results_available == 500


def test_lower_bound_flag_defaults_false_for_legacy_dict():
    """Older serialized reports without the flag default to an exact total."""
    legacy = {"total_results_available": 42}

    restored = ReportMetadata.from_dict(legacy)

    assert restored.total_is_lower_bound is False
