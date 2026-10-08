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

"""Assess one document's transparency and store what was found.

Shared by the two paths that run an analysis: ``TransparencyManager``, which
queues the documents a running review finds, and the Research Questions
tab's re-analysis pass, which reaches the documents of a question nobody is
reviewing (#373). One body, so the two cannot come to store different
results for the same study. Nothing here imports Qt.
"""

import logging
from typing import TYPE_CHECKING

from ..constants import FALLBACK_CONTACT_EMAIL
from ..elsevier_api import ElsevierCredentials
from ..study_transparency_analyzer.study_transparency_analyzer import (
    StudyTransparencyAnalyzer,
    TransparencyReport,
    score_components,
)
from ..transparency_terms import ScoreComponent, components_explain_score
from .transparency_models import (
    COI_NOT_ASSESSED,
    TransparencyResult,
    TransparencyRisk,
    calculate_risk_level,
)

if TYPE_CHECKING:
    from ..config import LiteConfig
    from ..storage import LiteStorage
    from .transparency_settings import TransparencySettings

logger = logging.getLogger(__name__)


def contact_email(config: "LiteConfig") -> str:
    """The address the literature sources are told to contact.

    Args:
        config: Application configuration.

    Returns:
        The user's configured PubMed email, or a placeholder when none is
        set: NCBI and Unpaywall both ask for one with every request.
    """
    return config.pubmed.email or FALLBACK_CONTACT_EMAIL


def unpaywall_contact_email(config: "LiteConfig") -> str:
    """The email to ask Unpaywall with: its own setting, else the contact.

    The Unpaywall setting is the one the configuration advice sends the
    reader to, so it must be the one read; before #435 the transparency
    analysis read only the PubMed email.

    Args:
        config: Application configuration.

    Returns:
        The configured Unpaywall email, else :func:`contact_email` -- which
        may be the placeholder, and PDF discovery treats that as none.
    """
    return config.discovery.unpaywall_email or contact_email(config)


def create_background_analyzer(
    email: str,
    pubmed_api_key: str | None = None,
    unpaywall_email: str | None = None,
    core_api_key: str | None = None,
    elsevier_credentials: ElsevierCredentials | None = None,
) -> StudyTransparencyAnalyzer:
    """Build the analyser a background analysis runs.

    Browser fallback is disabled, so no worker thread blocks on Playwright;
    the API-based sources are enough for a transparency assessment.

    Args:
        email: Contact email for the literature sources.
        pubmed_api_key: Optional NCBI API key for higher rate limits.
        unpaywall_email: Email for Unpaywall; ``email`` when not given.
        core_api_key: The configured CORE key (#480, stage C); the
            environment's when not given.
        elsevier_credentials: The configured Elsevier key and token (#480,
            stage C2); the environment's when not given.

    Returns:
        The analyser, with full-text discovery enabled.
    """
    return StudyTransparencyAnalyzer(
        email=email,
        pubmed_api_key=pubmed_api_key,
        unpaywall_email=unpaywall_email or email,
        use_browser_fallback=False,
        auto_discover_fulltext=True,
        core_api_key=core_api_key,
        elsevier_credentials=elsevier_credentials,
    )


