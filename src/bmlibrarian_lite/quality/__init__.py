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
Quality filtering module for BMLibrarian Lite.

This module provides quality assessment and filtering capabilities
for biomedical literature based on study design classification.

The module uses a tiered approach:
- Tier 1: PubMed metadata-based filtering (free, instant)
- Tier 2: LLM-based classification (Claude Haiku, ~$0.00025/doc)
- Tier 3: Detailed LLM assessment (Claude Sonnet, ~$0.003/doc)

Usage:
    from bmlibrarian_lite.quality import (
        QualityTier,
        StudyDesign,
        QualityFilter,
        QualityManager,
    )

    # Simple usage with QualityManager
    manager = QualityManager(config)
    filter_settings = QualityFilter(
        minimum_tier=QualityTier.TIER_4_EXPERIMENTAL,
        use_llm_classification=True,
    )

    # Assess single document
    assessment = manager.assess_document(document, filter_settings)

    # Filter multiple documents
    filtered_docs, assessments = manager.filter_documents(documents, filter_settings)

    # Check if document meets quality threshold
    if assessment.quality_tier.value >= QualityTier.TIER_4_EXPERIMENTAL.value:
        print("Document is RCT-level quality or above")
"""

from .data_models import (
    # Enums
    StudyDesign,
    QualityTier,
    # Dataclasses
    QualityFilter,
    StudyClassification,
    BiasRisk,
    QualityAssessment,
    # Mappings
    DESIGN_TO_TIER,
    DESIGN_TO_SCORE,
    DESIGN_LABELS,
    TIER_LABELS,
)

from .metadata_filter import (
    MetadataFilter,
    PUBMED_TYPE_TO_DESIGN,
    TYPE_PRIORITY,
)

from .study_classifier import (
    LiteStudyClassifier,
    STUDY_DESIGN_MAPPING,
)

from .quality_agent import (
    LiteQualityAgent,
)

from .quality_manager import (
    QualityManager,
)

from .evidence_summary import EvidenceSummaryGenerator

from .report_formatter import QualityReportFormatter

__all__ = [
    # Enums
    "StudyDesign",
    "QualityTier",
    # Dataclasses
    "QualityFilter",
    "StudyClassification",
    "BiasRisk",
    "QualityAssessment",
    # Mappings
    "DESIGN_TO_TIER",
    "DESIGN_TO_SCORE",
    "DESIGN_LABELS",
    "TIER_LABELS",
    # Tier 1: Metadata filter
    "MetadataFilter",
    "PUBMED_TYPE_TO_DESIGN",
    "TYPE_PRIORITY",
    # Tier 2: Study classifier
    "LiteStudyClassifier",
    "STUDY_DESIGN_MAPPING",
    # Tier 3: Quality agent
    "LiteQualityAgent",
    # Manager (orchestrates all tiers)
    "QualityManager",
    # Report enhancement
    "EvidenceSummaryGenerator",
    "QualityReportFormatter",
]
