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
Quality Manager: Orchestrates tiered quality assessment.

Combines Tier 1 (metadata), Tier 2 (Haiku), and Tier 3 (Sonnet)
into a unified assessment workflow with intelligent tier selection.

Assessment Flow:
1. Tier 1: Always check PubMed metadata first (free, instant)
2. Tier 2: LLM classification via Haiku if metadata inconclusive
3. Tier 3: Detailed assessment via Sonnet if explicitly requested

The manager respects QualityFilter settings to determine which
tiers to use and when to fall back to more expensive options.
"""

import logging
from typing import Optional, Callable

from ..data_models import LiteDocument
from ..config import LiteConfig
from .data_models import (
    QualityTier,
    QualityFilter,
    QualityAssessment,
)
from .metadata_filter import MetadataFilter
from .study_classifier import LiteStudyClassifier
from .quality_agent import LiteQualityAgent
from ..transparency import TransparencyResult, TransparencyRisk, TransparencySettings

logger = logging.getLogger(__name__)


# Minimum confidence to accept metadata result without LLM fallback
METADATA_ACCEPTANCE_THRESHOLD = 0.9


class QualityManager:
    """
    Orchestrates tiered quality assessment.

    Assessment flow:
    1. Tier 1: Check PubMed metadata (free, instant)
    2. Tier 2: LLM classification via Haiku (if needed)
    3. Tier 3: Detailed assessment via Sonnet (if requested)

    The manager intelligently selects which tier to use based on:
    - Filter settings (use_metadata_only, use_llm_classification, etc.)
    - Metadata confidence level
    - Document classification status

    Attributes:
        config: BMLibrarian Lite configuration
        metadata_filter: Tier 1 metadata filter
        study_classifier: Tier 2 Haiku classifier
        quality_agent: Tier 3 Sonnet assessor
    """

    def __init__(
        self,
        config: Optional[LiteConfig] = None,
    ) -> None:
        """
        Initialize the quality manager.

        Args:
            config: BMLibrarian Lite configuration
        """
        self.config = config or LiteConfig()
        self.metadata_filter = MetadataFilter()
        self.study_classifier = LiteStudyClassifier(config=self.config)
        self.quality_agent = LiteQualityAgent(config=self.config)
        self._transparency_settings = self.config.transparency

    def assess_document(
        self,
        document: LiteDocument,
        filter_settings: QualityFilter,
    ) -> QualityAssessment:
        """
        Assess document quality using tiered approach.

        The assessment follows this logic:
        1. Always try metadata first (free)
        2. If use_metadata_only is True, return metadata result
        3. If metadata has high confidence, use it (unless detailed requested)
        4. If use_llm_classification is True and metadata inconclusive, use Haiku
        5. If use_detailed_assessment is True, use Sonnet for full assessment

        Args:
            document: The document to assess
            filter_settings: Quality filter configuration

        Returns:
            QualityAssessment from appropriate tier
        """
        # Tier 1: Always try metadata first (free)
        metadata_result = self.metadata_filter.assess(document)
        logger.debug(
            f"Tier 1 result: {metadata_result.study_design.value} "
            f"(confidence: {metadata_result.confidence:.2f})"
        )

        # User wants metadata only - return immediately
        if filter_settings.use_metadata_only:
            return metadata_result

        # If metadata has high confidence and is classified, use it
        metadata_is_confident = (
            metadata_result.confidence >= METADATA_ACCEPTANCE_THRESHOLD
            and metadata_result.quality_tier != QualityTier.UNCLASSIFIED
        )

        if metadata_is_confident:
            # Unless detailed assessment is explicitly requested
            if filter_settings.use_detailed_assessment:
                logger.debug("Tier 3: Detailed assessment requested despite confident metadata")
                return self.quality_agent.assess_quality(document)
            return metadata_result

        # Tier 2: LLM classification for unclassified/low-confidence
        if filter_settings.use_llm_classification:
            classification = self.study_classifier.classify(document)
            logger.debug(
                f"Tier 2 result: {classification.study_design.value} "
                f"(confidence: {classification.confidence:.2f})"
            )

            # Tier 3: Detailed assessment if requested
            if filter_settings.use_detailed_assessment:
                logger.debug("Tier 3: Detailed assessment requested")
                return self.quality_agent.assess_quality(document)

            # Convert classification to assessment
            return QualityAssessment.from_classification(classification)

        # Fallback to metadata result (even if low confidence)
        return metadata_result

    def filter_documents(
        self,
        documents: list[LiteDocument],
        filter_settings: QualityFilter,
        progress_callback: Optional[Callable[[int, int, QualityAssessment], None]] = None,
    ) -> tuple[list[LiteDocument], list[QualityAssessment]]:
        """
        Filter documents based on quality criteria.

        Processes all documents through the tiered assessment system
        and returns only those that pass the filter criteria.

        Args:
            documents: List of documents to filter
            filter_settings: Quality filter configuration
            progress_callback: Optional callback(current, total, assessment)

        Returns:
            Tuple of (filtered_documents, all_assessments)
        """
        filtered: list[LiteDocument] = []
        assessments: list[QualityAssessment] = []

        total = len(documents)
        for i, doc in enumerate(documents):
            assessment = self.assess_document(doc, filter_settings)
            assessments.append(assessment)

            if assessment.passes_filter(filter_settings):
                filtered.append(doc)

            if progress_callback:
                progress_callback(i + 1, total, assessment)

        logger.info(
            f"Quality filtering: {len(filtered)}/{len(documents)} documents passed"
        )
        return filtered, assessments

    def get_assessment_summary(
        self,
        assessments: list[QualityAssessment],
    ) -> dict:
        """
        Generate summary statistics for assessments.

        Provides an overview of assessment results including
        distribution by tier, study design, and assessment source.

        Args:
            assessments: List of quality assessments

        Returns:
            Dictionary with summary statistics
        """
        if not assessments:
            return {
                "total": 0,
                "by_quality_tier": {},
                "by_study_design": {},
                "by_assessment_tier": {
                    "metadata": 0,
                    "haiku": 0,
                    "sonnet": 0,
                    "unclassified": 0,
                },
                "avg_confidence": 0.0,
            }

        tier_counts: dict[str, int] = {}
        design_counts: dict[str, int] = {}
        tier_sources = {1: 0, 2: 0, 3: 0, 0: 0}

        for assessment in assessments:
            # Count by quality tier
            tier_name = assessment.quality_tier.name
            tier_counts[tier_name] = tier_counts.get(tier_name, 0) + 1

            # Count by study design
            design_name = assessment.study_design.value
            design_counts[design_name] = design_counts.get(design_name, 0) + 1

            # Count by assessment source tier
            tier_sources[assessment.assessment_tier] = (
                tier_sources.get(assessment.assessment_tier, 0) + 1
            )

        avg_confidence = sum(a.confidence for a in assessments) / len(assessments)

        return {
            "total": len(assessments),
            "by_quality_tier": tier_counts,
            "by_study_design": design_counts,
            "by_assessment_tier": {
                "metadata": tier_sources[1],
                "haiku": tier_sources[2],
                "sonnet": tier_sources[3],
                "unclassified": tier_sources[0],
            },
            "avg_confidence": avg_confidence,
        }

    def get_tier_distribution(
        self,
        assessments: list[QualityAssessment],
    ) -> dict[QualityTier, int]:
        """
        Get distribution of assessments by quality tier.

        Args:
            assessments: List of quality assessments

        Returns:
            Dictionary mapping QualityTier to count
        """
        distribution: dict[QualityTier, int] = {}
        for tier in QualityTier:
            distribution[tier] = 0

        for assessment in assessments:
            distribution[assessment.quality_tier] = (
                distribution.get(assessment.quality_tier, 0) + 1
            )

        return distribution

    def get_design_distribution(
        self,
        assessments: list[QualityAssessment],
    ) -> dict[str, int]:
        """
        Get distribution of assessments by study design.

        Args:
            assessments: List of quality assessments

        Returns:
            Dictionary mapping study design value to count
        """
        distribution: dict[str, int] = {}
        for assessment in assessments:
            design = assessment.study_design.value
            distribution[design] = distribution.get(design, 0) + 1
        return distribution

    # === Transparency Integration Methods ===

    def apply_transparency_adjustment(
        self,
        assessment: QualityAssessment,
        transparency_result: TransparencyResult,
    ) -> QualityAssessment:
        """
        Apply tier downgrade based on transparency analysis.

        If transparency settings are disabled or the risk level is not HIGH,
        returns the original assessment unchanged. Otherwise, creates a new
        assessment with the tier downgraded.

        Args:
            assessment: Original quality assessment
            transparency_result: Transparency analysis result

        Returns:
            Modified assessment with tier adjustment (if applicable)
        """
        if not self._transparency_settings.enabled:
            return assessment

        if transparency_result.risk_level != TransparencyRisk.HIGH:
            return assessment

        # Store original tier for audit trail
        original_tier = assessment.quality_tier
        downgrade_amount = self._transparency_settings.tier_downgrade_amount

        # Calculate new tier (minimum is UNCLASSIFIED, value=0)
        new_tier_value = max(
            0,  # UNCLASSIFIED
            original_tier.value - downgrade_amount
        )

        # Get the new tier enum
        new_tier = QualityTier(new_tier_value)

        # Create modified assessment with transparency fields
        adjusted = QualityAssessment(
            assessment_tier=assessment.assessment_tier,
            extraction_method=assessment.extraction_method,
            study_design=assessment.study_design,
            quality_tier=new_tier,  # Adjusted tier
            quality_score=assessment.quality_score,
            evidence_level=assessment.evidence_level,
            is_randomized=assessment.is_randomized,
            is_controlled=assessment.is_controlled,
            is_blinded=assessment.is_blinded,
            is_prospective=assessment.is_prospective,
            is_multicenter=assessment.is_multicenter,
            sample_size=assessment.sample_size,
            confidence=assessment.confidence,
            bias_risk=assessment.bias_risk,
            strengths=assessment.strengths,
            limitations=assessment.limitations,
            extraction_details=assessment.extraction_details,
            # Transparency integration fields
            transparency_result=transparency_result,
            original_quality_tier=original_tier,
            transparency_adjusted=True,
        )

        logger.info(
            f"Transparency adjustment applied: {original_tier.name} -> {new_tier.name} "
            f"(risk: {transparency_result.risk_level.value})"
        )

        return adjusted

    def get_adjusted_quality(
        self,
        assessment: QualityAssessment,
        transparency_result: Optional[TransparencyResult],
    ) -> QualityAssessment:
        """
        Get quality assessment with transparency adjustment applied.

        If transparency result exists and indicates high risk,
        returns adjusted assessment with tier downgrade.

        Args:
            assessment: Quality assessment to potentially adjust
            transparency_result: Optional transparency result

        Returns:
            Adjusted quality assessment, or original if no adjustment needed
        """
        if transparency_result is None:
            return assessment

        # Apply adjustment if needed
        return self.apply_transparency_adjustment(assessment, transparency_result)

    def should_filter_document(
        self,
        transparency_result: Optional[TransparencyResult],
    ) -> bool:
        """
        Check if document should be filtered out due to transparency.

        Args:
            transparency_result: Transparency result for the document

        Returns:
            True if document should be excluded from results
        """
        if not self._transparency_settings.filtering_enabled:
            return False

        if transparency_result is None:
            return False  # Don't filter if not yet analyzed

        return transparency_result.risk_level == TransparencyRisk.HIGH

    def update_transparency_settings(self, settings: TransparencySettings) -> None:
        """
        Update transparency settings.

        Args:
            settings: New transparency settings to apply
        """
        self._transparency_settings = settings
        logger.debug("Transparency settings updated")
