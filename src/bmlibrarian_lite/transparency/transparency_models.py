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

"""Data models for transparency analysis results."""

from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field, fields, replace
from datetime import datetime
from enum import Enum
from typing import TYPE_CHECKING, Any, Union

if TYPE_CHECKING:
    from ..data_models import LiteDocument
    from .transparency_settings import TransparencySettings


# Threshold for medium vs low risk (score above this = low risk potential)
MEDIUM_RISK_SCORE_THRESHOLD = 70

# The three states a conflict of interest finding can be in, as they are
# stored and serialised. They are the values of
# ``study_transparency_analyzer.study_transparency_analyzer.COIDisclosureLevel``,
# repeated here rather than imported to keep this module a leaf: it holds the
# dataclass the GUI and storage pass around, and importing the analyzer would
# pull ``requests`` and ``urllib3`` into every consumer of
# ``TransparencyResult``. (There is no import cycle -- the analyzer package
# imports nothing from ``transparency`` -- so do not re-derive that as the
# reason.) ``test_the_stored_strings_match_the_enum`` pins each name to its
# member, so neither a re-spelling nor a swap can drift.
COI_DISCLOSED = "disclosed"
COI_NOT_STATED = "not_stated"
COI_NOT_ASSESSED = "not_assessed"


@dataclass(frozen=True)
class TransparencyUnassessed:
    """A document with no transparency finding, and the reason to show (#361).

    The counterpart of :class:`TransparencyResult` at every surface that
    presents one. A document whose analysis failed, and one whose stored
    assessment was made by an analyser this build has since corrected, are
    both *not* findings -- and showing nothing for them is what made a
    failure indistinguishable from an analysis still running.

    The reason is built by a pure function before it reaches here
    (:func:`~bmlibrarian_lite.analysis_failures.transparency_failure_text` or
    :func:`superseded_assessment_caveat`), never from a provider's own error
    text, which can carry a credential (#330).

    Attributes:
        reason: The complete sentences the reader is shown.

    Raises:
        ValueError: On construction, if the reason is empty: a badge that
            says "not assessed" and cannot say why is the defect one step on.
    """

    reason: str

    def __post_init__(self) -> None:
        """Refuse an unassessed outcome that says nothing.

        Raises:
            ValueError: If the reason is not a non-empty string.
        """
        if not isinstance(self.reason, str) or not self.reason.strip():
            raise ValueError("An unassessed transparency outcome says why")


#: What this build's analyser would find today. A stored row carrying any
#: other version was written by an analyser whose semantics have since been
#: corrected, so it is not a finding this build stands behind (#360).
#:
#: **Bump this whenever the analyser's semantics change**: whenever the same
#: inputs could produce a different score, risk level, indicator or caveat.
#: Not for a refactor that cannot move a result, and not for a change in the
#: user's settings -- ``calculate_risk_level`` applies those at analysis
#: time, so they are not part of what this version identifies. Every stored
#: row then becomes pending again and is re-analysed on the paced path that
#: already does that work. The same instruction sits on
#: ``study_transparency_analyzer``, where the semantics actually live.
#:
#: 2.0: #352 and #359 (a conflict of interest statement nobody read is not a
#: disclosure, and the headings journals actually print), #353--#356 and #250
#: (a source nobody asked is not a source that answered "nothing"). Between
#: them these move data availability and COI for the majority of articles.
TRANSPARENCY_ANALYZER_VERSION = "2.0"

#: What every row written before #360 says, whatever analysed it: the field
#: was never compared to anything, so it never moved off its default.
LEGACY_ANALYZER_VERSION = "1.0"


def analyzer_version_ordinal(version: str | None) -> tuple[int, ...]:
    """Order two analyser versions.

    Args:
        version: A stored ``analyzer_version``, or ``None`` for a row whose
            column predates the field.

    Returns:
        The dotted components as integers, for comparison. An absent or
        unparseable version sorts oldest, so an unknown provenance is
        re-analysed rather than trusted.
    """
    try:
        return tuple(int(part) for part in (version or "").split("."))
    except ValueError:
        return (0,)


