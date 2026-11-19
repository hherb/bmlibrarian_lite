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

"""Offline tests of scripts/manta_benchmark.py: labels, requests, metrics."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType

import pytest

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "manta_benchmark.py"


def _load_script() -> ModuleType:
    """Load the script as a module (scripts/ is not a package).

    Returns:
        The loaded module.
    """
    spec = importlib.util.spec_from_file_location("manta_benchmark", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["manta_benchmark"] = module
    spec.loader.exec_module(module)
    return module


mb = _load_script()


class TestDesignLabel:
    """The indexers' design, read from publication types and MeSH."""

    @pytest.mark.parametrize(
        ("pts", "mesh", "expected"),
        [
            (["Journal Article", "Meta-Analysis", "Systematic Review"], [], "meta_analysis"),
            (["Systematic Review"], [], "systematic_review"),
            (["Randomized Controlled Trial"], ["Humans"], "rct"),
            (["Randomized Controlled Trial", "Review"], [], None),
            (["Practice Guideline"], [], "guideline"),
            (["Guideline", "Randomized Controlled Trial"], [], None),
            (["Case Reports"], ["Humans"], "case_report"),
            (["Case Reports"], ["Cohort Studies"], None),
            (["Journal Article"], ["Cohort Studies", "Prospective Studies"], "cohort_prospective"),
            (["Journal Article"], ["Cohort Studies", "Retrospective Studies"], "cohort_retrospective"),
            (["Journal Article"], ["Cohort Studies", "Prospective Studies", "Retrospective Studies"], None),
            (["Journal Article"], ["Cohort Studies"], None),
            (["Journal Article"], ["Case-Control Studies", "Retrospective Studies"], "case_control"),
            (["Journal Article"], ["Case-Control Studies", "Prospective Studies"], None),
            (["Journal Article"], ["Cross-Sectional Studies"], "cross_sectional"),
            (["Journal Article"], ["Cross-Sectional Studies", "Case-Control Studies"], None),
            (["Clinical Trial"], ["Cohort Studies", "Prospective Studies"], None),
            (["Review"], ["Cross-Sectional Studies"], None),
            (["Journal Article"], ["Humans"], None),
        ],
    )
    def test_rules(self, pts: list[str], mesh: list[str], expected: str | None) -> None:
        """Each rule gives one design, or refuses two."""
        assert mb.design_label(pts, mesh) == expected

    def test_every_label_is_an_option(self) -> None:
        """A label the corpus can hold is an option both evaluators can answer."""
        assert set(mb.DESIGN_QUERIES) <= set(mb.DESIGN_OPTIONS)
        assert set(mb.DESIGN_OPTIONS) == set(mb.DESIGN_GROUPS)


PUBMED_XML = b"""<?xml version="1.0"?>
<PubmedArticleSet>
 <PubmedArticle>
  <MedlineCitation Status="MEDLINE" Owner="NLM" IndexingMethod="Manual">
   <PMID Version="1">111</PMID>
   <Article>
    <Journal><JournalIssue><PubDate><Year>2018</Year></PubDate></JournalIssue></Journal>
    <ArticleTitle>A <i>trial</i> of X.</ArticleTitle>
    <Abstract>
     <AbstractText Label="BACKGROUND">Why.</AbstractText>
     <AbstractText Label="METHODS">We   randomised.</AbstractText>
    </Abstract>
    <PublicationTypeList>
     <PublicationType UI="D016449">Randomized Controlled Trial</PublicationType>
    </PublicationTypeList>
   </Article>
   <MeshHeadingList>
    <MeshHeading><DescriptorName UI="D006801">Humans</DescriptorName>
     <QualifierName UI="Q1">therapy</QualifierName></MeshHeading>
   </MeshHeadingList>
  </MedlineCitation>
 </PubmedArticle>
 <PubmedArticle>
  <MedlineCitation Status="MEDLINE" Owner="NLM" IndexingMethod="Automated">
   <PMID Version="1">222</PMID>
   <Article><ArticleTitle>B</ArticleTitle></Article>
  </MedlineCitation>
 </PubmedArticle>
 <PubmedBookArticle><BookDocument><PMID>333</PMID></BookDocument></PubmedBookArticle>
</PubmedArticleSet>"""


class TestParsePubmedXml:
    """The parts of an efetch answer the corpus reads."""

    def test_fields(self) -> None:
        """Title, labelled abstract, year, types, descriptors (not qualifiers)."""
        first, second = mb.parse_pubmed_xml(PUBMED_XML)
        assert first.pmid == "111"
        assert first.title == "A trial of X."
        assert first.abstract == "BACKGROUND: Why.\nMETHODS: We randomised."
        assert first.year == 2018
        assert first.publication_types == ("Randomized Controlled Trial",)
        assert first.mesh_headings == ("Humans",)
        assert first.human_indexed
        assert second.pmid == "222"
        assert second.abstract == ""

    def test_automated_indexing_is_not_human(self) -> None:
        """Automated or curated indexing is not a human label; absent is."""
        _, auto = mb.parse_pubmed_xml(PUBMED_XML)
        assert not auto.human_indexed
        absent = mb.PubMedRecord("1", "", "", None, "MEDLINE", None, (), ())
        curated = mb.PubMedRecord("1", "", "", None, "MEDLINE", "Curated", (), ())
        not_medline = mb.PubMedRecord("1", "", "", None, "PubMed-not-MEDLINE", None, (), ())
        assert absent.human_indexed
        assert not curated.human_indexed
        assert not not_medline.human_indexed


