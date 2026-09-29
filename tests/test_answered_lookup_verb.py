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
    configuration_nudge,
    no_pdf_sources_message,
    paywall_message,
    unestablished_access_clause,
    unsettled_lookups_clause,
)
from bmlibrarian_lite.config import LiteConfig
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
from bmlibrarian_lite.fulltext_discovery import FulltextResult, FulltextSourceType
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    StudyTransparencyAnalyzer,
    TransparencyReport,
)

NOT_FOUND = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=404)
THROTTLED = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429)
TIMED_OUT = RequestFailure(RequestFailureKind.TIMEOUT)

#: What an unsettled-access sentence ends with when a source went unasked
#: (``_ACCESS_NOT_ESTABLISHED``).
ACCESS_OPEN = (
    "so a freely available copy may exist. Whether this document is open "
    "access was not established."
)

#: What it ends with when every unsettled source answered
#: (``_ANSWERED_ACCESS_NOT_ESTABLISHED``).
ANSWERED_ACCESS_OPEN = "so whether this document is open access was not established."

#: The configuration advice an unconfigured Unpaywall earns.
UNPAYWALL_NUDGE = (
    "Configuring Unpaywall would add an open-access route this search did "
    "not have."
)

SERVICE_UNAVAILABLE = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=503)

#: Europe PMC answered, doi.org was throttled with a 503, Unpaywall is not
#: configured: every group and both throttle statuses' verb in one record.
MIXED = LookupRecord(
    failures=(
        SourceLookupFailure(SERVICE_EUROPE_PMC, NOT_FOUND),
        SourceLookupFailure(SERVICE_DOI_RESOLVER, SERVICE_UNAVAILABLE),
    ),
    skipped=(
        SourceLookupSkipped(SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED),
    ),
)

