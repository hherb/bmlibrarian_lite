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
Data models for BMLibrarian Lite.

Type-safe dataclasses for documents, chunks, search sessions,
citations, and review checkpoints. These models are used throughout
the lite module for consistent data handling.
"""

import hashlib
import json
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from http import HTTPStatus
from typing import TYPE_CHECKING, Any, Optional, TypeGuard

from .constants import HTTP_STATUS_CODE_MAX, HTTP_STATUS_CODE_MIN, MAX_PUBMED_SEARCH_OFFSET

if TYPE_CHECKING:
    from .quality.data_models import QualityAssessment


class SearchProvider(Enum):
    """Search provider for literature retrieval."""

    PUBMED = "pubmed"
    EUROPEPMC = "europepmc"
    BOTH = "both"

    @property
    def display_name(self) -> str:
        """Human-readable name for display."""
        names = {
            SearchProvider.PUBMED: "PubMed",
            SearchProvider.EUROPEPMC: "Europe PMC",
            SearchProvider.BOTH: "PubMed + Europe PMC",
        }
        return names.get(self, self.value)

    @property
    def description(self) -> str:
        """Description of the provider."""
        descriptions = {
            SearchProvider.PUBMED: "NCBI PubMed via E-utilities API",
            SearchProvider.EUROPEPMC: "Europe PMC REST API with preprint support",
            SearchProvider.BOTH: "Search both providers and merge results",
        }
        return descriptions.get(self, "")

    @property
    def supports_preprints(self) -> bool:
        """Whether this provider can search preprints."""
        return self in (SearchProvider.EUROPEPMC, SearchProvider.BOTH)


class DocumentSource(Enum):
    """Source of a document."""

    PUBMED = "pubmed"
    EUROPEPMC = "europepmc"
    LOCAL_PDF = "local_pdf"
    LOCAL_TEXT = "local_text"


class RequestFailureKind(Enum):
    """Why a request to a literature source produced no usable answer (#247).

    Each kind reads differently to the user, so a timeout, an HTTP error and
    a garbled answer are never reported as the same thing, and none of them
    as a search that matched nothing. The raw values are persisted in search
    session and report metadata, and the Swift and Android ports write the
    same strings: never rename one.
    """

    TIMEOUT = "timeout"
    CONNECTION = "connection"
    HTTP_STATUS = "http_status"
    REDIRECT_REFUSED = "redirect_refused"
    # The source answered, but said the request failed: E-utilities reports
    # some failures as an ``ERROR`` field inside an HTTP 200 (#255).
    SERVICE_ERROR = "service_error"
    MALFORMED_RESPONSE = "malformed_response"
    # The answer was readable but held less than it said it would: a count of
    # 57 with an empty list of IDs.
    INCOMPLETE_RESPONSE = "incomplete_response"
    REQUEST_FAILED = "request_failed"


@dataclass(frozen=True)
class RequestFailure:
    """A request that failed after its retries, reduced to what is safe to show.

    Only the kind and the HTTP status are kept. The ``requests`` exception is
    not: since #196 its ``request.body`` holds the NCBI API key, and a failed
    E-utilities answer's body can repeat the key too. Nothing built from this
    type can therefore print either.

    Attributes:
        kind: What went wrong.
        status_code: The HTTP status, for ``HTTP_STATUS`` and
            ``REDIRECT_REFUSED``; ``None`` otherwise or when unknown.

    Raises:
        ValueError: On construction, if a status code is given for another
            kind, or is not a three-digit HTTP status.
    """

    kind: RequestFailureKind
    status_code: int | None = None

    def __post_init__(self) -> None:
        """Refuse a status code the failure's kind cannot carry."""
        if self.status_code is None:
            return
        if self.kind not in _STATUS_CODE_KINDS:
            raise ValueError(f"A {self.kind.value} failure carries no HTTP status")
        if not _is_http_status_code(self.status_code):
            raise ValueError("An HTTP status code is an integer from 100 to 999")

    def describe(self) -> str:
        """Describe the failure as a clause for a sentence shown to the user.

        Returns:
            For example ``"HTTP 429 Too Many Requests"`` or
            ``"the request timed out"``.
        """
        if self.kind is RequestFailureKind.HTTP_STATUS:
            if self.status_code is None:
                return "an HTTP error"
            return _http_status_label(self.status_code)
        if self.kind is RequestFailureKind.REDIRECT_REFUSED:
            status = "" if self.status_code is None else f" (HTTP {self.status_code})"
            return f"a redirect{status} was refused"
        return _REQUEST_FAILURE_REASONS[self.kind]

    def to_dict(self) -> dict[str, Any]:
        """Convert to a JSON-safe dictionary."""
        return {"kind": self.kind.value, "status_code": self.status_code}

    @classmethod
    def from_dict(cls, data: Any) -> "RequestFailure":
        """Read a stored failure, degrading rather than refusing.

        A kind this build does not know (written by a newer one, or damaged),
        and a missing or non-object failure, become ``REQUEST_FAILED``: the
        entry still says a request failed, which is the part the reader must
        not lose. A status code is kept only for a kind that carries one, and
        only when it is an integer from 100 to 999.

        Args:
            data: The stored value, untrusted.

        Returns:
            The failure, as specific as the stored value allows.
        """
        if not isinstance(data, dict):
            return cls(RequestFailureKind.REQUEST_FAILED)
        try:
            kind = RequestFailureKind(data.get("kind"))
        except (ValueError, TypeError):
            return cls(RequestFailureKind.REQUEST_FAILED)
        status = data.get("status_code")
        if kind not in _STATUS_CODE_KINDS or not _is_http_status_code(status):
            status = None
        return cls(kind, status)


# The kinds whose failure is an HTTP answer, and so can name its status.
_STATUS_CODE_KINDS = (RequestFailureKind.HTTP_STATUS, RequestFailureKind.REDIRECT_REFUSED)

_REQUEST_FAILURE_REASONS: dict[RequestFailureKind, str] = {
    RequestFailureKind.TIMEOUT: "the request timed out",
    RequestFailureKind.CONNECTION: "the connection failed",
    RequestFailureKind.SERVICE_ERROR: "the service reported an error",
    RequestFailureKind.MALFORMED_RESPONSE: "the response could not be read",
    RequestFailureKind.INCOMPLETE_RESPONSE: "the response was incomplete",
    RequestFailureKind.REQUEST_FAILED: "the request failed",
}

# The reason phrases a clause names, fixed here rather than taken from
# http.HTTPStatus, whose phrases change between Python releases (3.13 renamed
# 413, 414 and 422) and which the Swift and Android ports cannot share. Any
# other status reads as its number alone. RFC 9110 wording.
_HTTP_REASON_PHRASES: dict[int, str] = {
    HTTPStatus.BAD_REQUEST.value: "Bad Request",
    HTTPStatus.UNAUTHORIZED.value: "Unauthorized",
    HTTPStatus.FORBIDDEN.value: "Forbidden",
    HTTPStatus.NOT_FOUND.value: "Not Found",
    HTTPStatus.REQUEST_TIMEOUT.value: "Request Timeout",
    HTTPStatus.REQUEST_ENTITY_TOO_LARGE.value: "Content Too Large",
    HTTPStatus.REQUEST_URI_TOO_LONG.value: "URI Too Long",
    HTTPStatus.TOO_MANY_REQUESTS.value: "Too Many Requests",
    HTTPStatus.INTERNAL_SERVER_ERROR.value: "Internal Server Error",
    HTTPStatus.BAD_GATEWAY.value: "Bad Gateway",
    HTTPStatus.SERVICE_UNAVAILABLE.value: "Service Unavailable",
    HTTPStatus.GATEWAY_TIMEOUT.value: "Gateway Timeout",
}


def _is_http_status_code(value: object) -> bool:
    """Whether a value is a three-digit HTTP status code.

    Args:
        value: The value, untrusted.

    Returns:
        True for an integer from 100 to 999. ``True`` is not one, although
        bool is an int subclass.
    """
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and HTTP_STATUS_CODE_MIN <= value <= HTTP_STATUS_CODE_MAX
    )


