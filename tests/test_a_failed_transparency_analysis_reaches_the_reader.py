# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A transparency analysis that failed says so, and says why (#361, #249).

``TransparencyManager`` emitted ``analysis_failed`` into the void: nothing in
the application connected it, so a PubMed outage produced a review in which
half the studies carried no transparency badge and nothing said why. A
missing badge meant three different things -- transparency disabled, analysis
still running, analysis failed -- and the reader could not tell them apart.

What it emitted was ``str(e)``. A ``requests`` exception embeds the request
URL, and the Unpaywall URL carries the user's email address while the NCBI one
carries the API key (#196, #330), so connecting the signal to the screen
without classifying the failure first would have put a credential in a box the
user can screenshot.

These tests follow a failure from the worker's exception to the badge.
"""

from typing import Any
from unittest.mock import MagicMock

import pytest
import requests

from bmlibrarian_lite.analysis_failures import (
    source_failure_advice,
    transparency_failure_text,
)
from bmlibrarian_lite.data_models import (
    EvaluationErrorCode,
    TransparencyAnalysisFailure,
    TransparencyFailureKind,
)
from bmlibrarian_lite.utils import classify_analysis_exception

NOT_A_FINDING = "which is not a finding against the study"
DOC = "pmid-12345678"


class TestTheFailureValueRefusesImpossibleStates:
    """A failure carries a classified cause, or names no cause at all."""

    def test_an_analysis_failure_without_a_cause_is_refused(self) -> None:
        """A failed analysis the caller did not classify has no sentence."""
        with pytest.raises(ValueError):
            TransparencyAnalysisFailure(
                document_id=DOC,
                kind=TransparencyFailureKind.ANALYSIS_FAILED,
                cause=None,
            )

    def test_a_success_is_not_a_cause_of_failure(self) -> None:
        """``SUCCESS`` describes nothing a reader needs to be told about."""
        with pytest.raises(ValueError):
            TransparencyAnalysisFailure(
                document_id=DOC,
                kind=TransparencyFailureKind.ANALYSIS_FAILED,
                cause=EvaluationErrorCode.SUCCESS,
            )

    def test_a_missing_identifier_carries_no_provider_cause(self) -> None:
        """Nothing was asked, so no provider can have failed."""
        with pytest.raises(ValueError):
            TransparencyAnalysisFailure(
                document_id=DOC,
                kind=TransparencyFailureKind.NO_IDENTIFIER,
                cause=EvaluationErrorCode.API_RATE_LIMIT,
            )

    def test_the_two_constructors_build_the_two_states(self) -> None:
        """Both builders produce a failure naming the document."""
        skipped = TransparencyAnalysisFailure.no_identifier(DOC)
        failed = TransparencyAnalysisFailure.failed(
            DOC, EvaluationErrorCode.API_RATE_LIMIT
        )

        assert skipped.kind is TransparencyFailureKind.NO_IDENTIFIER
        assert skipped.cause is None
        assert failed.cause is EvaluationErrorCode.API_RATE_LIMIT
        assert skipped.document_id == failed.document_id == DOC


class TestWhatTheReaderIsTold:
    """The sentence is pure, classified, and never the provider's own words."""

    def test_a_missing_identifier_says_what_is_missing(self) -> None:
        """A record with neither identifier could not be looked up at all."""
        text = transparency_failure_text(
            TransparencyAnalysisFailure.no_identifier(DOC)
        )

        assert "PubMed ID" in text and "DOI" in text
        assert NOT_A_FINDING in text

    def test_a_failure_names_its_cause_and_what_to_do(self) -> None:
        """A rate limit is not reported as an article without a disclosure."""
        text = transparency_failure_text(
            TransparencyAnalysisFailure.failed(
                DOC, EvaluationErrorCode.API_RATE_LIMIT
            )
        )

        assert EvaluationErrorCode.API_RATE_LIMIT.description in text
        assert NOT_A_FINDING in text
        # The advice for a rate limit, from the one place that decides it.
        assert "wait" in text.lower()

    def test_a_refused_key_advises_checking_the_key(self) -> None:
        """Each cause brings the advice the reader can act on."""
        text = transparency_failure_text(
            TransparencyAnalysisFailure.failed(
                DOC, EvaluationErrorCode.API_AUTH_ERROR
            )
        )

        assert "key" in text.lower()

    def test_the_two_states_do_not_read_alike(self) -> None:
        """A skip and a failure are different things to tell the reader."""
        skipped = transparency_failure_text(
            TransparencyAnalysisFailure.no_identifier(DOC)
        )
        failed = transparency_failure_text(
            TransparencyAnalysisFailure.failed(
                DOC, EvaluationErrorCode.API_CONNECTION_ERROR
            )
        )

        assert skipped != failed


class TestClassifyingWhatTheAnalysisRaised:
    """A throttled source is not a broken connection, and reads differently."""

    @staticmethod
    def _http_error(status: int) -> requests.HTTPError:
        """Build the error ``raise_for_status`` raises for a status.

        Args:
            status: The HTTP status the source answered with.

        Returns:
            The exception, carrying a real response as production's does.
        """
        response = requests.Response()
        response.status_code = status
        response.url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
        return requests.HTTPError(f"{status} Server Error", response=response)

    def test_a_throttled_source_is_a_rate_limit(self) -> None:
        """429 used to classify as a connection error, and advised the wifi."""
        assert classify_analysis_exception(self._http_error(429)) is (
            EvaluationErrorCode.API_RATE_LIMIT
        )

    def test_a_refused_key_is_an_auth_error(self) -> None:
        """403 is the reader's own key, not the network."""
        assert classify_analysis_exception(self._http_error(403)) is (
            EvaluationErrorCode.API_AUTH_ERROR
        )

    def test_a_server_fault_is_a_server_error(self) -> None:
        """503 is the provider's, and nothing the reader can fix."""
        assert classify_analysis_exception(self._http_error(503)) is (
            EvaluationErrorCode.API_SERVER_ERROR
        )

    def test_a_refused_connection_is_still_a_connection_error(self) -> None:
        """The control: the classification that was already right stays."""
        assert classify_analysis_exception(
            requests.ConnectionError("connection refused")
        ) is EvaluationErrorCode.API_CONNECTION_ERROR

    def test_a_timeout_is_still_a_timeout(self) -> None:
        """The second control, for the other kind this must not swallow."""
        assert classify_analysis_exception(
            requests.Timeout("timed out")
        ) is EvaluationErrorCode.API_TIMEOUT


@pytest.fixture
def qapp() -> Any:
    """The QApplication the widget tests need."""
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


class TestTheManagerEmitsAClassifiedFailure:
    """What leaves the worker is a value, not the provider's error text."""

    @staticmethod
    def _manager(analyzer: Any) -> Any:
        """Build a manager whose analyzer is the given stand-in.

        Args:
            analyzer: What ``analyze`` should do.

        Returns:
            The manager, already started.
        """
        pytest.importorskip("PySide6")
        from unittest.mock import patch

        from bmlibrarian_lite.transparency import (
            TransparencyManager,
            TransparencySettings,
        )

        storage = MagicMock()
        storage.get_transparency_result.return_value = None
        config = MagicMock()
        config.transparency = TransparencySettings()
        with patch(
            "bmlibrarian_lite.transparency.transparency_manager."
            "StudyTransparencyAnalyzer"
        ) as analyzer_class:
            analyzer_class.return_value = analyzer
            return TransparencyManager(
                storage=storage, config=config, email="test@example.com"
            )

    def test_a_document_with_no_identifier_is_reported_as_a_skip(
        self, qapp: Any
    ) -> None:
        """Nothing was asked, so nothing about the study was established."""
        manager = self._manager(MagicMock())
        failures: list[Any] = []
        manager.analysis_failed.connect(
            lambda doc_id, failure: failures.append((doc_id, failure))
        )

        manager.analyze_document("doc-1")

        assert failures, "a document nobody could look up said nothing"
        doc_id, failure = failures[0]
        assert doc_id == "doc-1"
        assert failure.kind is TransparencyFailureKind.NO_IDENTIFIER

    def test_a_throttled_source_reaches_the_signal_classified(
        self, qapp: Any
    ) -> None:
        """The emitted value carries the cause, never the request's URL."""
        import threading

        from PySide6.QtCore import Qt

        response = requests.Response()
        response.status_code = 429
        response.url = (
            "https://api.unpaywall.org/v2/10.1/?email=reader@example.com"
        )
        analyzer = MagicMock()
        analyzer.analyze.side_effect = requests.HTTPError(
            "429 Client Error for url: "
            "https://api.unpaywall.org/v2/10.1/?email=reader@example.com",
            response=response,
        )
        manager = self._manager(analyzer)
        failures: list[Any] = []
        signalled = threading.Event()

        def record(doc_id: str, failure: Any) -> None:
            """Keep the failure and wake the test.

            Args:
                doc_id: The document analysed.
                failure: What the manager emitted.
            """
            failures.append(failure)
            signalled.set()

        manager.analysis_failed.connect(
            record, Qt.ConnectionType.DirectConnection
        )
        try:
            manager.analyze_document("doc-1", pmid="12345678")
            assert signalled.wait(10.0), "the analysis never failed"
        finally:
            manager.stop()

        assert failures[0].cause is EvaluationErrorCode.API_RATE_LIMIT
        assert "reader@example.com" not in transparency_failure_text(failures[0])


class TestTheBadgeShowsWhatWasNotAssessed:
    """A grey "not assessed" badge, with the reason, is not a missing badge."""

    def test_an_unassessed_badge_says_so_and_carries_the_reason(
        self, qapp: Any
    ) -> None:
        """The reader can tell a failed analysis from one still running."""
        from bmlibrarian_lite.gui.transparency_badge import (
            UNASSESSED_LABEL,
            TransparencyBadge,
        )
        from bmlibrarian_lite.transparency import TransparencyUnassessed

        reason = transparency_failure_text(
            TransparencyAnalysisFailure.failed(
                DOC, EvaluationErrorCode.API_RATE_LIMIT
            )
        )
        badge = TransparencyBadge(TransparencyUnassessed(reason=reason))

        assert badge.label.text() == UNASSESSED_LABEL
        assert EvaluationErrorCode.API_RATE_LIMIT.description in badge.toolTip()

    def test_a_result_still_shows_its_risk(self, qapp: Any) -> None:
        """The control: an assessment that ran still reads as a finding."""
        from bmlibrarian_lite.gui.transparency_badge import (
            RISK_LABELS,
            TransparencyBadge,
        )
        from bmlibrarian_lite.transparency import TransparencyResult, TransparencyRisk

        badge = TransparencyBadge(
            TransparencyResult(
                document_id=DOC,
                transparency_score=20,
                risk_level=TransparencyRisk.HIGH,
            )
        )

        assert badge.label.text() == RISK_LABELS[TransparencyRisk.HIGH]


class TestTheFailureReachesTheCard:
    """From the manager's signal to the document the reader is looking at."""

    @staticmethod
    def _document() -> Any:
        """Build a document to hang a card on.

        Returns:
            A document with the identifiers a card shows.
        """
        from bmlibrarian_lite.data_models import DocumentSource, LiteDocument

        return LiteDocument(
            id=DOC,
            title="A study",
            abstract="An abstract.",
            authors=["Author A"],
            year=2024,
            source=DocumentSource.PUBMED,
        )

    def test_the_card_draws_an_unassessed_badge(self, qapp: Any) -> None:
        """The card has no result, and says so rather than showing nothing."""
        from bmlibrarian_lite.gui.document_card import DocumentCard
        from bmlibrarian_lite.transparency import TransparencyUnassessed

        card = DocumentCard(document=self._document())
        card.set_transparency_outcome(TransparencyUnassessed(reason="Nothing read."))

        assert card.get_transparency_result() is None
        assert "Nothing read." in card._transparency_badge.toolTip()

    def test_the_literature_tab_forwards_the_unassessed_outcome(
        self, qapp: Any
    ) -> None:
        """The tab keeps it too, so a card added later still shows it."""
        from bmlibrarian_lite.gui.audit_literature_tab import AuditLiteratureTab
        from bmlibrarian_lite.transparency import TransparencyUnassessed

        tab = AuditLiteratureTab()
        tab._add_document_card(self._document())
        tab.update_transparency(DOC, TransparencyUnassessed(reason="Nothing read."))

        card = tab._cards_by_doc_id[DOC]
        assert "Nothing read." in card._transparency_badge.toolTip()

    def test_the_audit_tab_turns_a_failure_into_its_sentence(
        self, qapp: Any
    ) -> None:
        """The value becomes words at the surface that shows them, and there only."""
        from bmlibrarian_lite.gui.audit_trail_tab import AuditTrailTab

        tab = AuditTrailTab(config=MagicMock(), storage=MagicMock())
        tab.literature_tab._add_document_card(self._document())
        tab.on_transparency_outcome(
            DOC,
            TransparencyAnalysisFailure.failed(
                DOC, EvaluationErrorCode.API_CONNECTION_ERROR
            ),
        )

        card = tab.literature_tab._cards_by_doc_id[DOC]
        assert NOT_A_FINDING in card._transparency_badge.toolTip()


class TestTheWiringExists:
    """A signal nothing connects is the defect this slice is about."""

    def test_the_review_tab_re_emits_a_failed_analysis(self, qapp: Any) -> None:
        """The manager's failure leaves the tab the audit trail listens to."""
        from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

        outcomes: list[Any] = []
        tab = SystematicReviewTab(config=MagicMock(), storage=MagicMock())
        tab.transparency_outcome_ready.connect(
            lambda doc_id, outcome: outcomes.append((doc_id, outcome))
        )

        tab._transparency_manager.analysis_failed.emit(
            DOC, TransparencyAnalysisFailure.no_identifier(DOC)
        )

        assert outcomes and outcomes[0][0] == DOC
        assert isinstance(outcomes[0][1], TransparencyAnalysisFailure)

    def test_the_window_connects_the_outcome_to_the_audit_trail(self) -> None:
        """The connection #249 and #361 found missing, asserted where it is made."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.app import LiteMainWindow

        window = MagicMock()
        LiteMainWindow._connect_signals(window)

        window.systematic_review_tab.transparency_outcome_ready.connect.assert_called_once_with(
            window.audit_trail_tab.on_transparency_outcome
        )

    def test_building_the_window_reaches_the_wiring(self) -> None:
        """...and something actually calls it.

        The test above asserts what ``_connect_signals`` does. Extracting it
        created a second place for the same defect: deleting the call from
        ``_setup_ui`` left every one of the window's connections dead with
        the whole suite green, which is #249 one level up. Asserting the
        source rather than building the window keeps this free of Qt and of
        a display -- the point is only that the call is still there.
        """
        pytest.importorskip("PySide6")
        import inspect

        from bmlibrarian_lite.gui.app import LiteMainWindow

        setup = inspect.getsource(LiteMainWindow._setup_ui)
        assert "self._connect_signals()" in setup


class TestAdviceNamesSomethingTheReaderCanDo:
    """#335, at the three edges the classification fix did not reach.

    Advice the reader cannot act on reads exactly as confidently as advice
    they can, so a wrong remedy is not a smaller harm than none.
    """

    @staticmethod
    def _http(status: int, url: str) -> Any:
        """Build a failed request carrying a status and a URL.

        Args:
            status: What the source answered.
            url: Where the request went.

        Returns:
            The exception a source failure arrives as.
        """
        import requests

        response = requests.Response()
        response.status_code = status
        response.url = url
        return requests.HTTPError(response=response)

    def test_a_bad_request_to_an_unkeyed_source_is_not_a_refused_key(
        self,
    ) -> None:
        """A malformed DOI to CrossRef must not name an NCBI API key."""
        from bmlibrarian_lite.data_models import EvaluationErrorCode
        from bmlibrarian_lite.utils import classify_request_exception

        cause = classify_request_exception(
            self._http(400, "https://api.crossref.org/works/nonsense")
        )

        assert cause is not EvaluationErrorCode.API_AUTH_ERROR
        assert "API key" not in source_failure_advice(cause)

    def test_a_bad_request_to_ncbi_still_is(self) -> None:
        """The control: PubMed answers 400 for a key it will not take (#196)."""
        from bmlibrarian_lite.data_models import EvaluationErrorCode
        from bmlibrarian_lite.utils import classify_request_exception

        cause = classify_request_exception(
            self._http(400, "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/x")
        )

        assert cause is EvaluationErrorCode.API_AUTH_ERROR

    def test_a_source_having_trouble_is_not_the_readers_network(self) -> None:
        """A 503 is a throttle or an outage; neither is a cable to check."""
        from bmlibrarian_lite.data_models import EvaluationErrorCode
        from bmlibrarian_lite.utils import classify_request_exception

        cause = classify_request_exception(
            self._http(503, "https://www.ebi.ac.uk/europepmc/webservices/rest/x")
        )

        assert cause is EvaluationErrorCode.API_SERVER_ERROR
        assert "internet connection" not in source_failure_advice(cause)

    def test_a_refused_connection_still_names_the_connection(self) -> None:
        """The control: the one case where the advice is right."""
        import requests

        from bmlibrarian_lite.utils import classify_request_exception

        advice = source_failure_advice(
            classify_request_exception(requests.ConnectionError())
        )

        assert "internet connection" in advice

    def test_an_unreadable_answer_is_not_an_unreachable_source(self) -> None:
        """Falling back to the OSError blanket sent this reader to their cable."""
        import requests

        from bmlibrarian_lite.data_models import EvaluationErrorCode
        from bmlibrarian_lite.utils import classify_request_exception

        cause = classify_request_exception(
            requests.exceptions.JSONDecodeError("bad", "{", 0)
        )

        assert cause is EvaluationErrorCode.JSON_PARSE_ERROR
        assert "internet connection" not in source_failure_advice(cause)

    def test_our_own_defect_is_not_reported_as_the_sources_fault(self) -> None:
        """A shape error used to arrive as "the source's answer could not be read"."""
        from bmlibrarian_lite.data_models import EvaluationErrorCode
        from bmlibrarian_lite.utils import classify_analysis_exception

        cause = classify_analysis_exception(
            AttributeError("'NoneType' object has no attribute 'json'")
        )

        assert cause is EvaluationErrorCode.INTERNAL_ERROR
        advice = source_failure_advice(cause)
        assert "defect in BMLibrarian" in advice
        assert "try again later" not in advice.lower()

    def test_a_wrapped_throttle_is_still_a_throttle(self) -> None:
        """Spent retries must not re-enter the blanket the fix escaped."""
        from bmlibrarian_lite.data_models import EvaluationErrorCode
        from bmlibrarian_lite.exceptions import RetryExhaustedError
        from bmlibrarian_lite.utils import classify_analysis_exception

        wrapped = RetryExhaustedError("gave up")
        wrapped.last_error = self._http(
            429, "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/x"
        )

        assert (
            classify_analysis_exception(wrapped)
            is EvaluationErrorCode.API_RATE_LIMIT
        )


class TestTheValuesRefuseToSayNothing:
    """The guards that keep a caveat from being empty or nameless."""

    def test_an_unassessed_outcome_must_say_why(self) -> None:
        """A badge that says "Not assessed" and cannot say why is the defect on."""
        from bmlibrarian_lite.transparency import TransparencyUnassessed

        with pytest.raises(ValueError):
            TransparencyUnassessed(reason="   ")

    def test_a_failure_must_name_its_document(self) -> None:
        """A failure nobody can attach to a study reaches no badge."""
        from bmlibrarian_lite.data_models import (
            EvaluationErrorCode,
            TransparencyAnalysisFailure,
        )

        with pytest.raises(ValueError):
            TransparencyAnalysisFailure.failed(
                "", EvaluationErrorCode.API_TIMEOUT
            )

    def test_a_failures_kind_must_be_one_of_the_two(self) -> None:
        """The union is only as good as what may be put in it."""
        from bmlibrarian_lite.data_models import (
            EvaluationErrorCode,
            TransparencyAnalysisFailure,
        )

        with pytest.raises(ValueError):
            TransparencyAnalysisFailure(
                document_id=DOC,
                kind="analysis_failed",
                cause=EvaluationErrorCode.API_TIMEOUT,
            )


class TestNothingLeavesTheDocumentWithoutAnOutcome:
    """Every way out of the worker must reach one of the two signals.

    The pending entry is popped before the result is read, so anything that
    escapes the done-callback is swallowed by ``concurrent.futures`` and
    *neither* signal fires. The card then keeps no badge -- which this change
    has just taught the reader to read as "still running" (#333, #361).
    """

    @staticmethod
    def _manager() -> Any:
        """Build a manager with a stand-in analyzer.

        Returns:
            The manager.
        """
        pytest.importorskip("PySide6")
        from unittest.mock import patch

        from bmlibrarian_lite.transparency import (
            TransparencyManager,
            TransparencySettings,
        )

        config = MagicMock()
        config.transparency = TransparencySettings()
        with patch(
            "bmlibrarian_lite.transparency.transparency_manager."
            "StudyTransparencyAnalyzer"
        ):
            return TransparencyManager(
                storage=MagicMock(), config=config, email="test@example.com"
            )

    def test_a_base_exception_still_reaches_the_reader(self) -> None:
        """``except Exception`` let this one out in silence."""
        from concurrent.futures import Future

        manager = self._manager()
        failures: list[Any] = []
        manager.analysis_failed.connect(
            lambda doc_id, failure: failures.append(failure)
        )
        future: Future = Future()
        future.set_running_or_notify_cancel()
        future.set_exception(BaseException("out of a thread, in silence"))

        manager._on_analysis_complete(DOC, future)

        assert failures, "the document was left with no outcome at all"
        assert failures[0].document_id == DOC

    def test_an_ordinary_failure_still_reaches_it(self) -> None:
        """The control."""
        from concurrent.futures import Future

        manager = self._manager()
        failures: list[Any] = []
        manager.analysis_failed.connect(
            lambda doc_id, failure: failures.append(failure)
        )
        future: Future = Future()
        future.set_running_or_notify_cancel()
        future.set_exception(TimeoutError("slow"))

        manager._on_analysis_complete(DOC, future)

        assert failures and failures[0].cause is EvaluationErrorCode.API_TIMEOUT

    def test_a_success_still_reaches_it(self) -> None:
        """The other control: the happy path was not pinned either."""
        from concurrent.futures import Future

        manager = self._manager()
        results: list[Any] = []
        manager.analysis_complete.connect(
            lambda doc_id, result: results.append(result)
        )
        future: Future = Future()
        future.set_running_or_notify_cancel()
        future.set_result("a result")

        manager._on_analysis_complete(DOC, future)

        assert results == ["a result"]


class TestTheTabRelaysBothOutcomes:
    """The signal the window connects carries findings as well as failures."""

    def test_a_finding_is_relayed(self) -> None:
        """Silencing this emit would blank every successful badge."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab
        from bmlibrarian_lite.transparency import (
            TransparencyResult,
            TransparencyRisk,
        )

        outcomes: list[Any] = []
        tab = SystematicReviewTab(config=MagicMock(), storage=MagicMock())
        tab.transparency_outcome_ready.connect(
            lambda doc_id, outcome: outcomes.append((doc_id, outcome))
        )
        result = TransparencyResult(
            document_id=DOC,
            transparency_score=80,
            risk_level=TransparencyRisk.LOW,
        )

        tab._transparency_manager.analysis_complete.emit(DOC, result)

        assert outcomes and outcomes[0] == (DOC, result)
