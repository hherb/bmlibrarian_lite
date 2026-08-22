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

"""Tests for the JATS structural survey script.

A survey exists to be believed, so the ways it can quietly mislead are what
these tests pin: a miscount is worse than no count, and a *vacuous* result
reported as a clean one is worse than either. The counterexample detector in
`grouped-citations` is the sharpest case — it is the only thing standing
between the #177 drop and a false all-clear.
"""

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "jats_survey.py"


def _load_script() -> ModuleType:
    """Load jats_survey.py as a module (scripts/ is not a package).

    Returns:
        The loaded jats_survey module.
    """
    spec = importlib.util.spec_from_file_location("jats_survey", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["jats_survey"] = module
    spec.loader.exec_module(module)
    return module


jats_survey = _load_script()


# Returns a `jats_survey.Article`. Spelled `Any` because the module is loaded by
# path, so mypy cannot resolve names inside it.
def article(body: str = "", back: str = "", front: str = "") -> Any:
    """Build an Article from body/back/front fragments.

    Args:
        body: Markup placed inside `<body>`.
        back: Markup placed inside `<back>`.
        front: Extra markup placed inside `<article-meta>`.

    Returns:
        A parsed `Article`, with its parent index built.
    """
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
    <article>
      <front><article-meta>
        <article-id pub-id-type="pmc">PMC1234567</article-id>
        {front}
      </article-meta></front>
      <body>{body}</body>
      <back>{back}</back>
    </article>"""
    import xml.etree.ElementTree as ET

    root = ET.fromstring(xml)
    parents = {child: parent for parent in root.iter() for child in parent}
    return jats_survey.Article(
        pmc_id="PMC1234567", path=Path("memory.xml"), root=root, parents=parents
    )


class TestLabelParents:
    """`<label>` is routed by its parent, so the parent is what gets counted."""

    def test_counts_each_label_against_its_own_parent(self) -> None:
        """The same tag on four hosts must land in four buckets, not one."""
        result = jats_survey.measure_label_parents(
            [
                article(
                    body="""
                    <fig id="f1"><label>Figure 1.</label></fig>
                    <table-wrap id="t1"><label>Table 1.</label>
                      <table-wrap-foot><fn><label>a</label></fn></table-wrap-foot>
                    </table-wrap>
                    <disp-formula><label>(1)</label></disp-formula>
                    """
                )
            ]
        )

        assert result.data["byParent"] == {
            "fig": 1,
            "table-wrap": 1,
            "fn": 1,
            "disp-formula": 1,
        }
        assert result.data["unmodelled"] == 1

    def test_flags_an_unmodelled_label_sitting_inside_an_exhibit(self) -> None:
        """The #169 shape: a host with no model, nested in one that has.

        This is the count that says whether the ambient-flag routing would have
        misfiled anything, so it must not be confused with the plain total.
        """
        result = jats_survey.measure_label_parents(
            [
                article(
                    body="""
                    <fig id="f1"><label>Figure 1.</label>
                      <supplementary-material><label>Source data 1.</label></supplementary-material>
                    </fig>
                    <aff id="a1"><label>1</label></aff>
                    """
                )
            ]
        )

        assert result.data["unmodelled"] == 2
        assert result.data["unmodelledInsideExhibit"] == 1, "the <aff> is not inside an exhibit"


class TestGroupedCitations:
    """The measurement the #177 drop rests on."""

    GROUPED = """
    <ref-list>
      <ref id="cit1">
        <element-citation><label>(a)</label></element-citation>
        <element-citation><label>(b)</label></element-citation>
      </ref>
    </ref-list>
    """

    def test_counts_sub_markers_and_finds_no_counterexample(self) -> None:
        """Parenthesised letters are sub-markers; none is a reference number."""
        result = jats_survey.measure_grouped_citations([article(back=self.GROUPED)])

        assert result.data["multiCitationRefs"] == 1
        assert result.data["multiCitationLabels"] == 2
        assert result.data["nonSubMarkerExamples"] == []
        assert "No counterexamples" in result.headline

    def test_a_reference_number_on_a_citation_is_reported_as_a_counterexample(self) -> None:
        """The falsifier for #177, and the reason this script exists.

        If a publisher puts the real reference number on `<element-citation>`
        rather than on `<ref>`, dropping it loses data. A survey that failed to
        notice would hand back a false all-clear, which is worse than not
        running one.
        """
        result = jats_survey.measure_grouped_citations(
            [
                article(
                    back="""
                    <ref-list>
                      <ref id="cit1">
                        <element-citation><label>17.</label></element-citation>
                      </ref>
                    </ref-list>
                    """
                )
            ]
        )

        counterexamples = result.data["nonSubMarkerExamples"]
        assert len(counterexamples) == 1
        assert counterexamples[0]["label"] == "17."
        assert "counterexample" in result.headline.lower()
        assert "losing real reference numbers" in result.headline

    def test_inline_markup_inside_a_label_does_not_fake_a_counterexample(self) -> None:
        """`<label>(<italic>a</italic>)</label>` is a sub-marker like any other.

        Reading only `element.text` returns `"("`, which fails the sub-marker
        test and gets reported as a counterexample — a measurement inventing the
        very evidence it exists to look for.
        """
        result = jats_survey.measure_grouped_citations(
            [
                article(
                    back="""
                    <ref-list>
                      <ref id="cit1">
                        <element-citation><label>(<italic>a</italic>)</label></element-citation>
                        <element-citation><label>(<italic>b</italic>)</label></element-citation>
                      </ref>
                    </ref-list>
                    """
                )
            ]
        )

        assert result.data["multiCitationLabels"] == 2
        assert result.data["nonSubMarkerExamples"] == []
        assert sorted(result.data["markerTexts"]) == ["(a)", "(b)"]

    def test_a_label_nested_deeper_than_the_citation_is_not_counted(self) -> None:
        """Only a label whose *parent* is the citation routes as a sub-marker.

        This mirrors the Swift switch, which reads `enclosingElement`; counting
        "any label inside a citation" would inflate the figure the #177 decision
        rests on.
        """
        result = jats_survey.measure_grouped_citations(
            [
                article(
                    back="""
                    <ref-list>
                      <ref id="cit1">
                        <element-citation><label>(a)</label>
                          <supplementary-material><label>Data S1</label></supplementary-material>
                        </element-citation>
                      </ref>
                    </ref-list>
                    """
                )
            ]
        )

        assert result.data["singleCitationLabels"] == 1
        assert result.data["labelParents"] == {"element-citation": 1}

    def test_an_empty_sample_says_so_rather_than_reporting_a_clean_result(self) -> None:
        """A vacuous pass must not read as evidence.

        The committed corpus contains no grouped citation at all, so the
        headline has to distinguish "looked and found nothing wrong" from
        "there was nothing to look at".
        """
        result = jats_survey.measure_grouped_citations([article(body="<p>Prose.</p>")])

        assert result.data["multiCitationLabels"] == 0
        assert "says nothing either way" in result.headline
        assert "No counterexamples" not in result.headline

    def test_a_direct_ref_label_is_recorded_so_a_first_wins_rule_can_be_judged(self) -> None:
        """Whether a first-wins rule would ever fire is a fact about the data."""
        result = jats_survey.measure_grouped_citations(
            [
                article(
                    back="""
                    <ref-list>
                      <ref id="cit1"><label>3.</label>
                        <element-citation><label>(a)</label></element-citation>
                        <element-citation><label>(b)</label></element-citation>
                      </ref>
                    </ref-list>
                    """
                )
            ]
        )

        assert result.data["refsWithOwnLabel"] == 1


class TestNestedExhibits:
    """Nesting the digests cannot see, so the count has to be independent."""

    @pytest.mark.parametrize(
        "body,shape",
        [
            ("<fig id='a'><fig id='b'/></fig>", "fig in fig"),
            ("<fig id='a'><table-wrap id='t'/></fig>", "table-wrap in fig"),
            ("<table-wrap id='t'><fig id='a'/></table-wrap>", "fig in table-wrap"),
            (
                "<table-wrap id='o'><table-wrap id='i'/></table-wrap>",
                "table-wrap in table-wrap",
            ),
        ],
    )
    def test_each_nesting_direction_is_counted_separately(self, body: str, shape: str) -> None:
        """All four quadrants, since three of them are defects (#169, #173)."""
        result = jats_survey.measure_nested_exhibits([article(body=body)])

        assert result.data["occurrences"][shape] == 1
        assert sum(result.data["occurrences"].values()) == 1, "counted under another shape too"

    def test_an_unnested_article_reports_zero_for_every_shape(self) -> None:
        """The corpus's actual answer, which is a finding rather than a blank."""
        result = jats_survey.measure_nested_exhibits(
            [article(body="<fig id='a'/><table-wrap id='t'/>")]
        )

        assert sum(result.data["occurrences"].values()) == 0


class TestTitleParents:
    """`<title>` on a child element renamed its section before #167."""

    def test_a_footnote_group_title_inside_a_section_is_flagged(self) -> None:
        """The live #167 shape: two titles in one section, only one owning it."""
        result = jats_survey.measure_title_parents(
            [
                article(
                    back="""
                    <sec id="s5"><title>Additional information</title>
                      <fn-group><title>Competing interests</title></fn-group>
                    </sec>
                    """
                )
            ]
        )

        assert result.data["byParent"] == {"sec": 1, "fn-group": 1}
        assert result.data["insideSection"] == 1

    def test_a_caption_title_is_not_counted_as_a_section_hazard(self) -> None:
        """`<caption>` already routes correctly (#142), so it is not the hazard."""
        result = jats_survey.measure_title_parents(
            [article(body="<sec><title>Results</title><fig><caption><title>F1</title></caption></fig></sec>")]
        )

        assert result.data["insideSection"] == 0


class TestGraphicOwners:
    """`<alternatives>` is transparent for ownership; nothing else is."""

    def test_alternatives_passes_ownership_through_to_the_figure(self) -> None:
        """Otherwise the #161 multi-deposit ranking loses its inputs."""
        result = jats_survey.measure_table_graphics(
            [
                article(
                    body="""
                    <fig id="f1"><alternatives>
                      <graphic xlink:href="a.tif" xmlns:xlink="http://www.w3.org/1999/xlink"/>
                    </alternatives></fig>
                    """
                )
            ]
        )

        assert result.data["byOwner"] == {"fig": 1}

    def test_a_table_deposited_as_an_image_is_counted_against_the_table(self) -> None:
        """The #172 count, and the shape that misrouted before #169."""
        result = jats_survey.measure_table_graphics(
            [
                article(
                    body="""
                    <fig id="f1"><table-wrap id="t1">
                      <graphic xlink:href="t.jpg" xmlns:xlink="http://www.w3.org/1999/xlink"/>
                    </table-wrap></fig>
                    """
                )
            ]
        )

        assert result.data["byOwner"] == {"table-wrap": 1}
        assert result.data["tableWrapsWithGraphic"] == 1


class TestSampleComposition:
    """The guard against measuring a sample that has nothing to measure.

    Europe PMC serves a `fullTextXML` document for abstract-only deposits, and
    the newest open-access records are overwhelmingly conference abstracts. A
    400-article sample drawn without `PUB_TYPE` came back 390 abstracts and
    reported "0 nested figures across 400 articles" — a zero that reads as
    strong evidence and is pure front matter.
    """

    ABSTRACT_ONLY = '<?xml version="1.0"?><article article-type="abstract"><front/></article>'
    FULL_TEXT = (
        '<?xml version="1.0"?><article article-type="research-article">'
        "<front/><body><sec><p>Prose.</p></sec></body></article>"
    )

    def _article(self, xml_text: str) -> Any:
        """Parse a raw article string into an Article."""
        import xml.etree.ElementTree as ET

        root = ET.fromstring(xml_text)
        return jats_survey.Article(
            pmc_id="PMC1",
            path=Path("memory.xml"),
            root=root,
            parents={c: p for p in root.iter() for c in p},
        )

    def test_an_abstract_deposit_is_not_full_text(self) -> None:
        """A `<body>`-less record cannot answer a structural question."""
        assert self._article(self.ABSTRACT_ONLY).has_full_text is False
        assert self._article(self.ABSTRACT_ONLY).article_type == "abstract"

    def test_a_body_with_prose_is_full_text(self) -> None:
        """The positive control for the guard."""
        assert self._article(self.FULL_TEXT).has_full_text is True

    def test_an_empty_body_does_not_count_as_full_text(self) -> None:
        """`<body/>` with no prose is the same nothing, differently spelled."""
        empty = '<?xml version="1.0"?><article><front/><body/></article>'
        assert self._article(empty).has_full_text is False

    def test_composition_reports_the_full_text_share(self) -> None:
        """The share is what the warning threshold reads."""
        sample = jats_survey.describe_sample(
            [self._article(self.ABSTRACT_ONLY)] * 3 + [self._article(self.FULL_TEXT)]
        )

        assert sample.articles == 4
        assert sample.with_full_text == 1
        assert sample.full_text_share == 0.25
        assert sample.by_article_type == {"abstract": 3, "research-article": 1}

    def test_the_journal_mix_is_reported_because_it_explains_the_numbers(self) -> None:
        """Several figures are publisher conventions, not JATS properties.

        Nested `<fig>` is eLife's figure-supplement convention and grouped
        citations are an RSC chemistry one, so the same measurement over two
        samples can differ by two orders of magnitude without either being
        wrong. The mix is the only thing that makes a number readable.
        """
        elife = self._article(
            '<?xml version="1.0"?><article article-type="research-article"><front>'
            "<journal-meta><journal-title>eLife</journal-title></journal-meta>"
            "</front><body><p>Prose.</p></body></article>"
        )
        sample = jats_survey.describe_sample([elife, elife, self._article(self.FULL_TEXT)])

        assert sample.by_journal == {"eLife": 2, "(unnamed)": 1}
        assert "eLife (2)" in jats_survey.render_markdown([], [elife, elife], [])

    def test_a_mostly_abstract_sample_is_flagged_in_the_output(self) -> None:
        """The warning is what stops a junk sample reading as a finding."""
        report = jats_survey.render_markdown(
            [], [self._article(self.ABSTRACT_ONLY)] * 9 + [self._article(self.FULL_TEXT)], []
        )

        assert "describe front matter, not JATS structure" in report
        assert "--full-text-only" in report

    def test_a_full_text_sample_is_not_flagged(self) -> None:
        """The warning must stay rare enough to mean something."""
        report = jats_survey.render_markdown([], [self._article(self.FULL_TEXT)] * 10, [])

        assert "describe front matter" not in report
        assert "100.0%" in report


class TestArticleLoading:
    """A malformed article must not cost the run its other 399 results."""

    def test_an_unparseable_file_is_reported_and_skipped(self, tmp_path: Path) -> None:
        """One bad article must cost one article, not the whole survey."""
        (tmp_path / "good.xml").write_text(
            '<?xml version="1.0"?><article><body><p>Fine.</p></body></article>',
            encoding="utf-8",
        )
        (tmp_path / "broken.xml").write_text("<article><body>", encoding="utf-8")

        articles, problems = jats_survey.load_articles(tmp_path)

        assert len(articles) == 1
        assert len(problems) == 1
        assert "broken.xml" in problems[0]

    def test_the_pmc_id_falls_back_to_the_filename(self, tmp_path: Path) -> None:
        """Fetched files are named by id; hand-dropped ones may have no id."""
        (tmp_path / "PMC999.xml").write_text(
            '<?xml version="1.0"?><article><body/></article>', encoding="utf-8"
        )

        articles, _ = jats_survey.load_articles(tmp_path)

        assert articles[0].pmc_id == "PMC999"
