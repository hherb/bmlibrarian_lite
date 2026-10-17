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
Tier 3: Detailed quality assessment using Claude Sonnet.

Provides comprehensive assessment including bias risk, strengths,
and limitations. This is optional and used when detailed assessment
is requested for high-value documents.

Includes robust retry logic using tenacity for handling API failures and timeouts.

Cost: ~$0.003 per document
"""

import json
import logging
from typing import Optional

from ..agents.base import LiteBaseAgent
from ..data_models import LiteDocument
from ..config import LiteConfig
from ..constants import (
    QUALITY_ASSESSOR_MODEL,
    QUALITY_LLM_TEMPERATURE,
    QUALITY_ASSESSOR_MAX_TOKENS,
)
from ..exceptions import JSONParseError, RetryExhaustedError
from ..utils import llm_retry, classify_llm_exception
from .data_models import (
    StudyDesign,
    QualityTier,
    QualityAssessment,
    BiasRisk,
    DESIGN_TO_TIER,
    DESIGN_TO_SCORE,
    llm_extraction_method,
)
from .json_fields import (
    as_bool,
    as_dict,
    as_float,
    as_int,
    as_str_list,
    as_text,
    text_or,
)
from .study_classifier import STUDY_DESIGN_MAPPING

logger = logging.getLogger(__name__)


# System prompt for detailed quality assessment
ASSESSMENT_SYSTEM_PROMPT = """You are a research quality assessment expert.
Evaluate the methodological quality of biomedical research papers.

CRITICAL RULES:
1. Extract ONLY information that is ACTUALLY PRESENT in the text
2. DO NOT invent, assume, or fabricate any information
3. If information is unclear or not mentioned, use null or "unclear"
4. Focus on THIS study's methodology, not studies it references
5. Return ONLY valid JSON, no explanation"""


class LiteQualityAgent(LiteBaseAgent):
    """
    Comprehensive quality assessment by the "quality_assessment" task's model.

    Provides detailed evaluation including:
    - Study design classification
    - Evidence level (Oxford CEBM)
    - Design characteristics (randomization, blinding, etc.)
    - Risk of bias assessment (Cochrane RoB domains)
    - Methodological strengths and limitations

    This agent is more expensive than the classifier and should be used
    selectively for documents that require detailed assessment.
    """

    TASK_ID = "quality_assessment"

    def __init__(
        self,
        config: Optional[LiteConfig] = None,
    ) -> None:
        """
        Initialize the quality agent.

        Args:
            config: BMLibrarian Lite configuration
        """
        super().__init__(config)

    def assess_quality(self, document: LiteDocument) -> QualityAssessment:
        """
        Perform detailed quality assessment on a document.

        Uses tenacity-based retry logic for API failures. On complete failure
        after all retries, returns QualityAssessment.unclassified().

        Args:
            document: The document to assess

        Returns:
            QualityAssessment with full details, or unclassified on failure
        """
        doc_id = getattr(document, "id", None) or getattr(document, "pmid", "unknown")

        # Prepare prompt with abstract (allow more text for detailed analysis)
        abstract = (document.abstract or "")[:4000]
        title = document.title or "Untitled"

        prompt = f"""Assess this research paper's methodological quality:

Title: {title}
Abstract: {abstract}

Return JSON:
{{
    "study_design": "systematic_review|meta_analysis|rct|cohort_prospective|cohort_retrospective|case_control|cross_sectional|case_series|case_report|editorial|letter|guideline|other",
    "quality_score": <1-10>,
    "evidence_level": "1a|1b|2a|2b|3a|3b|4|5|null",
    "design_characteristics": {{
        "randomized": true|false|null,
        "controlled": true|false|null,
        "blinded": "none"|"single"|"double"|"triple"|null,
        "prospective": true|false|null,
        "multicenter": true|false|null
    }},
    "sample_size": <number or null>,
    "bias_risk": {{
        "selection": "low"|"unclear"|"high",
        "performance": "low"|"unclear"|"high",
        "detection": "low"|"unclear"|"high",
        "attrition": "low"|"unclear"|"high",
        "reporting": "low"|"unclear"|"high"
    }},
    "strengths": ["2-3 methodological strengths"],
    "limitations": ["2-3 methodological limitations"],
    "confidence": <0.0 to 1.0>
}}

