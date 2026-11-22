# MANTA-4B Shadow Screener Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local MANTA-4B server, and a shadow stage in the desktop app and the macOS Medical Fact Checker.

- In the shadow stage, every paper the LLM scores is also judged by MANTA (relevance and design). Both verdicts go
  to a ledger, and a report compares them.
- Nothing the reader sees changes.

**Architecture:**

- `tools/manta_server/` is a stand-alone Python program with its own environment (torch 2.15). It serves MANTA on
  `127.0.0.1:8765` only and decides each verdict ("in" or "out" at `SHADOW_CUTOFF = 1.95`). It keeps a SQLite
  ledger of judgements and of the LLM references the apps post back, and prints the comparison report.
- **Desktop:** the app hooks the single point every LLM score passes through, `LiteScoringAgent.score_document`. A
  background worker sends the paper to MANTA, stores the judgement, and posts the LLM score back.
- **Mac app:** the app hooks `applyScoringResult` and `scoreNewDocuments`, and runs a serial `MantaShadow` actor.

**Tech Stack:**

- Server: Python 3.12 standard library (`http.server`, `sqlite3`), plus MANTA's requirements.
- Desktop: `requests`, SQLite.
- Mac: Swift, SwiftData, URLSession.

**Spec:** `docs/superpowers/specs/2026-11-22-manta-screener-design.md`. Read it with this plan.

## Global Constraints

- **Server dependencies.** torch 2.15.0 and torchvision 0.29.2 on macOS and CUDA, never MANTA's pinned 2.6. On
  CUDA: the cu132 index, then `flash-linear-attention==0.6.0 fla-core==0.6.0`, installed with `--no-deps`. Never
  causal-conv1d. Every other MANTA pin is unchanged.
- **Model revision.** `ae0db2a45edc065315001055d172e6b76cf60ba2`, refused otherwise unless `--any-revision`.
- **Localhost only.** The server binds `127.0.0.1` and has no `--host` and no token. The DGX is used through
  `ssh -L 8765:127.0.0.1:8765 dgx`, which is README text only.
- **Cut-off.** `SHADOW_CUTOFF = 1.95` on MANTA's expected score on the app's 1–5 scale. Verdict `"out"` when
  expected < cut-off, else `"in"`. Both verdicts are stored.
- **LLM reference.** A score of 3 or more is relevant (`RELEVANT_MIN_SCORE = 3`); 1–2 is not.
- **Self-test.** The server refuses to serve if any design answer differs, if any probability is NaN, or if any
  expected score differs by more than `0.05` from `selftest.json`.
- **No abstract text in the repo or the ledger.** Self-test inputs are authored, synthetic abstracts. The ledger
  stores ids and the question, never abstracts.
- **Desktop.** No new UI. The MANTA URL setting is empty by default, which means off. No torch in `pyproject.toml`.
- **Mac.** macOS only. iOS shows no setting, but the shared code must still compile for iOS. New `Document` fields
  are optional, with no schema version bump, following `publicationTypesJSON` (commit `8d16cd70`).
- **Unreachable is not absent.** Every paper sent to MANTA gets a stored outcome: `judged`, `unreachable` or
  `failed`. A paper never sent has none.
- **A run never waits for MANTA.** MANTA errors never reach scoring.
- **Code style.** Golden rules apply: Google-style docstrings, type hints, no magic numbers (`constants.py`,
  `WorkflowConstants.swift`, module-level constants in the server). Use the AGPL file header the repo uses.
- **Gates.**
  - `env -u VIRTUAL_ENV ./.venv/bin/python -m pytest tests/`.
  - `PATH="$PWD/.venv/bin:$PATH" env -u VIRTUAL_ENV python .github/scripts/lint_delta.py --base-ref origin/master`,
    which must show no new findings.
  - `swift test --package-path Packages/BioMedLit`.
  - `swift test --package-path ios/MedicalFactChecker`.
  - The macOS app builds:
    `xcodebuild -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj -scheme MedicalFactChecker -destination 'platform=macOS' build`.
  - `python3 .github/scripts/xcode_project_guards.py`.
- **Delivery.** One branch, `feat/manta-screener`, and one PR, with one commit per task.

## Review Focus

These are inputs the spec implies but no feature test would otherwise hit. Each has its test in the owning task.

1. **A paper with no abstract** (letters, editorials). The LLM still scores it, so MANTA judges it with an empty
   abstract rather than refusing it. (Task 3, `test_judge_empty_abstract`.)
2. **A prompt reaching MANTA's 4,096-token limit.** Judged, with `truncated` true and stored. Not an error.
   (Task 3, `test_judge_truncated_is_recorded`.)
3. **The server restarted between a judgement and its reference.** The reference still lands, because the ledger
   is on disk. (Task 2, `test_reference_after_reopen`.)
4. **The same paper's LLM score posted twice** (a rescore or retry). One reference row, replaced, not two. (Task 2,
   `test_reference_upsert`.)
5. **MANTA down when a run starts and up partway through.** Each paper gets its own outcome; a "down" state is
   never cached. (Task 7, `test_outage_then_recovery_per_paper`.)

---

## Phase A — the MANTA server (`tools/manta_server/`)

Tests import the server modules with `sys.path.insert(0, str(REPO / "tools" / "manta_server"))` at the top of each
test file. The module names are all prefixed `manta_` so they cannot collide on `sys.path`.

### Task 1: The shared protocol module, moved out of the benchmark

**Files:**

- Create: `tools/manta_server/manta_protocol.py`
- Modify: `scripts/manta_benchmark.py`. Remove the moved definitions and import them from `manta_protocol`, adding
  the path insert.
