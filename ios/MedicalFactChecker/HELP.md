# Medical Fact Checker - Help Guide

Welcome to Medical Fact Checker, an AI-powered tool for evaluating medical claims using peer-reviewed scientific literature from PubMed.

---

## Contents

- Overview
- Important Limitations
- Getting Started
- How It Works
- Understanding Your Results
- Settings Explained
- Cost Management
- Tips for Best Results
- Frequently Asked Questions
- Privacy & Data

---

## Overview

Medical Fact Checker helps you evaluate health-related claims by searching the world's largest biomedical literature database (PubMed) and using AI to analyze the evidence. Enter any medical statement or question, and the app will:

1. Convert your claim into an optimized PubMed search query
2. Retrieve relevant research abstracts
3. Score each document for relevance
4. Extract key passages as citations
5. Generate an evidence report with a verdict

**This app is a research tool, not a substitute for professional medical advice.** Always consult qualified healthcare providers for medical decisions.

---

## Important Limitations

### Abstracts Only - Not Full Text

**This app analyzes publication abstracts, not full-text articles.** Unlike our desktop application [BMLibrarian](https://github.com/hherb/bmlibrarian) which can access and analyze complete research papers, this mobile/desktop app works only with the summaries (abstracts) available through PubMed.

**What this means:**
- Abstracts contain the key findings but not all the details
- Some nuances, methodology details, or subgroup analyses may be missed
- Results provide a good overview but may not capture the complete picture
- For thorough systematic reviews, use BMLibrarian or manual literature review

### Document Limit and Research Completeness

**The default setting fetches only 20 documents per search batch.** This is designed to balance thoroughness with cost, but it may not capture all relevant literature on well-researched topics.

**Important considerations:**

- **Popular topics may have hundreds or thousands of relevant publications.** If you search for "vitamin D COVID" or "aspirin heart disease," there may be far more relevant studies than the 20 initially fetched.

- **Limited searches may yield biased results.** If you happen to fetch primarily studies that support (or refute) a claim, while many other studies exist with different conclusions, your report may not reflect the true state of the evidence.

- **You can always fetch more documents.** After initial scoring, the app will tell you how many relevant documents were found and offer to fetch more if the threshold isn't met. You can also use "Get More Evidence" after a report is generated.

- **More documents = higher cost.** Unless you're using free local models (Ollama), fetching and scoring more documents increases API costs. A typical 20-document search costs $0.01-0.03 with Claude Sonnet, but a comprehensive 200-document search could cost 10x more.

**Recommendation:** For casual fact-checking, the default 20 documents is usually sufficient. For important decisions or thorough research, consider increasing the batch size or fetching additional batches.

### Model Quality Matters

The quality and reliability of your results depend significantly on which AI model you use:

| Model Tier | Examples | Best For |
|------------|----------|----------|
| **Premium** | Claude Opus 4.5, GPT-5.2 | Thorough analysis, nuanced interpretation, complex claims |
| **Balanced** | Claude Sonnet 4.5, GPT-4o | Good balance of quality and cost for most use cases |
| **Fast/Cheap** | Claude Haiku 4.5, GPT-4o Mini, Llama 4 Scout | Quick checks, cost-conscious research, simple claims |
| **Free/Local** | Ollama models | Privacy-focused, no API cost, but may be less accurate |

**Our testing** has been done primarily with Anthropic's Claude models:
- **Claude Haiku** provides reliable results for most fact-checks at low cost
- **Claude Sonnet** offers better analysis quality at moderate cost (recommended)
- **Claude Opus** provides the most sophisticated analysis but at higher cost

Other providers work well but may have different strengths and weaknesses.

---

## Getting Started

### Initial Setup

1. **Accept the Disclaimer**: On first launch, read and accept the disclaimer about AI limitations
2. **Configure Your LLM Provider**: Go to Settings and select your AI provider
3. **Enter Your API Key**: Obtain an API key from your chosen provider and enter it
4. **Optional**: Configure PubMed email and budget limits

### Getting API Keys

| Provider | Where to Get Key |
|----------|------------------|
| Anthropic | [console.anthropic.com](https://console.anthropic.com) |
| OpenAI | [platform.openai.com](https://platform.openai.com) |
| DeepSeek | [platform.deepseek.com](https://platform.deepseek.com) |
| Groq | [console.groq.com](https://console.groq.com) |
| Mistral | [console.mistral.ai](https://console.mistral.ai) |
| Ollama | No key needed - runs locally on your Mac |

### Quick Start

1. Enter a medical claim like "Vitamin D supplementation reduces respiratory infections"
2. Tap **Check Evidence**
3. Wait for the workflow to complete (typically 30-90 seconds)
4. Review the evidence report

---

## How It Works

### The Workflow Pipeline

Medical Fact Checker follows a five-step process:

#### Step 1: Query Conversion
Your natural language claim is converted into an optimized PubMed search query. The AI identifies key medical concepts and generates appropriate MeSH terms and keywords.

**Example:**
- Input: "Does omega-3 help with depression?"
- Generated query: `("Fatty Acids, Omega-3"[MeSH] OR omega-3[tiab]) AND ("Depression"[MeSH] OR depression[tiab]) AND hasabstract`

#### Step 2: PubMed Search
The app searches PubMed's database of 36+ million biomedical citations. Results are fetched in batches (default: 20 per batch) with the most recent publications first.

**What's searched:**
- Peer-reviewed journal articles
- Clinical trials and studies
- Systematic reviews and meta-analyses
- Case reports and series

#### Step 3: Document Scoring
Each document is scored for relevance on a 1-5 scale:

| Score | Meaning |
|-------|---------|
| **5** | Directly addresses the claim with strong evidence (supporting OR refuting) |
| **4** | Highly relevant with substantial information |
| **3** | Moderately relevant with useful related information |
| **2** | Marginally relevant, tangentially related |
| **1** | Not relevant to the claim |

**Note:** Evidence that *refutes* a claim is equally valuable as evidence that supports it. A study showing negative results is highly relevant if it directly addresses your question.

**Optional: Embedding Scores**
When enabled, documents also receive an on-device semantic similarity score using Apple's NLEmbedding. This provides a second opinion on relevance at no additional cost.

#### Step 4: Citation Extraction
For documents meeting the relevance threshold (default: score 3+), the AI extracts 1-2 key passages that:
- Directly address the claim
- Contain specific findings or data
- Note whether findings SUPPORT, REFUTE, or are NEUTRAL toward the claim
- Identify study type (RCT, systematic review, cohort, etc.)
- Capture sample size when available

#### Step 5: Report Generation
All citations are synthesized into an evidence report featuring:
- A **verdict** (Supported, Partially Supported, Not Supported, etc.)
- A **summary** of key findings (2-3 sentences)
- A **detailed report** discussing the evidence
- **References** with links to original PubMed articles

### Smart Search

If the initial search doesn't find enough relevant documents, the app can automatically try alternative search strategies:
- Different synonyms or medical terms
- Broader or narrower search scopes
- Separate queries for comparison questions (e.g., "Drug A vs Drug B")

### Getting More Evidence

After a report is generated, you can tap **Get More Evidence** to:
- Fetch additional documents from PubMed
- Score and extract citations from new documents
- Regenerate the report with all accumulated evidence

This is useful when you want a more comprehensive review or when initial results seem incomplete.

---

## Understanding Your Results

### Verdicts

| Verdict | Meaning |
|---------|---------|
| **Supported** | Strong, consistent evidence supports the claim |
| **Partially Supported** | Some evidence supports the claim, but with caveats or limitations |
| **Not Supported** | Evidence contradicts or does not support the claim |
| **Insufficient Evidence** | Not enough relevant studies found to evaluate the claim |
| **Conflicting Evidence** | Studies show mixed results - some support, some refute |

### Evidence Hierarchy

The report considers study quality when weighing evidence. From strongest to weakest:

1. **Systematic reviews & meta-analyses** - Synthesize multiple studies
2. **Randomized controlled trials (RCTs)** - Gold standard for interventions
3. **Cohort studies** - Prospective > retrospective
4. **Case-control studies** - Compare cases to controls
5. **Case reports/series** - Individual or small group observations
6. **Narrative reviews/expert opinion** - Qualitative summaries

A single high-quality RCT can outweigh multiple observational studies. The report notes when evidence quality varies.

### Reading Citations

Citations in reports use the format: `[Author, Year](doc:pmid-12345678)`

Tap any citation to:
- View the document details
- Read the full abstract
- Open the original PubMed article in your browser

### Reference Section

Each report ends with a numbered reference list in academic format:
```
1. Smith et al. (2023). Study Title. Journal Name. PMID: 12345678
```

---

## Settings Explained

### LLM Provider

Choose your AI provider for analysis:

| Provider | Notes |
|----------|-------|
| **Anthropic** | Recommended. Claude models tested extensively with this app |
| **OpenAI** | GPT models, widely used and reliable |
| **DeepSeek** | Cost-effective option with good quality |
| **Groq** | Fast inference with Llama models |
| **Mistral** | European provider with strong models |
| **Ollama** | Free, local - runs on your Mac (no API cost) |
| **Custom** | Any OpenAI-compatible API endpoint |

### Model Selection

After choosing a provider, select a specific model. Models are fetched automatically from the provider's API when you enter an API key.

**Recommendations:**
- **For quality**: Claude Opus 4.5, GPT-5.2
- **For balance**: Claude Sonnet 4.5, GPT-4o (recommended for most users)
- **For cost**: Claude Haiku 4.5, GPT-4o Mini, Llama 4 Scout

### Search Settings

#### Batch Size (5-50, default: 20)
How many documents to fetch per PubMed batch. Higher values provide more thorough searches but cost more.

- **5-10**: Quick checks, cost-conscious
- **20**: Good balance for most topics (default)
- **30-50**: Thorough research on important topics

#### Minimum Relevant Documents (1-20, default: 5)
The app will offer to fetch more documents if fewer than this many relevant papers are found.

#### Minimum Score Threshold (1-5, default: 3)
Documents must score at or above this level to be considered "relevant":

| Threshold | Meaning |
|-----------|---------|
| 1 - Any | Include all documents (not recommended) |
| 2 - Low | Include marginally relevant documents |
| 3 - Moderate | Include moderately relevant documents (default) |
| 4 - High | Only highly relevant documents |
| 5 - Very High | Only directly relevant documents |

### Scoring Methods

#### Enable Embedding Scoring (default: Off)
When enabled, documents receive two scores:
1. **LLM Score**: AI-based relevance assessment (costs API tokens)
2. **Embedding Score**: On-device semantic similarity (free)

Embedding scoring uses Apple's NLEmbedding and HyDE (Hypothetical Document Embedding) for improved accuracy. This allows you to compare AI scoring with on-device scoring and catch any discrepancies.

### Budget Limits

#### Per-Run Limit (default: $1.00)
Maximum spending for a single fact-check. The workflow stops if this limit is reached.

#### Monthly Limit (default: $10.00)
Maximum monthly spending across all fact-checks. Tracked automatically and resets at the start of each month.

View your current monthly usage and reset it in Settings if needed.

### PubMed API (Optional)

#### Email (recommended)
Providing an email helps NCBI identify your requests. They may contact you if there are issues.

#### NCBI API Key (optional)
Increases your rate limit for PubMed queries. Get one free at [NCBI](https://www.ncbi.nlm.nih.gov/account/).

---

## Cost Management

### Understanding Costs

Costs are based on tokens processed by the AI:
- **Input tokens**: The text sent to the AI (your claim, document abstracts, prompts)
- **Output tokens**: The AI's responses (scores, citations, reports)

Costs vary by model - see Settings > View Model Pricing for current rates.

### Typical Costs

| Scenario | Approximate Cost |
|----------|------------------|
| Quick check (20 docs, Claude Sonnet) | $0.01 - $0.03 |
| Quick check (20 docs, GPT-4o Mini) | $0.001 - $0.003 |
| Thorough review (100 docs, Claude Sonnet) | $0.05 - $0.15 |
| Comprehensive search (200+ docs, Claude Opus) | $0.50 - $1.00+ |

### Minimizing Costs

1. **Use cheaper models** for initial screening (Haiku, GPT-4o Mini)
2. **Start with smaller batch sizes** and fetch more only if needed
3. **Use Ollama** for free local inference (requires Mac)
4. **Set budget limits** to prevent surprises
5. **Enable embedding scoring** to supplement (not replace) LLM scoring at no extra cost

### Free Option: Ollama

Run AI models locally on your Mac at no API cost:

1. Install Ollama: [ollama.ai](https://ollama.ai)
2. Download a model: `ollama pull llama3.2` or `ollama pull mistral`
3. Select "Ollama" as your provider in Settings
4. Enter the model name you downloaded

**Trade-offs:**
- No API costs
- Complete privacy (data stays on device)
- May be slower or less accurate than cloud models
- Requires a Mac with sufficient RAM (8GB+ recommended)

---

## Tips for Best Results

### Writing Good Claims

**Be specific:**
- Good: "Does vitamin D supplementation reduce respiratory infections in adults?"
- Less good: "Is vitamin D good for health?"

**State claims clearly:**
- Good: "Metformin reduces cardiovascular mortality in type 2 diabetes"
- Less good: "Tell me about metformin"

**For comparisons, be explicit:**
- Good: "Is lisinopril more effective than amlodipine for blood pressure control?"
- Less good: "Blood pressure medications comparison"

### Interpreting Results Carefully

1. **Check the source quality** - Systematic reviews carry more weight than case reports
2. **Consider sample sizes** - Larger studies are generally more reliable
3. **Note conflicting evidence** - Medical science often has nuanced findings
4. **Read the cited passages** - The AI's summary may miss nuances
5. **Review original abstracts** - Tap citations to see full context

### When to Fetch More Evidence

Consider fetching more evidence when:
- The report indicates "Insufficient Evidence"
- You see "Conflicting Evidence" and want more clarity
- The topic is well-researched but few documents were found
- You need a comprehensive review for an important decision

### When to Use Premium Models

Use higher-quality (more expensive) models when:
- The claim involves complex medical reasoning
- You need nuanced interpretation of conflicting evidence
- The topic involves recent or evolving research
- You're making important decisions based on the results

---

## Frequently Asked Questions

### Why didn't the app find any relevant papers?

**Possible reasons:**
- The topic may have limited published research
- The search terms may need refinement (try rephrasing)
- The claim may be too specific or novel
- PubMed may not cover all medical literature (try specialized databases)

**Try:**
- Rephrasing with different medical terms
- Making the claim more general
- Searching for related topics

### Why do I get different results each time?

- AI models have some randomness in their responses
- New publications may appear in PubMed
- Smart search may generate different alternative queries
- The order of documents from PubMed may vary

Results should be broadly consistent, but minor variations are normal.

### Can I trust the verdict?

The verdict is an AI's interpretation of the available evidence. You should:
- Review the cited passages yourself
- Consider the quality and quantity of evidence
- Consult healthcare professionals for medical decisions
- Use this as a starting point, not a definitive answer

### Why is embedding scoring optional?

Embedding scoring runs entirely on your device and is free, but:
- It measures semantic similarity, not true relevance
- It may miss nuances that LLM scoring catches
- It's useful as a "second opinion" but not a replacement for LLM scoring

Enable it if you want to compare scoring methods or catch potential AI errors.

### What happens to my data?

- All data is stored locally on your device
- API calls send your claims and document abstracts to your chosen provider
- No data is collected by the app developers
- Use Ollama for complete privacy (no external API calls)

See the Privacy Policy in Settings for complete details.

### How do I delete my data?

- Swipe left on any session in History to delete it
- Reset monthly usage in Settings > Budget Limits
- Uninstall the app to remove all local data

---

## Privacy & Data

### What Data Stays on Device
- All session history and reports
- Your settings and preferences
- API keys (stored in iOS/macOS Keychain)
- Usage tracking data

### What's Sent to External Services

**To your LLM provider (Anthropic, OpenAI, etc.):**
- Your medical claims
- Document abstracts being analyzed
- Generated queries and prompts

**To PubMed (NCBI):**
- Search queries
- Your configured email (if provided)

**Collected by the app developers:**
- Nothing. No analytics, tracking, or data collection.

### For Maximum Privacy

Use **Ollama** as your provider:
- All AI processing happens locally on your Mac
- Only PubMed queries are sent externally
- No API keys or cloud accounts needed

---

## Need More Help?

- **GitHub Issues**: [github.com/hherb/bmlibrarian_lite/issues](https://github.com/hherb/bmlibrarian_lite/issues)
- **BMLibrarian (full version)**: [github.com/hherb/bmlibrarian](https://github.com/hherb/bmlibrarian)

---

*Medical Fact Checker v1.1 - January 2026*