class TestRequests:
    """The MANTA requests are valid in MANTA's own format."""

    def test_relevance_request(self) -> None:
        """One score question with the app's five levels, lowest first."""
        req = mb.relevance_request("t1-x", "Q?", "T", "A")
        q = req["questions"]["relevance"]
        assert q["type"] == "score"
        assert q["criteria"][0].startswith("Not relevant")
        assert q["criteria"][-1].startswith("Directly answers")
        assert req["state"]["research_question"] == "Q?"
        assert req["id"] == "t1-x"

    def test_design_request(self) -> None:
        """One choice question over the classifier's options."""
        q = mb.design_request("pmid-1", "T", "A")["questions"]["study_design"]
        assert q["type"] == "choice"
        assert list(q["criteria"]) == list(mb.DESIGN_OPTIONS)

    def test_expected_score(self) -> None:
        """Level "0" is a 1, level "4" a 5; order of the mapping is irrelevant."""
        assert mb.expected_score({"4": 1.0, "0": 0.0}) == 5.0
        assert mb.expected_score({"0": 0.5, "1": 0.5}) == pytest.approx(1.5)


class TestStatistics:
    """The metrics, checked against hand-computed values."""

    def test_average_ranks(self) -> None:
        """Ties take their mean rank."""
        assert mb.average_ranks([10, 20, 20, 5]) == [2.0, 3.5, 3.5, 1.0]

    def test_spearman(self) -> None:
        """Perfect, reversed and constant inputs."""
        assert mb.spearman([1, 2, 3], [10, 20, 30]) == pytest.approx(1.0)
        assert mb.spearman([1, 2, 3], [3, 2, 1]) == pytest.approx(-1.0)
        assert mb.spearman([1, 1, 1], [1, 2, 3]) is None

    def test_auc(self) -> None:
        """Separation, a tie counting half, and an empty side."""
        assert mb.auc([3, 4], [1, 2]) == 1.0
        assert mb.auc([1], [1]) == 0.5
        assert mb.auc([2, 0], [1]) == 0.5
        assert mb.auc([], [1]) is None

    def test_wilson(self) -> None:
        """Known value: 8 of 10."""
        lo, hi = mb.wilson_interval(8, 10)
        assert lo == pytest.approx(0.4902, abs=1e-3)
        assert hi == pytest.approx(0.9433, abs=1e-3)
        assert mb.wilson_interval(0, 0) is None

    def test_ece(self) -> None:
        """Calibrated answers give 0; overconfident ones the gap."""
        assert mb.expected_calibration_error([1.0, 1.0], [True, True]) == 0.0
        assert mb.expected_calibration_error([0.9, 0.9], [False, False]) == pytest.approx(0.9)
        assert mb.expected_calibration_error([], []) is None

    def test_macro_f1(self) -> None:
        """Per-class F1 averaged over the true classes."""
        assert mb.macro_f1(["a", "a", "b"], ["a", "b", "b"]) == pytest.approx((2 / 3 + 2 / 3) / 2)

    def test_cluster_bootstrap_is_seeded(self) -> None:
        """Same seed, same interval; it brackets the statistic."""
        clusters = {"a": [0, 1], "b": [2], "c": [3]}
        values = [1.0, 2.0, 3.0, 4.0]

        def mean(idx: list[int]) -> float:
            return sum(values[i] for i in idx) / len(idx)

        ci1 = mb.cluster_bootstrap(clusters, mean, draws=200, seed=3)
        ci2 = mb.cluster_bootstrap(clusters, mean, draws=200, seed=3)
        assert ci1 == ci2
        assert ci1 is not None and ci1[0] <= 2.5 <= ci1[1]


class TestSampling:
    """The relevance draw."""

    def test_sample_relevance(self) -> None:
        """Per question and grade, never a document without an abstract."""
        corpus = {"a": {"abstract": "x"}, "b": {"abstract": "y"}, "c": {"abstract": ""},
                  "d": {"abstract": "z"}}
        qrels = [("1", "a", 0), ("1", "b", 0), ("1", "c", 2), ("1", "d", 2), ("2", "a", 1)]
        rows = mb.sample_relevance(qrels, corpus, per_grade=1, seed=1)
        keys = sorted((r["topic_id"], r["grade"]) for r in rows)
        assert keys == [("1", 0), ("1", 2), ("2", 1)]
        assert all(r["doc_id"] != "c" for r in rows)
        assert rows == mb.sample_relevance(qrels, corpus, per_grade=1, seed=1)


