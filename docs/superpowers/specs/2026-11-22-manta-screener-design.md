# MANTA-4B as relevance screener and study-design classifier

The step after the TREC-COVID benchmark (`doc/developer/manta_benchmark/README.md`). There, MANTA-4B ranked
relevance about as well as the Sonnet scorer (Spearman ρ 0.617 vs 0.619; the two agree at ρ 0.893). Cut off to
keep 95 % of relevant pairs, it would drop 31–57 % of non-relevant ones. It got study design right 89 % of the
time, against 84 % for Haiku 5.5, and its probabilities are calibrated.

## Why

The maintainer wants two things from MANTA-4B:

- a relevance screener that keeps clearly irrelevant papers away from the paid LLM scorer;
- a study-design classifier.

Before MANTA decides anything, it should be benchmarked on real use: the questions the maintainer actually asks
in Medical Fact Checker on macOS and in the Python desktop app, not TREC-COVID's.

The reference is the app's LLM verdict. The maintainer has used Medical Fact Checker for months. They sometimes
disagree with its ranking between 3 and 5, mostly between 4 and 5. They have never seen it put a relevant paper
at 1 or 2. So a paper the LLM scores 3 or more is treated as relevant, and a paper it scores 1–2 as not.

## Goals, non-goals, anti-goals

- **Goal 1, the MANTA server.** A local HTTP service that serves MANTA-4B to both apps, on the Mac's GPU (MPS) or
  the DGX Spark (CUDA).
- **Goal 2, the shadow stage (built first).** Every fact check scores every paper with the LLM, as now. MANTA
  also judges every paper's relevance and design.
  - For each paper, its probabilities, its expected score and its verdict are stored, together with the LLM's
    verdict. The verdict is "would screen out" or, per the maintainer, also **"would screen in"**.
  - What the reader sees does not change.
  - A report compares MANTA with the LLM over everything stored so far.
- **Goal 3, the screening stage (built after shadow data exists).** A switch, off by default.
  - When it is on, papers MANTA screens out are not sent to the LLM scorer, except a random audit sample, which
    still is.
  - The cut-off is chosen from the shadow data.
- **Scope of this design's plan: Goals 1 and 2 only.** Goal 3 is sketched in §5 so that nothing built now blocks
  it. It gets its own revision of this document once the shadow report exists.
- **Non-goals:**
  - iOS and Android. A 10 GB torch model cannot run there; the shared Swift code may compile on iOS, but there is
    no iOS settings UI.
  - Replacing the LLM scorer's number with MANTA's.
  - Full-text relevance: MANTA sees the abstract, as the scorer does.
  - MANTA-27B, which needs about 60 GB of GPU memory.
  - Bundling torch into the desktop package or the DMG.
- **Anti-goals:**
  - A wrong probability served without warning. torch 2.6 on MPS gave plausible-looking wrong answers (spike
    below).
  - A fact check slowed or failed because MANTA is slow, down or missing.
  - A paper screened out that the reader is never told about.
  - "MANTA not reached" stored or reported as "MANTA judged".

## Spike findings (2026-11-21, throwaway; scripts not kept)

These are measured on the 40 relevance pairs and 20–40 design abstracts of the committed benchmark, compared with
the committed CPU predictions.