def _http_status_label(status_code: int) -> str:
    """Label an HTTP status with its reason phrase when the table has one.

    Args:
        status_code: The HTTP status code.

    Returns:
        For example ``"HTTP 503 Service Unavailable"``, or ``"HTTP 599"``.
    """
    phrase = _HTTP_REASON_PHRASES.get(status_code)
    return f"HTTP {status_code} {phrase}" if phrase else f"HTTP {status_code}"


# The providers a single request goes to; BOTH names a search, not a source.
_SINGLE_SOURCE_PROVIDERS = (SearchProvider.PUBMED, SearchProvider.EUROPEPMC)


@dataclass(frozen=True)
class RetrievalShortfall:
    """Part of a search that a failure left out (#247, #248).

    A search proceeds on what was retrieved, and the user is told what is
    missing: never silently, and never as a search that found nothing.

    Attributes:
        provider: The source that failed, ``PUBMED`` or ``EUROPEPMC``.
        failure: Why.
        records_missing: How many records could not be retrieved, at least
            one; or ``None`` when the source could not be searched at all, so
            how many it holds is unknown.

    Raises:
        ValueError: On construction, if the provider is ``BOTH`` or the count
            is below one. A shortfall with nothing missing is not recorded:
            it would tell the user a complete search was incomplete.
    """

    provider: SearchProvider
    failure: RequestFailure
    records_missing: int | None = None

    def __post_init__(self) -> None:
        """Refuse a shortfall that names no single source or misses nothing."""
        if self.provider not in _SINGLE_SOURCE_PROVIDERS:
            raise ValueError("A retrieval shortfall must name PubMed or Europe PMC")
        if self.records_missing is not None and not _is_record_count(self.records_missing):
            raise ValueError("A retrieval shortfall misses at least one record, or None")

    def describe(self) -> str:
        """Describe the shortfall as a clause for a sentence shown to the user.

        Returns:
            For example ``"PubMed could not be searched (HTTP 429 Too Many
            Requests)"`` or ``"200 PubMed records could not be retrieved (the
            request timed out)"``.
        """
        source = self.provider.display_name
        reason = self.failure.describe()
        if self.records_missing is None:
            return f"{source} could not be searched ({reason})"
        noun = "record" if self.records_missing == 1 else "records"
        return f"{self.records_missing:,} {source} {noun} could not be retrieved ({reason})"

    def to_dict(self) -> dict[str, Any]:
        """Convert to a JSON-safe dictionary."""
        return {
            "provider": self.provider.value,
            "failure": self.failure.to_dict(),
            "records_missing": self.records_missing,
        }

    @classmethod
    def from_dict(cls, data: Any) -> "RetrievalShortfall":
        """Read a stored shortfall.

        The failure and the count degrade: a count that is not a whole number
        of at least one becomes ``None``, which claims more is missing, never
        less. The source cannot degrade, so an entry that names neither
        PubMed nor Europe PMC (``both`` included) is refused.

        Args:
            data: The stored value, untrusted.

        Returns:
            The shortfall.

        Raises:
            ValueError: If the value is not a dictionary naming PubMed or
                Europe PMC.
        """
        if not isinstance(data, dict):
            raise ValueError(f"A retrieval shortfall must be a dict, not {type(data).__name__}")
        try:
            provider = SearchProvider(data.get("provider"))
        except (ValueError, TypeError):
            provider = None
        if provider is None or provider not in _SINGLE_SOURCE_PROVIDERS:
            raise ValueError("A retrieval shortfall must name PubMed or Europe PMC")
        missing = data.get("records_missing")
        if not _is_record_count(missing):
            missing = None
        return cls(provider, RequestFailure.from_dict(data.get("failure")), missing)


def _is_record_count(value: object) -> bool:
    """Whether a value counts at least one missing record.

    Args:
        value: The value, untrusted.

    Returns:
        True for an integer of at least one. ``True`` is not one, although
        bool is an int subclass.
    """
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


@dataclass
class CursorPaginationState:
    """
    Pagination state for cursor-based APIs (Europe PMC).

    Europe PMC uses cursor-based pagination which is more efficient
    for large result sets and provides stable iteration.

    Attributes:
        total_count: Total number of results available
        fetched_count: Number of results fetched so far
        current_cursor: Current cursor position
        next_cursor: Cursor for fetching next page (None if no more pages)
        unretrieved_count: Results the search asked for but could not
            retrieve: a later page failed or came back empty, or the cursor
            ended before them (#247)
        failure: Why they are missing, or None when every result arrived
        unreadable_count: Results Europe PMC sent that could not be parsed
    """

    total_count: int
    fetched_count: int
    current_cursor: str
    next_cursor: Optional[str]
    unretrieved_count: int = 0
    failure: RequestFailure | None = None
    unreadable_count: int = 0

    @property
    def has_more(self) -> bool:
        """Check if there are more results to fetch."""
        return (
            self.next_cursor is not None
            and self.next_cursor != self.current_cursor
            and self.fetched_count < self.total_count
        )

    @property
    def progress_percent(self) -> float:
        """Get fetch progress as percentage."""
        if self.total_count == 0:
            return 100.0
        return (self.fetched_count / self.total_count) * 100.0


@dataclass
class OffsetPaginationState:
    """
    Pagination state for offset-based APIs (PubMed).

    PubMed uses offset-based pagination with a maximum offset limit.

    Attributes:
        total_count: Total number of results available
        offset: Current offset position
        batch_size: Number of results per batch
        max_offset: Maximum allowed offset (API limit)
    """

    total_count: int
    offset: int
    batch_size: int
    max_offset: int = MAX_PUBMED_SEARCH_OFFSET

    @property
    def has_more(self) -> bool:
        """Check if there are more results to fetch."""
        return (
            self.offset + self.batch_size < self.total_count
            and self.offset < self.max_offset
        )

    @property
    def fetched_count(self) -> int:
        """Number of results fetched so far."""
        return min(self.offset + self.batch_size, self.total_count)

    @property
    def progress_percent(self) -> float:
        """Get fetch progress as percentage."""
        if self.total_count == 0:
            return 100.0
        return (self.fetched_count / self.total_count) * 100.0