Focus on THIS study's methodology, not studies it references."""

        messages = [
            self._create_system_message(ASSESSMENT_SYSTEM_PROMPT),
            self._create_user_message(prompt),
        ]

        try:
            return self._assess_with_retry(messages)
        except RetryExhaustedError as e:
            logger.error(
                f"Document {doc_id}: Quality assessment failed after all retries: {e}"
            )
            return QualityAssessment.unclassified()
        except Exception as e:
            error_code = classify_llm_exception(e)
            logger.error(
                f"Document {doc_id}: Quality assessment failed with "
                f"{error_code.name}: {e}"
            )
            return QualityAssessment.unclassified()

    @llm_retry(max_retries=3, retry_on_json_error=True)
    def _assess_with_retry(self, messages: list) -> QualityAssessment:
        """
        Internal method that performs quality assessment with retry logic.

        This method is decorated with @llm_retry to automatically retry
        on API failures and JSON parse errors.

        Args:
            messages: LLM messages for assessment

        Returns:
            QualityAssessment with parsed results

        Raises:
            JSONParseError: If response cannot be parsed
            RetryExhaustedError: If all retries exhausted
        """
        response = self._chat(
            messages=messages,
            temperature=QUALITY_LLM_TEMPERATURE,
            max_tokens=QUALITY_ASSESSOR_MAX_TOKENS,
            json_mode=True,
        )
        return self._parse_response(response)

    def _parse_response(self, response: str) -> QualityAssessment:
        """
        Parse LLM response into QualityAssessment.

        Args:
            response: Raw LLM response string

        Returns:
            Parsed QualityAssessment

        Raises:
            JSONParseError: If response cannot be parsed as valid JSON
        """
        try:
            # Clean response
            cleaned = self._clean_json_response(response)
            if not cleaned:
                raise JSONParseError(
                    "Empty response after cleaning",
                    raw_response=response,
                )

            data = json.loads(cleaned)
            if not isinstance(data, dict):
                raise JSONParseError(
                    f"Response is not a JSON object: {type(data).__name__}",
                    raw_response=response,
                )

            # Every value is narrowed to its annotated type (bmlib#295,
            # bmlib#320): a null or wrong-typed answer reads as unstated.
            design_str = text_or(
                data.get("study_design"), "unknown", "study_design"
            ).lower().strip()
            study_design = self._parse_study_design(design_str)

            # Parse design characteristics
            chars = as_dict(data.get("design_characteristics"), "design_characteristics")

            # Parse bias risk
            bias_risk = self._parse_bias_risk(as_dict(data.get("bias_risk"), "bias_risk"))

            # Parse sample size
            sample_size = self._parse_sample_size(data.get("sample_size"))

            # Parse blinding
            is_blinded = self._parse_blinding(chars.get("blinded"))

            # Parse quality score (1-10 scale)
            quality_score = self._parse_quality_score(data.get("quality_score"))

            # Parse confidence
            confidence = self._parse_confidence(data.get("confidence"))

            # The model is recorded so the benchmark reuses this answer as
            # that model's, and no other's
            model = self._get_model()
            return QualityAssessment(
                assessment_tier=3,
                extraction_method=llm_extraction_method(model),
                study_design=study_design,
                quality_tier=DESIGN_TO_TIER.get(study_design, QualityTier.UNCLASSIFIED),
                quality_score=quality_score,
                evidence_level=as_text(data.get("evidence_level"), "evidence_level"),
                is_randomized=as_bool(chars.get("randomized"), "randomized"),
                is_controlled=as_bool(chars.get("controlled"), "controlled"),
                is_blinded=is_blinded,
                is_prospective=as_bool(chars.get("prospective"), "prospective"),
                is_multicenter=as_bool(chars.get("multicenter"), "multicenter"),
                sample_size=sample_size,
                confidence=confidence,
                bias_risk=bias_risk,
                strengths=as_str_list(data.get("strengths"), "strengths") or [],
                limitations=as_str_list(data.get("limitations"), "limitations") or [],
                extraction_details=[f"Detailed assessment via {model}"],
            )

        except json.JSONDecodeError as e:
            logger.warning(f"Failed to parse JSON response: {e}")
            raise JSONParseError(
                f"Failed to parse JSON response: {e}",
                raw_response=response,
            ) from e

    def _clean_json_response(self, response: str) -> str:
        """
        Clean LLM response by removing markdown code blocks.

        Args:
            response: Raw response string

        Returns:
            Cleaned JSON string
        """
        cleaned = response.strip()
        if cleaned.startswith("```"):
            parts = cleaned.split("```")
            if len(parts) >= 2:
                cleaned = parts[1]
                if cleaned.startswith("json"):
                    cleaned = cleaned[4:]
        cleaned = cleaned.strip()
        return cleaned

    def _parse_study_design(self, design_str: str) -> StudyDesign:
        """
        Parse study design string to enum.

        Args:
            design_str: Study design as lowercase string

        Returns:
            StudyDesign enum value
        """
        return STUDY_DESIGN_MAPPING.get(design_str, StudyDesign.UNKNOWN)

    def _parse_bias_risk(self, bias_data: dict) -> BiasRisk:
        """
        Parse bias risk data into BiasRisk dataclass.

        Args:
            bias_data: Dictionary with bias domain values

        Returns:
            BiasRisk instance
        """
        valid_values = ("low", "unclear", "high")

        def validate_bias(value: object) -> str:
            text = as_text(value, "bias_risk")
            if text is None:
                return "unclear"
            normalized = text.lower().strip()
            return normalized if normalized in valid_values else "unclear"

        return BiasRisk(
            selection=validate_bias(bias_data.get("selection")),
            performance=validate_bias(bias_data.get("performance")),
            detection=validate_bias(bias_data.get("detection")),
            attrition=validate_bias(bias_data.get("attrition")),
            reporting=validate_bias(bias_data.get("reporting")),
        )

    def _parse_blinding(self, value: object) -> Optional[str]:
        """
        Parse and validate blinding value.

        Args:
            value: Raw blinding value from response

        Returns:
            Validated blinding string or None
        """
        text = as_text(value, "blinded")
        if text is None:
            return None
        normalized = text.lower().strip()
        valid_values = ("none", "single", "double", "triple")
        return normalized if normalized in valid_values else None

    def _parse_sample_size(self, value: object) -> Optional[int]:
        """
        Parse sample size to integer.

        Args:
            value: Raw sample size value

        Returns:
            Integer sample size or None
        """
        return as_int(value, "sample_size")

    def _parse_quality_score(self, value: object) -> float:
        """
        Parse and clamp quality score.

        Args:
            value: Raw quality score value

        Returns:
            Quality score clamped to 0.0-10.0 range
        """
        score = as_float(value, "quality_score")
        if score is None:
            return 0.0
        return max(0.0, min(10.0, score))

    def _parse_confidence(self, value: object) -> float:
        """
        Parse and clamp confidence value.

        Args:
            value: Raw confidence value

        Returns:
            Confidence clamped to 0.0-1.0 range
        """
        conf = as_float(value, "confidence")
        if conf is None:
            return 0.5
        return max(0.0, min(1.0, conf))
