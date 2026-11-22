# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
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

"""Tests of tools/manta_server/manta_protocol.py: verdict, scale, indexing design."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "manta_server"))

import manta_protocol  # noqa: E402


def test_verdict_at_cutoff() -> None:
    """The cutoff itself is kept."""
    assert manta_protocol.verdict(1.95) == "in"
    assert manta_protocol.verdict(1.9499) == "out"
    assert manta_protocol.SHADOW_CUTOFF == 1.95


def test_app_scale_shifts_levels() -> None:
    """Option ids 0-4 become levels 1-5."""
    assert manta_protocol.app_scale({"0": 0.7, "4": 0.3}) == {"1": 0.7, "5": 0.3}


def test_human_indexed() -> None:
    """Only MEDLINE with manual or no method counts."""
    assert manta_protocol.human_indexed("MEDLINE", None)
    assert manta_protocol.human_indexed("MEDLINE", "Manual")
    assert not manta_protocol.human_indexed("MEDLINE", "Automated")
    assert not manta_protocol.human_indexed("PubMed-not-MEDLINE", None)


def test_indexing_design() -> None:
    """The design and the human-indexed flag come together."""
    assert manta_protocol.indexing_design(None) == (None, None)
    got = manta_protocol.indexing_design(
        {
            "publication_types": ["Journal Article"],
            "mesh_terms": ["Cohort Studies", "Retrospective Studies"],
            "medline_status": "MEDLINE",
            "indexing_method": "Automated",
        }
    )
    assert got == ("cohort_retrospective", False)