class EvaluationErrorCode(Enum):
    """
    Error codes for evaluation failures.

    Negative values indicate failure types, allowing the score field
    to signal errors while maintaining the expected int type.

    Usage:
        if scored_doc.score < 0:
            error_code = EvaluationErrorCode(scored_doc.score)
            handle_error(error_code)
    """

    # Success (not an error)
    SUCCESS = 0

    # API/Network errors (-1 to -10)
    API_TIMEOUT = -1
    API_RATE_LIMIT = -2
    API_AUTH_ERROR = -3
    API_CONNECTION_ERROR = -4
    API_SERVER_ERROR = -5

    # Response parsing errors (-11 to -20)
    JSON_PARSE_ERROR = -11
    INVALID_RESPONSE_FORMAT = -12
    EMPTY_RESPONSE = -13
    RESPONSE_TOO_LARGE = -14

    # Retry exhaustion (-21 to -30)
    RETRY_EXHAUSTED = -21

    # General errors (-31 to -40)
    UNKNOWN_ERROR = -31
    INVALID_INPUT = -32

    @property
    def is_retryable(self) -> bool:
        """Check if this error type can be retried."""
        retryable_codes = {
            self.API_TIMEOUT,
            self.API_RATE_LIMIT,
            self.API_CONNECTION_ERROR,
            self.API_SERVER_ERROR,
        }
        return self in retryable_codes

    @property
    def description(self) -> str:
        """Get human-readable description of the error."""
        descriptions = {
            self.SUCCESS: "Success",
            self.API_TIMEOUT: "API request timed out",
            self.API_RATE_LIMIT: "API rate limit exceeded",
            self.API_AUTH_ERROR: "API authentication failed",
            self.API_CONNECTION_ERROR: "Failed to connect to API",
            self.API_SERVER_ERROR: "API server error",
            self.JSON_PARSE_ERROR: "Failed to parse JSON response",
            self.INVALID_RESPONSE_FORMAT: "Invalid response format",
            self.EMPTY_RESPONSE: "Empty response received",
            self.RESPONSE_TOO_LARGE: "Response exceeded size limit",
            self.RETRY_EXHAUSTED: "All retry attempts exhausted",
            self.UNKNOWN_ERROR: "Unknown error occurred",
            self.INVALID_INPUT: "Invalid input provided",
        }
        return descriptions.get(self, "Unknown error")


class AnalysisStage(Enum):
    """A stage of the review that reads documents with a model (#261, #262).

    The raw values are persisted in report metadata: never rename one.
    """

    SCORING = "scoring"
    CITATION_EXTRACTION = "citation_extraction"

    @property
    def loss_clause(self) -> str:
        """How a loss at this stage is described to the reader.

        Returns:
            The verb phrase completing "N of M documents ...". A stage added
            without a clause degrades to a general one rather than raising:
            the reason degrades, the loss never does -- and this is read at
            the moment the user is being told something failed.
        """
        return _STAGE_LOSS_CLAUSES.get(self, "could not be analysed")


_STAGE_LOSS_CLAUSES = {
    AnalysisStage.SCORING: "could not be scored",
    AnalysisStage.CITATION_EXTRACTION: "could not be read for citations",
}


@dataclass(frozen=True)
class AnalysisShortfall:
    """Documents a stage of the review could not analyse (#261, #262).

    The companion of :class:`RetrievalShortfall` for the stages after the
    search. A review proceeds on the documents that were analysed and says
    what is missing: never silently, and never as documents the model turned
    down.

    Attributes:
        stage: Which stage lost them.
        documents_failed: How many documents it could not analyse, at least
            one.
        documents_attempted: How many it tried, at least ``documents_failed``.
        causes: Why, each cause once, in the order it first occurred; empty
            when no cause was kept.

    Raises:
        ValueError: On construction, if nothing failed, or more documents
            failed than were attempted. A shortfall that lost nothing would
            tell the user a complete analysis was incomplete.
            See :meth:`__post_init__` for the full set.
    """

    stage: AnalysisStage
    documents_failed: int
    documents_attempted: int
    causes: tuple[EvaluationErrorCode, ...] = ()

    def __post_init__(self) -> None:
        """Refuse counts that cannot be true, and name each cause once.

        Twenty documents that timed out have one cause between them, so the
        causes are reduced on the way in rather than at each place they are
        read.

        The counts are checked with the same predicate :meth:`from_dict`
        uses, so a shortfall that can be written can always be read back --
        and ``bool`` is refused, because ``True`` is not a count.

        Raises:
            ValueError: If the stage is not an :class:`AnalysisStage`; if
                either count is not a whole number of at least one; if more
                documents failed than were attempted; or if the distinct
                causes outnumber the documents they are causes for.
        """
        if not isinstance(self.stage, AnalysisStage):
            raise ValueError("An analysis shortfall names the stage that lost them")
        if not _is_document_count(self.documents_failed):
            raise ValueError("An analysis shortfall loses at least one document")
        if not _is_document_count(self.documents_attempted):
            raise ValueError("An analysis shortfall attempts at least one document")
        if self.documents_attempted < self.documents_failed:
            raise ValueError(
                "An analysis shortfall cannot lose more documents than it attempted"
            )
        object.__setattr__(self, "causes", distinct_causes(self.causes))
        if len(self.causes) > self.documents_failed:
            raise ValueError(
                "An analysis shortfall cannot have more distinct causes "
                "than the documents it lost"
            )

    @property
    def nothing_survived(self) -> bool:
        """Whether every document attempted at this stage failed.

        Returns:
            True when the stage produced nothing, so there is nothing to
            proceed on.
        """
        return self.documents_failed == self.documents_attempted

    def describe(self) -> str:
        """Describe the shortfall as a clause for a sentence shown to the user.

        Returns:
            For example ``"3 of 20 documents could not be scored (API request
            timed out)"``. Without a cause, the count alone: the reason
            degrades, the loss never does.
        """
        noun = "document" if self.documents_attempted == 1 else "documents"
        clause = (
            f"{self.documents_failed:,} of {self.documents_attempted:,} "
            f"{noun} {self.stage.loss_clause}"
        )
        if not self.causes:
            return clause
        reasons = ", ".join(cause.description for cause in self.causes)
        return f"{clause} ({reasons})"

    def to_dict(self) -> dict[str, Any]:
        """Convert to a JSON-safe dictionary."""
        return {
            "stage": self.stage.value,
            "documents_failed": self.documents_failed,
            "documents_attempted": self.documents_attempted,
            "causes": [cause.value for cause in self.causes],
        }

    @classmethod
    def from_dict(cls, data: Any) -> "AnalysisShortfall":
        """Read a stored shortfall.

        The causes degrade: a code this build does not know is dropped, which
        loses the reason but never the loss. The stage and the counts cannot
        degrade -- a shortfall naming neither what failed nor how much tells
        the reader nothing -- so an entry missing either is refused.

        Args:
            data: The stored value, untrusted.

        Returns:
            The shortfall.

        Raises:
            ValueError: If the value is not a dictionary naming a known stage
                and counts that can be true.
        """
        if not isinstance(data, dict):
            raise ValueError(
                f"An analysis shortfall must be a dict, not {type(data).__name__}"
            )
        try:
            stage = AnalysisStage(data.get("stage"))
        except ValueError:
            raise ValueError("An analysis shortfall must name a known stage") from None
        failed = data.get("documents_failed")
        attempted = data.get("documents_attempted")
        if _is_document_count(failed) and _is_document_count(attempted):
            return cls(stage, failed, attempted, _causes_from_values(data.get("causes")))
        raise ValueError("An analysis shortfall counts the documents it lost")


def _is_document_count(value: object) -> TypeGuard[int]:
    """Whether a value counts documents.

    Args:
        value: The value, untrusted.

    Returns:
        True for a whole number of at least one. ``bool`` is an ``int`` in
        Python and is refused: ``True`` is not a count.
    """
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