def is_newer_than_this_build(version: str | None) -> bool:
    """Whether a stored row's version says a newer build wrote it.

    The one test of whose a row is, for every place that decides whether
    this build may replace it: the pass's pending list, the manager's cache
    check, and what the reader is told. Written out at each, the copies
    drifted, and a newer build's row that decoded but was provisional was
    re-analysed and overwritten (#374).

    *Strictly newer*: such a row is presumably that build's finding, and
    re-analysing it here would overwrite it (``INSERT OR REPLACE``) with an
    older analyser's. This build's own version, and any version that will
    not parse, is not newer.

    Args:
        version: A stored ``analyzer_version``, or ``None``.

    Returns:
        True when it orders after this build's.
    """
    return analyzer_version_ordinal(version) > analyzer_version_ordinal(
        TRANSPARENCY_ANALYZER_VERSION
    )


@dataclass(frozen=True)
class UndecodableTransparencyRow:
    """A stored transparency row this build could not decode (#374).

    One such row -- a risk level a newer build wrote into a shared
    ``~/.bmlibrarian_lite``, a timestamp that will not parse -- used to fail
    the batch read for every document asked about, so a review's report
    failed over it and a reloaded question lost every badge. It is carried
    as this value instead, beside the rows that did decode: dropped, it
    would read as a document never analysed.

    Only ``analyzer_version`` is kept, because it is the one column that
    decides what may be done with the row, and it usually survives whatever
    else failed to decode. When it does not, the row sorts oldest and is
    treated as damage.

    Attributes:
        document_id: Whose row it is.
        analyzer_version: The row's stored version, or ``None`` when the
            column is NULL or not readable as text.

    Raises:
        ValueError: On construction, for a row that names no document.
    """

    document_id: str
    analyzer_version: str | None

    def __post_init__(self) -> None:
        """Refuse a row that names no document.

        Raises:
            ValueError: If ``document_id`` is not a non-empty string.
        """
        if not isinstance(self.document_id, str) or not self.document_id:
            raise ValueError("An undecodable row names the document it belongs to")

    @property
    def written_by_newer_build(self) -> bool:
        """Whether a build newer than this one wrote the row.

        See :func:`is_newer_than_this_build`. Any other row that will not
        decode is damaged, not newer, and nothing is lost by replacing it.

        Returns:
            True when the row's version orders after this build's.
        """
        return is_newer_than_this_build(self.analyzer_version)


def undecodable_row_caveat(row: UndecodableTransparencyRow) -> str:
    """Say why a document whose stored row would not decode has no finding.

    One function, because the reloaded question's badge and the report's
    reference annotation both say it, and must say the same thing.

    Args:
        row: The row this build could not decode.

    Returns:
        The caveat's two sentences: a newer build's row, left unchanged, or
        a damaged one not yet re-analysed. Neither claims an *earlier*
        analyser wrote it.
    """
    from ..analysis_failures import (
        damaged_assessment_caveat,
        transparency_failure_text,
    )
    from ..data_models import TransparencyAnalysisFailure

    if row.written_by_newer_build:
        return transparency_failure_text(
            TransparencyAnalysisFailure.written_by_newer_build(row.document_id)
        )
    return damaged_assessment_caveat()


