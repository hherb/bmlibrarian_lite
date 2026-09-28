# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A source that answered was asked: it "did not serve it" (#435).

Since #429, full-text discovery records Europe PMC's 404 for an article its
search lists as held in PMC as ``HTTP 404 Not Found``, not as an absence,
because ``fullTextXML`` serves open-access text only (#432). Every sentence
built from the lookup record then said the source "could not be asked":

    … Europe PMC (HTTP 404 Not Found) could not be asked, so …

Europe PMC was asked, and answered. The maintainer's decision: an HTTP
status reads "did not serve it", except a throttle (429, 503), which says
only "not now" and keeps "could not be asked" with every other kind.

The sentences are asserted whole, never by a substring another caveat
shares. No test here touches the network.
"""

import pytest

from bmlibrarian_lite.analysis_failures import (
    no_pdf_sources_message,
    paywall_message,
    unestablished_access_clause,
    unsettled_lookups_clause,
)
from bmlibrarian_lite.constants import (
    POLITE_THROTTLE_STATUSES,
    SERVICE_DOI_RESOLVER,
    SERVICE_EUROPE_PMC,
    SERVICE_UNPAYWALL,
)
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)

NOT_FOUND = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=404)
THROTTLED = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429)
TIMED_OUT = RequestFailure(RequestFailureKind.TIMEOUT)

#: What every unsettled-access sentence ends with (``_ACCESS_NOT_ESTABLISHED``).
ACCESS_OPEN = (
    "so a freely available copy may exist. Whether this document is open "
    "access was not established."
)


def _failed(service: str, failure: RequestFailure) -> LookupRecord:
    """A record of one failed lookup.

    Args:
        service: The source, as the reader knows it.
        failure: What the lookup got.

    Returns:
        The record.
    """
    return LookupRecord(failures=(SourceLookupFailure(service, failure),))


class TestAnHttpStatusIsAnAnswer:
    """The predicate every platform's verb is chosen by."""

    @pytest.mark.parametrize("status", [400, 401, 403, 404, 410, 500, 502, 504])
    def test_a_status_that_is_not_a_throttle_is_an_answer(
        self, status: int
    ) -> None:
        """The source took the question and said no."""
        failure = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=status)
        assert failure.is_answer

    @pytest.mark.parametrize("status", POLITE_THROTTLE_STATUSES)
    def test_a_throttle_is_not_an_answer(self, status: int) -> None:
        """A throttle says "not now": the question was never put."""
        failure = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=status)
        assert not failure.is_answer

    def test_the_throttles_are_429_and_503(self) -> None:
        """Pinned: the Swift and Android ports name the same two statuses."""
        assert set(POLITE_THROTTLE_STATUSES) == {429, 503}

    def test_an_http_error_of_unknown_status_is_an_answer(self) -> None:
        """A status was answered even when this build could not keep it."""
        assert RequestFailure(RequestFailureKind.HTTP_STATUS).is_answer

    @pytest.mark.parametrize(
        "kind",
        [kind for kind in RequestFailureKind if kind is not RequestFailureKind.HTTP_STATUS],
    )
    def test_no_other_kind_is_an_answer(self, kind: RequestFailureKind) -> None:
        """Only ``HTTP_STATUS`` changes verb: the decision, as made.

        A refused redirect is our own refusal, and a blank or garbled 200 is
        not an answer about the article either.
        """
        assert not RequestFailure(kind).is_answer


class TestTheClauseChoosesTheVerb:
    """``unsettled_lookups_clause`` names each source with what happened to it."""

    def test_an_answered_404_did_not_serve_it(self) -> None:
        """The sentence #435 was lodged about."""
        assert unsettled_lookups_clause(_failed(SERVICE_EUROPE_PMC, NOT_FOUND)) == (
            "Europe PMC (HTTP 404 Not Found) did not serve it"
        )

    def test_a_throttle_could_not_be_asked(self) -> None:
        """The control: a 429 keeps the verb it had."""
        assert unsettled_lookups_clause(_failed(SERVICE_UNPAYWALL, THROTTLED)) == (
            "Unpaywall (HTTP 429 Too Many Requests) could not be asked"
        )

    def test_a_timeout_could_not_be_asked(self) -> None:
        """The control for a transport failure."""
        assert unsettled_lookups_clause(_failed(SERVICE_EUROPE_PMC, TIMED_OUT)) == (
            "Europe PMC (the request timed out) could not be asked"
        )

    def test_a_skip_could_not_be_asked(self) -> None:
        """A lookup never made was, of all of them, not asked."""
        record = LookupRecord(
            skipped=(
                SourceLookupSkipped(SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED),
            )
        )
        assert unsettled_lookups_clause(record) == (
            "Unpaywall (not configured) could not be asked"
        )

    def test_both_verbs_in_one_record(self) -> None:
        """Each source keeps its own verb; the unasked are named first."""
        record = LookupRecord(
            failures=(
                SourceLookupFailure(SERVICE_EUROPE_PMC, NOT_FOUND),
                SourceLookupFailure(SERVICE_DOI_RESOLVER, TIMED_OUT),
            ),
            skipped=(
                SourceLookupSkipped(SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED),
            ),
        )
        assert unsettled_lookups_clause(record) == (
            "doi.org (the request timed out) and Unpaywall (not configured) "
            "could not be asked, and Europe PMC (HTTP 404 Not Found) did not "
            "serve it"
        )

    def test_a_service_is_named_once_by_its_first_failure(self) -> None:
        """Two attempts against one host are one thing to tell the reader."""
        record = LookupRecord(
            failures=(
                SourceLookupFailure(SERVICE_EUROPE_PMC, NOT_FOUND),
                SourceLookupFailure(SERVICE_EUROPE_PMC, TIMED_OUT),
            ),
        )
        assert unsettled_lookups_clause(record) == (
            "Europe PMC (HTTP 404 Not Found) did not serve it"
        )

    def test_a_service_that_failed_is_not_named_again_by_its_skip(self) -> None:
        """It was reached, so "not configured" would be false of it."""
        record = LookupRecord(
            failures=(SourceLookupFailure(SERVICE_UNPAYWALL, NOT_FOUND),),
            skipped=(
                SourceLookupSkipped(SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED),
            ),
        )
        assert unsettled_lookups_clause(record) == (
            "Unpaywall (HTTP 404 Not Found) did not serve it"
        )

    def test_an_empty_record_names_nothing(self) -> None:
        """Every lookup made and answered is the ordinary case."""
        assert unsettled_lookups_clause(LookupRecord()) == ""