def build_transparency_result(
    document_id: str,
    report: TransparencyReport,
    settings: "TransparencySettings",
) -> TransparencyResult:
    """Turn an analyser's report into the result that is stored and shown.

    Args:
        document_id: The document the report is about.
        report: What the analyser found. Its ``full_text_analyzed`` is
            copied as it is: only the analyser knows whether it recognised
            anything in the text it was given or found (#386).
        settings: The transparency settings the risk level is judged by.

    Returns:
        The result, stamped with this build's analyser version.
    """
    data_availability_level = "unknown"
    if report.data_availability:
        data_availability_level = report.data_availability.disclosure_level.value

    # What is known about the study's COI disclosure. A report with no
    # coi_info at all has had nothing established either way, so it is
    # not assessed. The expression this replaced answered False on
    # exactly this branch and True on every other one, and neither was
    # ever established, so the badge read "Disclosed" for every study an
    # analysis actually ran on (#352).
    coi_disclosure = (
        report.coi_info.disclosure_level.value
        if report.coi_info
        else COI_NOT_ASSESSED
    )

    risk_level = calculate_risk_level(
        score=int(report.transparency_score),
        industry_funding=report.industry_funding_detected,
        data_availability=data_availability_level,
        coi_disclosure=coi_disclosure,
        settings=settings,
    )

    results_compliant = False
    if report.results_compliance:
        results_compliant = report.results_compliance.value == "compliant"

    return TransparencyResult(
        document_id=document_id,
        transparency_score=int(report.transparency_score),
        risk_level=risk_level,
        industry_funding_detected=report.industry_funding_detected,
        industry_funding_confidence=report.industry_funding_confidence,
        data_availability_level=data_availability_level,
        coi_disclosure=coi_disclosure,
        trial_registered=len(report.trial_registrations) > 0,
        trial_results_compliant=results_compliant,
        outcome_switching_detected=report.outcome_switching_detected,
        # Both copied, not aliased: the report stays alive in the
        # worker and a later append would silently edit a stored
        # result.
        risk_indicators=list(report.risk_of_bias_indicators),
        warnings=list(report.warnings),
        tier_downgrade_applied=(
            settings.tier_downgrade_amount
            if risk_level == TransparencyRisk.HIGH
            else 0
        ),
        full_text_analyzed=report.full_text_analyzed,
        score_components=_recorded_components(document_id, report),
        # A source that could not be read is our silence, not the
        # study's. Neither fetch raises -- each returns "unreachable" and
        # the analysis finishes with a caveat and a score that fell
        # because nothing could be established -- so without this the row
        # was stored as a settled finding and served from cache forever
        # (#346, #360).
        sources_unreachable=(
            report.pubmed_record_unreachable
            or report.crossref_record_unreachable
            or report.registry_record_unreachable
        ),
    )


def _recorded_components(
    document_id: str, report: TransparencyReport
) -> tuple[ScoreComponent, ...] | None:
    """The score's terms, as long as they add up to the score being stored.

    They do by construction: the analyser's score is the clamped sum of these
    same terms. A report whose score was set any other way would store a
    breakdown the reader can add up and find false, so it is not recorded
    -- the report then says the breakdown is not available.

    Args:
        document_id: The document the report is about, for the log line.
        report: What the analyser found.

    Returns:
        The terms, or ``None`` when they do not explain the score.
    """
    components = tuple(score_components(report))
    score = int(report.transparency_score)
    if components_explain_score(components, score):
        return components
    logger.error(
        "The score terms of document %s add up to %d, not its score of %d; "
        "storing it without a breakdown.",
        document_id,
        sum(component.points for component in components),
        score,
    )
    return None


def assess_document(
    analyzer: StudyTransparencyAnalyzer,
    storage: "LiteStorage",
    settings: "TransparencySettings",
    document_id: str,
    pmid: str | None,
    doi: str | None,
    full_text: str | None = None,
) -> TransparencyResult:
    """Analyse one document and store the result.

    Args:
        analyzer: The analyser to run.
        storage: Where the result is saved.
        settings: The transparency settings the risk level is judged by.
        document_id: The document being assessed.
        pmid: Its PubMed ID, if it has one.
        doi: Its DOI, if it has one.
        full_text: Its full text, which the analyser then uses instead of
            discovering the article itself.

    Returns:
        The stored result.

    Raises:
        Exception: Whatever the analyser or the store raised. The caller
            classifies it: the raw text can carry a credential (#330).
    """
    report = analyzer.analyze(pmid=pmid, doi=doi, fulltext=full_text)
    result = build_transparency_result(document_id, report, settings)
    storage.save_transparency_result(result)
    return result
