"""The relevance-score contract shared by the desktop and both apps.

Every row of ``doc/cross_platform/llm_parity/score_values.json`` is asserted
against the desktop's ``parse_score_response``; the Swift and Android suites
assert the same rows against their own parsers.
"""

import json
from pathlib import Path

import pytest

from bmlibrarian_lite.agents.scoring_agent import parse_score_response

CONTRACT = (
    Path(__file__).resolve().parent.parent
    / "doc" / "cross_platform" / "llm_parity" / "score_values.json"
)
CASES = json.loads(CONTRACT.read_text(encoding="utf-8"))["cases"]


def test_contract_covers_the_required_shapes() -> None:
    """The contract keeps a null case and a score case for each shape."""
    assert len(CASES) >= 18
    assert any(case["score"] is None for case in CASES)
    assert any(case["score"] is not None for case in CASES)


@pytest.mark.parametrize("case", CASES, ids=[case["name"] for case in CASES])
def test_each_case(case: dict) -> None:
    """A reply gives the contract's score, or no score at all."""
    parsed = parse_score_response(case["reply"])
    if case["score"] is None:
        assert parsed is None
    else:
        assert parsed is not None
        assert parsed[0] == case["score"]
