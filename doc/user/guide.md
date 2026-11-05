# BMLibrarian Lite User Guide

A lightweight biomedical literature research tool for systematic reviews,
fact-checking and document interrogation. It searches PubMed and Europe PMC,
leaves out retracted papers, scores each paper's relevance with an LLM,
checks how transparent each study is about its funding and conflicts of
interest, extracts citable passages and writes a referenced report. Your
data stays on your own computer, in SQLite. No database server is needed.

This guide describes the desktop application (Python/PySide6) as it stands
on `master`: version 0.5.0 plus the work listed under `[Unreleased]` in
`CHANGELOG.md`. The iOS, macOS and Android apps are described briefly under
[Cross-Platform Apps](#cross-platform-apps).

## Contents

- [Getting Started](#getting-started)
- [Running a Systematic Review](#running-a-systematic-review)
- [Research Questions](#research-questions)
- [The Report](#the-report)
- [Audit Trail](#audit-trail)
- [Study Transparency Analysis](#study-transparency-analysis)
- [Quality Assessment](#quality-assessment)
- [Full Text](#full-text)
- [Document Interrogation](#document-interrogation)
- [Multi-Model Benchmarking](#multi-model-benchmarking)
- [The MCP Server](#the-mcp-server)
- [Settings](#settings)
- [CLI Commands](#cli-commands)
- [Data Storage](#data-storage)
- [Cross-Platform Apps](#cross-platform-apps)
- [Workflow Tips](#workflow-tips)
- [Troubleshooting](#troubleshooting)

## Getting Started

### Requirements

- Python 3.12 or newer
- Git, for an installation from source. BMLibrarian Lite depends on
  [bmlib](https://github.com/hherb/bmlib), the maintainer's shared
  biomedical-literature library, which decides each paper's retraction
  status. Until bmlib 0.12.0 is published on PyPI, the installer fetches it
  from GitHub at a fixed commit, so `git` must be on your `PATH`.
- An LLM: an Anthropic API key, or a local [Ollama](https://ollama.com)
  server.

### Installation from Source (recommended)

```bash
git clone https://github.com/hherb/bmlibrarian_lite.git
cd bmlibrarian_lite
```

```bash
uv venv && source .venv/bin/activate  # On Windows: .venv\Scripts\activate
uv pip install -e .
```

With pip instead of uv:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e .
```

The installer fetches bmlib with the other dependencies; nothing else needs
setting up.

### Installation from PyPI

```bash
uv pip install bmlibrarian-lite
```

The PyPI release is 0.5.0. It predates much of what this guide describes,
including retraction checking, smart search, Find More Evidence, full-text
uploads and the CORE, Elsevier and OpenAlex sources. Install from source to
get them. A new PyPI release follows once bmlib 0.12.0 is on PyPI.

### Choosing an LLM Provider

#### Option A: Anthropic Claude (recommended)

1. Get an API key from the [Anthropic Console](https://console.anthropic.com/).
2. Set it in the environment:
   ```bash
   export ANTHROPIC_API_KEY="your-api-key-here"
   ```
   or enter it under Settings → API Keys after launching the application.

#### Option B: Ollama (local)

1. Install Ollama from [ollama.com](https://ollama.com).
2. Pull a model:
   ```bash
   ollama pull llama3.2
   ```
3. Set the host if it is not on this machine (the default is
   `http://localhost:11434`), in the environment or under Settings → Providers:
   ```bash
   export OLLAMA_HOST="http://localhost:11434"
   ```

Each task (query conversion, document scoring, citation extraction, report
generation, document Q&A and the rest) can use its own provider and model:
see Settings → Tasks.

For long documents, set a fixed `context_window` for each Ollama task in
`~/.bmlibrarian_lite/config.json`, under `models.tasks`:

```json
{
  "models": {
    "tasks": {
      "citation_extraction": {
        "provider": "ollama",
        "model": "llama3.2",
        "context_window": 32768
      }
    }
  }
}
```

The value is a positive integer number of tokens, sent as Ollama's `num_ctx`.
Use a size supported by the model and available memory, allowing room for both
the prompt and the generated answer. Other task IDs include `report_generation`
and `document_qa`; configure their limits separately if needed. A missing or
`null` value keeps Ollama's server/model default, which may be too small for
long prompts and may silently truncate them. This setting does not detect
server-side truncation or resize the context automatically. Changing the
context size can reload the model, so prefer a stable value for each task.
Anthropic requests are unaffected.

### PubMed Email and API Key (recommended)

NCBI asks for an email address with every E-utilities request. Enter it under
Settings → PubMed, or set it in the environment:

```bash
export NCBI_EMAIL="your@email.com"
export NCBI_API_KEY="your-ncbi-key"   # optional: raises NCBI's rate limit
```

An NCBI API key (free, from your NCBI account settings) raises the rate
limit; enter it under Settings → PubMed, or set `NCBI_API_KEY`.

Optional keys for more full-text sources (CORE, Elsevier) and OpenAthens are
described under [Full Text](#full-text).

Environment variables can also be put in `~/.bmlibrarian_lite/.env`, one
`NAME=value` per line; the application loads it at start-up.

### Launching the Application

```bash
# GUI (recommended)
bmlibrarian-lite-gui

# The same GUI: bmll with no command launches it
bmll
```

`bmll` also has maintenance commands; see [CLI Commands](#cli-commands).

The main window has seven tabs: **Research Questions**, **Systematic
Review**, **Audit Trail**, **Report**, **Document Interrogation**,
**Benchmark Results** and **Quality Benchmark**. **Settings** is the button at
the right of the status bar, beside the session's token count and estimated
cost. The **Tools** menu holds **Walled PDFs…** (see
[The review queue](#the-review-queue-walled-pdfs)).

## Running a Systematic Review

The Systematic Review tab runs the whole workflow from a question to a
report. Type your research question in natural language, choose the maximum
number of results and the minimum relevance score (1–5) a paper needs to be
cited, and press **Run Review**. **Cancel** stops it.

1. **Query**: The question is converted to a PubMed (or Europe PMC) query.
   The Audit Trail's Queries tab shows it.
2. **Search**: PubMed and/or Europe PMC are searched; results found by more
   than one provider are merged.
3. **Retraction screen**: Every paper found is checked for retraction before
   anything else happens. Retracted papers are left out (see
   [Retracted Papers](#retracted-papers)).
4. **Quality filter** (optional): Papers below the minimum quality tier you
   set are filtered out (see [Quality Assessment](#quality-assessment)).
5. **Relevance scoring**: The model scores each paper 1–5 for relevance to
   the question, in parallel for cloud providers.
6. **Smart search**: When fewer than three papers reach the threshold (and at
   least one paper was scored), the model proposes two or three alternative
   queries, which are searched, screened and scored the same way. The
   alternative queries are recorded with the run, so a later round does not
   ask them again.
7. **Transparency analysis**: Studies are analysed for funding disclosure,
   conflicts of interest, data availability and trial registration.
8. **Citations**: Passages that answer the question are extracted from each
   relevant paper, from its abstract, or from its full text (see
   [Reading Citations from Full Text](#reading-citations-from-full-text)).
9. **Report**: A referenced report is written, with risk warnings drawn
   from the transparency analysis. It opens in the Report tab and is saved
   automatically.

Progress appears under the question as each step runs, and the Audit Trail
fills in live.

### Search Providers

- **PubMed**: NCBI's biomedical literature database (default)
- **Europe PMC**: Alternative provider with cursor-based pagination and full-text access
- Results from multiple providers are automatically deduplicated by PMID, DOI, PMC ID, or title similarity

Choose the provider, and whether Europe PMC's preprints are included, under
Settings → Search.

### When a Search Is Incomplete

A database that cannot be reached is never reported as one with no articles.

- **The search failed outright** (for example PubMed rate-limited the request, or the connection failed): the review stops with an error dialog naming the database and the reason, and saying what to do next: for example wait a minute, add or check the NCBI API key in Settings, or check the internet connection.
- **Part of the search failed** (one of two providers, or a batch of records): the review continues on what was retrieved. A warning appears under Progress, the report opens with an **Incomplete search** notice, and its Methodology section lists what is missing and why.
- **Research Questions → search for more documents** keeps going past a batch of records it could not fetch, and stops at a page of results it could not retrieve. It hands the documents it found to the review with what is missing, so that review's report opens with the same notice. If the failures leave it with no new document, it shows an error with what to do next.
- **A smart-search round that could not run** (the model's answers held no
  usable query, or it declined) is not a failed search: the review goes on
  with what it has, and the Progress area says why no alternative search
  ran.

### When the AI Cannot Read What Was Found

A model that could not answer is never reported as a literature with nothing
relevant in it.

- **No document could be scored** (the model provider is unreachable, refuses
  the API key, or rate-limits every request): the review stops with an error
  naming what failed and what to do next. It does not say "No documents scored
  3 or higher": nobody knows what those documents would have scored.
- **Some documents could not be scored, or could not be read for citations**:
  the review continues on the rest. A warning appears under Progress, the
  report opens with an **Incomplete analysis** notice, and its Methodology
  section records it under Analysis Completeness. Those documents are not
  counted as rejected.
- **The audit trail names them.** Its dialog lists the documents that could
  not be scored, and the relevant documents whose citations could not be
  extracted, each with the reason. For every relevant document it says whether
  it was cited, held nothing quotable, or could not be read — three different
  things. A report restored from an older run that never recorded this says
  so rather than guessing.
- **A report that could not be generated is not saved.** The review ends with
  an error in the report step, and nothing is added to the report folder or
  offered under Load Report.

### Retracted Papers

Before anything is scored, every paper the search found is checked against
three sources:

- **Retraction Watch's database**, through a local copy kept in the data
  folder (`retraction_watch.db`);
- **Crossref**, which is asked about each paper's DOI;
- **PubMed's own "Retracted Publication" label** on the record.

The rule that turns what these sources say into a verdict comes from bmlib,
the library the desktop and mobile apps share, so every platform reaches the
same verdict from the same evidence. A paper is:

- **Retracted**: left out. The report lists it under **Left out as
  retracted**, and the audit trail shows it with a RETRACTED badge.
- **Under concern** (an expression of concern, or a partial retraction):
  kept, with a CONCERN badge and a caveat under its reference in the report.
- **Not checked**: a source was down, it has no DOI, or the local copy is out
  of date. Its card shows **NOT CHECKED**, and the report opens with a notice
  giving the count and the reason. Not checked never means "not retracted".
  A paper counts as clear only when the local copy was consulted *and*
  Crossref answered for its DOI.

A source that is down never erases an earlier verdict: a paper once found
retracted stays retracted. A verdict is reused for seven days; one that
rests on a source that did not answer is asked again at the next check.

The local copy is refreshed by the review itself when it is more than five
weeks old (a download of about 68 MB; Cancel stops it). To refresh it by
hand, run `bmll retractions-update`.

**Saved work is checked again on request.** A report you reopen (from the
Report tab's **Load Report** or the Research Questions tab's **Load**) shows
when its papers were last checked, and warns when a paper cited in it has
been found retracted since. **Check again** asks the sources again about the
run's papers and records the answer with the run; it does not change the
report's text. If the check fails or you stop it, the line says the run's
earlier record stands.

Document Interrogation shows the same status in a banner above a loaded
paper, and the MCP server's tools leave out retracted papers too, marking
every other paper with its status.

### Reading Citations from Full Text

By default citations are extracted from abstracts. Under Settings → Full
Text, **Read citations from full text** makes the review fetch the full text
of every paper scored at **Fetch Full Text From Score** (default 4) or higher
and extract its citations from that text instead. A long text is read in
several overlapping model calls and never cut. The report's methodology says
how many papers were read from a full text. A full text you uploaded (see
[Audit Trail](#literature-tab)) is read whatever this setting says.

### Search Tips

- Be specific in your research question
- Include key terms, populations, and outcomes of interest
- The AI converts natural language to optimized search queries
- Check the generated query on the Audit Trail's Queries tab

### Scoring Guidelines

| Score | Meaning |
|-------|---------|
| 5 | Highly relevant, directly addresses the question |
| 4 | Relevant, provides useful supporting evidence |
| 3 | Moderately relevant, tangentially related |
| 2 | Low relevance, limited applicability |
| 1 | Not relevant |

## Research Questions

The Research Questions tab lists every question you have reviewed, and lets
you revisit, extend and re-analyse it:

- View all previous research questions. The **Scored** column counts the documents a model scored; documents whose every scoring failed are shown beside it, for example **12 (+3 failed)**
- **Load** shows the question's saved report and audit trail, including each
  study's stored transparency badge and retraction status. Nothing is
  fetched: a study whose stored assessment is out of date, or that has none,
  reads **Not assessed** with the reason on hover. If the stored assessments
  cannot be read at all, every badge says so, and so does the status bar's
  "Loaded question" message; the log has the details
- **Re-run Search** fetches further results of the question's query (set how
  many with **Target new documents**) and reviews them. Documents already
  scored are skipped. A document whose every scoring failed is not counted as
  scored: a re-run hands it back to be scored again, and says how many it is
  retrying (for example **Found 5 new documents, and 3 whose scoring failed
  before**)
- **Find More Evidence** adds evidence to the question's latest reviewed run
  and writes its report again. It pages further through the question's own
  query; when that finds nothing new, it runs a round of alternative queries
  (smart search), told of every query already run. New documents are
  screened for retractions, scored into the same run, their citations
  extracted, and the report is rewritten from every citation of the run. A
  round that finds nothing new leaves the report as it is and says so.
  Documents an earlier run found but left unscored (a run you stopped) are
  scored first. What it learns is saved as it goes, so if it is stopped or
  fails before the report, the next **Find More Evidence** or **Retry Full
  Text** writes the report
- The context menu (right-click a question) offers **Re-classify
  Documents**, **Re-score Documents**, **Re-analyse Transparency**, **Retry
  Full Text**, **Re-run Search**, **Find More Evidence**, **Run Benchmark**
  (when benchmarking is enabled) and **Delete Question**
- **Re-analyse Transparency** (context menu, when transparency analysis is on)
  re-analyses only the question's studies whose assessment is missing, out of
  date, or provisional. It says how many that is, and how many carry no
  PubMed ID or DOI to look one up by, before it starts; it can be cancelled,
  and the badges of a loaded question update as each study comes back. A
  study whose sources could not all be read is reported as **provisional**:
  its result is shown with that caveat, and it stays pending
- **Retry Full Text** (context menu) reads full texts the question's report
  was not written from, then writes the report again. With **Read citations
  from full text** on (Settings → Full Text), it fetches the full text of each
  paper scored at **Fetch Full Text From Score** or higher whose citations
  were not read from it. Whatever the setting, it reads each full text you
  uploaded for a paper scored at or above the review's threshold (Audit
  Trail → Literature → right-click → **Upload Full Text…**) since that
  paper's citations were last read from a full text, or that was never read
  from one. A long text is read in several model calls and never cut. When no
  full text was read, the report stays as it was

## The Report

The Report tab shows the latest report, or one you load.

- **Citations are links**: click one to open that paper in Document
  Interrogation.
- **Load Report** opens a report saved earlier.
- **Audit Trail** opens the record of what became of every document the
  run found: accepted, rejected (with the model's reason), not scored, could
  not be scored, or left out as retracted.
- **Export Report** saves the report where you choose.
- **Check again** re-checks the run's papers for retraction (see
  [Retracted Papers](#retracted-papers)).

Every report is saved automatically to `~/bmlibrarian_reports/LITE/` as
`{timestamp}_{question}_report.md`, with the audit record beside it as
`…_audit.json`.

A report opens with a notice whenever it rests on less than was asked for:
**Incomplete search**, **Incomplete analysis**, papers whose retraction
status could not be checked. Its sections include the synthesis, the
reference list, **Left out as retracted** (when any were), **Why Studies
Were Rated High Transparency Risk** (when any cited study was rated High),
and the **Methodology**, which records the queries, the counts at each step,
what could not be done and why, and how many papers were read from a full
text.

## Audit Trail

The Audit Trail tab provides real-time visibility into the systematic review workflow. It has three sub-tabs.

### Queries Tab

Shows all generated search queries during the workflow:
- The natural language question and resulting search query
- Statistics: documents found, scored, citations extracted — and, when any
  failed, the documents the model could not score, counted apart from those
  it scored
- Query history for the current session

### Literature Tab

Displays document cards for all retrieved articles.

**Document Cards:**
- **Header**: Shows quality badge (RCT, SR, etc.), relevance score (1-5), transparency risk badge, retraction badge (RETRACTED, CONCERN or NOT CHECKED, when the paper is not clear), and title. A document the model could not score shows a grey **Scoring failed** badge instead of a score; hover over it for the reason. After the review finishes, cards are ordered by score, then the documents that could not be scored, then those never scored
- **Metadata**: Authors, journal, year, PMID/DOI
- **Click to expand**: View the full abstract
- **LLM Rationale**: See why the document received its score

**Quality Badges:**
- **RCT**: Randomized Controlled Trial (gold standard)
- **SR**: Systematic Review / Meta-analysis
- **Cohort**: Cohort study
- **Case-Ctrl**: Case-control study
- **Cross-Sec**: Cross-sectional study
- **Case**: Case report/series

**Interactions:**
- **Left-click**: Expand/collapse the card to show abstract
- **Right-click**: Context menu with options:
  - Send to Interrogator (opens document for Q&A)
  - Upload Full Text… (a PDF, HTML, Markdown or plain-text file of the
    paper, for one no source had). Its text is kept with the paper. HTML,
    Markdown and text files must be UTF-8, and a file over 100 MB, holding
    no text (a scanned PDF) or nothing before its reference list is refused.
    When the paper scored at or above the review's threshold, **Retry Full
    Text** on the Research Questions tab reads it and writes the report
    again, and every review run from then on reads it in place of fetching
    one, whatever the full-text setting. The report's methodology says how
    many papers were read from an upload
  - Copy PMID / Copy DOI
  - Expand / Collapse

### Citations Tab

Shows extracted citation passages:
- Citation number and quality badge
- Document metadata
- Highlighted passage within the abstract context
- Relevance explanation from the LLM

## Study Transparency Analysis

Each study is automatically analyzed for transparency indicators:

- **Funding Disclosure**: Whether funding sources are declared, and whether
  a funder is industry. A funder named by brand alone ("Pfizer") is
  recognised as industry; its charitable foundation is not.
- **Conflict of Interest**: Whether COI statements are present
- **Data Availability**: Whether underlying data is shared
- **Trial Registration**: Whether the study is registered. Registrations in any
  trial registry PubMed links (ClinicalTrials.gov, ISRCTN, EudraCT, ANZCTR,
  ChiCTR and the rest) count; only ClinicalTrials.gov records are read in
  detail, so a registration elsewhere is reported as registered but not
  assessed. "Clinical trial without detected registration" is raised only
  when every cited registration was checked and the title reads as a trial's
  by whole word, so "atrial fibrillation" is not a trial.
- **Transparency Score**: Overall transparency rating

Transparency results feed into risk warnings that appear in generated
reports, flagging studies with potential concerns. The thresholds behind the
warnings are set in the transparency settings, opened from the quality
filter panel on the Systematic Review tab.

A study can also show a grey **Not assessed** badge. That is not a finding
against the study — it means BMLibrarian has nothing to report about it, and
hovering over the badge says why:

- **The analysis could not be completed**: a source was unreachable, refused
  the request, or limited how often it can be called. The badge says which,
  and what you can do about it.
- **The record carries neither a PubMed ID nor a DOI**, so there was nothing
  to look the study up by.
- **The stored assessment was made by an earlier version of the analyser.**
  When a correction changes what the analyser would find, studies assessed
  before it are re-analysed the next time they come up in a review, or when
  you choose **Re-analyse Transparency** for their question on the Research
  Questions tab. Until that happens their old score and risk level are
  withheld rather than shown.
  A report counts those studies separately and says how many are waiting, and
  annotates each affected reference rather than leaving it bare.

> **After upgrading, expect this once, for everything the upgrade's analyser
> reads differently.** When a release corrects what the analyser accepts as
> evidence, every assessment stored before it is superseded, and badges read
> **Not assessed** until each study has been looked at again: the next time
> it appears in a review, or when you re-analyse its question from the
> Research Questions tab. This is the correction working, not the feature
> breaking. Re-analysis is paced against rate-limited sources, so it is
> deliberately not done all at once when you open the application.

A report's **Transparency Analysis** section accounts for every study it was
asked about. Alongside the risk distribution it names how many are awaiting
re-analysis, and how many came back with no finding at all — because an
analysis that could not be made is not a study with nothing to declare. Each
of those counts says what it is a share of, for example **12 of the 40
studies reviewed; 3 of them are cited in this report**, since only the cited
studies are annotated in the reference list. If
transparency analysis was switched on, the report says so even when every
analysis failed.

A rating made without the article's full text is never shown as an
unqualified score. Its badge carries a **· limited** suffix — for example
**High · limited** — and its tooltip says **Limited certainty because of
lack of full text access** directly under the risk level, because full-text
analysis is BMLibrarian's gold standard and a rating made from metadata
alone rests on less. A full text counts only when part of it could actually
be read: an article whose text arrived but in which none of the statements
the analysis looks for could be found is rated as limited too. The
statements are read in the places journals usually print them, including the
competing-interests, data-availability and funding statements that PLOS
journals keep with the article's front matter and that most journals keep
after the main text; an article an earlier version analysed is offered
for re-analysis so that its rating reflects them. For a
**High** rating, the tooltip also lists **Rated high risk because** — the
specific rule or rules that decided it, such as a low transparency score or
a missing conflict-of-interest statement — so you can see why a study was
flagged rather than only that it was. If none of the current rules matches
a stored High (usually because the transparency settings have changed since
it was rated), the tooltip says so under **Caveats** instead. If a source
the analysis needed could not be read, the tooltip adds a line saying the
rating is **provisional** and should be re-checked before you rely on it.

A generated report explains its own High ratings the same way. A **Why
Studies Were Rated High Transparency Risk** section, between the reference
list and the methodology, gives every cited High-risk study its score, the
rules that decided it (in the same words as the badge), and — where a low
score was one of those rules — **How the score was reached**, term by term.
It then lists any **Other concerns recorded** and **Caveats**. The section
is left out entirely when no cited study was rated High. Each flagged
reference in the reference list also carries the limited-certainty note
when its rating was made without the full text. The **Methodology**
section's transparency summary gains two counts of its own, each shown only
when it is not zero: how many ratings were made without the full text
(**Limited certainty because of lack of full text access**), and how many
were made while a source could not be read (**Provisional**) and so are due
for re-analysis.

## Quality Assessment

When enabled, the quality filter assesses each document for:

- **Study Design**: RCT, systematic review, cohort, case-control, etc.
- **Quality Tier**: High, Medium, Low based on methodology
- **Evidence Level**: Based on study design hierarchy

Set the minimum tier, and whether AI classification is used, in the quality
filter panel on the Systematic Review tab; the defaults are under Settings →
Quality. PubMed's publication types decide the design where they can, and the
model classifies the rest. A long text is classified in overlapping windows
whose answers are combined. Quality badges appear on document cards showing
the study type with color coding.

## Full Text

### Where Full Texts Come From

BMLibrarian Lite looks for an article's full text in this order, stopping at
the first source that has it:

1. **Your library**: a full text or PDF already downloaded (see
   [Data Storage](#data-storage)).
2. **Europe PMC XML**: Free full-text articles in structured JATS format.
3. **PMC open-access collection**: The same JATS, by PMC ID, from PMC's
   open-data bucket, including author manuscripts.
4. **Europe PMC PDF**: PDF versions from Europe PMC.
5. **Elsevier's Article API**: For an Elsevier article (a DOI starting
   `10.1016/`), with your API key.
6. **Unpaywall**: Every open-access PDF Unpaywall knows of.
7. **OpenAlex**: The PDFs OpenAlex's locations name.
8. **The publisher**: A PDF fetched through the article's DOI link.
9. **CORE extracted text**: With a key, when no PDF was obtained or the PDF
   holds no text (a scan). Plain text, so a missing funding or
   conflict-of-interest statement is "not assessed" rather than counted
   against the study.
10. **Your upload**: For a paper no source has, upload its PDF, HTML,
    Markdown or text file from the Audit Trail (right-click a card →
    **Upload Full Text…**).

JATS XML articles are rendered with full support for tables, figures,
references, and anchor navigation. Every request to these services is paced,
so a long review never floods one of them.

Set the Unpaywall email under Settings → Full Text to enable Unpaywall
access in Document Interrogation; the transparency analysis and the MCP
server fall back to your PubMed email when it is not set.

### CORE API Key (optional)

CORE (core.ac.uk) holds the text it extracted from open-access repository
copies. With a free key, BMLibrarian Lite reads that text when no other
source has the article. Register at https://core.ac.uk/services/api, then
enter the key under Settings → Full Text, or set it in the environment:
```bash
export CORE_API_KEY="your-key"
```
The key is stored only in your configuration file (readable by you alone)
and sent only to CORE. Without one, CORE is simply not asked. If CORE refuses
the key, the app stops asking CORE with that key for the rest of the session
and says 'the key in the settings was refused' (also when the key came from
`CORE_API_KEY`: the settings field then says so); correct the key under
Settings → Full Text and CORE is asked again, by Document Interrogation and
by the background transparency analysis alike, without a restart.

### Elsevier API Key and Institutional Token (optional)

Elsevier's Article API serves the PDF of an Elsevier article (a DOI starting
`10.1016/`) to a requestor entitled to it. Get a free API key at
https://dev.elsevier.com, then enter it under Settings → Full Text, or set it
in the environment:
```bash
export ELSEVIER_API_KEY="your-key"
export ELSEVIER_INSTTOKEN="your-institutional-token"   # optional
```
In testing, a key alone was refused for every article from outside the
institution's network, open-access ones included. An institutional token from
Elsevier is meant to lift that: it lets the key use your institution's
subscriptions away from its network. Both are stored only
in your configuration file (readable by you alone) and sent only to Elsevier,
in request headers. Without a key, Elsevier is simply not asked. When Elsevier
serves only an article's first page (you are not entitled to it), that page is
never used; the app goes on to look for an open-access copy. If Elsevier
refuses the key, or refuses the key and token from your current network, the
app stops asking with them for the rest of the session and says so ("the key
in the settings was refused" or "not available from this network"). A
corrected key is asked again; after a refusal from your network, so is the same
key with a token added or changed under Settings → Full Text. A token in the
`ELSEVIER_INSTTOKEN` variable is used only with the key in `ELSEVIER_API_KEY`,
never with a key typed in the settings. A key pasted with an invisible
character (one that cannot be sent in a request) is never sent: the app says
Elsevier could not be asked, and the log asks you to enter the key again.

### OpenAthens (optional)

If your institution uses OpenAthens, enable it under Settings → OpenAthens
and enter your institution's OpenAthens Redirector URL, or just its domain
(for example `jcu.edu.au`). Document Interrogation can then open paywalled
articles through your institution's subscription after you log in. Sessions
expire after the **Session Max Age** you set (24 hours by default).

### Every PDF Is Checked Against Its Article's Title

Every PDF is checked against its article's title before its text is read,
whether it was just downloaded or was already in your PDF library: its first
page with text must carry the title. In a real library, 10 of 25 PDFs turned
out to be other articles, filed under the wrong one. A PDF that does not carry
the title is never read as the article and never deleted: it is renamed
beside itself with `.mismatch` added (`article.pdf.mismatch`), the app looks
for the article's own PDF elsewhere, and you are told (in the chat, in the
article's transparency warnings, or by the MCP tool). If such a PDF *is* the
article (a preprint whose title changed, a scan with garbled text), keep it:

```bash
bmll keep-pdf ~/knowledgebase/pdf/2016/10.3945_ajcn.115.120147.pdf.mismatch
```

This renames it back and marks it as kept (a `.kept` file beside it), so it
is read from then on. A different PDF downloaded later in its place is checked
again. **Keep this PDF** in the review queue (below) marks a PDF the same way.
If another PDF is already in the library under the article's name (say a scan
whose title could not be checked), the command changes nothing and says so:
move that PDF out of the folder, or delete it, and run the command again.
Deleting a PDF from the Document Interrogation tab also removes its `.kept`
file, so the same PDF downloaded again is checked like any other.

A PDF whose title cannot be checked (a scan with no text, an article with no
title, or one whose title PubMed gives as an English translation in square
brackets) is read as it is.

### Bot-Walled PDFs (the hidden browser)

Some open-access PDFs sit behind a robot check that blocks the app's downloads.
Such a copy is reported as behind a robot check, never as paywalled, so no
OpenAthens login is offered for it. Under Settings → Full Text, "Try
bot-walled PDFs in a hidden browser" (on by default) lets the app later open
each such PDF in a hidden built-in browser, save it if it arrives, and
re-check that article's transparency when the article is in your library.
This runs only while the desktop app is open: at start-up, after each
analysis, and once a minute. It also opens the PDFs the app's MCP server
queued. Switching the setting off stops visits not yet made; the PDFs stay
queued for when it is on again.

The page opens as in any browser: it loads its own resources and runs the
publisher's scripts, and those of the robot check's provider (such as Google's
reCAPTCHA or Cloudflare), which is how the check is passed. Those sites learn
which article is fetched, as the publisher did when the app first tried. Your
searches, documents and keys are never sent.

A PDF the hidden browser fetches is not saved when its first page with text
shows it is another document (a supplement, another article), or when it
cannot be opened (it needs a password, or is damaged); the entry then waits
for you in the review queue. A PDF whose title cannot be checked is saved,
and the review queue says its title could not be checked.

Rescued PDFs are saved in your PDF library, and a rescued article's
transparency badge is re-checked, so it may change once the full text has been
read. The browser keeps the sites' cookies and a cache of what the pages loaded
in `browser_profile/` inside the app's data folder (by default
`~/.bmlibrarian_lite/browser_profile/`, readable by you alone); deleting that
folder clears them. While a copy has not been rescued (or cannot be), the
article reads "could not be asked … (the host asked for a robot check)". If the
hidden browser cannot start on your computer, the status bar says so at
start-up and the setting is shown disabled, with the reason in the log.

### The Review Queue (Walled PDFs)

Some robot checks need a person: ScienceDirect, for example, asks you to tick
a box. When PDFs like these are waiting for you (with the hidden browser off,
every queued walled PDF), the status bar shows "Walled PDFs: N"; click it, or
choose **Tools → Walled PDFs…** (which works at a count of 0 too).

- **Select an entry** to open its page in the window's built-in browser. If
  the page asks for a robot check, tick the box. When the PDF arrives it is
  saved, the article's transparency is re-checked, and the next entry opens.
  The page is yours to read and navigate. A PDF you download there is saved
  as the article's unless its first page with text shows it is another
  document (a supplement, another article). One that does is not kept: the
  window says so, the page stays open, and **Keep this PDF** saves it anyway,
  for a scan whose text is garbled or a preprint whose title changed. If it
  cannot be saved (the PDF library is unavailable), the window says so and
  the PDF stays held, so you can choose **Keep this PDF** again. Downloading
  another file replaces the held PDF. A file that is not a PDF (a citation
  export, say), or a PDF that cannot be opened, is not kept either: the
  window says so and the page stays open. Selecting an entry that is already
  settled shows only how its last visit ended.
- **Walk the queue** opens each waiting entry in turn and waits up to a minute
  for its PDF. Many robot checks (Cloudflare's, in testing) pass on their own
  this way, leaving mostly those that need a tick. Selecting an entry yourself
  stops the walk; when it ends, the window says how many pages could not be
  opened, if any.
- **Dismiss** sets an entry aside; it is not tried again.
- **Open in system browser** opens the address in your usual browser. Nothing
  downloaded there is saved by the app.
- The filter at the top shows "Waiting for you" by default; "Not yet settled"
  (everything still to be tried, including what the hidden browser has not
  reached yet); and "All", which also lists the PDFs found gone, too large, or
  with no PDF behind the page, those fetched, and those you dismissed.

The window and the hidden browser share one browser profile, so a robot check
you pass once usually covers that publisher's later PDFs. While the window has
a page open, the hidden browser waits.

## Document Interrogation

The Document Interrogation tab is for questions and answers about one
document:

1. **Load a document**: **Load Document** opens a PDF, plain-text (`.txt`)
   or Markdown (`.md`) file. Clicking a citation in a report, or **Send to
   Interrogator** on an Audit Trail card, loads that paper: its full text
   when one can be found (see [Full Text](#full-text)), else its abstract,
   with the reason the full text could not be had. **Fetch PDF** tries to
   fetch the PDF of the paper by its DOI or PMID.
2. **Ask questions**: Type a question about the document and press **Send**.
   The document is split into chunks and embedded locally; each question is
   answered from the chunks most relevant to it.
3. **Get answers**: The answer comes with references to the passages it
   rests on.

- **Retraction banner**: A loaded paper shows its retraction status above the
  document.
- **Wrong PDF**: When the PDF loaded is not the paper you asked for, **Wrong
  PDF** deletes it, or deletes it and tries again.
- **Save** exports the conversation as JSON or Markdown.

### Walled PDFs in Document Interrogation

Opening a citation whose open-access PDF is behind a robot check puts it
first in the review queue. The tab then shows "Trying the publisher's page in
a browser…" (with Cancel) for up to about a minute and a half:

- when the PDF arrives, it is loaded into the session;
- when the robot check needs you, the abstract (or an older cached full text)
  is loaded ("the publisher's copy is behind a robot check"), and you are
  offered the review queue for that article; once you have passed the check
  there, open the citation again to load its PDF;
- when the PDF the publisher's page gave was another document, or could not
  be opened, the abstract is loaded ("the PDF the publisher's page gave is not
  this article's", or "… could not be opened"), and you are offered the
  review queue to download the article's own PDF;
- when there is no PDF behind the page, the abstract is loaded as before.

With the hidden browser off or unavailable, or while the review queue window
has a page open or is walking the queue, the tab offers the review queue
straight away.

## Multi-Model Benchmarking

Compare how different LLM models score document relevance and classify study
quality. Enable benchmarking and choose the models under Settings →
Benchmarking, then press **Run Benchmark** or **Quality Benchmark** on the
Systematic Review tab, or **Run Benchmark** on the Research Questions tab.
Results appear in the **Benchmark Results** and **Quality Benchmark** tabs.

- Side-by-side model comparison with agreement matrices
- Score distribution analysis across models
- Per-document score comparison with disagreement highlighting
- Cost and latency tracking per model
- Export results to CSV/JSON

A document a model could not score — its provider unreachable, or an answer
that could not be read — is counted in that model's **Failed** column and
shown as **failed** in the document details (hover for why). It is never
counted as a score: not in the mean, the distribution, or the agreement
between models, which compares only documents both models scored (**n/a**
when they scored none in common). The next benchmark of the same question
scores it again rather than reusing the failure. A model that scored nothing
shows **n/a** for its cost per document and its score distribution, rather
than $0.00 or 0%. A result saved before this was recorded says so: its scores
of 1 may include failures. If a saved result cannot be read back, the
Benchmark tab says the results **could not be loaded**; that is not the same
as having none, and running the benchmark again would repeat its cost.

The quality benchmark follows the same rules. A document a model could not
classify is counted in its **Failed** column and shown as **failed** in the
document details (hover for why), never as an "Unknown" design: "Unknown" is
an answer, a failure is none. Design and tier agreement compare only
documents both models classified. An answer that names no recognised study
design is counted as a failure, and one bad answer fails only that document,
not the whole benchmark. When the benchmark reuses the review's own
classifications, it reuses only those the same model made for the same task,
as the model gave them: never one the review could not make, one read from
PubMed's publication types, one a transparency check downgraded, or one
another model made. Reused classifications cost nothing in this run, so they
are left out of the cost and speed per assessment.

A model's answer counts as a score only when it gives a whole number from 1
to 5. An answer that declines to score, gives 0, or scores on another scale
(such as "10/10") is retried, and if it never gives a score it is counted as
a failure, not as a score of 1.

## The MCP Server

BMLibrarian Lite includes a [Model Context Protocol](https://modelcontextprotocol.io)
server, so an MCP client such as Claude Desktop or Claude Code can use it as
a tool. Start it with:

```bash
bmlibrarian-lite-mcp
```

It offers four tools:

- `fact_check_claim`: check a claim or research question against the
  literature: search PubMed and/or Europe PMC, score the papers found,
  extract supporting citations and write a report;
- `search_literature`: search PubMed and/or Europe PMC and return the
  papers' metadata, unscored;
- `get_document_fulltext`: a paper's full text as Markdown, by PMID, DOI or
  PMC ID, which also loads it for `ask_document`;
- `ask_document`: a question about the paper loaded last, answered from its
  text.

The server uses the same configuration, library and retraction checking as
the desktop app; retracted papers are left out of its results. Setting it up
in each client is described in `HOWTO_MCP_SERVER.md` at the repository root.

## Settings

Press **Settings** in the status bar. The dialog's tabs:

| Tab | What it sets |
|-----|--------------|
| **Providers** | The Anthropic and Ollama connections (with **Test Connection**), the Ollama host, the default provider, model, temperature and token limit, and the number of parallel scoring and citation workers |
| **Tasks** | A provider and model per task, overriding the defaults |
| **Search** | PubMed or Europe PMC, preprints, maximum results |
| **Embeddings** | The local embedding model (FastEmbed) |
| **PubMed** | Your email and NCBI API key |
| **Full Text** | Read citations from full text, Fetch Full Text From Score, the Unpaywall email, the CORE key, the Elsevier key and token, the hidden browser |
| **API Keys** | The Anthropic API key |
| **OpenAthens** | Your institution's OpenAthens login |
| **Quality** | The default minimum tier, AI classification, quality badges |
| **Benchmarking** | Benchmarking on or off, the models compared, the sample |

Opening Settings asks each enabled provider for its models, waiting a few
seconds. If a provider does not answer, its status line says so ("Could not
load the model list…"), and the lists offer built-in models, which may not
match what the provider has now. Press **Test Connection** to ask again.

### Configuration File

Settings are stored in `~/.bmlibrarian_lite/config.json`, readable by you
alone. An abridged example:

```json
{
  "models": {
    "default_provider": "anthropic",
    "default_model": "claude-sonnet-4-20250514",
    "default_temperature": 0.3,
    "default_max_tokens": 4096,
    "tasks": {}
  },
  "embeddings": {
    "model": "BAAI/bge-small-en-v1.5"
  },
  "pubmed": {
    "email": "your@email.com"
  },
  "europepmc": {
    "include_preprints": false
  },
  "discovery": {
    "unpaywall_email": "",
    "browser_rescue_hidden": true,
    "citations_from_full_text": false,
    "full_text_min_score": 4
  },
  "openathens": {
    "enabled": false,
    "institution_url": "",
    "session_max_age_hours": 24
  },
  "storage": {
    "data_dir": "~/.bmlibrarian_lite"
  },
  "search": {
    "chunk_size": 8000,
    "chunk_overlap": 200,
    "similarity_threshold": 0.5,
    "max_results": 20,
    "search_provider": "pubmed"
  }
}
```

The file also holds the `benchmark`, `parallel` and `transparency` sections,
and your keys (`pubmed.api_key`, `discovery.core_api_key`,
`discovery.elsevier_api_key`, `discovery.elsevier_insttoken`) when you enter
them in the settings. Prefer the Settings dialog to editing the file by hand.

## CLI Commands

BMLibrarian Lite provides command-line utilities:

```bash
# Launch the GUI (also what bmll does with no command)
bmll gui

# Show storage statistics (--json for machine-readable output)
bmll stats

# Validate configuration
bmll validate --verbose

# Show current configuration
bmll config --json

# Clear all stored data (asks for confirmation; -f skips it)
bmll clear

# Keep a PDF the title check set aside as its article's
bmll keep-pdf <path to the .pdf.mismatch file>

# Refresh the local Retraction Watch copy
bmll retractions-update
```

`bmll retractions-update` exits 0 only when it built a new copy; otherwise it
says which copy is kept and how current it is.

`bmll config` prints your keys (the NCBI, CORE and Elsevier keys and the
Elsevier token) as `<redacted>` in both its plain and `--json` forms, so the
output is safe to paste into a bug report. That also makes it a lossy view:
it is a diagnostic, not a backup. Saving it back over
`~/.bmlibrarian_lite/config.json` would replace your keys with the
placeholder, which BMLibrarian detects on load and ignores, falling back to
the environment variable (`NCBI_API_KEY` for the NCBI key).

## Data Storage

Everything is stored locally. No external database server is required.

In the data folder, `~/.bmlibrarian_lite/` by default:

- **`config.json`**: your settings
- **`metadata.db`** (SQLite): documents, embeddings (via sqlite-vec), search
  sessions, review checkpoints, scores, citations, transparency results,
  retraction checks, uploaded full texts and the walled-PDF queue
- **`retraction_watch.db`**: the local copy of Retraction Watch's database
- **`browser_profile/`**: the built-in browser's cookies and cache
- **`.env`**: optional environment variables, loaded at start-up

In your home folder:

- **`~/knowledgebase/pdf/{year}/`**: downloaded PDFs, with any
  `.mismatch` (set aside) and `.kept` files beside them
- **`~/knowledgebase/fulltext/{year}/`**: full texts converted to Markdown
- **`~/bmlibrarian_reports/LITE/`**: generated reports and their audit
  records

The embedding model (about 100 MB) is downloaded on first use and cached.

## Cross-Platform Apps

BMLibrarian Lite is also available as native mobile and desktop apps:

- **iOS** and **macOS**: Native SwiftUI apps with iCloud sync, transparency analysis, retraction checking, parallel processing, and full-text access
- **Android**: Native Kotlin/Compose app with transparency analysis, retraction checking, parallel processing, and full-text access

These apps share the same core algorithms (documented in `doc/cross_platform/`)
but use platform-native storage and ML capabilities. iOS and macOS share code
via the BioMedLit Swift package. The apps decide retraction verdicts with
bmlib's Rust library, so all three platforms decide a paper's retraction
status by the same rule.

## Workflow Tips

### Best Practices for Systematic Reviews

1. **Start with a focused question**: Use PICO format (Population, Intervention, Comparison, Outcome)
2. **Review the generated query**: Check the Audit Trail to see the search query
3. **Adjust scoring threshold**: Higher threshold = more selective results
4. **Check quality badges**: Prioritize RCTs and systematic reviews for treatment questions
5. **Review transparency**: Check risk badges for funding and COI concerns
6. **Read LLM rationales**: Understand why documents were scored as they were
7. **Read notices first**: An **Incomplete search**, **Incomplete analysis**
   or not-checked notice at the top of a report says what it rests on
8. **Too little evidence?** Use **Find More Evidence** on the Research
   Questions tab rather than starting over: it extends the same run
9. **Before relying on an older report**, open it and press **Check again**

### Using the Interrogator

1. **Start from Audit Trail**: Right-click a document card and select "Send to Interrogator"
2. **Ask specific questions**: "What were the primary outcomes?" rather than "Tell me about this study"
3. **Follow up**: Ask clarifying questions based on the AI's responses

## Troubleshooting

### Common Issues

**Installation fails while fetching bmlib**
- An installation from source fetches bmlib from GitHub: make sure `git` is
  installed and GitHub is reachable

**"API key not set" error**
- Ensure `ANTHROPIC_API_KEY` is set in your environment
- Or configure it in Settings → API Keys

**"Connection refused" with Ollama**
- Verify Ollama is running: `ollama list`
- Check the host URL under Settings → Providers

**Slow embedding generation**
- First run downloads the embedding model (~100MB)
- Subsequent runs use the cached model

**PubMed rate limiting**
- Set your email under Settings → PubMed (or `NCBI_EMAIL`)
- Add an NCBI API key for heavy usage

**Papers show NOT CHECKED**
- Read the report's notice or the badge's tooltip for the reason: a source
  down, no DOI, or an out-of-date local copy
- Run `bmll retractions-update`, then **Check again** on the Report tab

**A PDF was set aside as `.mismatch`**
- If it really is the article, run `bmll keep-pdf <path>` (see
  [Every PDF Is Checked Against Its Article's Title](#every-pdf-is-checked-against-its-articles-title))

**Quality badges not appearing**
- Ensure quality filtering is enabled in Settings
- Quality assessment only runs when minimum tier is set

### Getting Help

- **Issues**: [GitHub Issues](https://github.com/hherb/bmlibrarian_lite/issues)
- **Documentation**: See other files in this `doc/` directory, and
  `HOWTO_MCP_SERVER.md` for the MCP server
