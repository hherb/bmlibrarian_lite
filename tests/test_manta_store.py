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

"""Tests of the MANTA judgements table."""

from __future__ import annotations

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.manta_store import MantaRow
from bmlibrarian_lite.storage import LiteStorage


def test_store_round_trip(tmp_path):
    """Every field survives, each attempt is kept, an update replaces its own row."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    storage = LiteStorage(config)
    judged = MantaRow(
        document_id="d1",
        question="Does café help?",
        outcome="judged",
        server_url="http://x",
        judged_at="2026-01-01T00:00:00+00:00",
        judgement_id="j",
        revision="r",
        expected_score=2.5,
        relevance_probabilities={"1": 0.5, "2": 0.5},
        verdict="in",
        cutoff=1.95,
        design="rct",
        design_probability=0.9,
        design_probabilities={"rct": 0.9},
        seconds=1.5,
        truncated=False,
    )
    failed = MantaRow("d1", "q", "unreachable", "http://x", "2026-01-02T00:00:00+00:00", error="e")
    storage.record_manta_judgement(judged)
    storage.record_manta_judgement(failed)
    assert storage.manta_judgements("d1") == [judged, failed]
    from dataclasses import replace

    posted = replace(judged, reference_posted=True)
    storage.record_manta_judgement(posted)
    assert storage.manta_judgements("d1") == [posted, failed]
    assert storage.manta_judgements("other") == []