#: How :data:`MIXED` is named.
MIXED_CLAUSE = (
    "doi.org (HTTP 503 Service Unavailable) and Unpaywall (not configured) "
    "could not be asked, and Europe PMC (HTTP 404 Not Found) did not serve it"
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

    def test_a_service_is_named_once_by_its_first_answer(self) -> None:
        """Two answers from one host are one thing to tell the reader."""
        gone = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=410)
        record = LookupRecord(
            failures=(
                SourceLookupFailure(SERVICE_EUROPE_PMC, NOT_FOUND),
                SourceLookupFailure(SERVICE_EUROPE_PMC, gone),
            ),
        )
        assert unsettled_lookups_clause(record) == (
            "Europe PMC (HTTP 404 Not Found) did not serve it"
        )

    def test_a_later_unasked_lookup_outranks_an_answer(self) -> None:
        """The XML 404, then the PDF render timing out: the PDF went unasked.

        "Did not serve it" would tell the reader the most promising route
        was tried, when it was the one that could not be.
        """
        record = LookupRecord(
            failures=(
                SourceLookupFailure(SERVICE_EUROPE_PMC, NOT_FOUND),
                SourceLookupFailure(SERVICE_EUROPE_PMC, TIMED_OUT),
            ),
        )
        assert unsettled_lookups_clause(record) == (
            "Europe PMC (the request timed out) could not be asked"
        )

    def test_an_answer_does_not_outrank_an_earlier_unasked_lookup(self) -> None:
        """The other order: the throttle still names it, once."""
        record = LookupRecord(
            failures=(
                SourceLookupFailure(SERVICE_EUROPE_PMC, THROTTLED),
                SourceLookupFailure(SERVICE_EUROPE_PMC, NOT_FOUND),
            ),
        )
        assert unsettled_lookups_clause(record) == (
            "Europe PMC (HTTP 429 Too Many Requests) could not be asked"
        )

    def test_a_service_is_named_once_by_its_first_unasked_failure(self) -> None:
        """Two unanswered attempts: the first is described."""
        record = LookupRecord(
            failures=(
                SourceLookupFailure(SERVICE_UNPAYWALL, TIMED_OUT),
                SourceLookupFailure(SERVICE_UNPAYWALL, THROTTLED),
            ),
        )
        assert unsettled_lookups_clause(record) == (
            "Unpaywall (the request timed out) could not be asked"
        )

    def test_an_unasked_failure_is_not_named_again_by_its_skip(self) -> None:
        """It was reached, so "not configured" would be false of it."""
        record = LookupRecord(
            failures=(SourceLookupFailure(SERVICE_UNPAYWALL, TIMED_OUT),),
            skipped=(
                SourceLookupSkipped(SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED),
            ),
        )
        assert unsettled_lookups_clause(record) == (
            "Unpaywall (the request timed out) could not be asked"
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
    """The three reader sentences in ``analysis_failures``, built whole.

    Each for a record of answers alone, of unasked lookups alone, and of
    both: the ending and the conjunction follow the verbs, so each shape
    reads differently.
    """

    def test_the_access_clause_after_an_answer(self) -> None:
        """What ``with_unestablished_access`` adds to a claim.

        A source that declined to serve is no reason to think a free copy
        exists, so the sentence does not say one may.
        """
        assert unestablished_access_clause(_failed(SERVICE_EUROPE_PMC, NOT_FOUND)) == (
            f"Europe PMC (HTTP 404 Not Found) did not serve it, {ANSWERED_ACCESS_OPEN}"
        )

    def test_the_access_clause_after_a_throttle(self) -> None:
        """The control: an unasked source may hold a free copy."""
        assert unestablished_access_clause(_failed(SERVICE_UNPAYWALL, THROTTLED)) == (
            f"Unpaywall (HTTP 429 Too Many Requests) could not be asked, {ACCESS_OPEN}"
        )

    def test_the_access_clause_after_both(self) -> None:
        """An unasked source anywhere in the record earns the free copy."""
        assert unestablished_access_clause(MIXED) == (
            f"{MIXED_CLAUSE}, {ACCESS_OPEN} {UNPAYWALL_NUDGE}"
        )

    def test_the_paywall_message_after_an_answer(self) -> None:
        """No "but": the answer points the same way as the refusal."""
        message = paywall_message(
            "Paywalled.", _failed(SERVICE_EUROPE_PMC, NOT_FOUND)
        )
        assert message == (
            "A source refused access to this document, and Europe PMC (HTTP "
            f"404 Not Found) did not serve it, {ANSWERED_ACCESS_OPEN}"
        )

    def test_the_paywall_message_after_a_throttle(self) -> None:
        """The claim is withheld against the source that went unasked."""
        message = paywall_message("Paywalled.", _failed(SERVICE_UNPAYWALL, THROTTLED))
        assert message == (
            "A source refused access to this document, but Unpaywall (HTTP 429 "
            f"Too Many Requests) could not be asked, {ACCESS_OPEN}"
        )

    def test_the_paywall_message_after_both(self) -> None:
        """"But", because a source went unasked; the advice follows."""
        assert paywall_message("Paywalled.", MIXED) == (
            f"A source refused access to this document, but {MIXED_CLAUSE}, "
            f"{ACCESS_OPEN} {UNPAYWALL_NUDGE}"
        )

    def test_the_no_pdf_sources_message_after_an_answer(self) -> None:
        """The one the full-text tab shows for Europe PMC's 404."""
        assert no_pdf_sources_message(_failed(SERVICE_EUROPE_PMC, NOT_FOUND)) == (
            "No PDF sources found for this document, and Europe PMC (HTTP 404 "
            f"Not Found) did not serve it, {ANSWERED_ACCESS_OPEN}"
        )

    def test_the_no_pdf_sources_message_after_a_throttle(self) -> None:
        """The control, whole: a 429 keeps its verb and its free copy."""
        assert no_pdf_sources_message(_failed(SERVICE_UNPAYWALL, THROTTLED)) == (
            "No PDF sources found for this document, but Unpaywall (HTTP 429 "
            f"Too Many Requests) could not be asked, {ACCESS_OPEN}"
        )

    def test_the_no_pdf_sources_message_after_both(self) -> None:
        """Both verbs, one ending, and the advice."""
        assert no_pdf_sources_message(MIXED) == (
            f"No PDF sources found for this document, but {MIXED_CLAUSE}, "
            f"{ACCESS_OPEN} {UNPAYWALL_NUDGE}"
        )

    @pytest.mark.parametrize("status", [403, 500])
    def test_any_answer_other_than_a_404_reads_the_same(self, status: int) -> None:
        """Not a 404 special case: the predicate, at sentence level."""
        answer = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=status)
        message = no_pdf_sources_message(_failed(SERVICE_EUROPE_PMC, answer))
        assert message == (
            "No PDF sources found for this document, and Europe PMC "
            f"({answer.describe()}) did not serve it, {ANSWERED_ACCESS_OPEN}"
        )


