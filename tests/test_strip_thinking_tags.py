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

"""Tests for strip_thinking_tags utility."""

import json

import pytest

from bmlibrarian_lite.llm.data_types import strip_thinking_tags


class TestStripThinkingTags:
    """Tests for stripping <think>/<thinking> tags from LLM responses."""

    def test_no_thinking_tags(self) -> None:
        """Text without thinking tags passes through unchanged."""
        text = '{"score": 8, "reason": "High quality study"}'
        assert strip_thinking_tags(text) == text

    def test_think_tags_before_json(self) -> None:
        """<think> block before JSON is stripped, leaving valid JSON."""
        text = (
            "<think>\nLet me analyze this study carefully.\n"
            "The methodology seems sound.\n</think>\n"
            '{"score": 8, "reason": "High quality study"}'
        )
        result = strip_thinking_tags(text)
        assert json.loads(result) == {"score": 8, "reason": "High quality study"}

    def test_thinking_tags_before_json(self) -> None:
        """<thinking> block before JSON is stripped, leaving valid JSON."""
        text = (
            "<thinking>\nI need to evaluate the evidence.\n</thinking>\n"
            '{"relevance": "high"}'
        )
        result = strip_thinking_tags(text)
        assert json.loads(result) == {"relevance": "high"}

    def test_multiline_thinking_block(self) -> None:
        """Multi-line thinking blocks are fully removed."""
        text = (
            "<think>\n"
            "Step 1: Check the abstract.\n"
            "Step 2: Review the methods.\n"
            "Step 3: Evaluate the results.\n"
            "This is a randomized controlled trial with 500 participants.\n"
            "</think>\n"
            '{"study_type": "RCT", "participants": 500}'
        )
        result = strip_thinking_tags(text)
        parsed = json.loads(result)
        assert parsed["study_type"] == "RCT"
        assert parsed["participants"] == 500

    def test_empty_thinking_block(self) -> None:
        """Empty thinking block is stripped."""
        text = '<think></think>{"result": true}'
        result = strip_thinking_tags(text)
        assert json.loads(result) == {"result": True}

    def test_plain_text_response(self) -> None:
        """Non-JSON responses with thinking tags also get cleaned."""
        text = (
            "<thinking>Let me think about this.</thinking>\n"
            "The study shows strong evidence for the intervention."
        )
        result = strip_thinking_tags(text)
        assert result == "The study shows strong evidence for the intervention."

    def test_empty_string(self) -> None:
        """Empty string returns empty string."""
        assert strip_thinking_tags("") == ""

    def test_only_thinking_block(self) -> None:
        """Response that is only a thinking block returns empty string."""
        text = "<think>Just thinking, no actual output.</think>"
        assert strip_thinking_tags(text) == ""

    def test_whitespace_around_tags(self) -> None:
        """Extra whitespace around thinking blocks is handled."""
        text = (
            "  <think>  reasoning  </think>  \n\n"
            '{"answer": 42}'
        )
        result = strip_thinking_tags(text)
        assert json.loads(result) == {"answer": 42}

    def test_does_not_strip_non_thinking_xml(self) -> None:
        """Other XML-like tags are NOT stripped."""
        text = '<result>{"score": 5}</result>'
        assert strip_thinking_tags(text) == text

    def test_nested_angle_brackets_in_content(self) -> None:
        """Angle brackets inside the thinking block don't break parsing."""
        text = (
            "<think>The value x > 5 and y < 10 seems relevant.</think>\n"
            '{"x": 6, "y": 9}'
        )
        result = strip_thinking_tags(text)
        assert json.loads(result) == {"x": 6, "y": 9}

    def test_mismatched_variants_still_stripped(self) -> None:
        """Mixed think/thinking tags are still stripped (models are inconsistent)."""
        text = '<think>some reasoning</thinking>\n{"data": 1}'
        result = strip_thinking_tags(text)
        assert json.loads(result) == {"data": 1}