class TestEverySentenceUsesTheVerb:
    """The three reader sentences in ``analysis_failures``, built whole."""

    def test_the_access_clause(self) -> None:
        """What ``with_unestablished_access`` adds to a claim."""
        assert unestablished_access_clause(_failed(SERVICE_EUROPE_PMC, NOT_FOUND)) == (
            f"Europe PMC (HTTP 404 Not Found) did not serve it, {ACCESS_OPEN}"
        )

    def test_the_paywall_message(self) -> None:
        """The claim is withheld, and the source that answered is not "unasked"."""
        message = paywall_message(
            "Paywalled.", _failed(SERVICE_EUROPE_PMC, NOT_FOUND)
        )
        assert message == (
            "A source refused access, but Europe PMC (HTTP 404 Not Found) did "
            f"not serve it, {ACCESS_OPEN}"
        )

    def test_the_no_pdf_sources_message(self) -> None:
        """The one the full-text tab shows."""
        assert no_pdf_sources_message(_failed(SERVICE_EUROPE_PMC, NOT_FOUND)) == (
            "No PDF sources found, but Europe PMC (HTTP 404 Not Found) did not "
            f"serve it, {ACCESS_OPEN}"
        )

    def test_a_throttle_keeps_its_sentence(self) -> None:
        """The control, whole: nothing changes for a 429."""
        assert no_pdf_sources_message(_failed(SERVICE_UNPAYWALL, THROTTLED)) == (
            "No PDF sources found, but Unpaywall (HTTP 429 Too Many Requests) "
            f"could not be asked, {ACCESS_OPEN}"
        )


class TestTheTransparencyCaveatsUseTheVerb:
    """The two sentences the transparency analyser builds from the record."""

    @staticmethod
    def _discover(monkeypatch, result):
        """Run the analyser's discovery with the discoverer answering ``result``.

        Args:
            monkeypatch: pytest's monkeypatch fixture.
            result: What ``discover_fulltext`` returns.

        Returns:
            The report discovery ran against.
        """
        from bmlibrarian_lite import fulltext_discovery
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            StudyTransparencyAnalyzer,
            TransparencyReport,
        )

        monkeypatch.setattr(
            fulltext_discovery.FulltextDiscoverer,
            "discover_fulltext",
            lambda *_a, **_k: result,
        )
        report = TransparencyReport()
        report.doi = "10.1/abc"
        StudyTransparencyAnalyzer(email="test@example.com")._discover_fulltext(report)
        return report

    def test_the_unretrieved_full_text_caveat(self, monkeypatch) -> None:
        """Europe PMC's 404 for a held article is the case #435 was lodged on."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        report = self._discover(
            monkeypatch,
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error="ignored",
                lookups=_failed(SERVICE_EUROPE_PMC, NOT_FOUND),
            ),
        )

        assert report.warnings == [
            "The article's full text was not retrieved, and Europe PMC "
            "(HTTP 404 Not Found) did not serve it, so what this article's own "
            "text states could not be checked. It is recorded as not assessed, "
            "which is not a finding against the study."
        ]

    def test_the_paywall_warning(self, monkeypatch) -> None:
        """The analyser's own copy of the withheld paywall claim."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        report = self._discover(
            monkeypatch,
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error="ignored",
                is_paywall=True,
                paywall_url="https://publisher/x",
                lookups=_failed(SERVICE_EUROPE_PMC, NOT_FOUND),
            ),
        )

        assert report.warnings == [
            "A source refused access, but Europe PMC (HTTP 404 Not Found) did "
            "not serve it, so a freely available copy may exist."
        ]
