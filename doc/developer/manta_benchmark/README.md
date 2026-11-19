# MANTA decision models: relevance scoring and study design

Can [MANTA](https://huggingface.co/gevaertlab/MANTA-4B) (Gevaert Lab, Stanford; released 10 November 2026) take over two jobs our LLM agents do: scoring an abstract's relevance to a research question (`LiteScoringAgent`), and classifying its study design (`LiteStudyClassifier`)?

MANTA is a classifier, not a chat model. It reads a case and a set of questions with fixed options, and returns a probability for every option in one forward pass. It writes no text and no explanation. This benchmark holds MANTA-4B, and two free baselines the code base already has, to human labels. The harness is `scripts/manta_benchmark.py`; its offline tests are in `tests/test_manta_benchmark.py`.

**Run:** 19 November 2026. MANTA-4B at revision `ae0db2a45edc065315001055d172e6b76cf60ba2`, on CPU (4 Xeon cores with AMX-BF16; torch 2.6.0+cpu; transformers 5.19.0), BF16. flash-linear-attention was not installed: MANTA warns that its probabilities can then differ slightly from the published evaluation. No prompt reached MANTA's 4,096-token limit. MANTA-27B was not run: it needs about 60 GB of GPU memory.

**Not run: the app's own Claude agents.** This cloud session could not hold an Anthropic key, so `LiteScoringAgent` and `LiteStudyClassifier` have no column here yet. To add them, see [Adding the Claude comparison](#adding-the-claude-comparison).

## Results

### Relevance (TREC-COVID, 300 pairs, 50 questions)

| Metric | MANTA-4B | App embedder (bge-small cosine) |
|---|---|---|
| Spearman ρ with the human grade | **0.617** [0.549, 0.679] | 0.505 [0.416, 0.587] |
| AUC, relevant (grade ≥ 1) vs not | **0.855** [0.817, 0.897] | 0.791 [0.735, 0.839] |
| AUC, fully relevant (2) vs the rest | **0.799** [0.750, 0.844] | 0.745 [0.686, 0.798] |
| Mean within-question AUC (≥ 1 vs 0) | **0.875** [0.843, 0.911] | 0.790 [0.746, 0.833] |
| Grade-0 pairs dropped while keeping 95 % of relevant pairs | **0.46** [0.31, 0.57] | 0.33 [0.17, 0.51] |
| Mean score: grade 0 / 1 / 2 | 1.66 / 2.44 / 3.01 | 0.67 / 0.72 / 0.75 (cosine) |
| Median seconds per pair (CPU) | 3.9 | 0.2 |

95 % intervals come from a bootstrap that resamples whole questions (1,000 draws), because pairs that share a question are not independent. MANTA's score is the expected level on the app's 1–5 scale. Its most probable level was 1 for 67 of the 100 grade-0 pairs, and 4 or 5 for 34 of the 100 grade-2 pairs.

### Study design (PubMed, 270 human-indexed abstracts, 30 per design)

| Metric | MANTA-4B | bmlib keyword rules |
|---|---|---|
| Accuracy over the classifier's 13 options | **0.889** [0.846, 0.921] | 0.393 [0.336, 0.452] |
| Macro F1 | **0.898** | 0.467 |
| Accuracy, designs grouped¹ | **0.922** [0.884, 0.949] | 0.470 [0.412, 0.530] |
| Top-3 accuracy | 0.970 | — |
| ECE-15 of its top probability | 0.049 | — (no confidence) |
| No answer ("unknown") | 0 | 135 |
| Median seconds per abstract (CPU) | 5.8 | < 0.01 |

¹ Systematic review with meta-analysis; prospective with retrospective cohort; case report with case series; editorial with letter.

Accuracy intervals are Wilson 95 % intervals. Recall per design for MANTA-4B:

| Design | Recall | MANTA's wrong answers |
|---|---|---|
| Cross-sectional | 1.00 | — |
| RCT | 0.97 | other 1 |
| Guideline | 0.97 | systematic review 1 |
| Prospective cohort | 0.90 | cross-sectional 3 |
| Retrospective cohort | 0.90 | prospective cohort 2, cross-sectional 1 |
| Meta-analysis | 0.90 | case-control 1, prospective cohort 1, systematic review 1 |
| Systematic review | 0.90 | meta-analysis 3 |
| Case report | 0.87 | case series 3, systematic review 1 |
| Case-control | **0.60** | cross-sectional 5, retrospective cohort 3, other 2, prospective cohort 1, case series 1 |

MANTA's probabilities are well calibrated on this task:

| Top probability | Answers | Correct |
|---|---|---|
| below 0.5 | 18 | 50 % |
| 0.5 to 0.8 | 46 | 78 % |
| 0.8 to 0.95 | 77 | 91 % |
| 0.95 and above | 129 | 97 % |

## Reading the results

- **Study design: MANTA-4B is good enough to use.** It got 89 % of the 13-way classification right, the errors are mostly between neighbouring designs, and its confidence means what it says. That last point is what the cheap Tier 2 classifier needs: a low-probability answer can be escalated to a stronger model or to a person. Case-control studies are its weak spot (60 %), and it never answered "unknown". The keyword rules are no competition: they found no design at all for half of the abstracts.
- **Relevance: better than the free baseline, not good enough to stand alone.** MANTA ranks pairs clearly better than the embedding cosine, which the app already computes for nothing. But 29 of the 100 fully relevant pairs got one of its bottom two levels as the most probable, and 33 of the 100 non-relevant pairs got level 2 or higher. The best use would be as a pre-filter in front of the LLM scorer: at a cut-off keeping 95 % of relevant pairs, it would drop about half the non-relevant ones (31–57 %).
- **Some of the relevance "misses" are the labels.** TREC-COVID's judged pairs were pooled from search engines' top hits, so grade-0 pairs are hard negatives, and some grade-2 judgements are generous. Among the five grade-2 pairs MANTA scored lowest are a paper on competency-based medical education judged fully relevant to "benefits and risks of re-opening schools", and an engineering-response paper judged fully relevant to "how long can the coronavirus live outside the body". Part of the remaining gap is therefore not MANTA's.
- **It cannot explain itself.** Neither job gets an explanation: `ScoredDocument.explanation` would be empty, and so would the audit trail's reasons.

## Caveats

- **Possible training overlap.** The model card lists "research abstracts and claims" and "clinical-trial records" among its training text, but names no text sources. PubMed abstracts with their publication types, and CORD-19 with TREC-COVID's judgements, could have been in its training data. Nothing here can rule that out, so these figures may flatter MANTA. A check on papers newer than its training would settle it.
- **The design labels are the indexers' labels, not ground truth.** NLM's human indexers made them (2015–2020, `IndexingMethod` Manual), and they are sometimes wrong. At least one RCT-labelled record is a trial protocol. The rules in `design_label` refuse records whose headings name two designs, so mixed-design papers are under-represented. Classes are balanced (30 each), so accuracy here is not what a real search result, which is mostly observational studies, would give.
- **One domain for relevance.** TREC-COVID is COVID-19 only, and its questions are short.
- **Speed.** Times are CPU times on 4 cores. The card gives 68 ms a request on one H100.

## How the corpora were made

**Relevance.** TREC-COVID as BEIR distributes it: corpus and questions at `BeIR/trec-covid@7e16fde3`, human judgements at `BeIR/trec-covid-qrels@532ac68e`. For each of the 50 questions, two pairs were drawn at random (seed 1) per grade, from documents that have an abstract. MANTA got one `score` question with the app's five relevance levels, lowest first. The state held the research question and the article's title and abstract.

**Study design.** For each of 9 designs, the script ran a PubMed pre-filter for each year 2015–2020, restricted to English MEDLINE records with an abstract (see `DESIGN_QUERIES`). It drew 90 records at random (seed 1) and kept the first 30 that were human-indexed (`Status="MEDLINE"`, `IndexingMethod` Manual or absent) and whose own publication types and MeSH headings give that design under `design_label`. MANTA got one `choice` question over the 13 options of `LiteStudyClassifier`, with the title and abstract only. Neither evaluator saw the publication types or MeSH headings.

The label files (`relevance_labels.jsonl`, `design_labels.jsonl`) hold identifiers and labels only, because the abstracts carry their publishers' licences. `materialise` fetches the texts again. The prediction files in `predictions/` hold no abstract text.

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

## Adding the Claude comparison

In the project venv, with `ANTHROPIC_API_KEY` set (about 570 calls):

```bash
python scripts/manta_benchmark.py run-llm relevance tmp/manta_benchmark/relevance_items.jsonl \
    doc/developer/manta_benchmark/predictions/relevance_claude-sonnet-5-5.jsonl --model anthropic:claude-sonnet-5-5
python scripts/manta_benchmark.py run-llm design tmp/manta_benchmark/design_items.jsonl \
    doc/developer/manta_benchmark/predictions/design_claude-haiku-5-5.jsonl --model anthropic:claude-haiku-5-5
```

These calls run the app's own agents with their own prompts. A failed call (an unreachable provider, a refused key) is marked `failed`, is retried when the run is started again, and is counted apart in the analysis, never as a score. Then re-run `analyse` to get the Claude columns.