| Setup | Per pair | Per abstract | Agreement with the CPU reference |
|---|---|---|---|
| M3 Max, torch 2.6.0, MPS (MANTA's pin) | ~1 s | ~2 s | 4/20 designs, NaN relevance. **Wrong** |
| M3 Max, torch 2.15.0, MPS | 0.65–1.1 s | 0.9–1.85 s | 40/40 designs, mean \|Δ score\| 0.005 |
| M3 Max CPU, float32 | 5.2 s | 6.5 s | 8/8 |
| Benchmark CPU (4 Xeon cores) | 3.9 s | 5.8 s | (the reference) |

- **The cause.** In torch 2.6 on MPS, `torch.linalg.solve_triangular` is wrong (99.9 % relative error) whenever
  its input has two or more batch dimensions. transformers' Qwen3.5 Gated DeltaNet fallback calls it that way.
  The fallback is used because flash-linear-attention is Triton-only.
- **The fix.** torch 2.10 solves it correctly. 2.15.0 is correct and fast.
- **Other measurements.**
  - Batching is slower (padding), so requests are scored one at a time.
  - It uses 14 GB of MPS memory and loads in about 2 s.
  - All other MANTA pins are unchanged. The only changes are torch 2.15.0 and torchvision 0.29.2.
- **The DGX Spark (GB10, sm_121, aarch64, driver 580), 2026-11-22.**
  - **Setup.**
    - torch 2.15.0+cu132, from the cu132 index. The cu130 index stops at 2.14.1, and driver 580 runs 13.2 builds.
    - torchvision 0.29.2, Triton 3.9.0.
    - MANTA's other pins are unchanged.
  - **flash-linear-attention.** MANTA's pinned 0.4.2 does not work with Triton 3.9 (an Autotuner `STAGE` key
    error). transformers swallows the import error and silently uses the PyTorch fallback. flash-linear-attention
    and fla-core 0.6.0, installed with `--no-deps`, work. causal-conv1d is left out, as MANTA's requirements say.
  - **Results with flash-linear-attention 0.6.0.**
    - 40/40 designs. Relevance mean \|Δ score\| 0.006, max 0.023.
    - **0.11 s per pair, 0.17 s per abstract**, 10.8 GB peak.
    - Batching is slower (0.60 s per pair at batch size 4).
    - The first load took 71 s from a cold disk.
  - **Without the kernel** (the silent fallback): 40/40, 0.19 s per pair, 0.31 s per abstract.
  - These ran alongside the maintainer's `llama-server` (17 GB) and localmail on the same GPU.
- **What the speed means.** 200 papers take about 20 s on the DGX and about 3–4 minutes on the M3 Max. Screening on
  the DGX would be faster than parallel LLM scoring; on the Mac it is not.
- **Self-test tolerance.** The CPU reference ran without flash-linear-attention. CUDA with the kernel is within
  0.023 of it, so one reference and the 0.05 tolerance serve every device measured.
- **Which kernel is running.** `/health` reports whether the flash-linear-attention kernel is the one in use. The
  server checks the import itself, because transformers falls back silently.

## Approaches

1. **One local MANTA server, called over HTTP by both apps (chosen; maintainer 2026-11-21).**
   - It is a Python process in its own environment, started like Ollama.
   - torch stays outside the signed DMG, the App Store sandbox and the desktop package.
   - The Mac app already has `com.apple.security.network.client`, which it uses for Ollama.
   - Either app can use the M3 Max, or the DGX through an SSH tunnel.
   - The cost is one more process to start.
2. **MANTA inside the desktop process, plus a server for the Mac app.** This means two code paths for one model,
   and torch in the desktop install.
3. **MANTA converted to Core ML or MLX, native in Swift.** Qwen3.5 plus MANTA's own heads and remote code make
   this a project of its own.

## Design

### 1. The server: `tools/manta_server/`

- **Files.**
  - `manta_server.py`, the server.
  - `requirements-macos.txt`: MANTA's `requirements.txt` with torch 2.15.0 and torchvision 0.29.2, and no
    flash-linear-attention.
  - `requirements-cuda.txt`: the cu132 index, torch 2.15.0, torchvision 0.29.2, and flash-linear-attention plus
    fla-core 0.6.0, installed with `--no-deps` as a second step (their metadata would otherwise move torch).
  - `README.md`, covering setup, download and starting the server.
- **Dependencies.** It uses the standard library only, beyond MANTA's own requirements: `ThreadingHTTPServer`, and
  one lock around the model because there is one GPU. It is not added to `pyproject.toml`.
- **Start-up.**
  - Its arguments are the model folder (default `~/models/MANTA-4B`) and the device (`mps`, `cuda` or `cpu`).
  - The model revision is pinned to `ae0db2a45edc065315001055d172e6b76cf60ba2`. The server reads it from
    `config.json`, or from the download's metadata, and refuses any other revision unless `--any-revision` is
    passed.