@dataclass(frozen=True)
class TransparencyCounts:
    """How a set of stored assessments is distributed, for a report.

    Attributes:
        low: Documents this build's analyser rates low risk.
        medium: Documents it rates medium risk.
        high: Documents it rates high risk.
        superseded: Documents whose stored assessment an earlier analyser
            made. They are counted apart and not as a risk level: an old
            row's level is not this build's finding, and dropping it from
            the counts without saying so would report an analysis that did
            not happen as one that found nothing (#360).
        unknown: Documents this build's analyser rates at no risk level it
            can name. A row like this used to fall through every bucket, so
            an analysis that ran and reached a conclusion vanished from the
            distribution with nothing saying so -- the same defect the
            ``superseded`` bucket exists to prevent, one level down.
        not_stored: Documents asked about that have no stored row at all:
            the analysis failed, found no identifier to look one up by, or
            had not finished. Only :func:`count_transparency_over` can know
            these, since it is the one given the documents as well as the
            rows.
        undecodable: Documents whose stored row this build could not decode
            (#374). Not a risk level, and not superseded either: a newer
            build may have written it.
    """

    low: int = 0
    medium: int = 0
    high: int = 0
    superseded: int = 0
    unknown: int = 0
    not_stored: int = 0
    undecodable: int = 0

    def __post_init__(self) -> None:
        """Refuse a count that is not a whole number of documents.

        Every bucket is built from a count of rows today, so none can go
        negative -- but that holds only while nothing else builds one. A
        negative bucket would shrink ``considered`` and hide the studies it
        stands for.

        Raises:
            ValueError: If any bucket is not a non-negative ``int``.
        """
        for bucket in fields(self):
            value = getattr(self, bucket.name)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(
                    f"TransparencyCounts.{bucket.name} must be a non-negative "
                    f"int, got {value!r}"
                )

    @property
    def not_assessed(self) -> int:
        """How many documents came back without a finding this build can name.

        Returns:
            Those with no row, those whose row names no risk level, and those
            whose row could not be read. Each asked a question that produced
            nothing this build can state, and none is a study with nothing
            to declare (#361, #374).
        """
        return self.not_stored + self.unknown + self.undecodable

    @property
    def considered(self) -> int:
        """How many documents these counts account for.

        Returns:
            Every bucket, so the report can say what the others are a share
            of (#372).
        """
        return self.assessed + self.superseded + self.not_assessed

    @property
    def assessed(self) -> int:
        """How many documents carry a finding this build can name.

        Returns:
            The sum of the three named risk levels, which is what
            "Documents Analyzed" means in a report. ``unknown`` is
            deliberately excluded: a row at no nameable level has nothing
            for the report to state, so it is accounted for under the
            studies that came back without a finding rather than inflating
            a distribution it appears in none of.
        """
        return self.low + self.medium + self.high


def _count_rows(
    results: Iterable["StoredTransparency"],
) -> TransparencyCounts:
    """Count stored assessments by risk level, keeping superseded ones apart.

    Private: given rows alone it cannot know which documents have none, so
    its ``not_stored`` is always 0, which reads as "none missing" rather
    than "not known". :func:`count_transparency_over` is the public count.

    Args:
        results: The stored assessments, in any order.

    Returns:
        The counts, ``not_stored`` apart. A result an earlier analyser wrote
        is counted only as superseded, whatever risk level it stored; every
        other result is counted under some bucket, so none can leave the
        distribution without the report being able to say so.
    """
    counts = dict.fromkeys(NAMEABLE_RISK_LEVELS, 0)
    superseded = 0
    unknown = 0
    undecodable = 0
    for result in results:
        if isinstance(result, UndecodableTransparencyRow):
            undecodable += 1
        elif not result.is_current:
            superseded += 1
        elif result.risk_level in counts:
            counts[result.risk_level] += 1
        else:
            unknown += 1
    return TransparencyCounts(
        low=counts[TransparencyRisk.LOW],
        medium=counts[TransparencyRisk.MEDIUM],
        high=counts[TransparencyRisk.HIGH],
        superseded=superseded,
        unknown=unknown,
        undecodable=undecodable,
    )


def count_transparency_over(
    stored: Mapping[str, "StoredTransparency"],
    document_ids: Iterable[str],
) -> TransparencyCounts:
    """Count what is known about a set of documents' transparency.

    Args:
        stored: The stored assessments, by document id. Rows for documents
            outside ``document_ids`` are ignored, so one batch can be counted
            over the documents a review assessed and over the ones it cited.
        document_ids: The documents to account for. A repeated id counts
            once.

    Returns:
        The counts, with every document in exactly one bucket: the report
        names a population and says what became of each member of it, so
        two figures taken over different sets cannot be read as one (#372).
    """
    ids = list(dict.fromkeys(document_ids))
    counts = _count_rows(stored[doc_id] for doc_id in ids if doc_id in stored)
    return replace(
        counts, not_stored=sum(1 for doc_id in ids if doc_id not in stored)
    )


