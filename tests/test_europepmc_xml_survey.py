# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
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

"""Tests for the Europe PMC ``fullTextXML`` availability survey (#432).

The survey decided which articles discovery stops asking for XML, so what is
pinned here is what would make it lie: a row read under the wrong accession,
a transport error counted as an answer, a rule scored on the wrong cell, or a
shipped rule that is only a copy of the code.
"""

import argparse
import importlib.util
import random
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest
import requests

from bmlibrarian_lite.constants import POLITE_RATE_CEILINGS
from bmlibrarian_lite.europepmc import offers_fulltext_xml
from bmlibrarian_lite.rate_limit import HostPolicy, RateLimiter

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "europepmc_xml_survey.py"
COMMITTED_SAMPLES = sorted((REPO_ROOT / "doc/developer/europepmc_xml_survey").glob("*.jsonl"))


def _load_script() -> ModuleType:
    """Load europepmc_xml_survey.py as a module (scripts/ is not a package).

    Returns:
        The loaded module.
    """
    spec = importlib.util.spec_from_file_location("europepmc_xml_survey", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["europepmc_xml_survey"] = module
    spec.loader.exec_module(module)
    return module


survey = _load_script()


def _row(status: int | None, has_body: bool = False, **fields: Any) -> dict[str, Any]:
    """A sample row with a fetch answer and any record fields.

    Args:
        status: What fullTextXML answered, or None for no answer.
        has_body: Whether a 200's XML had a body.
        **fields: Record fields to set.

    Returns:
        The row.
    """
    return {"stratum": "s", "status": status, "hasBody": has_body, **fields}


def _unpaced() -> RateLimiter:
    """A limiter that never waits, so tests do not sleep.

    Returns:
        The limiter.
    """
    return RateLimiter(HostPolicy(1.0), sleep=lambda _seconds: None)


class TestFulltextAccession:
    """The survey asks by what discovery would ask by."""

    def test_the_pmc_id_first(self) -> None:
        """A PMC ID wins, even on a preprint record."""
        result = {"pmcid": "PMC1", "source": "PPR", "id": "PPR2"}
        assert survey.fulltext_accession(result) == "PMC1"

    def test_a_preprint_by_its_record_id(self) -> None:
        """A preprint without a PMC ID is asked by its PPR ID."""
        assert survey.fulltext_accession({"source": "PPR", "id": "PPR2"}) == "PPR2"

    @pytest.mark.parametrize(
        "result",
        [
            {"source": "MED", "id": "31996627"},
            {"pmcid": "", "source": "MED", "id": "1"},
            {"pmcid": 7, "source": "MED"},
            {"source": "PPR", "id": None},
        ],
    )
    def test_nothing_to_send(self, result: dict[str, Any]) -> None:
        """A MED record ID is a PMID; a malformed ID is not sent."""
        assert survey.fulltext_accession(result) is None


class TestRecordFeatures:
    """What a record says is kept whole, and a missing flag is visible."""

    def test_a_missing_flag_is_a_question_mark(self) -> None:
        """Not read as N: a missing flag is not a stated no."""
        features = survey.record_features({"pmcid": "PMC1", "inPMC": "Y"})

        assert features["inPMC"] == "Y"
        assert features["isOpenAccess"] == "?"
        assert features["accession"] == "PMC1"

    @pytest.mark.parametrize(
        ("url_list", "codes"),
        [
            (
                {"fullTextUrl": [
                    {"availabilityCode": "S"},
                    {"availabilityCode": "OA"},
                    {"availabilityCode": "OA"},
                ]},
                ["OA", "S"],
            ),
            ({"fullTextUrl": [{"availabilityCode": 3}, "junk", {}]}, []),
            ({"fullTextUrl": "junk"}, []),
            ("junk", []),
            (None, []),
        ],
    )
    def test_availability_codes_are_distinct_and_tolerant(
        self, url_list: object, codes: list[str]
    ) -> None:
        """Untrusted input: a malformed URL list yields no codes, not a crash."""
        result: dict[str, Any] = {} if url_list is None else {"fullTextUrlList": url_list}
        assert survey.availability_codes(result) == codes


class TestOutcome:
    """Each fetch answer is named as what it was."""

    @pytest.mark.parametrize(
        ("row", "name"),
        [
            (_row(200, has_body=True), "served"),
            (_row(200, has_body=False), "bodyless"),
            (_row(500), "http-500"),
            (_row(404), "http-404"),
            (_row(None), "no-answer"),
        ],
    )
    def test_names(self, row: dict[str, Any], name: str) -> None:
        """A transport error is no answer, not a status."""
        assert survey.outcome(row) == name


class TestScoring:
    """A rule is scored on the cell its decision and the answer put it in."""

    def test_each_cell_counts_its_own_rows(self) -> None:
        """Ask/skip against served/not, one row per cell plus a duplicate."""
        rows = [
            _row(200, isOpenAccess="Y"),
            _row(200, isOpenAccess="Y"),
            _row(500, isOpenAccess="Y"),
            _row(200, isOpenAccess="N"),
            _row(500, isOpenAccess="N"),
        ]

        score = survey.score_rule(rows, lambda r: r["isOpenAccess"] == "Y")

        assert score == survey.RuleScore(ask_hit=2, ask_miss=1, skip_hit=1, skip_miss=1)

    def test_a_bodyless_200_is_served(self) -> None:
        """The fetch answered; whether it holds a body is the parser's call."""
        assert survey.served(_row(200, has_body=False))
        assert not survey.served(_row(None))

    @pytest.mark.parametrize("status", [None, 429, 502, 503, 504, 408, "500", True])
    def test_no_answer_falls_in_no_cell(self, status: object) -> None:
        """A failed probe says nothing, so it cannot credit a rule's skip."""
        rows = [_row(status, isOpenAccess="N"), _row(500, isOpenAccess="N")]  # type: ignore[arg-type]

        score = survey.score_rule(rows, lambda r: r["isOpenAccess"] == "Y")

        assert score == survey.RuleScore(
            ask_hit=0, ask_miss=0, skip_hit=0, skip_miss=1, unanswered=1
        )

    @pytest.mark.parametrize("status", [200, 404, 500])
    def test_the_answers(self, status: int) -> None:
        """A 200, Europe PMC's 404, and the steady 500 being measured."""
        assert survey.answered(_row(status))

    def test_served_by_value_leaves_out_no_answer(self) -> None:
        """An unanswered row does not dilute a value's served share."""
        rows = [_row(200, license="cc by"), _row(None, license="cc by"), _row(503, license="cc by")]

        assert survey.served_by_value(rows, survey.FIELDS["license"]) == {"cc by": (1, 1)}

    def test_the_report_warns_of_no_answer(self) -> None:
        """Left out silently, a throttled re-run would look like a clean one."""
        rows = [{**_row(None), "availabilityCodes": []}, {**_row(500), "availabilityCodes": []}]

        assert "1 got no answer" in survey.analyse(rows)

    def test_served_by_value_splits_and_sorts(self) -> None:
        """Every value keeps its served and total counts."""
        rows = [_row(200, license="cc by"), _row(500, license="cc by"), _row(500)]

        split = survey.served_by_value(rows, survey.FIELDS["license"])

        assert split == {"None": (0, 1), "cc by": (1, 2)}

    def test_the_shipped_rule_is_the_code(self) -> None:
        """Measured as shipped, so the survey cannot drift from discovery."""
        assert survey.RULES["shipped: offers_fulltext_xml"] is offers_fulltext_xml

    def test_rows_are_read_as_search_results(self) -> None:
        """The shipped rule reads a row's flags under their search names."""
        closed = survey.record_features({"pmcid": "PMC1", "inPMC": "Y", "isOpenAccess": "N"})
        open_ = survey.record_features({"pmcid": "PMC1", "inPMC": "Y", "isOpenAccess": "Y"})

        assert offers_fulltext_xml(closed) is False
        assert offers_fulltext_xml(open_) is True

    def test_the_report_names_every_stratum_and_rule(self) -> None:
        """A stratum or rule missing from the report is a silent gap."""
        rows = [
            {**_row(200, has_body=True), "stratum": "pmc-oa", "availabilityCodes": ["OA"]},
            {**_row(500), "stratum": "preprint", "availabilityCodes": []},
        ]

        report = survey.analyse(rows)

        assert "pmc-oa" in report and "preprint" in report
        assert "no answer" not in report
        for name in survey.RULES:
            assert name in report


class TestTheCommittedEvidence:
    """The rows behind the figures in the docs, scored by the code as shipped.

    A later change to ``offers_fulltext_xml`` shows here what it costs in
    text lost (``skip_hit``) and requests spent (``ask_miss``), and the
    figures quoted in the docs cannot drift from the rows.
    """

    @pytest.fixture(scope="class")
    def rows(self) -> list[dict[str, Any]]:
        """Every committed row.

        Returns:
            The rows of the three committed samples.
        """
        assert len(COMMITTED_SAMPLES) == 3
        return survey.load_rows(COMMITTED_SAMPLES)

    def test_every_row_was_answered(self, rows: list[dict[str, Any]]) -> None:
        """761 records, each with Europe PMC's own answer."""
        assert len(rows) == 761
        assert all(survey.answered(row) for row in rows)

    def test_the_shipped_rule(self, rows: list[dict[str, Any]]) -> None:
        """Two texts lost (PMC9391270, PPR1051747); 326 futile requests saved."""
        assert survey.score_rule(rows, offers_fulltext_xml) == survey.RuleScore(
            ask_hit=239, ask_miss=194, skip_hit=2, skip_miss=326
        )
        lost = sorted(
            str(row["accession"])
            for row in rows
            if survey.served(row) and not offers_fulltext_xml(row)
        )
        assert lost == ["PMC9391270", "PPR1051747"]

    def test_the_rule_before_it(self, rows: list[dict[str, Any]]) -> None:
        """Held alone asked 520 times for text that was not served."""
        before = survey.RULES["before #432: inEPMC or inPMC"]
        assert survey.score_rule(rows, before) == survey.RuleScore(
            ask_hit=240, ask_miss=520, skip_hit=1, skip_miss=0
        )


class TestProbe:
    """One request, no retries, and a transport error is not a status."""

    @staticmethod
    def _requests_answering(answer: object) -> SimpleNamespace:
        """A stand-in ``requests`` module whose ``get`` returns or raises ``answer``.

        Args:
            answer: A response, or an exception to raise.

        Returns:
            The stand-in.
        """
        get = MagicMock()
        if isinstance(answer, BaseException):
            get.side_effect = answer
        else:
            get.return_value = answer
        return SimpleNamespace(get=get, RequestException=requests.RequestException)

    def _probe(self, monkeypatch: pytest.MonkeyPatch, answer: object) -> dict[str, Any]:
        """Probe once against ``answer``.

        Args:
            monkeypatch: The fixture.
            answer: What the request meets.

        Returns:
            The probe's description.
        """
        fake = self._requests_answering(answer)
        monkeypatch.setattr(survey, "_requests", lambda: fake)
        result: dict[str, Any] = survey.probe("PMC1", _unpaced())
        assert fake.get.call_count == 1
        assert fake.get.call_args.kwargs["headers"] == survey._HEADERS
        return result

    def test_a_body_is_seen(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """A 200 whose XML has a body."""
        response = SimpleNamespace(status_code=200, content=b"<article><body><p>x</p></body>")
        assert self._probe(monkeypatch, response)["hasBody"] is True

    def test_a_bodyless_200(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """A 200 without a body is not counted as a body."""
        response = SimpleNamespace(status_code=200, content=b"<article><front/></article>")
        assert self._probe(monkeypatch, response)["hasBody"] is False

    def test_a_500_is_its_status(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Even a 500 whose error page mentions a body."""
        response = SimpleNamespace(status_code=500, content=b"<body>error</body>")
        result = self._probe(monkeypatch, response)

        assert result["status"] == 500
        assert result["hasBody"] is False

    def test_a_timeout_is_no_answer(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Not a status: nothing was said about the article."""
        result = self._probe(monkeypatch, requests.exceptions.ReadTimeout("slow"))

        assert result["status"] is None
        assert result["error"] == "ReadTimeout"
        assert not survey.answered(result)

    @pytest.mark.parametrize("status", [429, 503])
    def test_a_throttle_slows_every_later_request(
        self, monkeypatch: pytest.MonkeyPatch, status: int
    ) -> None:
        """Not retried, but yielded to, as the app would."""
        response = SimpleNamespace(status_code=status, content=b"", headers={"Retry-After": "7"})
        fake = self._requests_answering(response)
        monkeypatch.setattr(survey, "_requests", lambda: fake)
        limiter = _unpaced()
        before = limiter.interval

        survey.probe("PMC1", limiter)

        assert limiter.interval > before

    def test_control_a_500_is_not_a_throttle(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """The steady refusal being measured does not slow the survey."""
        response = SimpleNamespace(status_code=500, content=b"", headers={})
        fake = self._requests_answering(response)
        monkeypatch.setattr(survey, "_requests", lambda: fake)
        limiter = _unpaced()
        before = limiter.interval

        survey.probe("PMC1", limiter)

        assert limiter.interval == before


class TestSampling:
    """Days are drawn reproducibly from the asked range."""

    def test_days_are_distinct_in_range_and_seeded(self) -> None:
        """The same seed draws the same days; none falls outside the years."""
        first = survey._random_days((2019, 2020), 50, random.Random(1))
        again = survey._random_days((2019, 2020), 50, random.Random(1))

        assert first == again
        assert len(set(first)) == 50
        assert all(2019 <= day.year <= 2020 for day in first)

    def test_a_short_range_is_not_overdrawn(self) -> None:
        """Asking for more days than exist returns every day once."""
        days = survey._random_days((2020, 2020), 1000, random.Random(1))
        assert len(days) == len(set(days)) == 366

    @pytest.mark.parametrize(("text", "years"), [("2019-2020", (2019, 2020)), ("2021", (2021, 2021))])
    def test_year_ranges(self, text: str, years: tuple[int, int]) -> None:
        """One year or two."""
        assert survey._year_range(text) == years

    @pytest.mark.parametrize("text", ["2020-2019", "twenty", "2019-2020-2021", ""])
    def test_bad_year_ranges_are_refused(self, text: str) -> None:
        """Reversed, non-numeric or three-part ranges are errors, not samples."""
        with pytest.raises(argparse.ArgumentTypeError):
            survey._year_range(text)


class TestPoliteness:
    """The survey asks Europe PMC no faster than the app does, and says who it is."""

    def test_requests_wait_on_the_apps_europe_pmc_limiter(self) -> None:
        """The shared limiter for the host, at the host's ceiling."""
        limiter = survey._limiter()

        assert limiter.host == "www.ebi.ac.uk"
        assert limiter.interval >= 1.0 / POLITE_RATE_CEILINGS["www.ebi.ac.uk"]

    def test_the_search_pages_are_read_tolerantly(self) -> None:
        """An unreadable answer or entry yields no record rather than a crash."""
        assert survey._search_results({"version": "6.9"}) == []
        assert survey._search_results([]) == []
        assert survey._search_results({"resultList": {"result": ["x", {"id": "1"}]}}) == [
            {"id": "1"}
        ]


class TestTheOutputIsWrittenWhole:
    """A run that stops half way leaves the sample it would replace."""

    def test_a_failed_run_keeps_the_existing_sample(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        """The committed rows survive a search that fails mid-run."""
        out = tmp_path / "sample.jsonl"
        out.write_text('{"kept": true}\n', encoding="utf-8")

        def failing_sample(*_args: object) -> list[dict[str, Any]]:
            """A search that fails, as a throttled one would.

            Args:
                *_args: ``sample_stratum``'s arguments, unused.

            Raises:
                requests.HTTPError: Always.
            """
            raise requests.HTTPError("503 Service Unavailable")

        monkeypatch.setattr(survey, "sample_stratum", failing_sample)
        monkeypatch.setattr(survey, "_limiter", _unpaced)
        with pytest.raises(requests.HTTPError):
            survey.fetch_sample((2020, 2020), 1, 1, out, ["pmc-oa"])

        assert out.read_text(encoding="utf-8") == '{"kept": true}\n'

    def test_a_finished_run_replaces_it(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        """Once every stratum is written, the new sample takes its place."""
        out = tmp_path / "sample.jsonl"
        out.write_text('{"old": true}\n', encoding="utf-8")
        monkeypatch.setattr(
            survey, "sample_stratum", lambda *_args: [{"pmcid": "PMC1", "isOpenAccess": "Y"}]
        )
        monkeypatch.setattr(survey, "probe", lambda *_args: {"status": 200, "hasBody": True})
        monkeypatch.setattr(survey, "_limiter", _unpaced)

        survey.fetch_sample((2020, 2020), 1, 1, out, ["pmc-oa"])

        rows = survey.load_rows([out])
        assert [row["accession"] for row in rows] == ["PMC1"]
        assert not list(tmp_path.glob("*.partial"))
