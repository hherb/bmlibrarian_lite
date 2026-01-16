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
Lite agents for BMLibrarian Lite.

This module provides simplified, stateless agents that work without PostgreSQL,
using SQLite (with sqlite-vec) for persistence and online LLM providers for inference.

Agents:
    LiteBaseAgent: Base class with LLM communication
    LiteSearchAgent: PubMed search and caching
    LiteScoringAgent: Document relevance scoring
    LiteCitationAgent: Citation extraction
    LiteReportingAgent: Report generation
    LiteInterrogationAgent: Document Q&A

Usage:
    from bmlibrarian_lite.agents import (
        LiteSearchAgent,
        LiteScoringAgent,
        LiteCitationAgent,
        LiteReportingAgent,
        LiteInterrogationAgent,
    )

    # Create agents with shared config
    from bmlibrarian_lite import LiteConfig, LiteStorage

    config = LiteConfig.load()
    storage = LiteStorage(config)

    search_agent = LiteSearchAgent(storage=storage, config=config)
    scoring_agent = LiteScoringAgent(config=config)
    citation_agent = LiteCitationAgent(config=config)
    reporting_agent = LiteReportingAgent(config=config)
    interrogation_agent = LiteInterrogationAgent(storage=storage, config=config)

    # Execute a research workflow
    session, documents = search_agent.search("cardiovascular effects of exercise")
    scored = scoring_agent.score_documents("cardiovascular effects", documents)
    citations = citation_agent.extract_all_citations("cardiovascular effects", scored)
    report = reporting_agent.generate_report("cardiovascular effects", citations)
"""

from .base import LiteBaseAgent
from .search_agent import LiteSearchAgent
from .scoring_agent import LiteScoringAgent
from .citation_agent import LiteCitationAgent
from .reporting_agent import LiteReportingAgent
from .interrogation_agent import LiteInterrogationAgent

__all__ = [
    "LiteBaseAgent",
    "LiteSearchAgent",
    "LiteScoringAgent",
    "LiteCitationAgent",
    "LiteReportingAgent",
    "LiteInterrogationAgent",
]