def _causes_from_values(values: object) -> tuple[EvaluationErrorCode, ...]:
    """Read stored error codes, dropping what this build cannot name.

    Args:
        values: The stored causes, untrusted.

    Returns:
        The codes it recognised, each once, in order.
    """
    if not isinstance(values, list):
        return ()
    causes: list[EvaluationErrorCode] = []
    for value in values:
        try:
            causes.append(EvaluationErrorCode(value))
        except ValueError:
            continue
    return distinct_causes(causes)


def distinct_causes(
    causes: Iterable[EvaluationErrorCode],
) -> tuple[EvaluationErrorCode, ...]:
    """Reduce repeated causes to one mention each.

    Twenty documents that timed out have one cause between them, not twenty.

    Args:
        causes: The causes, in the order they occurred.

    Returns:
        Each cause once, in the order it first occurred, with ``SUCCESS``
        dropped: it is not a failure.
    """
    seen: dict[EvaluationErrorCode, None] = {}
    for cause in causes:
        if cause is not EvaluationErrorCode.SUCCESS:
            seen.setdefault(cause, None)
    return tuple(seen)


@dataclass(frozen=True)
class PassFailure:
    """One document a re-classification or re-scoring pass could not finish (#327).

    The pass counted its failures and logged the rest, so seventeen documents
    behind one unreachable provider and seventeen unprocessable abstracts
    reached the user as the same sentence: "17 documents failed". The user
    could not tell a retry from a dead end.

    The cause is classified, never the provider's own words: those can print
    the request, credentials and all, and belong in the log (#330).

    Attributes:
        document_id: The document the pass was working on.
        cause: What went wrong, classified.

    Raises:
        ValueError: On construction, if the document is unnamed or the cause
            is not a failure. A failure with no cause and no document is the
            count this class exists to replace.
    """

    document_id: str
    cause: EvaluationErrorCode

    def __post_init__(self) -> None:
        """Refuse a failure that names neither a document nor a cause.

        Raises:
            ValueError: If the document id is not a non-empty string, if the
                cause is not an :class:`EvaluationErrorCode`, or if it is
                ``SUCCESS``, which is not a failure.
        """
        if not isinstance(self.document_id, str) or not self.document_id:
            raise ValueError("A pass failure names the document it happened to")
        if not isinstance(self.cause, EvaluationErrorCode):
            raise ValueError("A pass failure names a classified cause")
        if self.cause is EvaluationErrorCode.SUCCESS:
            raise ValueError("A pass failure cannot be caused by success")


@dataclass(frozen=True)
class PassOutcome:
    """What a re-classification or re-scoring did with the documents it was given.

    Both passes reported a pair of counts, which a cancel then had to be told
    separately (#320) and which said nothing about why anything failed (#327).
    This is the one value both their terminal signals carry.

    A document the model answered for without naming a study design is neither
    a success nor a failure: nothing broke, and the model was honest. Counted
    as a failure it made "6 documents failed classification" out of a pass in
    which nothing went wrong.

    Attributes:
        succeeded: Documents the pass finished.
        failures: One per document it could not finish, in the order they
            happened.
        total: Documents it was given.
        unclassified: Documents the model answered for without naming a study
            design. Re-classification only; re-scoring has no such answer.

    Raises:
        ValueError: On construction, for counts that cannot be true --
            negative, or attempting more documents than were given. A pass
            that reports more work than it was given is not describing a run
            that happened.
    """

    succeeded: int
    failures: tuple[PassFailure, ...] = ()
    total: int = 0
    unclassified: int = 0

    def __post_init__(self) -> None:
        """Refuse counts that cannot be true, and keep the failures a tuple.

        Impossible counts are refused rather than repaired: a clamped count
        reads as a fact about the run, and the repair is invisible (#261).

        Raises:
            ValueError: If any count is not a whole number of at least zero,
                if the failures are not :class:`PassFailure` values, or if
                more documents were attempted than the pass was given.
        """
        object.__setattr__(self, "failures", tuple(self.failures))
        for count in (self.succeeded, self.total, self.unclassified):
            if isinstance(count, bool) or not isinstance(count, int) or count < 0:
                raise ValueError("A pass outcome counts documents in whole numbers")
        if not all(isinstance(failure, PassFailure) for failure in self.failures):
            raise ValueError("A pass outcome's failures each name a document and a cause")
        if self.attempted > self.total:
            raise ValueError(
                "A pass outcome cannot attempt more documents than it was given"
            )

    @property
    def failed(self) -> int:
        """How many documents the pass could not finish.

        Returns:
            The number of failures, which is what the user is told.
        """
        return len(self.failures)

    @property
    def attempted(self) -> int:
        """How many documents the pass reached.

        Returns:
            The successes, the failures and the documents left unclassified:
            every document it got an answer about, one way or another.
        """
        return self.succeeded + self.failed + self.unclassified

    @property
    def not_attempted(self) -> int:
        """How many documents the pass never reached.

        Returns:
            What a cancel stopped it from getting to; zero for a pass that
            ran to the end.
        """
        return self.total - self.attempted

    @property
    def causes(self) -> tuple[EvaluationErrorCode, ...]:
        """Why documents failed, each cause once.

        Returns:
            Each distinct cause, in the order it first occurred.
        """
        return distinct_causes(failure.cause for failure in self.failures)


class EvaluatorType(Enum):
    """Type of evaluator that produced an evaluation."""

    MODEL = "model"
    HUMAN = "human"


class BenchmarkStatus(Enum):
    """Status of a benchmark run."""

    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


