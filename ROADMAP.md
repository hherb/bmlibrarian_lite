# ROADMAP

Planned work, decided unless an item says otherwise, and not started. Where to start on an item is in
`HANDOVER.md`; remove an item here once it has landed.

---

## Parity: taking a fact check further (Python desktop)

iOS and macOS (PR #611) and Android (PR #616) have five ways to take a
finished fact check further. The Python desktop needs the same, with the same
rules. Swift is the reference: `FactCheckWorkflow.swift`, `FullTextAutoFetch.swift`,
`FullTextUpload.swift`, `PromptTemplates.alternativeQueries`; Kotlin's port is
`FactCheckWorkflow.kt` and `domain/workflow/FullTextAutoFetch.kt`.

| Feature | Rule (as on iOS/macOS; Android's divergences below) | Python desktop |
|---|---|---|
| **Find More Evidence / New Question** | After a search, the submit button fetches more for the same claim; an edited claim is a new question. New Question clears claim and session. | No one-click "fetch more and regenerate"; Research Questions has *Re-run Search* |
| **Repeated smart search** | With the original query and a smart-search round used up, another round runs; the prompt lists every query already run, as its concept names joined by AND; the session keeps each query once it has run, not one a source could not answer. A round that finds nothing new leaves the report and says so; a session without a report goes on to make one. *Get More Evidence* always offered. | No alternative-query search at all |
| **Full-text score setting** | *Fetch Full Text From Score*, 1–5, default 4, never below the relevance threshold. | **Done** (PR #622): *Settings → Full Text → Read citations from full text*, *Fetch Full Text From Score* (off, 4); every text a model analyses is read in sliding 16,000-character windows overlapping by 250 (map-reduce), never cut, references left out |
| **Retry Full Text Fetching** | With the setting on, asks again for qualifying papers without full text, including ones no source had; re-extracts the citations of a relevant paper whose full text they have not read (a per-paper record of whether the last extraction read the full text); replaces them only when the text yields passages, and not when the run budget leaves the text out; redoes transparency; regenerates the report; no full text read, no regeneration. | **Done** (PR #622): *Research Questions → Retry Full Text* on the reviewed run; `citation_reads` records each paper's text; the run keeps its `ReportMetadata` so the report can be written again (runs from before cannot) |
| **Upload Full Text** | On each paper card without readable text: PDF (text extracted, kept apart from the PDF cache), HTML, Markdown, plain text. An upload is read whatever the full-text setting or score. Offered during a run too: the automatic fetch leaves a paper the reader uploaded for alone. | **Done**: *Audit Trail → Literature → right-click → Upload Full Text…* (PDF text, HTML reduced to text, Markdown, plain text; UTF-8, 100 MB, no empty text, not only references); kept in SQLite (`uploaded_full_texts`), apart from the converter-stamped cache; the review reads it in place of a fetch, *Retry Full Text* reads one newer than the paper's last read, whatever the setting or score at or above the threshold; the methodology counts them. Differs: offered on every card, and a running review reads the uploads once, before its citations, so one made later waits for *Retry Full Text* |

**Python, decided 2026-10-23:** actions live on the Research Questions tab,
the full-text rows first (done in PR #622). Every LLM text path reads in
16,000-character windows overlapping by 250 and reduces the answers, on the
apps too (`text_windows.json`): with references out, 40% of PMC texts and 45% of PDF texts
exceed 40,000 characters. *Upload Full Text* is on the Audit Trail cards.
Still owed: *Find More Evidence* / repeated smart search (extending *Re-run
Search*).

**Android's known divergences** are #615 (undownloaded PDF links re-fetched
only on a retry; a textless Elsevier PDF or Europe PMC render gives way to a
held abstract; no transparency redo, as Android's transparency reads no full
text, #384; an unsectioned JATS body is held back as abstract-only, #384) and
#614 (no Regenerate Report offer, so a retry that found citations in an
abstract regenerates the report itself).

**Also owed on iOS/macOS:** HTML uploads are passed on as raw markup; an
upload is not checked against the paper's title (`PDFTitleCheck`).
