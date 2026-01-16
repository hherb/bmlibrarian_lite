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
LLM client module for BMLibrarian Lite.

Provides a unified interface for LLM communication supporting both:
- Anthropic Claude API (online)
- Ollama local models (offline)

Usage:
    from bmlibrarian_lite.llm import LLMClient, LLMMessage, get_llm_client

    client = get_llm_client()
    response = client.chat(
        messages=[LLMMessage(role="user", content="Hello")],
        model="anthropic:claude-sonnet-4-20250514",
    )
    print(response.content)
"""

from .client import LLMClient, get_llm_client
from .data_types import LLMMessage, LLMResponse
from .token_tracker import TokenTracker, TokenUsageSummary, get_token_tracker

__all__ = [
    "LLMClient",
    "get_llm_client",
    "LLMMessage",
    "LLMResponse",
    "TokenTracker",
    "TokenUsageSummary",
    "get_token_tracker",
]
