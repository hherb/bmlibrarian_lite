# Analysis Failure Reporting

A model that could not read a document is not a document with nothing to say.
This document is the cross-platform contract for telling the two apart, from
the failed LLM call to the words the reader sees. It is the companion of
[Search Failure Reporting](search_failure_reporting.md), which covers the
stage before: a source that failed is not a source with no evidence.

Python (`analysis_failures.py`, `agents/`) is the reference.

| Platform | Status |
|----------|--------|
| Python | Conforms (#261, #262, #263, #264) |
| Swift (BioMedLit + app) | **Unchecked.** `ParallelScoringService` and `ParallelCitationService` have the same shape; see #300 |
| Android | **Unchecked.** `domain/workflow/` has the same shape; see #300 |

## Why

Before #261–#263, every failure after the search left the pipeline the way a
document the model had judged irrelevant did — as something missing from the
result:

- a provider that could not be reached ended a review with "No documents
  scored 3 or higher. Try lowering the minimum score threshold.", and an MCP
  `fact_check_claim` with "Found 20 documents but none scored above the
  relevance threshold (3/5)." A calling agent reads that as the literature not
  supporting the claim (#262);
- a citation extraction that failed for every relevant document produced "No
  relevant evidence was found in the searched literature. This may indicate:
  1. The topic has limited published research", in the same result that
  reported `documents_relevant` above zero (#261);
- a report the model could not generate came back as the string `Error
  generating report: …`, which the GUI checkpointed as `step="complete"`,
  auto-saved to `~/bmlibrarian_reports/LITE` and listed under Load Report, and
  which MCP returned as a successful result (#263);
- a full text that was retrieved but could not be loaded for interrogation was
  reported as `{"success": true}`, and the caller's next `ask_document` call
  failed with nothing having said why (#264).

## What counts as a failed analysis

A stage failed for a document when the model call did not produce a usable
answer after its retries: a timeout, a refused or unreachable provider, a
rate limit, an answer that could not be parsed, or spent retries. Python
classifies each one into an `EvaluationErrorCode`, whose negative value a
`ScoredDocument` carries in place of a score.

A document that was never attempted — below the score threshold, or after the
run was cancelled — did not fail. It is not counted.

## What a stage records

`AnalysisShortfall` (`data_models.py`) is the unit:

| Field | Meaning |
|-------|---------|
| `stage` | `scoring` or `citation_extraction`, persisted by those names |
| `documents_failed` | At least one; a shortfall that lost nothing is refused on construction |
| `documents_attempted` | At least `documents_failed` |
| `causes` | Each distinct `EvaluationErrorCode`, in the order it first occurred |

Its clause is `"3 of 20 documents could not be scored (API request timed
out)"`, or `"… could not be read for citations (…)"`. Without a cause, the
count alone: **the reason degrades, the loss never does.**

Twenty documents that timed out are one cause, not twenty — the constructor
reduces repeats, so no reader has to.

## What each stage does

- **Scoring** (`LiteScoringAgent.score_documents`) answers with a
  `ScoringOutcome`: the documents that met the threshold, the documents that
  failed, and how many were attempted. When **every** attempted document
  failed, it raises `AnalysisFailedError` instead: there is nothing to proceed
  on, and a threshold message would be read as the literature's answer.
- **Citation extraction** (`LiteCitationAgent.extract_all_citations`) answers
  with a `CitationOutcome` and never raises: losing every document is
  reportable, because the documents are known to be relevant. A report built
  on no citations then says the extraction failed rather than that the
  literature is silent.
- **Report generation** (`LiteReportingAgent.generate_report`,
  `generate_brief_summary`) **raises**. An error message returned as the
  report is a report as far as every caller is concerned.

## What the reader sees

- **A report, or a message standing in for one**, opens with
  `> **Incomplete analysis:** <clauses>. Everything below rests only on the
  documents that were analysed.` The search notice (#247) goes in front of it,
  so a review that lost both reads the search first.
  A check that decides *what a text is* — the Report tab's auto-save — reads
  the body behind **both** notices, never in front of them.
- **The Methodology section** gains `- **Analysis Completeness:** Incomplete:
  <clauses>`. Documents that failed are **not** counted as rejected: recording
  them as rejected is what made a failure read as the literature's answer.
- **The GUI** shows a standing "Incomplete analysis: …" warning under
  Progress, accumulating one clause per stage — a second notice that replaced
  the first would hide what the first said. A stage that lost everything ends
  the review with an error naming what failed and what to do next, never a
  threshold message.
- **MCP** carries `analysis_shortfalls` beside `retrieval_shortfalls` in every
  `fact_check_claim` result, each entry with a sentence-ready `description`.
  A failed analysis is an error result carrying the same list plus `advice`.
  `get_document_fulltext` reports `interrogation_available`, and
  `interrogation_error` when it is false: the text was retrieved, but
  `ask_document` cannot answer about it.

## Advice

`analysis_failure_advice` says what the user can do, each sentence at most
once and in this order: a refused key sends them to Settings; a rate limit
says to wait; an unreachable or failing provider says to check that it is
reachable; an unreadable answer suggests another model. Otherwise, "Try again
later."

## Ports

Nothing here has been checked against Swift or Android (#300). Both run the
same pipeline with the same shape — a parallel scoring service that drops
what it could not score, and a report built from whatever citations arrived —
so the same defects are likely present. A port conforms when a review whose
model is unreachable ends in an error naming the provider, and no report can
be built from an empty citation list without saying why it is empty.