def may_replace_stored(row: "StoredTransparency") -> bool:
    """Whether this build may overwrite a stored row with its own analysis.

    Asked before anything is re-analysed, whatever the cache setting:
    switching off reuse of this build's results is not permission to
    overwrite a newer build's (#374).

    Args:
        row: The document's stored row, decoded or not.

    Returns:
        False when a newer build wrote it, decodable or not: re-analysing it
        would replace that build's finding with an older analyser's.
    """
    return not row.written_by_newer_build


def _needs_analysis(row: "StoredTransparency") -> bool:
    """Whether a stored row leaves its document's transparency to be done.

    Args:
        row: The document's stored row.

    Returns:
        Never for a row this build may not replace (a newer build's, even a
        provisional one). Otherwise: for one that would not decode, always;
        for a decoded one, whether it is not final.
    """
    if not may_replace_stored(row):
        return False
    if isinstance(row, UndecodableTransparencyRow):
        return True
    return not row.is_final


def pending_transparency_ids(
    stored: Mapping[str, "StoredTransparency"],
    document_ids: Iterable[str],
) -> list[str]:
    """Say which documents' transparency this build has yet to establish.

    Args:
        stored: The stored assessments, by document id.
        document_ids: The documents to consider.

    Returns:
        Each document with no row, or whose row is not final -- an earlier
        analyser wrote it (#360), or a source it scores against could not be
        read (#346) -- or whose row is damaged beyond decoding, once each, in
        the order given. A row a newer build wrote is never pending, whether
        or not it decodes and even if it is provisional (#374). The same
        question ``TransparencyManager.analyze_document`` asks of its cache
        when caching is on (with it off, a review re-analyses every document
        but a newer build's), so the pass that re-analyses a question's
        documents and the review that re-analyses them as it goes cannot
        disagree about which are done.
    """
    return [
        doc_id
        for doc_id in dict.fromkeys(document_ids)
        if doc_id not in stored or _needs_analysis(stored[doc_id])
    ]


def stored_transparency_outcomes(
    documents: Iterable["LiteDocument"],
    stored: Mapping[str, "StoredTransparency"],
) -> dict[str, "TransparencyOutcome"]:
    """Say what each document of a reloaded question may be presented as.

    A question loaded from the store used to show no transparency badge at
    all, current or not, so a missing badge meant a fourth thing beside
    disabled, still running and failed. Every document gets an outcome here,
    and nothing is fetched: opening a question is not a request to re-fetch
    it, which is what the Research Questions tab's re-analysis is for (#373).

    Args:
        documents: The question's documents.
        stored: Their stored assessments, by document id.

    Returns:
        By document id: the row itself when this build stands behind it;
        otherwise the caveat for why there is none -- a superseded or
        undecodable row, no identifier to look one up by, or nothing stored
        -- ending with how to have it assessed where that is possible.
    """
    from ..analysis_failures import (
        not_stored_assessment_caveat,
        reanalysis_advice,
        superseded_assessment_caveat,
        transparency_failure_text,
    )
    from ..data_models import TransparencyAnalysisFailure

    outcomes: dict[str, TransparencyOutcome] = {}
    for document in documents:
        row = stored.get(document.id)
        if isinstance(row, TransparencyResult) and row.is_current:
            outcomes[document.id] = row
        elif not document.pmid and not document.doi:
            outcomes[document.id] = TransparencyUnassessed(
                reason=transparency_failure_text(
                    TransparencyAnalysisFailure.no_identifier(document.id)
                )
            )
        elif isinstance(row, UndecodableTransparencyRow):
            # No advice for a newer build's row: the pass leaves it alone
            advice = "" if row.written_by_newer_build else reanalysis_advice()
            outcomes[document.id] = TransparencyUnassessed(
                reason=undecodable_row_caveat(row) + advice
            )
        elif row is not None:
            outcomes[document.id] = TransparencyUnassessed(
                reason=superseded_assessment_caveat() + reanalysis_advice()
            )
        else:
            outcomes[document.id] = TransparencyUnassessed(
                reason=not_stored_assessment_caveat() + reanalysis_advice()
            )
    return outcomes