@dataclass
class Evaluator:
    """
    Represents an entity that can produce evaluations.

    An evaluator can be either an LLM model with specific parameters
    or a human reviewer. This enables tracking which model/human
    produced each score for benchmarking comparisons.

    Attributes:
        id: Unique identifier (auto-generated from params for models)
        type: Whether this is a model or human evaluator
        display_name: Human-readable name for UI display
        provider: LLM provider (anthropic, ollama) - None for human
        model_name: Model identifier - None for human
        temperature: Sampling temperature - None for human
        max_tokens: Max output tokens - None for human
        top_p: Nucleus sampling parameter - None for human
        top_k: Top-k sampling parameter - None for human
        human_name: Reviewer name - None for model
        human_email: Reviewer email - None for model
        description: Optional description
        created_at: When this evaluator was first created
    """

    id: str
    type: EvaluatorType
    display_name: str

    # Model-specific fields (None for human)
    provider: Optional[str] = None
    model_name: Optional[str] = None
    temperature: Optional[float] = None
    max_tokens: Optional[int] = None
    top_p: Optional[float] = None
    top_k: Optional[int] = None

    # Human-specific fields (None for model)
    human_name: Optional[str] = None
    human_email: Optional[str] = None

    description: Optional[str] = None
    created_at: datetime = field(default_factory=datetime.now)

    @classmethod
    def from_model_config(
        cls,
        provider: str,
        model_name: str,
        temperature: float = 0.1,
        max_tokens: int = 256,
        top_p: Optional[float] = None,
        top_k: Optional[int] = None,
    ) -> "Evaluator":
        """
        Create a model evaluator from configuration.

        Generates a deterministic ID from the parameters so that
        the same model+params always produces the same evaluator ID.

        Args:
            provider: LLM provider (anthropic, ollama)
            model_name: Model identifier
            temperature: Sampling temperature
            max_tokens: Maximum output tokens
            top_p: Nucleus sampling parameter
            top_k: Top-k sampling parameter

        Returns:
            Evaluator configured for the specified model
        """
        # Generate deterministic ID from params
        params = {
            "provider": provider,
            "model": model_name,
            "temp": temperature,
            "max_tokens": max_tokens,
            "top_p": top_p,
            "top_k": top_k,
        }
        param_str = json.dumps(params, sort_keys=True)
        eval_id = f"eval_{hashlib.sha256(param_str.encode()).hexdigest()[:12]}"

        # Build display name
        display_name = f"{provider}:{model_name}"
        if temperature != 0.1:
            display_name += f" (t={temperature})"

        return cls(
            id=eval_id,
            type=EvaluatorType.MODEL,
            display_name=display_name,
            provider=provider,
            model_name=model_name,
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p,
            top_k=top_k,
        )

    @classmethod
    def from_human(
        cls,
        name: str,
        email: Optional[str] = None,
    ) -> "Evaluator":
        """
        Create a human evaluator.

        Args:
            name: Reviewer name
            email: Optional reviewer email

        Returns:
            Evaluator configured for human review
        """
        eval_id = f"human_{hashlib.sha256(name.encode()).hexdigest()[:12]}"
        return cls(
            id=eval_id,
            type=EvaluatorType.HUMAN,
            display_name=f"Human: {name}",
            human_name=name,
            human_email=email,
        )

    @property
    def is_model(self) -> bool:
        """Check if this is a model evaluator."""
        return self.type == EvaluatorType.MODEL

    @property
    def is_human(self) -> bool:
        """Check if this is a human evaluator."""
        return self.type == EvaluatorType.HUMAN

    @property
    def model_string(self) -> Optional[str]:
        """
        Get provider:model string for LLM client.

        Returns:
            Model string in "provider:model" format, or None for human
        """
        if self.is_model and self.provider and self.model_name:
            return f"{self.provider}:{self.model_name}"
        return None

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "type": self.type.value,
            "display_name": self.display_name,
            "provider": self.provider,
            "model_name": self.model_name,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
            "top_p": self.top_p,
            "top_k": self.top_k,
            "human_name": self.human_name,
            "human_email": self.human_email,
            "description": self.description,
            "created_at": self.created_at.isoformat(),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Evaluator":
        """Create from dictionary."""
        created_at = data.get("created_at")
        if isinstance(created_at, str):
            created_at = datetime.fromisoformat(created_at)
        elif created_at is None:
            created_at = datetime.now()

        return cls(
            id=data["id"],
            type=EvaluatorType(data["type"]),
            display_name=data["display_name"],
            provider=data.get("provider"),
            model_name=data.get("model_name"),
            temperature=data.get("temperature"),
            max_tokens=data.get("max_tokens"),
            top_p=data.get("top_p"),
            top_k=data.get("top_k"),
            human_name=data.get("human_name"),
            human_email=data.get("human_email"),
            description=data.get("description"),
            created_at=created_at,
        )


@dataclass
class LiteDocument:
    """
    Document representation for Lite version.

    Stores essential document metadata and abstract text.
    Used for both PubMed articles and local documents.

    Attributes:
        id: Unique identifier (e.g., "pmid-12345" or UUID)
        title: Document title
        abstract: Document abstract text
        authors: List of author names
        year: Publication year
        journal: Journal name
        doi: Digital Object Identifier
        pmid: PubMed ID
        pmc_id: PubMed Central ID (for open access articles)
        url: URL to the article
        mesh_terms: MeSH terms associated with the article
        source: Source of the document (PubMed, Europe PMC, local PDF, etc.)
        is_preprint: Whether this document is a preprint (Europe PMC only)
        metadata: Additional custom metadata
    """

    id: str  # Unique identifier (e.g., "pmid-12345" or UUID)
    title: str
    abstract: str
    authors: list[str] = field(default_factory=list)
    year: Optional[int] = None
    journal: Optional[str] = None
    doi: Optional[str] = None
    pmid: Optional[str] = None
    pmc_id: Optional[str] = None
    url: Optional[str] = None
    mesh_terms: list[str] = field(default_factory=list)
    source: DocumentSource = DocumentSource.PUBMED
    is_preprint: bool = False
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def formatted_authors(self) -> str:
        """
        Return formatted author string.

        Returns:
            Formatted authors (e.g., "Smith J, Jones A" or "Smith J et al.")
        """
        if not self.authors:
            return "Unknown"
        if len(self.authors) <= 3:
            return ", ".join(self.authors)
        return f"{self.authors[0]} et al."

    @property
    def citation(self) -> str:
        """
        Return formatted citation string.

        Returns:
            Citation in standard format
        """
        parts = [self.formatted_authors]
        if self.year:
            parts.append(f"({self.year})")
        parts.append(self.title)
        if self.journal:
            parts.append(self.journal)
        return ". ".join(parts)

    def to_dict(self) -> dict[str, Any]:
        """
        Convert to dictionary for serialization.

        Returns:
            Dictionary representation
        """
        return {
            "id": self.id,
            "title": self.title,
            "abstract": self.abstract,
            "authors": self.authors,
            "year": self.year,
            "journal": self.journal,
            "doi": self.doi,
            "pmid": self.pmid,
            "pmc_id": self.pmc_id,
            "url": self.url,
            "mesh_terms": self.mesh_terms,
            "source": self.source.value,
            "is_preprint": self.is_preprint,
            "metadata": self.metadata,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "LiteDocument":
        """
        Create from dictionary.

        Args:
            data: Dictionary representation

        Returns:
            LiteDocument instance
        """
        return cls(
            id=data["id"],
            title=data["title"],
            abstract=data["abstract"],
            authors=data.get("authors", []),
            year=data.get("year"),
            journal=data.get("journal"),
            doi=data.get("doi"),
            pmid=data.get("pmid"),
            pmc_id=data.get("pmc_id"),
            url=data.get("url"),
            mesh_terms=data.get("mesh_terms", []),
            source=DocumentSource(data.get("source", "pubmed")),
            is_preprint=data.get("is_preprint", False),
            metadata=data.get("metadata", {}),
        )


@dataclass
class LiteChunk:
    """
    A chunk of a document for embedding and retrieval.

    Used in document interrogation for semantic search
    over document sections.
    """

    id: str  # Unique chunk ID (e.g., "doc-123_chunk_0")
    document_id: str  # Parent document ID
    text: str  # Chunk text content
    chunk_index: int  # Position in document (0-indexed)
    start_char: int  # Start character position in original
    end_char: int  # End character position in original
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "document_id": self.document_id,
            "text": self.text,
            "chunk_index": self.chunk_index,
            "start_char": self.start_char,
            "end_char": self.end_char,
            "metadata": self.metadata,
        }


@dataclass
class SearchSession:
    """
    A PubMed search session.

    Tracks search queries and their results for history
    and reproducibility.
    """

    id: str  # Session UUID
    query: str  # PubMed query string
    natural_language_query: str  # Original user question
    created_at: datetime
    document_count: int  # Number of documents found
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "query": self.query,
            "natural_language_query": self.natural_language_query,
            "created_at": self.created_at.isoformat(),
            "document_count": self.document_count,
            "metadata": self.metadata,
        }