- **Self-test (the anti-goal guard).**
  - Before it answers anything, the server runs fixed requests: two relevance pairs and two design abstracts, taken
    from the committed benchmark, with their CPU-reference results stored beside the server.
  - It refuses to serve if a design answer differs, if any probability is NaN, or if an expected score differs by
    more than 0.05.
  - `/health` reports which check passed and when.
- **One source of truth for the prompts.** The request builders move from `scripts/manta_benchmark.py` into the
  server module, and the benchmark imports them from there. These are `relevance_request`, `design_request` and
  `expected_score`, plus `RELEVANCE_LEVELS`, `RELEVANCE_INSTRUCTIONS`, `DESIGN_OPTIONS` and `DESIGN_INSTRUCTIONS`.
  Clients send plain fields and never MANTA prompts.
- **API.** JSON on `127.0.0.1:8765`, and on localhost only. The DGX is not reachable over plain HTTP and will stay
  that way (maintainer, 2026-11-22). A full service there may come later, as its own design.
  - Until then, the DGX is used through an SSH tunnel, `ssh -L 8765:127.0.0.1:8765 dgx`, which the README
    documents. The apps still see `127.0.0.1`, and nothing is exposed.
  - No `--host` or token now.
  - `GET /health`: model, revision, torch version, device, self-test result.
  - `POST /v1/judge` with `{app, question, title, abstract, ids, tasks: ["relevance", "design"]}`. It returns, per
    task, the probabilities, plus the expected score for relevance and the answer and its probability for design.
    It also returns `prompt_tokens`, `truncated` (whether the prompt reached MANTA's 4,096-token limit),
    `seconds`, the revision and a `judgement_id`.
  - **The verdict is computed by the server, never by the apps.** This keeps the rule in one place, not ported to
    Swift.
    - `/v1/judge` returns `verdict` (`"in"` or `"out"`: two states) and the `cutoff` it used.
    - Both verdicts are stored and reported. "Would screen in" is the maintainer's addition: the record is not
      only of the outs.
    - The cut-off is a server constant, `SHADOW_CUTOFF = 1.95` on the expected score.
      - Provisional, from the TREC-COVID benchmark against Sonnet's verdicts. At 1.98 MANTA kept all 110 papers
        Sonnet scored 3 or more, and dropped 60 % of the 190 Sonnet scored 1–2. At 2.24 it kept 99 % and
        dropped 77 %.
      - Changing the constant changes only new verdicts. The report also sweeps cut-offs over the stored
        probabilities.
    - The screening stage's audit draw (§5) will also be made by the server.
  - `POST /v1/reference` with `{judgement_id, app, llm_model, llm_score?, llm_design?, indexing?}`. This is the
    reference verdict for the same paper, posted back by the client once it has one. `indexing` is
    `{publication_types, mesh_terms}`, which the server maps to a design (§3).
- **The ledger.** The server keeps every judgement and every reference in its own SQLite, at
  `~/.manta_server/ledger.db`.
  - A row holds: the time; the app; a hash of the question; the paper's ids (PMID, DOI, PMC ID, whichever the
    client sends); MANTA's output; and the cut-off and verdict in force.
  - Abstracts are not stored. The question text is stored, because the report needs it.
  - `python manta_server.py report [LEDGER ...]` prints the comparison (§4). It merges several ledgers (the M3 Max
    and the DGX each keep their own), keyed by `judgement_id`, which is a UUID.
  - Each app stores, with each judgement, the server URL that issued it, and posts that judgement's reference
    there. A change of URL mid-run therefore never sends a reference to the wrong ledger.
  - This gives one benchmark across both apps with no export UI. The apps still persist MANTA's judgement per
    paper themselves (§2, §3), by the maintainer's rule that everything learned about a document is persisted.

### 2. The Python desktop app

- **Setting.** A MANTA URL, empty by default, which means off. Defaults go in `constants.py`. The screening
  switch comes with §5.