#: What a surface can be asked to present. A document either has a finding
#: or has none for a reason the reader is owed: an analysis that failed
#: (#361), or a stored assessment an analyser this build has since corrected
#: made (#360). Showing nothing for those made them indistinguishable from
#: an analysis still running. Defined here rather than in the badge that
#: first needed it, so that naming the domain's own outcome type does not
#: require importing Qt.
TransparencyOutcome = Union["TransparencyResult", TransparencyUnassessed]

#: What the store holds for a document: a row it decoded, or one it could
#: not (#374). Every reader of the store is handed this, so none can treat a
#: row that failed to decode as a finding or as a row that is not there.
StoredTransparency = Union["TransparencyResult", UndecodableTransparencyRow]


def transparency_outcome(
    result: "TransparencyResult",
) -> TransparencyOutcome:
    """Say what a stored assessment may be presented as.

    One place, because five surfaces read a stored row and made a claim from
    it. A row an earlier analyser wrote is not a finding this build stands
    behind, and showing its risk level would show a clinician a claim the
    corrections have already retracted (#360).

    Args:
        result: The stored assessment.

    Returns:
        The result itself when this build's analyser wrote it; otherwise the
        caveat saying it has not been re-analysed yet.
    """
    from ..analysis_failures import superseded_assessment_caveat

    if result.is_current:
        return result
    return TransparencyUnassessed(reason=superseded_assessment_caveat())


class TransparencyRisk(Enum):
    """Risk level based on transparency analysis."""

    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    UNKNOWN = "unknown"


#: The risk levels a current finding can be reported under. The report's
#: distribution counts these three, and annotates a cited study at any other
#: level as not assessed; one definition, so the count and the annotations
#: cannot disagree about which studies are "Not assessed" (#372).
NAMEABLE_RISK_LEVELS = (
    TransparencyRisk.LOW,
    TransparencyRisk.MEDIUM,
    TransparencyRisk.HIGH,
)