- Test: `tests/test_manta_protocol.py`. The existing `tests/test_manta_benchmark.py` must still pass unchanged
  (42 tests).

**Interfaces:**

- **Produces, moved verbatim from `scripts/manta_benchmark.py`:**
  - `RELEVANCE_LEVELS`, `RELEVANCE_INSTRUCTIONS`, `SCORE_MIN`, `DESIGN_OPTIONS`, `DESIGN_INSTRUCTIONS`,
    `DESIGN_GROUPS`.
  - The `_PT_*`, `_MH_*` and `_HUMAN_INDEXING` constants.
  - `design_label(publication_types, mesh_headings) -> str | None`.
  - `relevance_request(item_id, question, title, abstract) -> dict`.
  - `design_request(item_id, title, abstract) -> dict`.
  - `expected_score(level_probabilities) -> float`.
- **Produces, new:**
  - `SHADOW_CUTOFF: float = 1.95`.
  - `RELEVANT_MIN_SCORE: int = 3`.
  - `verdict(expected: float, cutoff: float = SHADOW_CUTOFF) -> str`, returning `"in"` or `"out"`.
  - `app_scale(level_probabilities: Mapping[str, float]) -> dict[str, float]`, which turns MANTA option ids
    `"0".."4"` into app levels `"1".."5"`.
  - `human_indexed(medline_status: str | None, indexing_method: str | None) -> bool`, the same rule as
    `PubMedRecord.human_indexed`.
  - `indexing_design(indexing: Mapping[str, Any] | None) -> tuple[str | None, bool | None]`. It returns
    `(design_label(...), human_indexed(...))`, or `(None, None)` for `None`.

- [ ] **Step 1: Write failing tests in `tests/test_manta_protocol.py`**

```python
def test_verdict_at_cutoff():
    assert manta_protocol.verdict(1.95) == "in"
    assert manta_protocol.verdict(1.9499) == "out"
    assert manta_protocol.SHADOW_CUTOFF == 1.95

def test_app_scale_shifts_levels():
    assert manta_protocol.app_scale({"0": 0.7, "4": 0.3}) == {"1": 0.7, "5": 0.3}

def test_human_indexed():
    assert manta_protocol.human_indexed("MEDLINE", None)
    assert manta_protocol.human_indexed("MEDLINE", "Manual")
    assert not manta_protocol.human_indexed("MEDLINE", "Automated")
    assert not manta_protocol.human_indexed("PubMed-not-MEDLINE", None)

def test_indexing_design():
    assert manta_protocol.indexing_design(None) == (None, None)
    got = manta_protocol.indexing_design({"publication_types": ["Journal Article"],
        "mesh_terms": ["Cohort Studies", "Retrospective Studies"],
        "medline_status": "MEDLINE", "indexing_method": "Automated"})
    assert got == ("cohort_retrospective", False)
```

- [ ] **Step 2:** Run `env -u VIRTUAL_ENV ./.venv/bin/python -m pytest tests/test_manta_protocol.py -q`. Expected:
  FAIL (no module).
- [ ] **Step 3:** Create `manta_protocol.py` with the moved definitions (a verbatim move: check the line ranges) and
  the new functions. Make `scripts/manta_benchmark.py` import every moved name, so its module namespace still has
  them (`PubMedRecord.human_indexed` keeps using `_HUMAN_INDEXING`).
- [ ] **Step 4:** Run `pytest tests/test_manta_protocol.py tests/test_manta_benchmark.py -q`. Expected: all pass,
  with the benchmark at 42.
- [ ] **Step 5:** Commit: `feat(manta): shared MANTA protocol module (requests, verdict, indexing design)`.

### Task 2: The ledger

**Files:**

- Create: `tools/manta_server/manta_ledger.py`
- Test: `tests/test_manta_ledger.py`

**Interfaces:**

- **Produces:**
  - `open_ledger(path: Path) -> sqlite3.Connection`. It creates the parent directory and the schema.
  - `@dataclass(frozen=True) Judgement`, with fields:
    - `judgement_id: str`, `app: str`, `question: str`, `ids: dict[str, str]`, `revision: str`
    - `relevance_probabilities: dict[str, float]` (app scale), `expected_score: float`, `verdict: str`,
      `cutoff: float`
    - `design: str | None`, `design_probability: float | None`, `design_probabilities: dict[str, float] | None`
    - `prompt_tokens: int`, `truncated: bool`, `seconds: float`, `created_at: str` (ISO, UTC)
  - `@dataclass(frozen=True) Reference`, with fields:
    - `judgement_id: str`, `app: str`, `llm_model: str`, `llm_score: int | None`, `llm_design: str | None`
    - `indexing: dict[str, Any] | None`, `indexing_design: str | None`, `human_indexed: bool | None`
    - `created_at: str`
  - `record_judgement(conn, j: Judgement) -> None`.
  - `record_reference(conn, r: Reference) -> bool`. It returns False, and writes nothing, for an unknown
    `judgement_id`. It upserts on `(judgement_id, llm_model)`.
  - `rows(conn) -> list[tuple[Judgement, list[Reference]]]`.
- **Schema:**
  - Table `judgements`, with the primary key `judgement_id`. Dicts are stored as JSON with `ensure_ascii=False`.
  - Table `references_` (`references` is reserved), with the primary key `(judgement_id, llm_model)`.
  - No abstract column.