class TestMetrics:
    """The per-evaluator metrics."""

    def test_relevance_metrics_set_failures_apart(self) -> None:
        """A negative score is a failure, not a score; a missing id is missing."""
        labels = [{"id": f"i{i}", "topic_id": str(i % 2), "grade": g}
                  for i, g in enumerate([0, 1, 2, 0, 1, 2, 2])]
        preds = {f"i{i}": {"id": f"i{i}", "score": s} for i, s in enumerate([1, 3, 5, 2, 3, -1])}
        m = mb.relevance_metrics(labels, preds)
        assert m["failed"] == 1
        assert m["missing"] == 1
        assert m["n"] == 5
        assert m["spearman"] == pytest.approx(mb.spearman([1, 3, 5, 2, 3], [0, 1, 2, 0, 1]))
        assert m["auc_relevant"] == 1.0

    def test_design_metrics(self) -> None:
        """Accuracy, grouped accuracy and top-3 from the probabilities."""
        labels = [{"id": "a", "label": "meta_analysis"}, {"id": "b", "label": "rct"}]
        preds = {
            "a": {"id": "a", "design": "systematic_review", "confidence": 0.6,
                  "probabilities": {"systematic_review": 0.6, "meta_analysis": 0.3, "rct": 0.1}},
            "b": {"id": "b", "design": "rct", "confidence": 0.9,
                  "probabilities": {"rct": 0.9, "other": 0.1}},
        }
        m = mb.design_metrics(labels, preds)
        assert m["accuracy"] == 0.5
        assert m["group_accuracy"] == 1.0
        assert m["top3_accuracy"] == 1.0
        assert m["per_class"]["meta_analysis"]["answers"] == {"systematic_review": 1}


def test_jsonl_round_trip(tmp_path: Path) -> None:
    """Rows written are the rows read."""
    rows = [{"id": "a", "x": 1}, {"id": "b", "x": "é"}]
    path = tmp_path / "sub" / "rows.jsonl"
    mb.write_jsonl(path, rows)
    assert mb.read_jsonl(path) == rows
    assert json.loads(path.read_text(encoding="utf-8").splitlines()[1])["x"] == "é"


def test_failed_rows_are_not_done(tmp_path: Path) -> None:
    """A resumed run asks again for a row that got no answer."""
    path = tmp_path / "preds.jsonl"
    mb.write_jsonl(path, [{"id": "a", "failed": True}, {"id": "b", "failed": False}, {"id": "c"}])
    assert mb._done_ids(path) == {"b", "c"}
    assert mb._done_ids(tmp_path / "absent.jsonl") == set()


def test_cosine() -> None:
    """Parallel, orthogonal and zero vectors."""
    assert mb.cosine([1.0, 0.0], [2.0, 0.0]) == pytest.approx(1.0)
    assert mb.cosine([1.0, 0.0], [0.0, 3.0]) == 0.0
    assert mb.cosine([0.0, 0.0], [1.0, 1.0]) == 0.0


def test_a_flagged_row_decides_failure() -> None:
    """A cosine below 1 is a score when the row says it did not fail."""
    assert not mb._failed({"score": 0.3, "failed": False})
    assert mb._failed({"score": 4, "failed": True})
    assert mb._failed({"score": -3})
    assert not mb._failed({"score": 3})


def test_rule_design() -> None:
    """The types of bmlib onto the classifier's options."""
    assert mb.rule_design("rct") == "rct"
    assert mb.rule_design("quasi_experimental") == "other"
    assert mb.rule_design("unknown") == "unknown"
    assert mb.rule_design("None") == "unknown"


def test_no_ece_without_a_confidence_for_every_answer() -> None:
    """An evaluator that states no confidence gets no ECE."""
    labels = [{"id": "a", "label": "rct"}]
    assert mb.design_metrics(labels, {"a": {"id": "a", "design": "rct"}})["ece"] is None


def test_screening_at_recall() -> None:
    """The cut-off keeps the recall asked; negatives below it are dropped."""
    positives = [5.0, 4.0, 3.0, 2.0]
    negatives = [1.0, 1.5, 2.0, 3.5]
    # 3 of 4 positives (75 %) kept at a cut-off of 3.0: 1.0, 1.5, 2.0 below it.
    assert mb.screening_at_recall(positives, negatives, recall=0.75) == 0.75
    # All positives kept: cut-off 2.0, so 2.0 itself is kept; 1.0, 1.5 dropped.
    assert mb.screening_at_recall(positives, negatives, recall=1.0) == 0.5
    # One positive kept: cut-off 5.0 drops every negative.
    assert mb.screening_at_recall(positives, negatives, recall=0.25) == 1.0
    assert mb.screening_at_recall([], negatives) is None