class TestTheTransparencyCaveatsUseTheVerb:
    """The two sentences the transparency analyser builds from the record."""

    @staticmethod
    def _discover(
        monkeypatch: pytest.MonkeyPatch, result: FulltextResult
    ) -> TransparencyReport:
        """Run the analyser's discovery with the discoverer answering ``result``.

        Args:
            monkeypatch: pytest's monkeypatch fixture.
            result: What ``discover_fulltext`` returns.

        Returns:
            The report discovery ran against.
        """
        from bmlibrarian_lite import fulltext_discovery

        monkeypatch.setattr(
            fulltext_discovery.FulltextDiscoverer,
            "discover_fulltext",
            lambda *_a, **_k: result,
        )
        report = TransparencyReport()
        report.doi = "10.1/abc"
        StudyTransparencyAnalyzer(email="test@example.com")._discover_fulltext(report)
        return report

    @staticmethod
    def _unretrieved(
        lookups: LookupRecord, *, paywall: bool = False
    ) -> FulltextResult:
        """A discovery result that found no text, with ``lookups`` recorded.

        Args:
            lookups: What went unsettled.
            paywall: Whether a source refused access.

        Returns:
            The result.
        """
        return FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_ASSESSED,
            error="ignored",
            is_paywall=paywall,
            paywall_url="https://publisher/x" if paywall else None,
            lookups=lookups,
        )

    @pytest.mark.parametrize(
        ("lookups", "named", "nudge"),
        [
            pytest.param(
                _failed(SERVICE_EUROPE_PMC, NOT_FOUND),
                "Europe PMC (HTTP 404 Not Found) did not serve it",
                "",
                id="answered",
            ),
            pytest.param(
                _failed(SERVICE_UNPAYWALL, THROTTLED),
                "Unpaywall (HTTP 429 Too Many Requests) could not be asked",
                "",
                id="throttled",
            ),
            pytest.param(MIXED, MIXED_CLAUSE, f" {UNPAYWALL_NUDGE}", id="both"),
        ],
    )
    def test_the_unretrieved_full_text_caveat(
        self,
        monkeypatch: pytest.MonkeyPatch,
        lookups: LookupRecord,
        named: str,
        nudge: str,
    ) -> None:
        """Europe PMC's 404 for a held article is the case #435 was lodged on.

        A colon introduces the reasons, so a record of both groups does not
        run three "and"s together.
        """
        report = self._discover(monkeypatch, self._unretrieved(lookups))

        assert report.warnings == [
            f"The article's full text was not retrieved: {named}, so what this "
            "article's own text states could not be checked. It is recorded "
            f"as not assessed, which is not a finding against the study.{nudge}"
        ]

    def test_the_paywall_warning_after_an_answer(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The analyser's paywall sentence is ``paywall_message``'s."""
        report = self._discover(
            monkeypatch,
            self._unretrieved(_failed(SERVICE_EUROPE_PMC, NOT_FOUND), paywall=True),
        )

        assert report.warnings == [
            "A source refused access to this document, and Europe PMC (HTTP "
            f"404 Not Found) did not serve it, {ANSWERED_ACCESS_OPEN}"
        ]

    def test_the_paywall_warning_after_both(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The advice stays a warning of its own."""
        report = self._discover(monkeypatch, self._unretrieved(MIXED, paywall=True))

        assert report.warnings == [
            f"A source refused access to this document, but {MIXED_CLAUSE}, "
            f"{ACCESS_OPEN}",
            UNPAYWALL_NUDGE,
        ]


class TestThePlaceholderEmailIsNotConfiguration:
    """Unpaywall is not asked with the application's placeholder address.

    Unpaywall answers ``bmlibrarian@example.com`` with HTTP 422 for every
    article, which would read "Unpaywall (HTTP 422 …) did not serve it" and
    blame the article for our configuration.
    """

    def test_the_placeholder_is_no_email(self) -> None:
        """What the transparency GUI sends when no PubMed email is set."""
        from bmlibrarian_lite.constants import FALLBACK_CONTACT_EMAIL
        from bmlibrarian_lite.pdf_discovery import usable_unpaywall_email

        assert usable_unpaywall_email(FALLBACK_CONTACT_EMAIL) is None
        assert usable_unpaywall_email(f"  {FALLBACK_CONTACT_EMAIL} ") is None

    @pytest.mark.parametrize("email", [None, "", "   "])
    def test_no_email_is_no_email(self, email: str | None) -> None:
        """Blank is as unconfigured as absent."""
        from bmlibrarian_lite.pdf_discovery import usable_unpaywall_email

        assert usable_unpaywall_email(email) is None

    def test_a_real_address_is_used(self) -> None:
        """The control: the user's own address is kept, stripped."""
        from bmlibrarian_lite.pdf_discovery import usable_unpaywall_email

        assert usable_unpaywall_email(" me@uni.edu ") == "me@uni.edu"

    def test_the_placeholder_is_skipped_and_earns_the_advice(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """No request is made, and the reader is told what to configure."""
        from bmlibrarian_lite.constants import FALLBACK_CONTACT_EMAIL
        from bmlibrarian_lite.pdf_discovery import PDFDiscoverer

        discoverer = PDFDiscoverer(
            unpaywall_email=FALLBACK_CONTACT_EMAIL, use_browser_fallback=False
        )

        def refuse(*_args: object, **_kwargs: object) -> None:
            raise AssertionError("Unpaywall was asked with the placeholder")

        monkeypatch.setattr(discoverer, "_discover_unpaywall", refuse)
        monkeypatch.setattr(
            discoverer, "_discover_publisher_specific", lambda _doi: []
        )
        monkeypatch.setattr(
            discoverer, "_discover_doi_direct", lambda _doi: ([], None)
        )

        _sources, record = discoverer._discover_sources(
            doi="10.1/abc", pmid=None, pmcid=None
        )

        assert record.skipped == (
            SourceLookupSkipped(SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED),
        )
        assert configuration_nudge(record) == UNPAYWALL_NUDGE


class TestTheTransparencyAnalysisReadsTheUnpaywallSetting:
    """The setting the advice names is the one the analysis reads."""

    @staticmethod
    def _config(unpaywall: str, pubmed: str) -> LiteConfig:
        """A configuration with the two emails set.

        Args:
            unpaywall: The Unpaywall setting.
            pubmed: The PubMed email.

        Returns:
            The configuration.
        """
        config = LiteConfig()
        config.discovery.unpaywall_email = unpaywall
        config.pubmed.email = pubmed
        return config

    def test_the_unpaywall_setting_wins(self) -> None:
        """Configuring Unpaywall, as the advice says, now reaches it."""
        from bmlibrarian_lite.transparency.assessment import unpaywall_contact_email

        config = self._config("me@uni.edu", "other@uni.edu")
        assert unpaywall_contact_email(config) == "me@uni.edu"

    def test_the_contact_email_is_the_fallback(self) -> None:
        """As before: the PubMed email, else the placeholder."""
        from bmlibrarian_lite.constants import FALLBACK_CONTACT_EMAIL
        from bmlibrarian_lite.transparency.assessment import unpaywall_contact_email

        assert unpaywall_contact_email(self._config("", "me@uni.edu")) == "me@uni.edu"
        assert unpaywall_contact_email(self._config("", "")) == FALLBACK_CONTACT_EMAIL

    def test_the_background_analyser_is_given_it(self) -> None:
        """Not the contact email, which was all it read before."""
        from bmlibrarian_lite.transparency.assessment import create_background_analyzer

        analyzer = create_background_analyzer(
            "contact@uni.edu", unpaywall_email="me@uni.edu"
        )
        assert analyzer._unpaywall_email == "me@uni.edu"
        assert create_background_analyzer("contact@uni.edu")._unpaywall_email == (
            "contact@uni.edu"
        )