@dataclass
class ScoredDocument:
    """
    Document with relevance score.

    Result of document scoring by an evaluator (LLM model or human).
    Includes performance metrics for benchmarking comparisons.

    Attributes:
        document: The scored document
        score: Relevance score (1-5 scale)
        explanation: Rationale for the score
        evaluator_id: ID of the evaluator that produced this score
        evaluator: Full evaluator object (optional, for convenience)
        latency_ms: Time taken to produce the score (milliseconds)
        tokens_input: Number of input tokens used
        tokens_output: Number of output tokens used
        cost_usd: Estimated cost in USD
        scored_at: Timestamp when scoring occurred
    """

    document: LiteDocument
    score: int  # 1-5 scale
    explanation: str  # Why this score was assigned

    # Evaluator tracking
    evaluator_id: Optional[str] = None
    evaluator: Optional[Evaluator] = None

    # Performance metrics for benchmarking
    latency_ms: Optional[int] = None
    tokens_input: Optional[int] = None
    tokens_output: Optional[int] = None
    cost_usd: Optional[float] = None

    scored_at: datetime = field(default_factory=datetime.now)

    @property
    def is_relevant(self) -> bool:
        """Check if document meets minimum relevance threshold (score >= 3)."""
        return self.score >= 3

    @property
    def total_tokens(self) -> int:
        """Total tokens used (input + output)."""
        return (self.tokens_input or 0) + (self.tokens_output or 0)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "document": self.document.to_dict(),
            "score": self.score,
            "explanation": self.explanation,
            "evaluator_id": self.evaluator_id,
            "latency_ms": self.latency_ms,
            "tokens_input": self.tokens_input,
            "tokens_output": self.tokens_output,
            "cost_usd": self.cost_usd,
            "scored_at": self.scored_at.isoformat(),
        }


@dataclass(frozen=True)
class ScoringOutcome:
    """What scoring produced, and what it could not do (#262).

    Documents the model could not score used to leave scoring the same way
    documents it judged irrelevant did -- missing from the result -- so a
    review whose provider was down ended with "no documents scored 3 or
    higher". They are counted apart here.

    Attributes:
        accepted: The documents that met the threshold, highest score first.
        failed: The documents scoring could not score, each carrying its
            error code as a negative score.
        documents_attempted: How many documents scoring tried, which is fewer
            than were asked for when the run was cancelled.
    """

    accepted: list["ScoredDocument"]
    failed: list["ScoredDocument"]
    documents_attempted: int

    def __post_init__(self) -> None:
        """Refuse an outcome whose numbers cannot all be true.

        The counts decide whether the stage raises, so a caller that
        miscounts must not be quietly corrected into a plausible verdict:
        floored to the number of failures, an under-counted ``attempted``
        reads as "every document failed" and ends the review (#301 review).

        Raises:
            ValueError: If more documents were accepted and lost than were
                attempted, or if a document in ``failed`` does not carry an
                error code in place of its score.
        """
        if self.documents_attempted < len(self.accepted) + len(self.failed):
            raise ValueError(
                "A scoring outcome cannot accept and lose more documents "
                "than it attempted"
            )
        if any(scored.score >= 0 for scored in self.failed):
            raise ValueError(
                "A failed document carries its error code as a negative score"
            )

    @property
    def shortfall(self) -> AnalysisShortfall | None:
        """What scoring lost, or ``None`` when it scored every document.

        Returns:
            The shortfall, its causes read from the failed documents' error
            codes.
        """
        return analysis_shortfall_for_failed_scores(
            AnalysisStage.SCORING, self.failed, self.documents_attempted
        )


def analysis_shortfall_for_failed_scores(
    stage: AnalysisStage,
    failed: "Sequence[ScoredDocument]",
    documents_attempted: int,
) -> AnalysisShortfall | None:
    """Record what a stage lost, reading each failure's cause from its score.

    Args:
        stage: The stage that lost them.
        failed: The documents it could not analyse, each with a negative
            score holding an :class:`EvaluationErrorCode`.
        documents_attempted: How many documents the stage tried.

    Returns:
        The shortfall, or ``None`` when nothing failed: a shortfall that lost
        nothing would tell the user a complete analysis was incomplete.
    """
    if not failed:
        return None
    causes: list[EvaluationErrorCode] = []
    for scored in failed:
        try:
            causes.append(EvaluationErrorCode(scored.score))
        except ValueError:
            causes.append(EvaluationErrorCode.UNKNOWN_ERROR)
    return AnalysisShortfall(
        stage=stage,
        documents_failed=len(failed),
        documents_attempted=documents_attempted,
        causes=tuple(causes),
    )


@dataclass
class Citation:
    """
    Extracted citation from a document.

    Contains a specific passage that supports answering
    the research question.
    """

    document: LiteDocument
    passage: str  # Extracted text passage
    relevance_score: int  # Score of parent document
    context: str = ""  # Why this passage is relevant
    assessment: Optional["QualityAssessment"] = None  # Quality assessment if available

    @property
    def formatted_citation(self) -> str:
        """
        Return formatted citation with passage.

        Returns:
            Citation with quoted passage
        """
        return f'"{self.passage}" [{self.document.formatted_authors}, {self.document.year or "n.d."}]'

    @property
    def formatted_reference(self) -> str:
        """
        Return a short reference string.

        Handles author names in either "LastName, FirstName" or "LastName FirstName" formats.

        Returns:
            Short reference (e.g., "Smith et al., 2023")
        """
        if self.document.authors:
            first_author_full = self.document.authors[0]
            # Handle both "LastName, FirstName" and "LastName FirstName" formats
            if "," in first_author_full:
                # "LastName, FirstName" format - take part before comma
                last_name = first_author_full.split(",")[0].strip()
            else:
                # "LastName FirstName" format - take first word
                last_name = first_author_full.split()[0].strip()

            if len(self.document.authors) > 1:
                author_str = f"{last_name} et al."
            else:
                author_str = last_name
        else:
            author_str = "Unknown"
        year = self.document.year or "n.d."
        return f"{author_str}, {year}"

    @property
    def quality_annotation(self) -> str:
        """
        Get quality annotation for inline use.

        Returns:
            Quality annotation string or empty string
        """
        if not self.assessment:
            return ""

        parts = []
        design = self.assessment.study_design.value.replace("_", " ").title()
        if design.lower() not in ["unknown", "other"]:
            parts.append(design)

        if self.assessment.sample_size:
            parts.append(f"n={self.assessment.sample_size:,}")

        if self.assessment.is_blinded and self.assessment.is_blinded != "none":
            parts.append(f"{self.assessment.is_blinded}-blind")

        if parts:
            return f"**{', '.join(parts)}**"
        return ""


@dataclass(frozen=True)
class ExtractionFailure:
    """A relevant document whose citations could not be extracted (#310).

    Attributes:
        document: The document the model could not read.
        cause: The error code classifying why extraction failed.
    """

    document: LiteDocument
    cause: EvaluationErrorCode

    def __post_init__(self) -> None:
        """Refuse a failure whose cause is success.

        Raises:
            ValueError: If the cause is ``SUCCESS``: the audit would say the
                document failed because it succeeded.
        """
        if self.cause is EvaluationErrorCode.SUCCESS:
            raise ValueError(f"{self.document.id}: a failure cannot be caused by success")


