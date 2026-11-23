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


"""The MANTA comparison report: stored judgements against the apps' references.

A judgement with several LLM references (different models) is counted once per
(judgement, reference) pair, in the headline lists as in ``by_llm_model``.
"""

from __future__ import annotations

import sqlite3
from collections import Counter
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import manta_ledger as ml
import manta_protocol as mp
import manta_stats as stats

SWEEP_CUTOFFS = (1.5, 1.75, 1.95, 2.0, 2.25, 2.5, 3.0)
CALIBRATION_BINS = 10

Row = tuple[ml.Judgement, list[ml.Reference]]


def load_rows(paths: Sequence[Path]) -> list[Row]:
    """Merge the ledgers at paths, de-duplicated on judgement_id (first wins).

    Each ledger is opened read-only: the report never writes into a file.

    Raises:
        FileNotFoundError: A ledger file does not exist (it is never created).
        ValueError: A file is not a MANTA ledger.
    """
    seen: dict[str, Row] = {}
    for path in paths:
        if not path.exists():
            raise FileNotFoundError(f"no ledger at {path}")
        conn = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
        try:
            for j, refs in ml.rows(conn):
                seen.setdefault(j.judgement_id, (j, refs))
        except sqlite3.DatabaseError as exc:
            raise ValueError(f"{path} is not a MANTA ledger ({exc})") from exc
        finally:
            conn.close()
    return list(seen.values())


def _entry(j: ml.Judgement, r: ml.Reference) -> dict[str, Any]:
    return {
        "question": j.question,
        "title": j.title,
        "ids": j.ids,
        "expected_score": j.expected_score,
        "llm_score": r.llm_score,
        "llm_model": r.llm_model,
        "app": j.app,
    }


def _share(num: int, den: int) -> float | None:
    return num / den if den else None


def relevance_report(rows: Sequence[Row]) -> dict[str, Any]:
    """Relevance against the LLM references (those with an ``llm_score``)."""
    pairs = [(j, r) for j, refs in rows for r in refs if r.llm_score is not None]
    no_ref = sum(1 for _, refs in rows if not any(r.llm_score is not None for r in refs))
    relevant = lambda r: r.llm_score >= mp.RELEVANT_MIN_SCORE  # noqa: E731

    def kind(j: ml.Judgement, r: ml.Reference) -> str | None:
        if j.verdict == "out":
            return "wrongly_out" if relevant(r) else "rightly_out"
        return None if relevant(r) else "in_but_low"

    out: dict[str, Any] = {"n": len({j.judgement_id for j, _ in pairs}), "pairs": len(pairs)}
    for name in ("wrongly_out", "rightly_out", "in_but_low"):
        out[name] = [_entry(j, r) for j, r in pairs if kind(j, r) == name]
    rel = [j.expected_score for j, r in pairs if relevant(r)]
    low = [j.expected_score for j, r in pairs if not relevant(r)]
    out["sweep"] = [
        {
            "cutoff": c,
            "keeps_relevant": _share(sum(e >= c for e in rel), len(rel)),
            "drops_low": _share(sum(e < c for e in low), len(low)),
        }
        for c in SWEEP_CUTOFFS
    ]
    out["spearman"] = stats.spearman(
        [j.expected_score for j, _ in pairs], [float(r.llm_score) for _, r in pairs]
    )
    out["judged_without_reference"] = no_ref
    for key, get in (("by_app", lambda j, r: j.app), ("by_llm_model", lambda j, r: r.llm_model)):
        groups: dict[str, Counter] = {}
        for j, r in pairs:
            c = groups.setdefault(get(j, r), Counter())
            c["n"] += 1
            if (k := kind(j, r)) is not None:
                c[k] += 1
        out[key] = {name: dict(c) for name, c in groups.items()}
    return out