@dataclass
class TransparencyResult:
    """
    Stores transparency analysis results for a document.

    Contains the transparency score, risk level, and specific indicators
    from the study transparency analyzer. Used for display (badges),
    filtering, and quality tier adjustment.

    Attributes:
        document_id: Internal document ID
        transparency_score: Overall transparency score (0-100)
        risk_level: Computed risk level (low/medium/high/unknown)
        industry_funding_detected: Whether industry funding was detected
        industry_funding_confidence: Confidence in industry funding detection (0-1)
        data_availability_level: Data disclosure level
        coi_disclosure: What is known about the study's conflict of interest
            disclosure: ``COI_DISCLOSED``, ``COI_NOT_STATED`` (the article
            was read and declares none) or ``COI_NOT_ASSESSED`` (no source
            carrying a statement was read). The boolean this replaced could
            not tell the last two apart, and in practice was always true, so
            every badge read "Disclosed" (#352).
        trial_registered: Whether clinical trial was registered
        trial_results_compliant: Whether trial results were posted as required
        outcome_switching_detected: Whether outcome switching was detected
        risk_indicators: List of human-readable risk indicators
        warnings: Caveats about how reliable this analysis is, as opposed to
            what it found — e.g. funder names that matched no known body. Kept
            separate from risk_indicators because they qualify the result rather
            than describing the study. Mirrors Swift's TransparencyResult.warnings.
        tier_downgrade_applied: Number of quality tiers downgraded
        analyzed_at: Timestamp of analysis
        analyzer_version: The analyser semantics this result was produced
            under. Compared against ``TRANSPARENCY_ANALYZER_VERSION`` by
            ``is_current``: a row an earlier analyser wrote is re-analysed
            rather than shown, because every correction since #352 would
            otherwise reach only documents analysed after it (#360).
        sources_unreachable: Whether a source this analysis needed could not
            be read. The finding is then provisional: ``is_final`` is False,
            so it is re-analysed rather than cached as a settled answer, and
            the reference annotation says so rather than printing its risk
            level unqualified (#346, #360).
        full_text_analyzed: Whether full text was used (future enhancement)
    """

    document_id: str
    transparency_score: int  # 0-100
    risk_level: TransparencyRisk

    # Specific indicators
    industry_funding_detected: bool = False
    industry_funding_confidence: float = 0.0
    data_availability_level: str = "unknown"
    coi_disclosure: str = COI_NOT_ASSESSED
    trial_registered: bool = False
    trial_results_compliant: bool = False
    outcome_switching_detected: bool = False

    # Risk indicators list (human-readable)
    risk_indicators: list[str] = field(default_factory=list)

    # Caveats about the analysis itself (human-readable)
    warnings: list[str] = field(default_factory=list)

    # Tier adjustment applied
    tier_downgrade_applied: int = 0

    # Metadata
    analyzed_at: datetime = field(default_factory=datetime.now)
    analyzer_version: str = TRANSPARENCY_ANALYZER_VERSION

    # Whether a source the analysis needed could not be read at all, as
    # opposed to answering that it holds nothing. Only the first is our
    # silence, and only the first makes the finding provisional (#346).
    sources_unreachable: bool = False

    # For future full-text enhancement
    full_text_analyzed: bool = False

    @property
    def is_current(self) -> bool:
        """Whether no correction has landed since this result was produced.

        *Strictly older*, not merely different. Equality also called a row
        stamped with a **newer** version superseded, which re-analysed it and
        -- ``save_transparency_result`` being ``INSERT OR REPLACE`` --
        overwrote a better finding with this build's worse one. Two builds
        sharing one ``~/.bmlibrarian_lite`` would each supersede the other's
        rows and re-analyse the whole library, forever. It also made the
        caveat's own words false: it says an *earlier* analyser made the row,
        which only an ordering establishes. Swift settled this first, for the
        same reason under CloudKit sync -- see ``TransparencyResult.isStale``
        in ``Packages/BioMedLit``.

        Returns:
            True unless an analyser older than this build's produced the
            result. A superseded row is not a finding this build stands
            behind: it is re-analysed, and until it has been, no surface
            presents it (#360).
        """
        return analyzer_version_ordinal(
            self.analyzer_version
        ) >= analyzer_version_ordinal(TRANSPARENCY_ANALYZER_VERSION)

    @property
    def written_by_newer_build(self) -> bool:
        """Whether a build newer than this one produced this result.

        See :func:`is_newer_than_this_build`. Such a row is current -- it is
        served -- but it is never this build's to replace, even when it is
        provisional (#374).

        Returns:
            True when the result's version orders after this build's.
        """
        return is_newer_than_this_build(self.analyzer_version)

    @property
    def is_final(self) -> bool:
        """Whether this row is a finished finding, safe to serve from cache.

        ``is_current`` asks only who produced the row, never whether the
        analysis reached the sources it scores a study against. A throttled
        PubMed does not raise -- the fetch returns "unreachable" and the
        analysis completes with a caveat and a score that fell because
        nothing could be established. Stamped with the current version, that
        row answered ``is_current`` forever: a transient outage became a
        permanent risk claim no re-analysis would ever revisit.

        Returns:
            True when this build's analyser produced the result *and* every
            source it consulted answered. A provisional row is a cache miss.
        """
        return self.is_current and not self.sources_unreachable

    def to_dict(self) -> dict[str, Any]:
        """
        Serialize to dictionary for storage.

        Returns:
            Dictionary representation suitable for JSON serialization
        """
        return {
            "document_id": self.document_id,
            "transparency_score": self.transparency_score,
            "risk_level": self.risk_level.value,
            "industry_funding_detected": self.industry_funding_detected,
            "industry_funding_confidence": self.industry_funding_confidence,
            "data_availability_level": self.data_availability_level,
            "coi_disclosure": self.coi_disclosure,
            "trial_registered": self.trial_registered,
            "trial_results_compliant": self.trial_results_compliant,
            "outcome_switching_detected": self.outcome_switching_detected,
            "risk_indicators": self.risk_indicators,
            "warnings": self.warnings,
            "tier_downgrade_applied": self.tier_downgrade_applied,
            "analyzed_at": self.analyzed_at.isoformat(),
            "analyzer_version": self.analyzer_version,
            "sources_unreachable": self.sources_unreachable,
            "full_text_analyzed": self.full_text_analyzed,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "TransparencyResult":
        """
        Deserialize from dictionary.

        Args:
            data: Dictionary representation

        Returns:
            TransparencyResult instance
        """
        return cls(
            document_id=data["document_id"],
            transparency_score=data["transparency_score"],
            risk_level=TransparencyRisk(data["risk_level"]),
            industry_funding_detected=data.get("industry_funding_detected", False),
            industry_funding_confidence=data.get("industry_funding_confidence", 0.0),
            data_availability_level=data.get("data_availability_level", "unknown"),
            # ``or``, not a ``get`` default: a dict carrying an explicit
            # ``null`` would otherwise put ``None`` into a field every reader
            # treats as a string, and title-case it into the badge.
            coi_disclosure=data.get("coi_disclosure") or COI_NOT_ASSESSED,
            trial_registered=data.get("trial_registered", False),
            trial_results_compliant=data.get("trial_results_compliant", False),
            outcome_switching_detected=data.get("outcome_switching_detected", False),
            risk_indicators=data.get("risk_indicators", []),
            warnings=data.get("warnings", []),
            tier_downgrade_applied=data.get("tier_downgrade_applied", 0),
            analyzed_at=datetime.fromisoformat(data["analyzed_at"]),
            # A stored dict with no version was written before the field
            # was compared to anything, so it is legacy -- never current.
            # ``or``, not a ``get`` default, for the reason above: an
            # explicit ``null`` would otherwise put ``None`` into a field
            # typed ``str``. It reads as legacy either way, but honestly.
            analyzer_version=(
                data.get("analyzer_version") or LEGACY_ANALYZER_VERSION
            ),
            sources_unreachable=data.get("sources_unreachable", False),
            full_text_analyzed=data.get("full_text_analyzed", False),
        )


def calculate_risk_level(
    score: int,
    industry_funding: bool,
    data_availability: str,
    coi_disclosure: str,
    settings: "TransparencySettings",
) -> TransparencyRisk:
    """
    Determine risk level from transparency metrics.

    Risk levels:
    - High Risk: score < threshold OR (industry + restricted data) OR a COI
      statement the article was read to be missing
    - Medium Risk: between ``settings.score_threshold`` and
      ``MEDIUM_RISK_SCORE_THRESHOLD`` OR industry with disclosure
    - Low Risk: above ``MEDIUM_RISK_SCORE_THRESHOLD``, transparent

    Only ``COI_NOT_STATED`` raises the risk. ``COI_NOT_ASSESSED`` is not a
    finding about the study, so it cannot downgrade it -- the whole point of
    keeping the two apart (#352).

    Args:
        score: Transparency score (0-100)
        industry_funding: Whether industry funding was detected
        data_availability: Data availability level string
        coi_disclosure: One of ``COI_DISCLOSED``, ``COI_NOT_STATED`` or
            ``COI_NOT_ASSESSED``
        settings: Transparency settings with thresholds

    Returns:
        TransparencyRisk enum value
    """
    # High risk conditions
    if score < settings.score_threshold:
        return TransparencyRisk.HIGH

    if settings.industry_funding_triggers_downgrade:
        restricted_data = data_availability in (
            "restricted",
            "not_available",
            "not_stated",
        )
        if industry_funding and restricted_data:
            return TransparencyRisk.HIGH

    if settings.missing_coi_triggers_downgrade and coi_disclosure == COI_NOT_STATED:
        return TransparencyRisk.HIGH

    # Medium risk conditions
    if score <= MEDIUM_RISK_SCORE_THRESHOLD:
        return TransparencyRisk.MEDIUM

    if industry_funding:
        return TransparencyRisk.MEDIUM

    return TransparencyRisk.LOW
