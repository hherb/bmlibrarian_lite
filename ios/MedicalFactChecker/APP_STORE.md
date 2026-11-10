# App Store Metadata

## App Name
Medical Fact Checker

## Subtitle (30 characters max)
Evidence-Based Medical Research

## Category
Primary: Medical
Secondary: Reference

---

## App Description (4000 characters max)

Medical Fact Checker helps you evaluate medical claims using peer-reviewed scientific literature. Enter any health-related statement or question, and the app searches PubMed's database of over 36 million biomedical articles to find relevant evidence and generate a comprehensive report.

**How It Works**

1. Enter a medical claim like "Vitamin D supplementation reduces risk of respiratory infections"
2. The app converts your query into an optimized PubMed search
3. Relevant research papers are retrieved and scored for relevance
4. Key passages are extracted as citations
5. An evidence report is generated with a verdict and supporting references

**Key Features**

- Direct PubMed Integration: Searches the world's largest biomedical literature database
- AI-Powered Analysis: Uses advanced language models to evaluate document relevance and synthesize findings
- Multiple AI Providers: Choose from Anthropic (Claude), OpenAI, DeepSeek, Groq, Mistral, or run locally with Ollama
- Dual Scoring System: Combines AI scoring with on-device semantic similarity for improved accuracy
- Clickable References: Tap any citation to view the original PubMed article
- PDF Export: Save reports with full citations for sharing or printing
- Cost Controls: Set per-run and monthly spending limits
- Complete History: Browse and re-share all your past fact-checks
- Privacy First: API keys stored securely in Keychain

**Who Is This For?**

- Healthcare professionals wanting quick literature reviews
- Researchers checking claims before deeper investigation
- Students learning to evaluate medical evidence
- Anyone curious about the science behind health claims

**Important Notes**

This app is a research tool, not a substitute for professional medical advice. Always consult qualified healthcare providers for medical decisions. AI-generated summaries may contain errors - verify important findings in the original sources.

**Requirements**

You'll need an API key from one of the supported AI providers (Anthropic, OpenAI, DeepSeek, Groq, or Mistral). Alternatively, use Ollama to run AI models locally on your Mac at no cost.

---

## Keywords (100 characters max)
medical,fact-check,pubmed,research,evidence,health,literature,citations,AI,science

---

## What's New (Version 1.9.0)

**Retraction Checking**
- Every paper is checked against Retraction Watch and Crossref before it
  is scored; retracted papers are left out, counted and named in the report
- Papers under an expression of concern are flagged, never silently dropped
- Badges and banners show each paper's retraction status
- A saved report shows when its papers were last checked, with a
  *Check again* button you can stop at any time
- A check that fails or is stopped never reads as "not retracted", and
  still warns of a paper PubMed itself marks as retracted

**More Full Text**
- Full text is now also fetched from PubMed Central's open-access
  collection, OpenAlex, CORE (with your free CORE key) and Elsevier
  (with your Elsevier key, on an institutional network)
- Every PDF an open-access source names is tried, and each source that
  failed is named
- A downloaded PDF that turns out to be a different article is refused
- Upload a paper's full text yourself from its card
- Long articles are read in full, in overlapping sections, never cut short

**Research Tools**
- Find More Evidence, a repeated smart search, and a retry for full texts
  that could not be read, on a saved report
- Fetch Full Text for Top Papers (those scored 4 or 5)
- Transparency is analysed again once a paper's full text arrives
- Cancel works on every run and records no failure

**Bug Fixes & Improvements**
- The Mac app now runs in Apple's app sandbox
- Every second report no longer crashes on iOS 18 and macOS 15
- Runs no longer hang at "Checking retraction status"
- Settings no longer freezes while reading a saved key
- "Get More Evidence" on the Mac Report tab starts the fetch

**Supported AI Models**
- Anthropic Claude (all models)
- OpenAI GPT (all models)
- DeepSeek (all models)
- Mistral AI (all models)
- Open models hosted by Groq
- Local models via Ollama
- Any OpenAI-compatible endpoint

---

## Version History

### Version 1.9.0 (November 2026)
- First App Store release since 1.6.0, with everything in 1.8.0
- Check again runs in one window at a time
- Fixed: a crash on every second report (iOS 18 / macOS 15)

### Version 1.8.0 (November 2026, macOS beta DMG only)
- Retraction checking before scoring, with badges, report sections and Check again
- Full text from PMC's open-access collection, OpenAlex, CORE and Elsevier
- Another article's PDF refused; full-text upload; long texts read in full
- Find More Evidence, Fetch Full Text for Top Papers, Retry Full Text; a working Cancel
- Sandboxed Mac app; fixed runs hung at the retraction check

### Version 1.6.0 (September 2026)
- High-risk transparency ratings explained in every report
- Limited-certainty and "Unassessed" ratings when full text was not read
- PDF text used for analysis; abstract-only records recognised
- Failed literature sources reported instead of shown as empty

### Version 1.5.1 (August 2026)
- DeepSeek V4 migration after the V3 model retirement
- Model fetch failures reported instead of silently falling back

### Version 1.1 (January 2026)
- Updated to January 2026 AI models
- Dynamic model fetching from provider APIs
- Improved model pricing display

### Version 1.0 (Initial Release)
- Medical claim fact-checking with PubMed
- Multiple AI provider support
- Dual scoring (AI + embedding)
- PDF export
- Cost tracking and budgets
- Session history

---

## Promotional Text (170 characters max)
Fact-check medical claims against PubMed research with the AI of your choice: Claude, GPT, DeepSeek, Mistral or models running locally on your Mac.

---

## Support URL
https://github.com/hherb/bmlibrarian_lite/issues

## Privacy Policy URL
[Your privacy policy URL]

## App Store Screenshots Descriptions

**Screenshot 1 - Main Screen**
Enter any medical claim to check against scientific literature

**Screenshot 2 - Evidence Report**
Get detailed reports with verdicts and cited sources

**Screenshot 3 - Document Scoring**
See relevance scores for each research paper found

**Screenshot 4 - Settings**
Choose from 7 AI providers with automatic model discovery

**Screenshot 5 - PDF Export**
Export professional reports with full citations

**Screenshot 6 - History**
Access all your past fact-checks anytime