- [ ] **Step 1: Write failing tests:**
  - `test_judgement_round_trip`: every field comes back equal.
  - `test_reference_unknown_judgement`: returns False, and leaves 0 reference rows.
  - `test_reference_upsert`: two posts for one model give one row, holding the second score.
  - `test_reference_after_reopen`: close, then `open_ledger` the same path; the reference is accepted.
  - `test_no_abstract_column`: `PRAGMA table_info(judgements)` has no column named like `abstract`.
- [ ] **Step 2:** Run `pytest tests/test_manta_ledger.py -q`. Expected: FAIL.
- [ ] **Step 3:** Implement the module.
- [ ] **Step 4:** Run the same. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(manta): server ledger of judgements and LLM references`.

### Task 3: The service and its HTTP API (with a stand-in model)

**Files:**

- Create: `tools/manta_server/manta_service.py`
- Create: `tests/manta_fakes.py`, which holds `FakeManta`, shared with Tasks 6–7.
- Test: `tests/test_manta_service.py`

**Interfaces:**

- **Consumes:** Task 1 (`relevance_request`, `design_request`, `expected_score`, `app_scale`, `verdict`,
  `indexing_design`) and Task 2.
- **Produces:**
  - `class Predictor(Protocol)`, with `def predict(self, request: dict) -> dict`. This is the shape of
    `Manta.predict`: `{"questions": {qid: {"probabilities": {...}, "answer": str}}, "prompt_tokens": int,
    "truncated": bool}`.
  - `@dataclass(frozen=True) SelfTestResult`, with fields `passed: bool`, `detail: str` and `at: str`.
  - `self_test(predictor: Predictor, cases: list[dict], tolerance: float = SELF_TEST_TOLERANCE) -> SelfTestResult`,
    where `SELF_TEST_TOLERANCE = 0.05`.
    - A case is `{"task": "relevance" | "design", "question"?, "title", "abstract", "expected_score"?, "answer"?}`.
    - It fails on NaN, on an expected score outside the tolerance, or on a different design answer. `detail` names
      the case.
  - `class MantaService`, with `__init__(self, predictor, ledger: sqlite3.Connection, revision: str,
    info: dict[str, Any], self_test: SelfTestResult)`. `info` holds `torch`, `device` and `fla_kernel`.
    - `health() -> dict` returns `{"ready", "revision", **info, "self_test": {"passed", "detail", "at"}}`.
    - `judge(payload: dict) -> dict`, the `/v1/judge` answer below. It takes one `threading.Lock` around
      `predict`.
    - `reference(payload: dict) -> bool`.
  - `class BadRequest(ValueError)` and `class NotReady(RuntimeError)`.
  - `make_server(service: MantaService, port: int = DEFAULT_PORT) -> ThreadingHTTPServer`, where
    `DEFAULT_PORT = 8765` and the bind is always `"127.0.0.1"`.
- **`POST /v1/judge` body:**
  - `{"app": str, "question": str, "title": str, "abstract": str, "ids": {str: str}, "tasks": ["relevance",
    "design"]}`.
  - `abstract` may be `""`. `tasks` defaults to both.
- **`POST /v1/judge` answer (200):**

  ```json
  {"judgement_id": "<uuid4>", "revision": "...", "seconds": 0.1, "prompt_tokens": 512, "truncated": false,
   "relevance": {"probabilities": {"1": 0.7, "2": 0.2, "3": 0.05, "4": 0.03, "5": 0.02},
                 "expected_score": 1.45, "verdict": "out", "cutoff": 1.95},
   "design": {"probabilities": {"rct": 0.9, "...": 0.1}, "answer": "rct", "probability": 0.9}}
  ```

  - `prompt_tokens` is the larger of the two requests'.
  - `truncated` is true when either request was truncated.
  - The judgement is written to the ledger before the answer goes back.
- **`POST /v1/reference` body:**
  - `{"judgement_id", "app", "llm_model", "llm_score": int | null, "llm_design": str | null, "indexing":
    {"publication_types": [...], "mesh_terms": [...], "medline_status": str | null, "indexing_method": str | null}
    | null}`.
  - The answer is 200 `{"ok": true}`, or 404 `{"error": "unknown judgement"}`.
- **Errors:**
  - 400 `{"error": ...}` for bad JSON or missing or mistyped fields.
  - 503 `{"error": "self-test failed: <detail>"}` for `/v1/*` when not ready.
  - 404 for any other path.

- [ ] **Step 1:** Write `tests/manta_fakes.py`.
  - `FakeManta(relevance: dict[str, float] | None = None, design: str = "rct", truncated: bool = False,
    fail_with: Exception | None = None)`.
  - Its `predict` returns Manta's shape, with MANTA option ids `"0".."4"` for relevance. It records every request
    in `.requests`.
- [ ] **Step 2: Write failing tests**, each starting a real server on port 0 in a thread and calling it with
  `requests`:
  - `test_health_ready`.
  - `test_judge_answer_shape`: the expected score with `FakeManta(relevance={"0": 1.0})` is 1.0, the verdict is
    `"out"` and the cut-off is 1.95. The ledger has one judgement.
  - `test_judge_empty_abstract`: 200, and the fake received `abstract == ""`.
  - `test_judge_truncated_is_recorded`: `truncated` is true in the answer and in the ledger.
  - `test_judge_bad_request`: a missing `question` gives 400.
  - `test_not_ready_refuses`: a service built with a failed `SelfTestResult` answers 503 on `/v1/judge`, and
    `/health` says `ready: false`.
  - `test_reference_unknown`: 404.
  - `test_binds_loopback_only`: `make_server(...).server_address[0] == "127.0.0.1"`.
  - `test_self_test_catches`: a NaN case fails, an expected score off by 0.06 fails, a different design answer
    fails, and an exact match passes.
- [ ] **Step 3:** Run `pytest tests/test_manta_service.py -q`. Expected: FAIL.
- [ ] **Step 4:** Implement `manta_service.py`.
- [ ] **Step 5:** Run the same. Expected: PASS.
- [ ] **Step 6:** Commit: `feat(manta): MANTA judging service with a localhost-only HTTP API and self-test`.

### Task 4: The real model, the CLI, the self-test fixture and the setup

**Files:**

- Create: `tools/manta_server/manta_model.py`
- Create: `tools/manta_server/manta_server.py`, the CLI.
- Create: `tools/manta_server/selftest.json`, `requirements-macos.txt`, `requirements-cuda.txt`, `README.md`.
- Test: `tests/test_manta_model.py`. It covers the revision check and the kernel probe only; torch is not in the
  project venv.

**Interfaces:**

- **Produces:**
  - `EXPECTED_REVISION = "ae0db2a45edc065315001055d172e6b76cf60ba2"`.
  - `read_revision(model_dir: Path) -> str | None`. It reads the download metadata that `hf download --local-dir`
    writes: the commit in `.cache/huggingface/download/*.metadata`, the first line of each file. A missing file
    gives None.
  - `fla_kernel_available() -> bool`. True when `from fla.ops.gated_delta_rule import chunk_gated_delta_rule`
    imports. Any exception gives False, because transformers swallows these.
  - `load_predictor(model_dir: Path, device: str) -> Predictor`. It does the `sys.path` insert of `model_dir`,
    `from manta import Manta` and `Manta.from_pretrained(str(model_dir), device=device)`.
- **The CLI:**
  - `python manta_server.py serve [--model ~/models/MANTA-4B] [--device mps|cuda|cpu] [--port 8765]
    [--ledger ~/.manta_server/ledger.db] [--any-revision]`. It checks the revision, loads the model, runs the
    self-test and serves. It logs the self-test result and whether the kernel is in use.
  - `python manta_server.py make-selftest --device cpu`. It reads `selftest.json`'s inputs and writes their
    reference `expected_score` or `answer` back in place.
  - `python manta_server.py report [LEDGER ...]`, built in Task 5.
- **`selftest.json`:** four cases, two relevance and two design (an RCT and a case-control study).
  - Each is a short abstract the builder writes, about 120 words, invented and copied from nowhere.
  - The relevance pair has one clearly relevant and one clearly irrelevant case, against an authored question.
  - The references come from a CPU float32 `make-selftest` run. Then validate on the M3 Max (MPS) and on the DGX
    (`ssh dgx`, venv `~/manta-spike/.venv`): `serve` must report the self-test passed on both.
- **`README.md`:**
  - Setup for each platform: the two requirements files, and the `--no-deps` second step on CUDA.
  - The download: `hf download gevaertlab/MANTA-4B --revision ae0db2a… --local-dir ~/models/MANTA-4B`, plus
    `shasum -a 256 -c SHA256SUMS`.
  - Starting the server.
  - The SSH tunnel for the DGX.
  - Both licences: Apache 2.0, MANTA's and Qwen3.5-4B's `LICENSE_base_model`.
  - Why torch is not MANTA's 2.6: the spike findings, in one paragraph.

- [ ] **Step 1: Write failing tests:**
  - `test_read_revision` from a temp dir with a fake `.cache/huggingface/download/config.json.metadata` whose
    first line is the revision.
  - `test_read_revision_missing`, which gives None.
  - `test_fla_probe_false_without_fla`, run in the project venv, where fla is absent.
- [ ] **Step 2:** Run `pytest tests/test_manta_model.py -q`. Expected: FAIL.
- [ ] **Step 3:** Implement `manta_model.py` and `manta_server.py`, and write the requirements files and the
  README.
- [ ] **Step 4:** Run the same. Expected: PASS.
- [ ] **Step 5:** Generate the fixture, in the spike env with torch 2.15:
  `python tools/manta_server/manta_server.py make-selftest --device cpu`.
- [ ] **Step 6: Validate the self-test on real hardware.**
  - Run `serve --device mps`, then `curl -s 127.0.0.1:8765/health`. Expected: `"ready": true`.
  - On the DGX, copy `tools/manta_server/` and run `serve --device cuda`. Expected: `"ready": true` and
    `"fla_kernel": true`.
  - Record both results in the README.
- [ ] **Step 7:** Commit: `feat(manta): model loader, CLI, self-test fixture, setup README`.

### Task 5: The comparison report

**Files:**

- Create: `tools/manta_server/manta_report.py`
- Modify: `tools/manta_server/manta_server.py` (the `report` subcommand).
- Test: `tests/test_manta_report.py`

**Interfaces:**

- **Consumes:**
  - Task 2's `rows`.
  - The benchmark's `spearman`, `wilson_interval` and `expected_calibration_error`, loaded from
    `scripts/manta_benchmark.py` with `importlib`, as `tests/test_manta_benchmark.py` does.
- **Produces:**
  - `SWEEP_CUTOFFS = (1.5, 1.75, 1.95, 2.0, 2.25, 2.5, 3.0)`.
  - `load_rows(paths: Sequence[Path]) -> list[tuple[Judgement, list[Reference]]]`. It merges ledgers, de-duplicated
    on `judgement_id`.
  - `relevance_report(rows) -> dict`, using only references with an `llm_score`. Keys:
    - `n`
    - `wrongly_out`, a list of `{question, ids, expected_score, llm_score, llm_model, app}`
    - `rightly_out`
    - `in_but_low`
    - `sweep`, a list of `{cutoff, keeps_relevant, drops_low}`, as shares
    - `spearman`
    - `judged_without_reference`
    - `by_app`
    - `by_llm_model`
  - `design_report(rows) -> dict`. It is computed separately for `llm_design` references and for indexing
    references. The indexing results are split by `human_indexed`: True, False, None. Each part has `n`,
    `agreement` with a Wilson interval, a `confusion` dict, and `calibration_bins`.
  - `render(relevance: dict, design: dict) -> str`, plain text.

- [ ] **Step 1: Write failing tests**, from a ledger built in a temp dir with Task 2's functions:
  - `test_wrongly_out_listed`: expected 1.5 and an LLM score of 4 appear in `wrongly_out`.
  - `test_counts`: `rightly_out` (1.5 against an LLM 1) and `in_but_low` (3.2 against an LLM 2).
  - `test_sweep_monotone`: as the cut-off rises, `keeps_relevant` never increases.
  - `test_merge_dedupes`: two ledger files holding the same judgement count it once.
  - `test_indexing_split`: human and automated indexing are reported apart.
  - `test_judged_without_reference_counted`.
- [ ] **Step 2:** Run `pytest tests/test_manta_report.py -q`. Expected: FAIL.
- [ ] **Step 3:** Implement the report and the `report` subcommand.
- [ ] **Step 4:** Run the same. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(manta): shadow comparison report over one or more ledgers`.

## Phase B — the desktop app

### Task 6: PubMed indexing kept, the MANTA client, and the setting

**Files:**

- Modify:
  - `src/bmlibrarian_lite/pubmed/data_types.py` (`ArticleMetadata`: add `medline_status: str | None = None` and
    `indexing_method: str | None = None`)
  - `src/bmlibrarian_lite/pubmed/search_client.py` (`_parse_single_article`: read the `MedlineCitation`
    `Status` and `IndexingMethod` attributes)
  - `src/bmlibrarian_lite/data_models.py` (`LiteDocument`: the same two fields)
  - `src/bmlibrarian_lite/storage.py`: add the two columns, the migration following
    `_migrate_document_publication_types`, and the upsert with `COALESCE`, as for `publication_types`.
  - The `ArticleMetadata` → `LiteDocument` conversion.
  - `src/bmlibrarian_lite/config.py`: a `MantaConfig(url: str = MANTA_DEFAULT_URL)`, at `LiteConfig.manta`,
    with `to_dict`/`from_dict` under `"manta"`.
  - `src/bmlibrarian_lite/constants.py`: `MANTA_DEFAULT_URL = ""`, `MANTA_REQUEST_TIMEOUT_SECONDS = 60`,
    `MANTA_APP_NAME = "desktop"`.
- Create: `src/bmlibrarian_lite/manta_client.py`
- Test: `tests/test_manta_client.py`, plus `tests/test_pubmed_indexing_fields.py` for the parse, storage round
  trip and migration.

**Interfaces:**

- **Produces:**
  - `@dataclass(frozen=True) MantaJudgement`, the `/v1/judge` answer flattened, with fields:
    - `judgement_id`, `revision`
    - `expected_score: float`, `relevance_probabilities: dict[str, float]`, `verdict: str`, `cutoff: float`
    - `design: str | None`, `design_probability: float | None`, `design_probabilities: dict[str, float] | None`
    - `seconds: float`, `truncated: bool`
  - `class MantaUnreachable(Exception)`, raised for a connection error or a timeout.
  - `class MantaRefused(Exception)`, with `status: int` and `message: str`. It is raised for a non-2xx answer, and
    for an unreadable 2xx answer with `status` 200 and message `"unreadable answer"`.
  - `class MantaClient`, with `__init__(self, base_url: str, session: requests.Session | None = None, timeout:
    float = MANTA_REQUEST_TIMEOUT_SECONDS)`.
    - It uses a plain `requests.Session`: the server is loopback, so it is not paced.
    - `judge(self, question: str, document: LiteDocument) -> MantaJudgement`. The `ids` are the document's
      `pmid`, `doi` and `pmc_id`, for those present.
    - `reference(self, judgement_id: str, llm_model: str, llm_score: int, document: LiteDocument) -> None`. The
      indexing comes from the document's `publication_types`, `mesh_terms`, `medline_status` and
      `indexing_method`, or is `null` when the document has no PMID.

- [ ] **Step 1: Write failing tests.**
  - The client tests run against the real `manta_service.make_server` and `FakeManta` (Tasks 3, 6) on port 0:
    - `test_judge_round_trip`
    - `test_reference_carries_indexing`: the ledger's reference row has the indexing and its design.
    - `test_unreachable`: a port with nothing listening raises `MantaUnreachable`.
    - `test_not_ready_is_refused`: a 503 raises `MantaRefused` with status 503.
  - The parse tests:
    - `test_parse_keeps_status_and_method`, on a minimal efetch XML with `<MedlineCitation Status="MEDLINE"
      IndexingMethod="Automated">`.
    - `test_document_round_trip_keeps_indexing`.
    - `test_migration_adds_columns`, on an old-shape `documents` table.
  - The config test: `test_manta_config_round_trip`, where the default URL is `""`.
- [ ] **Step 2:** Run `pytest tests/test_manta_client.py tests/test_pubmed_indexing_fields.py -q`. Expected:
  FAIL.
- [ ] **Step 3:** Implement the changes.
- [ ] **Step 4:** Run the same, plus `pytest tests/ -q -k "pubmed or storage or config"`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(manta): desktop MANTA client and setting; keep PubMed's indexing status`.

### Task 7: The store, the shadow worker and the scoring hook

**Files:**

- Create: `src/bmlibrarian_lite/manta_store.py`
- Create: `src/bmlibrarian_lite/manta_shadow.py`
- Modify: `src/bmlibrarian_lite/storage.py` (the schema at init, as for `citation_reads_store`, plus
  `record_manta_judgement(row: MantaRow) -> None` and `manta_judgements(document_id: str) -> list[MantaRow]`)
- Modify: `src/bmlibrarian_lite/agents/scoring_agent.py` (`score_document`, the success branch only)
- Modify: `CLAUDE.md` (the module map: `manta_client.py`, `manta_store.py`, `manta_shadow.py`, `tools/manta_server/`)
- Modify: `CHANGELOG.md` (Unreleased → Added)
- Test: `tests/test_manta_store.py`, `tests/test_manta_shadow.py`

**Interfaces:**

- **Consumes:** Task 6's client and config.
- **Produces:**
  - `manta_store.TABLE = "manta_judgements"`.
  - `@dataclass(frozen=True) MantaRow`, with fields:
    - `document_id`, `question`, `outcome` (`"judged" | "unreachable" | "failed"`)
    - `server_url`, `judgement_id: str | None`, `revision: str | None`
    - `expected_score: float | None`, `relevance_probabilities: dict | None`, `verdict: str | None`,
      `cutoff: float | None`
    - `design: str | None`, `design_probability: float | None`, `design_probabilities: dict | None`
    - `seconds: float | None`, `truncated: bool | None`
    - `reference_posted: bool`, `error: str | None`, `judged_at: str`
    - The primary key is `(document_id, question, judged_at)`, so each attempt is kept.
  - `class MantaShadow`, with `__init__(self, client: MantaClient, storage: LiteStorage, server_url: str)`.
    - `observe(self, question: str, document: LiteDocument, llm_score: int, llm_model: str) -> None`. It never
      blocks and never raises; it enqueues.
    - `drain(self, timeout: float) -> bool`, for tests.
    - One daemon worker thread. Per item, it judges, stores the row, posts the reference, then updates
      `reference_posted`.
    - `MantaUnreachable` gives an `unreachable` row. `MantaRefused` gives a `failed` row whose `error` is
      `redact_secrets(message)`.
    - A reference that fails leaves `reference_posted` False and logs a warning.
  - `shadow_for(config: LiteConfig) -> MantaShadow | None`. It returns None when `config.manta.url` is empty.
    Otherwise it returns one process-wide instance per URL, built under a module lock, with its own
    `LiteStorage(config)`.
- **The hook:** in `score_document`'s success branch, after building the `ScoredDocument`, call
  `shadow = shadow_for(self.config)`, then `shadow.observe(question, document, result["score"], self._get_model())`
  when it exists. Failures and negative scores are never observed. The hook adds nothing else.

- [ ] **Step 1: Write failing tests.**
  - `test_store_round_trip`.
  - `test_shadow_judges_and_posts_reference`: with the real server and `FakeManta`, there is one `judged` row with
    `reference_posted` True, and the ledger has the reference with the LLM score.
  - `test_unreachable_is_recorded`: the row's outcome is `unreachable`, and there is no reference.
  - `test_outage_then_recovery_per_paper`:
    - The shadow points at port P with nothing listening, and observes doc A.
    - Then the server starts on P, and the shadow observes doc B.
    - A is `unreachable`, B is `judged`.
  - `test_refused_is_failed`: a not-ready server gives a `failed` row with the error text.
  - `test_scoring_hook_observes_success_only`:
    - Patch `shadow_for` to return a recorder, and the LLM client to answer a score of 4.
    - One `observe` arrives, with 4 and the model string.
    - With a failing LLM, `observe` is never called.
  - `test_shadow_off_by_default`: `shadow_for(LiteConfig())` is None.
- [ ] **Step 2:** Run `pytest tests/test_manta_store.py tests/test_manta_shadow.py -q`. Expected: FAIL.
- [ ] **Step 3:** Implement the changes, and add the docs lines.
- [ ] **Step 4:** Run the full `pytest tests/ -q`, then `lint_delta.py`. Expected: 0 failures and no new findings.
  The 37 browser-rescue setup errors seen on master in full local runs don't count; compare against master's
  count.
- [ ] **Step 5:** Commit: `feat(manta): desktop shadow stage: every LLM-scored paper judged by MANTA beside it`.

## Phase C — the macOS Medical Fact Checker

### Task 8: BioMedLit parses MeSH and the indexing method

**Files:**

- Modify:
  - `Packages/BioMedLit/Sources/BioMedLit/Models/SearchProvider.swift` (`SearchArticle`: add
    `public var meshTerms: [String]?`, `public var medlineStatus: String?` and `public var indexingMethod: String?`,
    with init parameters defaulting to nil; nil means not recorded)
  - `Packages/BioMedLit/Sources/BioMedLit/Services/PubMedService.swift` (`PubMedXMLParser`)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/MeshIndexingParsingTests.swift`

**Parser rules:**

- On the `MedlineCitation` start, take the `Status` and `IndexingMethod` attributes.
- On the `MeshHeadingList` start, set the current terms to `[]`.
- On a `DescriptorName` end inside `MeshHeadingList` at `referenceDepth == 0`, append the trimmed text. Qualifier
  names are not terms.
- Add `"DescriptorName"` to `textElements`, and reset the three in `resetCurrentArticle`.

- [ ] **Step 1: Write failing tests** with the `PublicationTypeParsingTests` helper pattern:
  - `testKeepsMeshDescriptorsNotQualifiers`: two headings, one with a qualifier, give exactly the two descriptor
    names.
  - `testKeepsStatusAndIndexingMethod`: `"MEDLINE"` and `"Automated"`.
  - `testNoMeshListIsNil`.
- [ ] **Step 2:** Run `swift test --package-path Packages/BioMedLit --filter MeshIndexingParsingTests`. Expected:
  FAIL.
- [ ] **Step 3:** Implement the changes.
- [ ] **Step 4:** Run the same, then the full `swift test --package-path Packages/BioMedLit`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(biomedlit): keep PubMed MeSH descriptors, MEDLINE status and indexing method`.

### Task 9: BioMedLit `MantaService`

**Files:**

- Create: `Packages/BioMedLit/Sources/BioMedLit/Services/MantaService.swift`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/MantaServiceTests.swift`, using its own stub `URLProtocol`, in the
  pattern of `FullTextServiceParseWarningsTests.swift`.

**Interfaces (all `public`, `Sendable`):**

- `struct MantaJudgeRequest: Encodable`, with `app`, `question`, `title`, `abstract`, `ids: [String: String]` and
  `tasks: [String]`.
- `struct MantaJudgement: Decodable, Equatable`, with:
  - `judgementID`, `revision`, `seconds: Double`, `truncated: Bool`
  - `expectedScore: Double`, `relevanceProbabilities: [String: Double]`, `verdict: String`, `cutoff: Double`
  - `design: String?`, `designProbability: Double?`, `designProbabilities: [String: Double]?`
  - It decodes the nested `/v1/judge` JSON of Task 3 through explicit `CodingKeys`.
- `struct MantaIndexing: Encodable`, with `publicationTypes`, `meshTerms`, `medlineStatus` and `indexingMethod`.
  The JSON keys are snake_case.
- `struct MantaReference: Encodable`, with `judgementID`, `app`, `llmModel`, `llmScore: Int?`,
  `llmDesign: String?` and `indexing: MantaIndexing?`. The JSON keys match Task 3.
- `enum MantaServiceError: Error, Equatable`, with the cases `unreachable(String)`,
  `refused(status: Int, message: String)` and `unreadable`.
- `struct MantaService`, with `init(baseURL: URL, session: URLSession = .shared)`,
  `func judge(_ request: MantaJudgeRequest) async throws -> MantaJudgement` and
  `func reference(_ reference: MantaReference) async throws`.
  - A `URLError` maps to `unreachable`. A non-2xx answer maps to `refused`, with the `error` field as the message.
  - The timeout is a named constant, 60 s.

- [ ] **Step 1: Write failing tests:**
  - `testJudgeDecodes`, from a JSON literal shaped like Task 3's answer.
  - `testNotReadyIsRefused`: a 503 with `{"error": "self-test failed: x"}` gives `.refused(503, "self-test
    failed: x")`.
  - `testConnectionFailureIsUnreachable`.
  - `testReferenceBodyIsSnakeCase`: the recorded body has `judgement_id`, `llm_score` and `indexing.mesh_terms`.
- [ ] **Step 2:** Run `swift test --package-path Packages/BioMedLit --filter MantaServiceTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the service.
- [ ] **Step 4:** Run the same. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(biomedlit): MantaService client for the local MANTA server`.

### Task 10: The Mac app stores indexing and MANTA's judgement; the `MantaShadow` actor

**Files:**

- Modify: `ios/MedicalFactChecker/Sources/Utilities/BioMedLitAdapters.swift`. Replace the hard-coded
  `meshTerms: []` with `article.meshTerms ?? []`, and carry `medlineStatus` and `indexingMethod` through the
  metadata struct.
- Modify: `ios/MedicalFactChecker/Sources/Models/Document.swift`. New optional stored fields:
  - `medlineStatus: String?`, `indexingMethod: String?`
  - `mantaOutcome: String?` (`"judged" | "unreachable" | "failed"`), `mantaJudgementID: String?`,
    `mantaServerURL: String?`, `mantaRevision: String?`
  - `mantaExpectedScore: Double?`, `mantaRelevanceJSON: String?`, `mantaVerdict: String?`, `mantaCutoff: Double?`
  - `mantaDesign: String?`, `mantaDesignProbability: Double?`, `mantaDesignJSON: String?`
  - `mantaError: String?`, `mantaJudgedAt: Date?`
  - Plus `func applyManta(_ result: MantaShadowResult, serverURL: String)`.
- Create: `ios/MedicalFactChecker/Sources/Services/MantaShadow.swift`. Add it to `project.pbxproj` for every app
  target that compiles `Sources/Services`, with unique UUIDs (see how `d0c2aff4` added a file), then run
  `python3 .github/scripts/xcode_project_guards.py`.
- Modify: `ios/MedicalFactChecker/Sources/Models/AppSettings.swift`. Add
  `var mantaURL: String`, under UserDefaults key `"manta_url"`, default `""`.
- Test: `ios/MedicalFactChecker/Tests/MantaShadowTests.swift`. Also `StoreMigrationTests.swift`: an older-shape
  row reads nil for every new field.

**Interfaces:**

- `protocol MantaJudging: Sendable`, with `judge(_:) async throws -> MantaJudgement` and
  `reference(_:) async throws`. `MantaService` conforms through an extension in the app.
- `struct MantaShadowItem: Sendable`, with `pmid`, `claim`, `title`, `abstract`, `ids: [String: String]`,
  `llmScore: Int`, `llmModel: String` and `indexing: MantaIndexing?`.
- `struct MantaShadowResult: Sendable`, with `pmid`, `outcome: Outcome`, `judgedAt: Date` and `referencePosted: Bool`.
  `enum Outcome` has the cases `judged(MantaJudgement)`, `unreachable(String)` and `failed(String)`.
- `actor MantaShadow`, with `init(service: MantaJudging, onResult: @escaping @MainActor @Sendable
  (MantaShadowResult) -> Void)`.
  - `func observe(_ item: MantaShadowItem)`: items run one at a time, in order. Each is judged, then its reference
    posted (app `"macos"`), then `onResult` is called.
  - `func cancel()`: pending items are dropped, and results already delivered are kept.
- `Document.applyManta` writes the fields above. For `judged`, the probabilities are JSON-encoded. The
  `unreachable` and `failed` outcomes set `mantaOutcome` and `mantaError` and leave the scores nil.

- [ ] **Step 1: Write failing tests**, with a stub `MantaJudging`:
  - `testItemsRunInOrderAndPostReference`: two items give judge A, reference A, judge B, reference B. The
    reference carries the LLM score and model.
  - `testUnreachableHasNoReference`.
  - `testCancelDropsPending`.
  - `testApplyMantaJudged` and `testApplyMantaUnreachable`, on a `Document`.
  - `testAdapterKeepsMesh`: a `SearchArticle` with MeSH becomes a `Document` with `meshTerms` and
    `indexingMethod`.
  - The `StoreMigrationTests` nil assertions.
- [ ] **Step 2:** Run
  `swift test --package-path ios/MedicalFactChecker --filter 'MantaShadowTests|StoreMigrationTests'`. Expected:
  FAIL.
- [ ] **Step 3:** Implement the changes.
- [ ] **Step 4:** Run the same, then the full `swift test --package-path ios/MedicalFactChecker`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(apple): keep MeSH and indexing; MantaShadow actor and Document fields`.

### Task 11: Workflow wiring, the macOS setting, and the docs

**Files:**

- Modify: `ios/MedicalFactChecker/Sources/Services/FactCheckWorkflow.swift`:
  - Add `private var mantaShadow: MantaShadow?`. It is created when scoring starts, only when
    `URL(string: settings.mantaURL)` parses and is non-empty. Its `onResult` finds the document by PMID in
    `session.documents`, calls `applyManta`, and saves `modelContext`.
  - In the `applyScoringResult` success branch, and the `scoreNewDocuments` result loop's success path, call
    `observe`. The item is built from the document, `session.claim`, the score and `settings.llmModel`. Indexing
    is `nil` when the document has no PubMed indexing.
  - `stopWork` calls `cancel()`.
- Modify: `ios/MedicalFactChecker/Sources/macOS/Views/Settings/MacSettingsView.swift`. In the LLM tab, add a text
  field: "MANTA server URL (shadow benchmarking; empty = off)", with help text saying it is localhost only.
- Modify: `ios/MedicalFactChecker/Sources/Services/WorkflowConstants.swift`, if a constant is needed.
- Modify: `HANDOVER.md`. Add a Recently landed entry, plus the next step: run real fact checks, then read
  `manta_server.py report`. Prune it to under 500 lines.
- Modify: `CLAUDE.md`, the Mac and BioMedLit map lines (`MantaService`, `MantaShadow`).
- Modify: `CHANGELOG.md`.
- Test: `ios/MedicalFactChecker/Tests/MantaShadowTests.swift`, adding
  `testWorkflowObservesOnlySuccessfulScores` if the workflow can be driven with stub services, following
  `ScoringRetryTests`. If not, say so in the PR and rely on the manual check below.

- [ ] **Step 1:** Write the failing workflow test, where the harness allows it.
- [ ] **Step 2:** Run `swift test --package-path ios/MedicalFactChecker --filter MantaShadowTests`. Expected:
  FAIL.
- [ ] **Step 3:** Implement the wiring and the setting.
- [ ] **Step 4:** Run the full `swift test --package-path ios/MedicalFactChecker`, then the macOS `xcodebuild …
  build`, then `xcode_project_guards.py`. Expected: PASS, BUILD SUCCEEDED, and guards OK.
- [ ] **Step 5: Manual end to end.**
  - Start `serve --device mps`, and set the URL in the Mac app to `http://127.0.0.1:8765`.
  - Run one fact check.
  - Run `manta_server.py report`, which shows the judgements with `macos` references.
  - Then run one desktop fact check with `manta.url` set; the report shows `desktop` rows too.
- [ ] **Step 6:** Commit: `feat(apple): MANTA shadow stage in the macOS fact check`.
- [ ] **Step 7:** Run every gate in Global Constraints. Push, and open the PR to master, saying it implements the
  spec. If any issue is deferred, write "Deferred: #N", never a closing keyword.

---

## Departures from the spec, and why

- **The desktop store is keyed by document, question and time, not by checkpoint.** The MCP `fact_check_claim`
  path runs without a review checkpoint. The one hook in `score_document`, the single point every desktop LLM
  score passes through, also catches the scores `fact_check_claim` later drops below its threshold, which the
  spec required.
- **The desktop client uses a plain `requests.Session`, not the polite session.** The server is loopback only,
  and the polite pacing exists for remote hosts.
- **Relevance probabilities travel on the app's 1–5 scale (`"1".."5"`).** MANTA's own option ids `"0".."4"` stay
  inside the server.

## Deliberately not in this plan

- **Haiku's Tier 2 design as a reference.** It runs only with the quality filter on, which is off by default.
  Its results are already stored locally in `study_classifications`. PubMed indexing is the design reference in
  both apps for now.
- **The screening stage** (spec §5). It gets its own spec revision after the shadow report.
- **Unreachable and failed counts in the server report.** The server never sees those calls. They are in each
  app's store (`manta_judgements`, `Document.mantaOutcome`).