def _design_part(pairs: Sequence[tuple[ml.Judgement, str]]) -> dict[str, Any]:
    """Agreement, confusion (reference -> MANTA -> count) and calibration of one group."""
    pairs = [(j, ref) for j, ref in pairs if j.design is not None]
    hits = [j.design == ref for j, ref in pairs]
    interval = stats.wilson_interval(sum(hits), len(hits))
    confusion: dict[str, dict[str, int]] = {}
    for j, ref in pairs:
        row = confusion.setdefault(ref, {})
        row[j.design] = row.get(j.design, 0) + 1
    probs = [j.design_probability or 0.0 for j, _ in pairs]
    bins: list[dict[str, Any]] = []
    for b in range(CALIBRATION_BINS):
        lo, hi = b / CALIBRATION_BINS, (b + 1) / CALIBRATION_BINS
        # the top bin includes 1.0
        inside = [
            h for p, h in zip(probs, hits, strict=True) if lo <= p < hi or (hi == 1.0 and p == 1.0)
        ]
        if inside:
            bins.append(
                {"low": lo, "high": hi, "count": len(inside), "accuracy": sum(inside) / len(inside)}
            )
    return {
        "n": len(pairs),
        "agreement": {
            "rate": _share(sum(hits), len(hits)),
            "wilson": list(interval) if interval else None,
        },
        "confusion": confusion,
        "calibration_bins": bins,
        "ece": stats.expected_calibration_error(probs, hits),
    }


def design_report(rows: Sequence[Row]) -> dict[str, Any]:
    """Design agreement, apart for LLM references and for PubMed indexing (by human_indexed)."""
    llm = [(j, r.llm_design) for j, refs in rows for r in refs if r.llm_design is not None]
    idx: dict[Any, list] = {True: [], False: [], None: []}
    for j, refs in rows:
        for r in refs:
            if r.indexing_design is not None:
                idx[r.human_indexed].append((j, r.indexing_design))
    return {
        "llm_design": _design_part(llm),
        "indexing": {
            "human": _design_part(idx[True]),
            "automated": _design_part(idx[False]),
            "unknown": _design_part(idx[None]),
        },
    }


def _pct(x: float | None) -> str:
    return "n/a" if x is None else f"{x * 100:.1f}%"


def _design_text(title: str, part: dict[str, Any]) -> list[str]:
    ag = part["agreement"]
    ci = ag["wilson"]
    span = f" (95% CI {_pct(ci[0])}-{_pct(ci[1])})" if ci else ""
    ece = "n/a" if part["ece"] is None else f"{part['ece']:.3f}"
    lines = [f"{title}: n={part['n']}, agreement {_pct(ag['rate'])}{span}, ECE {ece}"]
    for ref, row in sorted(part["confusion"].items()):
        lines.append(
            f"    reference {ref}: " + ", ".join(f"{k}={v}" for k, v in sorted(row.items()))
        )
    lines += [
        f"    p {b['low']:.1f}-{b['high']:.1f}: n={b['count']}, accuracy {_pct(b['accuracy'])}"
        for b in part["calibration_bins"]
    ]
    return lines


def render(relevance: dict[str, Any], design: dict[str, Any]) -> str:
    """The report as plain text for a terminal (the wrongly-out list comes first)."""
    sp = relevance["spearman"]
    lines = [
        "MANTA shadow report",
        f"Relevance: {relevance['n']} judgements with an LLM reference "
        f"({relevance['pairs']} judgement/reference pairs; a judgement with several models "
        f"counts once per model); {relevance['judged_without_reference']} judged without one.",
        f"  wrongly out (LLM >= {mp.RELEVANT_MIN_SCORE}): {len(relevance['wrongly_out'])}",
        f"  rightly out: {len(relevance['rightly_out'])}",
        f"  in but LLM-low: {len(relevance['in_but_low'])}",
        "  Spearman (expected vs LLM score): " + ("n/a" if sp is None else f"{sp:.3f}"),
        "",
        "Wrongly out (question | title | ids | expected | LLM score | model | app):",
    ]
    lines += [
        f"  {e['question']} | {e['title']} | {e['ids']} | {e['expected_score']:.2f} "
        f"| {e['llm_score']} "
        f"| {e['llm_model']} | {e['app']}"
        for e in relevance["wrongly_out"]
    ] or ["  none"]
    lines += ["", "Cut-off sweep (cutoff: keeps relevant / drops low):"]
    lines += [
        f"  {s['cutoff']:.2f}: {_pct(s['keeps_relevant'])} / {_pct(s['drops_low'])}"
        for s in relevance["sweep"]
    ]
    for key, label in (("by_app", "By app"), ("by_llm_model", "By LLM model")):
        lines += ["", label + ":"]
        lines += [f"  {k}: {v}" for k, v in sorted(relevance[key].items())] or ["  none"]
    lines += ["", "Design"]
    lines += _design_text("  vs LLM design", design["llm_design"])
    for name in ("human", "automated", "unknown"):
        lines += _design_text(f"  vs {name} PubMed indexing", design["indexing"][name])
    return "\n".join(lines) + "\n"