@dataclass(frozen=True)
class CitationOutcome:
    """What citation extraction produced, and what it could not do (#261).

    A relevant document the model could not read is not a document with
    nothing to say, but both used to leave extraction as an absent citation.
    A report built on no citations at all then told the reader that the
    literature was silent. The outcome names each document it could not read
    (#310): counted only, the audit record could not tell which of the
    uncited relevant documents were silent and which were never read.

    Attributes:
        citations: The passages that were extracted.
        documents_attempted: How many documents extraction tried: those at or
            above the threshold, each counted once however often it was
            listed, minus any the run was cancelled before.
        failed: The documents it could not read, each with why, in the order
            they failed. The count and the causes are read from these.
    """

    citations: list["Citation"]
    documents_attempted: int
    failed: tuple[ExtractionFailure, ...] = ()

    def __post_init__(self) -> None:
        """Refuse an outcome whose numbers cannot all be true.

        An under-counted ``attempted`` floored to the failures would report a
        total loss on a report that is fine (#301 review), so an impossible
        count is refused rather than repaired.

        Raises:
            ValueError: If the attempted count is negative, if more documents
                were lost than attempted, if a document failed twice, or if a
                document that failed was also cited.
        """
        object.__setattr__(self, "failed", tuple(self.failed))
        if self.documents_attempted < 0:
            raise ValueError("A citation outcome counts documents, never fewer than none")
        if self.documents_attempted < len(self.failed):
            raise ValueError(
                "A citation outcome cannot lose more documents than it attempted"
            )
        failed_ids = [failure.document.id for failure in self.failed]
        if len(failed_ids) != len(set(failed_ids)):
            raise ValueError("A document's extraction is attempted, and fails, once")
        if any(citation.document.id in failed_ids for citation in self.citations):
            raise ValueError("A document whose extraction failed cannot have been cited")

    @property
    def documents_failed(self) -> int:
        """How many of the documents attempted could not be read.

        Returns:
            The number of failed documents.
        """
        return len(self.failed)

    @property
    def causes(self) -> tuple[EvaluationErrorCode, ...]:
        """Why, each cause once, in the order it first occurred.

        Returns:
            The distinct causes of the failures.
        """
        return distinct_causes(failure.cause for failure in self.failed)

    @property
    def shortfall(self) -> AnalysisShortfall | None:
        """What extraction lost, or ``None`` when it read every document.

        Returns:
            The shortfall, or ``None`` when nothing failed.
        """
        if not self.failed:
            return None
        return AnalysisShortfall(
            stage=AnalysisStage.CITATION_EXTRACTION,
            documents_failed=self.documents_failed,
            documents_attempted=self.documents_attempted,
            causes=self.causes,
        )


@dataclass
class ReviewCheckpoint:
    """
    Checkpoint for systematic review progress.

    Allows resuming reviews from any step in the workflow.
    """

    id: str  # Checkpoint UUID
    research_question: str
    created_at: datetime
    updated_at: datetime
    step: str  # Current workflow step (e.g., "search", "scoring", "report")
    search_session_id: Optional[str] = None
    scored_documents: list[ScoredDocument] = field(default_factory=list)
    citations: list[Citation] = field(default_factory=list)
    report: Optional[str] = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "research_question": self.research_question,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
            "step": self.step,
            "search_session_id": self.search_session_id,
            "report": self.report,
            "metadata": self.metadata,
        }


@dataclass
class InterrogationSession:
    """
    Session for document interrogation.

    Tracks the loaded document and conversation history.
    """

    id: str  # Session UUID
    document_id: str  # ID of loaded document
    document_title: str
    created_at: datetime
    messages: list[dict[str, str]] = field(default_factory=list)  # Chat history
    metadata: dict[str, Any] = field(default_factory=dict)

    def add_message(self, role: str, content: str) -> None:
        """
        Add a message to the conversation history.

        Args:
            role: "user" or "assistant"
            content: Message text
        """
        self.messages.append({
            "role": role,
            "content": content,
            "timestamp": datetime.now().isoformat(),
        })


@dataclass
class BenchmarkRun:
    """
    A benchmark comparison run.

    Tracks a benchmarking session that compares multiple evaluators
    on a set of documents for a given research question.

    Attributes:
        id: Unique identifier for this benchmark run
        name: User-provided name for the run
        description: Optional description
        question: Research question being evaluated
        question_hash: Normalized hash of question for efficient lookup
        task_type: Type of task being benchmarked (e.g., document_scoring)
        evaluator_ids: List of evaluator IDs to compare
        document_ids: List of document IDs to evaluate
        status: Current status of the benchmark
        progress_current: Current progress count
        progress_total: Total items to process
        error_message: Error message if failed
        results_summary: JSON string with aggregated statistics
        created_at: When the run was created
        started_at: When execution started
        completed_at: When execution completed
    """

    id: str
    name: str
    question: str
    task_type: str
    evaluator_ids: list[str]
    document_ids: list[str]

    description: Optional[str] = None
    question_hash: Optional[str] = None
    status: BenchmarkStatus = BenchmarkStatus.PENDING
    progress_current: int = 0
    progress_total: int = 0
    error_message: Optional[str] = None
    results_summary: Optional[str] = None

    created_at: datetime = field(default_factory=datetime.now)
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None

    @property
    def is_complete(self) -> bool:
        """Check if benchmark has finished (successfully or not)."""
        return self.status in (
            BenchmarkStatus.COMPLETED,
            BenchmarkStatus.FAILED,
            BenchmarkStatus.CANCELLED,
        )

    @property
    def progress_percent(self) -> float:
        """Get progress as percentage (0.0 to 100.0)."""
        if self.progress_total == 0:
            return 0.0
        return (self.progress_current / self.progress_total) * 100.0

    @property
    def duration_seconds(self) -> Optional[float]:
        """Get duration in seconds if completed."""
        if self.started_at is None:
            return None
        end_time = self.completed_at or datetime.now()
        return (end_time - self.started_at).total_seconds()

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "question": self.question,
            "question_hash": self.question_hash,
            "task_type": self.task_type,
            "evaluator_ids": self.evaluator_ids,
            "document_ids": self.document_ids,
            "status": self.status.value,
            "progress_current": self.progress_current,
            "progress_total": self.progress_total,
            "error_message": self.error_message,
            "results_summary": self.results_summary,
            "created_at": self.created_at.isoformat(),
            "started_at": self.started_at.isoformat() if self.started_at else None,
            "completed_at": self.completed_at.isoformat() if self.completed_at else None,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "BenchmarkRun":
        """Create from dictionary."""
        def parse_datetime(val: Any) -> Optional[datetime]:
            if val is None:
                return None
            if isinstance(val, datetime):
                return val
            return datetime.fromisoformat(val)

        return cls(
            id=data["id"],
            name=data["name"],
            description=data.get("description"),
            question=data["question"],
            question_hash=data.get("question_hash"),
            task_type=data["task_type"],
            evaluator_ids=data["evaluator_ids"],
            document_ids=data["document_ids"],
            status=BenchmarkStatus(data.get("status", "pending")),
            progress_current=data.get("progress_current", 0),
            progress_total=data.get("progress_total", 0),
            error_message=data.get("error_message"),
            results_summary=data.get("results_summary"),
            created_at=parse_datetime(data.get("created_at")) or datetime.now(),
            started_at=parse_datetime(data.get("started_at")),
            completed_at=parse_datetime(data.get("completed_at")),
        )


@dataclass
class ResearchQuestionSummary:
    """
    Summary of a research question for the Research Questions tab.

    Contains metadata about past runs of a research question including
    the most recent PubMed query, document counts, and scoring status.

    Attributes:
        question: The natural language research question
        question_hash: Normalized hash for matching variations
        pubmed_query: Most recent PubMed query string used
        last_run_at: When the question was last run
        total_documents: Total documents found across all runs
        scored_documents: Count of documents with a score, failures excluded
        run_count: Number of times this question has been run
        failed_documents: Count of documents every scoring of which failed;
            counted as scored, an outage looked like a finished review (#307)
    """

    question: str
    question_hash: str
    pubmed_query: str
    last_run_at: datetime
    total_documents: int = 0
    scored_documents: int = 0
    run_count: int = 1
    failed_documents: int = 0


