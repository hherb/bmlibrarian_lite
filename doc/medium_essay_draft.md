# AI-Powered Medical Fact-Checking in Your Pocket: How BMLibrarian Lite Fights Health Misinformation

*An open-source tool that lets anyone verify medical claims against peer-reviewed literature — on desktop, iPhone, or Android.*

---

## The Problem We All Face

A friend sends you a WhatsApp message: "I read that ivermectin cures long COVID." A patient asks their doctor about a supplement they saw promoted on TikTok. A journalist needs to verify a health claim before publication deadline.

In each case, the same question arises: **what does the actual scientific evidence say?**

Finding the answer traditionally requires navigating PubMed's arcane search syntax, reading dozens of abstracts, mentally weighing study quality, and synthesizing a conclusion — skills that take years to develop and hours to execute. Most people, even many healthcare professionals pressed for time, simply can't do this for every claim they encounter.

That's the gap BMLibrarian Lite was built to fill.

## What BMLibrarian Lite Does

BMLibrarian Lite is an open-source biomedical literature research tool that uses AI to automate the systematic review process. Give it a medical claim or research question in plain English, and it will:

1. **Translate your question** into optimized search queries for biomedical databases
2. **Search PubMed and Europe PMC** — the world's largest repositories of biomedical research — retrieving relevant articles
3. **Score each document for relevance** using large language models, with rationales explaining why each paper matters (or doesn't)
4. **Analyze study transparency** — automatically flagging undisclosed conflicts of interest, industry funding, restricted data, and unregistered trials
5. **Extract key citations** — pulling the specific passages that support or refute the claim, with direction classification
6. **Generate an evidence report** — a structured synthesis with a verdict, supporting citations, and risk warnings about potential bias

The entire process takes 1-3 minutes and costs pennies in API fees.

## Available Everywhere You Need It

### Desktop: The Full Research Workstation

The Python desktop application (built with PySide6) is the most feature-rich version, designed for researchers and healthcare professionals doing serious systematic literature review.

Beyond the core fact-checking workflow, the desktop app offers:

- **Research Questions Management**: Save questions, re-run searches months later to find new publications, and track how the evidence landscape evolves
- **Multi-Model Benchmarking**: Compare how different AI models (Claude, GPT, Llama, Mistral, DeepSeek) score the same documents — a built-in check on AI reliability
- **Document Interrogation**: Load a PDF and have a conversation with it — ask follow-up questions and get answers grounded in the actual text
- **Audit Trail**: Full transparency into every step of the review, from generated search queries to individual scoring rationales
- **Quality Assessment**: Automated classification of study designs (RCT, meta-analysis, cohort study, etc.) with evidence grading

Installation is as simple as `pip install bmlibrarian-lite`.

### MCP Server: Give Claude Your Own Medical Fact-Checker

One of the most powerful recent additions is the **Model Context Protocol (MCP) server**. This turns BMLibrarian Lite into a tool that Claude Desktop, Claude Code, or any MCP-compatible AI assistant can use directly.

Imagine asking Claude: "Is there evidence that meditation reduces blood pressure?" Instead of relying on its training data, Claude can now call BMLibrarian Lite to search PubMed in real time, score the results, and return a properly cited evidence synthesis — complete with transparency analysis of the underlying studies.

The MCP server exposes four tools:

- **`fact_check_claim`** — the full pipeline from question to evidence report, with real-time progress notifications
- **`search_literature`** — quick literature searches for exploratory research
- **`get_document_fulltext`** — retrieve the full text of any article by its PubMed ID, DOI, or PMC ID
- **`ask_document`** — RAG-powered Q&A on retrieved documents

This means you can build workflows where AI assistants have access to live biomedical evidence — not just what was in their training data, but what was published yesterday.

### iOS & macOS: Medical Fact-Checking On the Go

The native iOS app (MedicalFactChecker) brings the same evidence-based workflow to your iPhone and iPad. Built with SwiftUI and SwiftData, it feels like a first-class iOS citizen:

- **Six LLM providers**: Choose from Anthropic Claude, OpenAI, DeepSeek, Groq, Mistral, or your own Ollama server — models are fetched dynamically from provider APIs
- **Dual scoring**: LLM-based scoring plus optional on-device Apple NLEmbedding for semantic similarity — the embedding scoring runs entirely on-device at zero API cost
- **HyDE (Hypothetical Document Embedding)**: The app generates a synthetic "ideal" abstract for your claim and uses it to improve semantic matching — a technique from cutting-edge information retrieval research
- **Smart search**: When initial results aren't sufficient, the AI automatically generates 2-3 alternative search strategies (trying synonyms, broader terms, or splitting compound questions) and searches again
- **Full-text access**: A four-tier fallback chain (Europe PMC XML, Europe PMC PDF, Unpaywall, DOI) means you can often read the full paper, not just the abstract
- **Budget controls**: Set per-run and monthly spending limits — typical fact-checks cost $0.01-$0.03 with Claude Sonnet
- **iCloud sync**: Optionally sync your sessions across iPhone, iPad, and Mac
- **PDF export**: Generate polished evidence reports to share with colleagues

The macOS app shares the same codebase through the BioMedLit Swift Package, providing an optimized desktop experience with keyboard navigation and larger layouts.

### Android: The Same Power with Material Design

The Android app (built with Kotlin, Jetpack Compose, and Material 3) brings full feature parity to the Android ecosystem:

- **Same workflow, native feel**: Material You design that adapts to your device's color scheme
- **Smart search**: Identical alternative query generation to iOS — when initial results are sparse, the AI finds better search strategies
- **HyDE embedding**: Same hypothetical document embedding technique for improved retrieval
- **Parallel processing**: Semaphore-based concurrent scoring and citation extraction with real-time progress updates
- **Europe PMC PDF fallback**: When XML full text isn't available but a free PDF exists, the app uses it automatically — no extra API calls
- **Secure storage**: API keys are stored using Android's EncryptedSharedPreferences; all data stays on your device
- **Room database**: Robust local persistence with automatic schema migrations across five database versions

## The Transparency Layer: Why It Matters

Perhaps the most important feature across all platforms is the **Study Transparency Analysis**. When you're evaluating medical evidence, knowing *what* a study found isn't enough — you need to know *who funded it, whether the authors disclosed conflicts of interest, whether the data is available for independent verification, and whether the trial was properly registered*.

BMLibrarian Lite automatically analyzes each relevant document for:

- **Funding disclosure**: Who paid for this research? Was it industry-funded? The analyzer detects not just direct pharmaceutical funding but also **institutional intermediaries** — cases where industry money flows through universities or foundations
- **Conflict of interest**: A multi-pass analysis that matches against 40+ known pharmaceutical companies, detects institutional intermediary patterns, and flags blanket denials that contradict other evidence in the paper
- **Data availability**: Does the study share its data? The analyzer goes beyond simple statements to detect **effective refusals** — language like "data available upon reasonable request" from studies where sponsor confidentiality agreements make that request practically impossible
- **Trial registration**: Is the trial registered on ClinicalTrials.gov? Were results posted? Is there evidence of **outcome switching** — changing what the trial measured after seeing the data?

These findings appear as color-coded risk badges on every document card, with detailed breakdowns available on tap. They're also aggregated into the final evidence report as risk warnings.

This matters because industry-funded studies with undisclosed conflicts of interest are [significantly more likely to report favorable results](https://doi.org/10.1136/bmj.d7373). BMLibrarian Lite doesn't just tell you what the evidence says — it helps you judge how much to trust it.

## Under the Hood: How It Works

The architecture reflects a key design philosophy: **the same algorithms on every platform, adapted to each platform's strengths**.

Cross-platform algorithm specifications (in `doc/cross_platform/`) ensure that parallel processing, full-text retrieval, hybrid search, JATS XML parsing, and sync protocols behave identically whether implemented in Python, Swift, or Kotlin.

The full-text discovery chain illustrates this approach. On all platforms, when you want to read a paper:

1. Try **Europe PMC XML** — the best format, machine-readable with structure preserved
2. Try **Europe PMC PDF** — the free PDF render URL extracted from search results (no extra API call)
3. Try **Unpaywall** — open-access PDFs from publishers
4. Fall back to **DOI resolution** — a link to the publisher's website

The JATS XML parser (Journal Article Tag Suite) converts PubMed Central's XML format into readable markdown or HTML, preserving figures, tables, references, and section structure. Each platform has its own parser implementation (Python, Swift, Kotlin) following the same specification.

Similarly, the parallel processing system uses platform-appropriate concurrency primitives — Python's asyncio, Swift's structured concurrency with actors, Kotlin's coroutines with semaphores — but follows the same algorithm: automatic concurrency detection, per-document checkpointing, incremental result callbacks, and graceful cancellation.

## What It Costs

BMLibrarian Lite itself is free and open-source (AGPL-3.0). The only cost is the API fees for whatever LLM provider you choose:

| Provider | Typical Cost per Fact-Check |
|----------|---------------------------|
| Claude Sonnet | $0.01 - $0.03 |
| GPT-4o Mini | $0.001 - $0.003 |
| DeepSeek V3 | $0.002 - $0.005 |
| Llama (via Groq) | $0.001 - $0.003 |
| Ollama (local) | Free |

Budget controls on mobile apps ensure you never spend more than you intend.

## Who Is This For?

- **Healthcare professionals** who want to quickly check claims before or during patient consultations
- **Medical journalists** who need to verify health claims on deadline
- **Researchers** who want a faster first pass through the literature
- **Students** learning to evaluate medical evidence
- **Patients and advocates** who want to understand the evidence behind treatments they're considering — as a starting point for informed discussions with their doctors, never as a substitute for professional medical advice
- **Anyone** tired of trying to separate medical fact from social media fiction

**Important:** BMLibrarian Lite is **not** a replacement for professional medical advice. For patients, the output should be used as a basis for informed conversation with your healthcare provider — never as a reason to self-diagnose, self-treat, or override your doctor's recommendations. It's a tool that makes the peer-reviewed evidence more accessible — and more transparent — for everyone.

## Getting Started

**Desktop:**
```bash
pip install bmlibrarian-lite
export ANTHROPIC_API_KEY="your-key"
bmll
```

**MCP Server (for Claude Desktop/Code):**
```bash
uv tool install bmlibrarian-lite
bmlibrarian-lite-mcp
```

**iOS/macOS:** Available on the [App Store](https://apps.apple.com/) as MedicalFactChecker (v1.5 update with parallel processing pending review).

**Android:** Build from source with Android Studio (Google Play submission forthcoming).

The full source code is available at [github.com/hherb/bmlibrarian_lite](https://github.com/hherb/bmlibrarian_lite).

## What's Next

BMLibrarian Lite is under active development. The iOS/macOS app is already on the App Store with a v1.5 update (parallel processing, smart search, enhanced transparency) pending review. A Google Play release for Android is forthcoming. Upcoming features include a web interface, collaborative review sessions, and integration with additional literature databases including bioRxiv and medRxiv preprint servers.

The vision is simple: **every medical claim should be easy to check against the actual evidence**. Not just for experts — for everyone.

---

*Dr Horst Herb is a medical doctor and software developer. BMLibrarian Lite is derived from BMLibrarian, a comprehensive biomedical literature research platform. The project is open-source under the AGPL-3.0 license.*

*Try it yourself: [github.com/hherb/bmlibrarian_lite](https://github.com/hherb/bmlibrarian_lite)*
