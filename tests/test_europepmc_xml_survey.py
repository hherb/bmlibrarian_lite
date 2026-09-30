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
import time
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest
import requests

from bmlibrarian_lite.europepmc import offers_fulltext_xml

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "europepmc_xml_survey.py"


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
        for name in survey.RULES:
            assert name in report


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
        result: dict[str, Any] = survey.probe("PMC1", survey._Pacer(0.0))
        assert fake.get.call_count == 1
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


class TestPacer:
    """Requests start no faster than the courtesy interval, across threads."""

    def test_starts_are_spaced(self) -> None:
        """Three waits take at least two intervals."""
        pacer = survey._Pacer(0.02)
        started = time.monotonic()
        for _ in range(3):
            pacer.wait()

        assert time.monotonic() - started >= 0.04