@dataclass
class ReportMetadata:
    """
    Metadata for report reproducibility and versioning.

    Captures all parameters and statistics from a systematic review
    workflow for inclusion in the report methodology section.

    Attributes:
        version: Report version number (increments for re-runs)
        generated_at: When the report was generated

        research_question: The natural language research question
        pubmed_query: PubMed query string used for search
        pubmed_search_date: When the PubMed search was executed
        total_results_available: Total results available in PubMed
        total_is_lower_bound: Whether total_results_available is a conservative
            lower bound rather than an exact count (true for "Both" mode, where
            the PubMed/Europe PMC union size is unknowable without full retrieval)
        documents_retrieved: Number of documents actually retrieved
        search_shortfalls: What failed sources, batches or pages left out of
            the search (#247); empty when the search was complete
        analysis_shortfalls: What scoring and citation extraction could not
            read (#261, #262); empty when every document was analysed

        documents_scored: Documents the model actually scored, which is
            ``documents_accepted + documents_rejected``. Documents it could
            not score are counted in ``analysis_shortfalls``, not here: a
            document that failed was neither scored nor rejected (#262)
        documents_accepted: Documents that met the score threshold
        documents_rejected: Documents below the score threshold
        min_score_threshold: Minimum relevance score used (1-5)
        score_distribution: Count of documents at each score level

        quality_filter_applied: Whether quality filtering was used
        quality_filter_settings: Quality filter configuration
        documents_filtered_by_quality: Documents removed by quality filter

        transparency_analysis_applied: Whether transparency analysis was run
        transparency_low_risk_count: Documents with low transparency risk
        transparency_medium_risk_count: Documents with medium transparency risk
        transparency_high_risk_count: Documents with high transparency risk

        model_configs: LLM configuration for each workflow task
        citations_extracted: Total citation passages extracted
        unique_sources_cited: Number of unique documents cited
    """

    # Version info
    version: int = 1
    generated_at: datetime = field(default_factory=datetime.now)

    # Search info
    research_question: str = ""
    pubmed_query: str = ""
    pubmed_search_date: Optional[datetime] = None
    total_results_available: int = 0
    total_is_lower_bound: bool = False
    documents_retrieved: int = 0
    search_shortfalls: list[RetrievalShortfall] = field(default_factory=list)
    analysis_shortfalls: list[AnalysisShortfall] = field(default_factory=list)

    # Scoring info
    documents_scored: int = 0
    documents_accepted: int = 0
    documents_rejected: int = 0
    min_score_threshold: int = 3
    score_distribution: dict[int, int] = field(default_factory=dict)

    # Quality filter info
    quality_filter_applied: bool = False
    quality_filter_settings: Optional[dict[str, Any]] = None
    documents_filtered_by_quality: int = 0

    # Transparency analysis info
    transparency_analysis_applied: bool = False
    transparency_low_risk_count: int = 0
    transparency_medium_risk_count: int = 0
    transparency_high_risk_count: int = 0

    # LLM configuration by task
    model_configs: dict[str, dict[str, Any]] = field(default_factory=dict)

    # Citations info
    citations_extracted: int = 0
    unique_sources_cited: int = 0

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "version": self.version,
            "generated_at": self.generated_at.isoformat(),
            "research_question": self.research_question,
            "pubmed_query": self.pubmed_query,
            "pubmed_search_date": (
                self.pubmed_search_date.isoformat()
                if self.pubmed_search_date
                else None
            ),
            "total_results_available": self.total_results_available,
            "total_is_lower_bound": self.total_is_lower_bound,
            "documents_retrieved": self.documents_retrieved,
            "search_shortfalls": [s.to_dict() for s in self.search_shortfalls],
            "analysis_shortfalls": [s.to_dict() for s in self.analysis_shortfalls],
            "documents_scored": self.documents_scored,
            "documents_accepted": self.documents_accepted,
            "documents_rejected": self.documents_rejected,
            "min_score_threshold": self.min_score_threshold,
            "score_distribution": self.score_distribution,
            "quality_filter_applied": self.quality_filter_applied,
            "quality_filter_settings": self.quality_filter_settings,
            "documents_filtered_by_quality": self.documents_filtered_by_quality,
            "transparency_analysis_applied": self.transparency_analysis_applied,
            "transparency_low_risk_count": self.transparency_low_risk_count,
            "transparency_medium_risk_count": self.transparency_medium_risk_count,
            "transparency_high_risk_count": self.transparency_high_risk_count,
            "model_configs": self.model_configs,
            "citations_extracted": self.citations_extracted,
            "unique_sources_cited": self.unique_sources_cited,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ReportMetadata":
        """Create from dictionary."""
        generated_at = data.get("generated_at")
        if isinstance(generated_at, str):
            generated_at = datetime.fromisoformat(generated_at)
        elif generated_at is None:
            generated_at = datetime.now()

        search_date = data.get("pubmed_search_date")
        if isinstance(search_date, str):
            search_date = datetime.fromisoformat(search_date)

        # Metadata saved before #247 has no shortfalls. Anything else that is
        # not a list is refused rather than read as a complete search.
        stored_shortfalls = data.get("search_shortfalls", [])
        if not isinstance(stored_shortfalls, list):
            raise ValueError("search_shortfalls must be a list")

        # Metadata saved before #261 has no analysis shortfalls.
        stored_analysis = data.get("analysis_shortfalls", [])
        if not isinstance(stored_analysis, list):
            raise ValueError("analysis_shortfalls must be a list")

        return cls(
            version=data.get("version", 1),
            generated_at=generated_at,
            research_question=data.get("research_question", ""),
            pubmed_query=data.get("pubmed_query", ""),
            pubmed_search_date=search_date,
            total_results_available=data.get("total_results_available", 0),
            total_is_lower_bound=data.get("total_is_lower_bound", False),
            documents_retrieved=data.get("documents_retrieved", 0),
            search_shortfalls=[RetrievalShortfall.from_dict(s) for s in stored_shortfalls],
            analysis_shortfalls=[AnalysisShortfall.from_dict(s) for s in stored_analysis],
            documents_scored=data.get("documents_scored", 0),
            documents_accepted=data.get("documents_accepted", 0),
            documents_rejected=data.get("documents_rejected", 0),
            min_score_threshold=data.get("min_score_threshold", 3),
            score_distribution=data.get("score_distribution", {}),
            quality_filter_applied=data.get("quality_filter_applied", False),
            quality_filter_settings=data.get("quality_filter_settings"),
            documents_filtered_by_quality=data.get("documents_filtered_by_quality", 0),
            transparency_analysis_applied=data.get(
                "transparency_analysis_applied", False
            ),
            transparency_low_risk_count=data.get("transparency_low_risk_count", 0),
            transparency_medium_risk_count=data.get(
                "transparency_medium_risk_count", 0
            ),
            transparency_high_risk_count=data.get("transparency_high_risk_count", 0),
            model_configs=data.get("model_configs", {}),
            citations_extracted=data.get("citations_extracted", 0),
            unique_sources_cited=data.get("unique_sources_cited", 0),
        )
