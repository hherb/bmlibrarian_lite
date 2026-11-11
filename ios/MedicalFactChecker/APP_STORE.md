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

Medical Fact Checker helps you evaluate medical claims against peer-reviewed scientific literature. Enter any health-related statement or question, and the app searches PubMed's more than 36 million biomedical articles, and Europe PMC, for the relevant evidence, checks it, and writes an evidence report with a verdict and references.

**New in Version 1.9**

- Retraction checking: every paper is checked against Retraction Watch and Crossref before it is scored. Retracted papers are left out and named in the report; papers under an expression of concern are flagged, never silently dropped
- More full text: articles are now also fetched from PubMed Central's open-access collection, OpenAlex, CORE and Elsevier, and you can upload a paper's full text yourself
- Long articles are read in full, never cut short, and a downloaded PDF that turns out to be a different article is refused
- New tools on saved reports: Find More Evidence, Fetch Full Text for Top Papers, and Retry Full Text
- Cancel works on every run, and the Mac app now runs in Apple's app sandbox

**How It Works**

1. Enter a medical claim like "Vitamin D supplementation reduces risk of respiratory infections"
2. The app converts your claim into optimized PubMed and Europe PMC searches
3. Every paper found is checked for retractions
4. The remaining papers are scored for relevance, and their full text is fetched where it is freely available
5. Key passages are extracted as citations, and each study's transparency is assessed
6. An evidence report is generated with a verdict and supporting references

**Key Features**

- PubMed and Europe PMC: searches the world's largest biomedical literature databases
- Retraction Checking: retracted papers never count as evidence, and the report says which were left out
- Full-Text Retrieval: open-access articles from PubMed Central, Europe PMC, Unpaywall, OpenAlex and more, read in full
- Study Transparency: ratings for funding, conflicts of interest, data availability and trial registration
- AI-Powered Analysis: language models evaluate each paper's relevance and synthesize the findings
- Multiple AI Providers: choose Anthropic (Claude), OpenAI, DeepSeek, Groq, Mistral, any OpenAI-compatible endpoint, or run models locally with Ollama
- Dual Scoring System: combines AI scoring with on-device semantic similarity for improved accuracy
- Clickable References: tap any citation to view the original article
- PDF Export: save reports with full citations for sharing or printing
- Cost Controls: set per-run and monthly spending limits
- Complete History: browse and re-share all your past fact-checks, with optional iCloud sync across your devices
- Privacy First: no accounts, no tracking, and API keys stored securely in Keychain

**Who Is This For?**

- Healthcare professionals wanting quick literature reviews
- Researchers checking claims before deeper investigation
- Students learning to evaluate medical evidence
- Anyone curious about the science behind health claims

**Important Notes**

This app is a research tool, not a substitute for professional medical advice. Always consult qualified healthcare providers for medical decisions. AI-generated summaries may contain errors - verify important findings in the original sources.

**Requirements**

You'll need an API key from one of the supported AI providers (Anthropic, OpenAI, DeepSeek, Groq, or Mistral). Alternatively, use Ollama to run AI models locally on your Mac at no cost. Full text from CORE needs a free CORE API key; full text from Elsevier needs an Elsevier API key and an institutional network.

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
- Sandboxed Mac app

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
https://medfactcheck.org/#support

## Marketing URL
https://medfactcheck.org/

## Privacy Policy URL
https://medfactcheck.org/privacy

The same URL goes in Google Play Console (App content > Privacy policy). The page is generated from PRIVACY.md by website/build_privacy.py; see website/wrangler.jsonc to deploy.

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