- **New modules.**
  - `manta_client.py`: HTTP over the polite session, with the request and error types.
  - `manta_store.py`: a `manta_judgements` table keyed by checkpoint and document, holding probabilities as JSON,
    expected score, design, the server's verdict and cut-off, revision, seconds, `truncated`, the issuing URL and
    `judgement_id`, and an outcome of `judged`, `unreachable` or `failed`. A paper never sent has no row.
- **The desktop app is a deliberate exception.** It is being retired (no new PyQt features of substance), but the
  maintainer asked for it here (2026-11-21) so that benchmarks accumulate from both apps. Keep the desktop work to
  the client, the store and the hooks; it gets no new UI beyond the setting.
- **Where it runs (shadow).**
  - Every path that LLM-scores documents for a run: `systematic_review_tab._score_documents`, `mcp_server`'s
    `fact_check_claim`, `more_evidence`, `full_text_retry` (only where it scores new documents).
  - MANTA judges exactly the papers the LLM scores. Papers that the quality filter or the retraction screen leaves
    out before scoring are not judged, because they would have no reference.
  - `fact_check_claim` drops scores below its threshold. Every LLM score must be posted as a reference before
    that drop, or the 1–2 scores the comparison needs are lost.
  - A separate single worker sends the papers to MANTA alongside the LLM pool, so LLM scoring is not slowed. Each
    LLM score that arrives is posted back as a reference.
  - The run never waits for MANTA. Judgements still pending when the run finishes are completed in the background
    and stored. If the app quits first, they are left unjudged.
- **Design.**
  - MANTA's design is stored for every judged paper.
  - Every reference carries the paper's PubMed indexing as `indexing`, which the desktop already parses
    (`LiteDocument.publication_types`, `mesh_terms`). Add the record's MEDLINE `IndexingMethod` attribute
    (`Automated` or `Curated`; absent means human) to the PubMed parse and to the document.
  - Tier 2 (Haiku) runs only with the quality filter on (off by default) and only on papers that Tier 1 metadata
    left unresolved. Where it does run, Haiku's design is also sent, as `llm_design`. The report keeps the two
    references apart.
  - In the shadow stage, MANTA does not change `QualityManager`'s result.

### 3. The macOS Medical Fact Checker

- **Setting.** A MANTA URL in the macOS Settings, empty by default, which means off. iOS shows no
  setting.
- **BioMedLit.** A `MantaService` in `Packages/BioMedLit/Sources/BioMedLit/Services/` that calls the API above.
- **Document.**
  - New optional fields, following how `embeddingScore` was added: MANTA's expected score, probabilities as JSON,
    design, design probability, verdict, cut-off, revision and outcome.
  - The schema version changes if the migration plan needs it. Every field is optional, as CloudKit requires.
- **The workflow (shadow).**
  - `FactCheckWorkflow.scoreDocuments` and `scoreNewDocuments` start MANTA judgements as a separate task beside
    `CheckpointedScoringService`, one request at a time.
  - Each LLM score that arrives is posted back as a reference.
  - Stopping the workflow (`stopWork`) cancels the MANTA task as well.
- **Design.** The Mac app has no LLM design classifier, so its design reference is PubMed's indexing.
  - The Mac app sends the raw indexing to the server. The server maps it with `design_label` from
    `scripts/manta_benchmark.py`, moved into the server module, so the mapping exists once and is not ported to
    Swift. The reference is recorded with `llm_model = "pubmed-indexing"`. Papers whose indexing names no single
    design have no design reference.
  - **New work:** the Mac app stores publication types but never MeSH (`BioMedLitAdapters.swift` hard-codes
    `meshTerms: []`, and BioMedLit does not parse it). `design_label` needs MeSH for both cohort designs,
    case-control and cross-sectional.
  - So BioMedLit's `PubMedXMLParser` parses `MeshHeading/DescriptorName` and the `IndexingMethod` attribute, the
    adapter carries them, and `Document` stores them (`meshTerms` exists; the indexing method is new). This also
    serves the maintainer's rule that everything learned about a paper is kept. Europe PMC-only records carry no
    MEDLINE indexing and send none.

