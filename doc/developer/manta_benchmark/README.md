# MANTA decision models: relevance scoring and study design

Can [MANTA](https://huggingface.co/gevaertlab/MANTA-4B) (Gevaert Lab, Stanford; released 10 November 2026) take over two jobs our LLM agents do: scoring an abstract's relevance to a research question (`LiteScoringAgent`), and classifying its study design (`LiteStudyClassifier`)?

MANTA is a classifier, not a chat model. It reads a case and a set of questions with fixed options, and returns a probability for every option in one forward pass. It writes no text and no explanation. This benchmark holds MANTA-4B, and two free baselines the code base already has, to human labels. The harness is `scripts/manta_benchmark.py`; its offline tests are in `tests/test_manta_benchmark.py`.

**Run:** 19 November 2026. MANTA-4B at revision `ae0db2a45edc065315001055d172e6b76cf60ba2`, on CPU (4 Xeon cores with AMX-BF16; torch 2.6.0+cpu; transformers 5.19.0), BF16. flash-linear-attention was not installed: MANTA warns that its probabilities can then differ slightly from the published evaluation. No prompt reached MANTA's 4,096-token limit. MANTA-27B was not run: it needs about 60 GB of GPU memory.

**The app's own Claude agents, run on 20 November 2026:** `LiteScoringAgent` on Claude Sonnet 5.5 (the app's default model) and `LiteStudyClassifier` on Claude Haiku 5.5 (the app's Tier 2 classifier model). Both used their own prompts, with no failed call. Before the run the classifier's token limit was raised from 256 to 2048. Haiku 5.5 thinks by default, and its thinking counts against the limit. In a test on 40 of these abstracts, 13 answers stopped at 256 tokens (the longest needed 431). The app recorded those papers as "unknown". See [Running the Claude comparison](#running-the-claude-comparison).

## Results

### Relevance (TREC-COVID, 300 pairs, 50 questions)

| Metric | MANTA-4B | Claude Sonnet 5.5 (`LiteScoringAgent`) | App embedder (bge-small cosine) |
|---|---|---|---|
| Spearman ρ with the human grade | 0.617 [0.549, 0.679] | 0.619 [0.545, 0.689] | 0.505 [0.416, 0.587] |
| AUC, relevant (grade ≥ 1) vs not | 0.855 [0.817, 0.897] | 0.845 [0.804, 0.886] | 0.791 [0.735, 0.839] |
| AUC, fully relevant (2) vs the rest | 0.799 [0.750, 0.844] | 0.788 [0.734, 0.837] | 0.745 [0.686, 0.798] |
| Mean within-question AUC (≥ 1 vs 0) | 0.875 [0.843, 0.911] | 0.848 [0.812, 0.885] | 0.790 [0.746, 0.833] |
| Grade-0 pairs dropped while keeping 95 % of relevant pairs | 0.46 [0.31, 0.57] | 0.00² | 0.33 [0.17, 0.51] |
| Mean score: grade 0 / 1 / 2 | 1.66 / 2.44 / 3.01 | 1.39 / 2.39 / 3.16 | 0.67 / 0.72 / 0.75 (cosine) |
| Median seconds per pair | 3.9 (CPU) | 2.7 (API) | 0.2 (CPU) |

95 % intervals come from a bootstrap that resamples whole questions (1,000 draws), because pairs that share a question are not independent. MANTA's score is the expected level on the app's 1–5 scale. Its most probable level was 1 for 67 of the 100 grade-0 pairs, and 4 or 5 for 34 of the 100 grade-2 pairs. Claude gave 1 to 71 of the 100 grade-0 pairs, and 4 or 5 to 43 of the 100 grade-2 pairs. Claude's and MANTA's scores agree closely with each other (Spearman ρ 0.893).

² Claude's scores are whole numbers. It gave 23 of the 200 relevant pairs a 1, so the only cut-off that keeps 95 % of them keeps every pair. At a cut-off of 2 it keeps 88.5 % of relevant pairs and drops 71 % of grade-0 pairs.

### Study design (PubMed, 270 human-indexed abstracts, 30 per design)

| Metric | MANTA-4B | Claude Haiku 5.5 (`LiteStudyClassifier`) | bmlib keyword rules |
|---|---|---|---|
| Accuracy over the classifier's 13 options | **0.889** [0.846, 0.921] | 0.837 [0.788, 0.876] | 0.393 [0.336, 0.452] |
| Macro F1 | **0.898** | 0.858 | 0.467 |
| Accuracy, designs grouped¹ | **0.922** [0.884, 0.949] | 0.889 [0.846, 0.921] | 0.470 [0.412, 0.530] |
| Top-3 accuracy | 0.970 | — | — |
| ECE-15 of its confidence | 0.049 (top probability) | 0.066 (stated confidence) | — (no confidence) |
| No answer ("unknown") | 0 | 0 | 135 |
| Median seconds per abstract | 5.8 (CPU) | 1.5 (API) | < 0.01 |

¹ Systematic review with meta-analysis; prospective with retrospective cohort; case report with case series; editorial with letter.

Accuracy intervals are Wilson 95 % intervals. The two models gave the same design for 243 of the 270 abstracts. Recall per design:

| Design | MANTA-4B | MANTA's wrong answers | Haiku 5.5 | Haiku's wrong answers |
|---|---|---|---|---|
| Cross-sectional | 1.00 | — | 1.00 | — |
| RCT | 0.97 | other 1 | 0.97 | other 1 |
| Guideline | 0.97 | systematic review 1 | 0.93 | other 2 |
| Prospective cohort | 0.90 | cross-sectional 3 | 0.80 | cross-sectional 4, other 1, case series 1 |
| Retrospective cohort | 0.90 | prospective cohort 2, cross-sectional 1 | 0.87 | cross-sectional 3, other 1 |
| Meta-analysis | 0.90 | case-control 1, prospective cohort 1, systematic review 1 | **0.67** | systematic review 8, case-control 1, prospective cohort 1 |
| Systematic review | 0.90 | meta-analysis 3 | 0.97 | meta-analysis 1 |
| Case report | 0.87 | case series 3, systematic review 1 | 0.80 | case series 5, systematic review 1 |
| Case-control | **0.60** | cross-sectional 5, retrospective cohort 3, other 2, prospective cohort 1, case series 1 | **0.53** | cross-sectional 7, prospective cohort 2, other 2, case series 2, retrospective cohort 1 |

MANTA's probabilities are well calibrated on this task. Haiku's stated confidence is too high below 0.95:

| Confidence | MANTA answers | MANTA correct | Haiku answers | Haiku correct |
|---|---|---|---|---|
| below 0.5 | 18 | 50 % | 0 | — |
| 0.5 to 0.8 | 46 | 78 % | 41 | 54 % |
| 0.8 to 0.95 | 77 | 91 % | 100 | 77 % |
| 0.95 and above | 129 | 97 % | 129 | 98 % |

## Reading the results

- **Study design: MANTA-4B is at least as good as the app's own classifier.** It got 89 % of the 13-way classification right; Claude Haiku 5.5 got 84 % (the intervals overlap). The two gave the same answer for 243 of the 270 abstracts, and the errors of both are mostly between neighbouring designs. Haiku's main slip is calling 8 of the 30 meta-analyses systematic reviews. MANTA's confidence means what it says, and Haiku's stated confidence does not: Haiku's answers given 0.8 to 0.95 were right 77 % of the time. Calibration is what the cheap Tier 2 classifier needs, because a low-probability answer can be escalated to a stronger model or to a person. Case-control studies are the weak spot of both (60 % and 53 %). The keyword rules are no competition: they found no design at all for half of the abstracts.
- **Relevance: MANTA-4B ranks as well as the app's Sonnet scorer.** On every ranking measure the two are within each other's intervals (Spearman ρ 0.617 and 0.619), and their scores agree closely with each other (ρ 0.893). Both rank clearly better than the embedding cosine, which the app already computes for nothing. Neither matches the human grades well: Claude gave 23 of the 200 relevant pairs its lowest score, and MANTA's most probable level was one of its bottom two for 29 of the 100 fully relevant pairs. So MANTA could replace the scorer's number, or sit in front of it as a pre-filter: at a cut-off keeping 95 % of relevant pairs, it would drop about half the non-relevant ones (31–57 %).
- **Some of the relevance "misses" are the labels.** TREC-COVID's judged pairs were pooled from search engines' top hits, so grade-0 pairs are hard negatives, and some grade-2 judgements are generous. Among the five grade-2 pairs MANTA scored lowest are a paper on competency-based medical education judged fully relevant to "benefits and risks of re-opening schools", and an engineering-response paper judged fully relevant to "how long can the coronavirus live outside the body". That the two models agree with each other more than with the grades points the same way.
- **MANTA cannot explain itself.** Neither job gets an explanation: `ScoredDocument.explanation` would be empty, and so would the audit trail's reasons. The Claude scorer writes one for every paper.

## Caveats

- **Possible training overlap.** The model card lists "research abstracts and claims" and "clinical-trial records" among its training text, but names no text sources. PubMed abstracts with their publication types, and CORD-19 with TREC-COVID's judgements, could have been in its training data. Nothing here can rule that out, so these figures may flatter MANTA. A check on papers newer than its training would settle it.
- **The design labels are the indexers' labels, not ground truth.** NLM's human indexers made them (2015–2020, `IndexingMethod` Manual), and they are sometimes wrong. At least one RCT-labelled record is a trial protocol. The rules in `design_label` refuse records whose headings name two designs, so mixed-design papers are under-represented. Classes are balanced (30 each), so accuracy here is not what a real search result, which is mostly observational studies, would give.
- **One domain for relevance.** TREC-COVID is COVID-19 only, and its questions are short.
- **Speed.** Times are CPU times on 4 cores. The card gives 68 ms a request on one H100.

## How the corpora were made

**Relevance.** TREC-COVID as BEIR distributes it: corpus and questions at `BeIR/trec-covid@7e16fde3`, human judgements at `BeIR/trec-covid-qrels@532ac68e`. For each of the 50 questions, two pairs were drawn at random (seed 1) per grade, from documents that have an abstract. MANTA got one `score` question with the app's five relevance levels, lowest first. The state held the research question and the article's title and abstract.

**Study design.** For each of 9 designs, the script ran a PubMed pre-filter for each year 2015–2020, restricted to English MEDLINE records with an abstract (see `DESIGN_QUERIES`). It drew 90 records at random (seed 1) and kept the first 30 that were human-indexed (`Status="MEDLINE"`, `IndexingMethod` Manual or absent) and whose own publication types and MeSH headings give that design under `design_label`. MANTA got one `choice` question over the 13 options of `LiteStudyClassifier`, with the title and abstract only. Neither evaluator saw the publication types or MeSH headings.

The label files (`relevance_labels.jsonl`, `design_labels.jsonl`) hold identifiers and labels only, because the abstracts carry their publishers' licences. `materialise` fetches the texts again. The prediction files in `predictions/` hold no abstract text. The Claude scorer's explanations are its own words: one of the 300 quotes a phrase of ten words or more from its abstract.

## Reproducing

```bash
# Texts of the committed labels (pyarrow needed for the BEIR files)
python scripts/manta_benchmark.py materialise relevance \
    doc/developer/manta_benchmark/relevance_labels.jsonl tmp/manta_benchmark/relevance_items.jsonl
python scripts/manta_benchmark.py materialise design \
    doc/developer/manta_benchmark/design_labels.jsonl tmp/manta_benchmark/design_items.jsonl

# MANTA, in a separate venv with the model repository's requirements.txt
# (on CPU: torch from the CPU index, flash-linear-attention left out)
hf download gevaertlab/MANTA-4B --local-dir ~/models/MANTA-4B
python scripts/manta_benchmark.py run-manta relevance \
    tmp/manta_benchmark/relevance_items.jsonl preds/relevance_manta-4b.jsonl \
    --model ~/models/MANTA-4B --device cpu      # or --device cuda

# Baselines
python scripts/manta_benchmark.py run-embed tmp/manta_benchmark/relevance_items.jsonl preds/relevance_embedding.jsonl
python scripts/manta_benchmark.py run-rules tmp/manta_benchmark/design_items.jsonl preds/design_bmlib-rules.jsonl

# Tables
python scripts/manta_benchmark.py analyse relevance \
    doc/developer/manta_benchmark/relevance_labels.jsonl doc/developer/manta_benchmark/predictions/relevance_*.jsonl
python scripts/manta_benchmark.py analyse design \
    doc/developer/manta_benchmark/design_labels.jsonl doc/developer/manta_benchmark/predictions/design_*.jsonl
```

MANTA's runs are resumable: a run that stops skips the ids it has already answered.

## Running the Claude comparison

In the project venv, with `ANTHROPIC_API_KEY` set (570 calls; `materialise` first):

```bash
python scripts/manta_benchmark.py run-llm relevance tmp/manta_benchmark/relevance_items.jsonl \
    doc/developer/manta_benchmark/predictions/relevance_claude-sonnet-5-5.jsonl --model anthropic:claude-sonnet-5-5
python scripts/manta_benchmark.py run-llm design tmp/manta_benchmark/design_items.jsonl \
    doc/developer/manta_benchmark/predictions/design_claude-haiku-5-5.jsonl --model anthropic:claude-haiku-5-5
```

These calls run the app's own agents with their own prompts. A failed call (an unreachable provider, a refused key) is marked `failed`, is retried when the run is started again, and is counted apart in the analysis, never as a score. Then re-run `analyse` to get the Claude columns.