### 4. The comparison report

The report treats the LLM as the reference: a score of 3 or more counts as relevant, 1–2 as not. It reports:

- **Relevance.**
  - Papers judged by both.
  - **Wrongly screened out**: papers MANTA would screen out that the LLM scored 3 or more. This is the harm; each
    one is listed with its question, title and ids for the maintainer to read.
  - **Rightly screened out**: the LLM calls those were not needed (the saving).
  - **Screened in but scored 1–2 by the LLM**: the saving missed.
  - These are given at the cut-off in force and at a sweep of cut-offs. For each cut-off: the share of the
    LLM-relevant papers it keeps, and the share of the LLM 1–2 papers it drops.
  - Spearman ρ between MANTA's expected score and the LLM's score.
  - Counts of `unreachable` and `failed`, never folded into "screened in".
- **Design.**
  - Agreement and a confusion table, against Haiku and against PubMed indexing, each reported separately.
  - The indexing results are split by indexing method. The benchmark validated `design_label` only on
    human-indexed MEDLINE records, so automated indexing is reported apart and never pooled into the headline.
  - Calibration bins of MANTA's design probability.
- **Breakdowns** by app and by LLM model.

### 5. The screening stage (built later, from the shadow data)

- **The switch.** "Screen with MANTA" in both apps, off by default. The cut-off defaults to the shadow data's
  value at which no LLM-relevant paper was dropped, and is shown beside the switch.
- **Behaviour when it is on.**
  - A paper screened out is not sent to the LLM scorer. It is stored with the outcome "screened out by MANTA" and
    carries no relevance score. MANTA's decimal score never stands in for the LLM's whole-number score, which
    drives thresholds and counts. The paper is shown in its own "screened out by MANTA" group.
  - A random 10 % of screened-out papers are still scored by the LLM and posted as references, so a harm rate can
    be measured. The rate is a constant.
- **What the reader is told.**
  - The report's methods text says how many papers MANTA screened out, at what cut-off, and how many of those the
    audit checked.
  - The desktop audit trail (`audit_records.py`) gains a "screened out by MANTA" category.
  - The Mac app lists screened-out papers the way it lists retracted ones left out.
- **MANTA unavailable.** If MANTA is unreachable, the run scores every paper with the LLM and says once that
  screening was off for this run. It never screens with a missing verdict.

## Constraints

- **torch.** 2.15.0 on both macOS and CUDA, never MANTA's pinned 2.6. Re-measure the self-test on every torch or
  transformers bump.
- **Licence.** MANTA is Apache 2.0. Its base model's `LICENSE_base_model` is also Apache 2.0 (Qwen3.5-4B,
  copyright 2026 Alibaba Cloud; checked 2026-11-22). The server README names both licences. The model is
  downloaded by the user and never redistributed by this repo.
- **Prompt input.** MANTA was benchmarked with research questions. In the fact checker its input is a claim. The
  shadow report shows whether that matters; the prompt itself is not changed.
- **Truncation.** MANTA truncates at 4,096 tokens. Abstracts fit (the largest of the 570 benchmark prompts was
  1,508 tokens), and `truncated` is stored.
- **Speed.** About 1 s per paper on the M3 Max and 0.1–0.2 s on the DGX, so 200 papers take 3–4 minutes or about
  20 s, in the background. The shadow stage must never block a run.
- **App Transport Security.** The Mac app declares no ATS exceptions and needs none: it talks only to
  `127.0.0.1`.
- **Rules.** Golden rules apply on both platforms: no magic numbers (`constants.py`,
  `WorkflowConstants.swift`), and unreachable is not absent.

## Left to the builder

- The port default.
- Field and column names.
- Whether `/v1/judge` takes one task or both per call.
- Exactly how the background completion survives the end of a run.
- The report's text layout.
- Which four self-test items to use.
- The order of the PRs: server first, then desktop, then Mac (BioMedLit's MeSH parse can go first, on its own),
  each with its tests.
