# Privacy Policy

**Medical Fact Checker** for iPhone, iPad, Mac and Android  
Last Updated: 10 November 2026

## Overview

Medical Fact Checker is developed by Dr Horst Herb. It has no servers and no user accounts. We do not collect, store or share any personal information. Everything you do in the app stays on your device, except what the app must send to the services named below in order to work, and what you choose to sync.

## What We Do Not Collect

- No personal information
- No usage analytics or crash reports
- No location
- No advertising identifiers or trackers
- Nothing sold or shared with us or anyone else

## What Stays On Your Device

- **Medical claims and queries**: the text you enter for fact-checking
- **Fact-check history**: your sessions and reports, and the retraction status found for each paper
- **Full texts you upload**: files you choose to upload are read on the device and stored with the paper
- **App settings**: your preferences and configuration
- **API keys**: on iPhone, iPad and Mac in the Apple Keychain; on Android encrypted with a key held in the Android Keystore
- **Usage records**: token counts and cost tracking for your budgets

## Third-Party Services

The app connects to the services below because it cannot work without them. It does so when you run a fact-check or open, analyse or re-check its documents, except the Retraction Watch download, which the app refreshes on its own over Wi-Fi or another unmetered network.

### PubMed / NCBI

When you run a fact-check, the app searches PubMed through the NCBI E-utilities API.

- **Data sent**: search queries derived from your medical claim
- **Data received**: article metadata (titles, abstracts, authors, publication details)
- **Privacy policy**: [NCBI Privacy Policy](https://www.ncbi.nlm.nih.gov/home/about/policies/)

If you enter an email address in Settings, it is sent to NCBI to identify your requests, as NCBI's API guidelines ask. The same address is sent to Crossref, Unpaywall and OpenAlex, which ask for one for the same reason. If you have not set one, a generic placeholder address is sent instead.

### Article Databases and Full-Text Sources

To find articles and read their full text, the app asks these services about the articles a search found. What is sent is the article's identifiers (DOI, PubMed ID, PMC ID) or, for Europe PMC, the search query; never the wording of your claim beyond that query.

| Service | What's Sent | Privacy Policy |
|---------|-------------|----------------|
| Europe PMC (EMBL-EBI) | Search queries, article identifiers | [ebi.ac.uk/data-protection](https://www.ebi.ac.uk/data-protection/) |
| PMC Open Access (Amazon S3) | PMC IDs | [NCBI Privacy Policy](https://www.ncbi.nlm.nih.gov/home/about/policies/) |
| Unpaywall | DOIs, your email address | [unpaywall.org/legal](https://unpaywall.org/legal) |
| OpenAlex | DOIs, your email address | [openalex.org](https://openalex.org/) |
| CORE (only with your CORE API key) | DOIs, your CORE API key | [core.ac.uk/privacy](https://core.ac.uk/privacy) |
| Elsevier (only with your Elsevier API key) | DOIs of Elsevier articles, your Elsevier API key and institutional token | [elsevier.com/legal/privacy-policy](https://www.elsevier.com/legal/privacy-policy) |
| doi.org and publishers' websites | Requests for an article's page or PDF | Each publisher's own policy |

### Retraction and Transparency Checks

| Service | What's Sent | Privacy Policy |
|---------|-------------|----------------|
| Crossref | DOIs, your email address; the app also downloads the Retraction Watch database from Crossref | [crossref.org/operations-and-sustainability/privacy](https://www.crossref.org/operations-and-sustainability/privacy/) |
| ClinicalTrials.gov | Trial registration numbers | [NLM Privacy Policy](https://www.nlm.nih.gov/web_policies.html) |

None of these services receives your AI provider API key, your fact-check history, or anything about you beyond the email address named above and your device's network address, which any internet request reveals.

### AI Providers

The app sends text to the AI provider you select, which scores the articles, extracts citations and writes the report. You supply your own API key; your use of the provider is under your own agreement with them.

| Provider | What's Sent | Privacy Policy |
|----------|-------------|----------------|
| Anthropic | Your claim and the articles' abstracts and full texts | [anthropic.com/privacy](https://www.anthropic.com/privacy) |
| OpenAI | Your claim and the articles' abstracts and full texts | [openai.com/privacy](https://openai.com/privacy) |
| DeepSeek | Your claim and the articles' abstracts and full texts | [deepseek.com/privacy](https://www.deepseek.com/privacy) |
| Groq | Your claim and the articles' abstracts and full texts | [groq.com/privacy](https://groq.com/privacy-policy) |
| Mistral | Your claim and the articles' abstracts and full texts | [mistral.ai/privacy](https://mistral.ai/terms/#privacy-policy) |
| Ollama | The same, sent only to the Ollama server you run yourself | No external transmission |
| Custom | The same, sent to the endpoint you configure | Depends on your provider |

**Important**: with a cloud AI provider, your claims and the text of the articles (including the text of files you upload) are processed on that provider's servers. Review its privacy policy and data retention before use. If you use Ollama, the processing happens on a computer you control, and nothing is sent to an AI company.

### On-Device Embedding Scoring

When embedding scoring is enabled, the similarity calculations run entirely on your device: Apple's NLEmbedding on iPhone, iPad and Mac, and Google's MediaPipe text embedder on Android. No text is sent anywhere for this feature. On Android the app downloads the embedding model once from Google's servers (storage.googleapis.com) the first time the feature is used.

## Sync and Backups (optional)

- **iCloud (iPhone, iPad, Mac)**: if you turn on iCloud sync, your fact-check history is stored in your own iCloud account through Apple's CloudKit, so your other devices can read it. We have no access to it. See [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).
- **Folder sync (Android)**: if you turn on sync, your fact-check history is written to the folder you pick. If that folder belongs to a cloud storage service, that service's privacy policy applies. We have no access to it.
- **Android backup**: if Android's device backup is turned on, Android may include the app's history and settings in your Google account backup. Your API keys are encrypted with a key that never leaves the device, so a backup holds no usable API keys. See [Google's Privacy Policy](https://policies.google.com/privacy).

## Data Security

- **API keys**: stored in the Apple Keychain, or encrypted with the Android Keystore
- **Local data**: protected by your device's own data protection and passcode
- **Network traffic**: every connection to an internet service uses HTTPS; only a local Ollama server on your own network may be reached over plain HTTP

## Data Retention

- **On your device**: data stays until you delete it in the app or remove the app
- **Third-party services**: see each provider's own retention policy
- **With us**: nothing; we have no servers and store no user data

## This Website

medfactcheck.org sets no cookies and runs no analytics. It is served by Cloudflare, which processes the network requests needed to deliver the pages. See [Cloudflare's Privacy Policy](https://www.cloudflare.com/privacypolicy/).

## Children's Privacy

The app is not intended for children under 13, and we do not knowingly collect information from anyone.

## Your Rights

Because your data is stored only on your devices, you control it fully:

- **Access**: see your sessions in the app's History
- **Delete**: delete individual sessions, or clear all report data in Settings
- **Export**: share or export reports as PDF

We hold no personal data about you, so there is nothing for us to access, correct or delete. For data held by a third-party service you used through the app, contact that service.

## Changes to This Policy

We may update this policy. Changes are published at https://medfactcheck.org/privacy and shown in the "Last Updated" date above.

## Contact

For privacy questions, please open an issue at:
https://github.com/hherb/bmlibrarian_lite/issues

## Summary

| Aspect | Status |
|--------|--------|
| Personal data collection | None |
| Analytics and tracking | None |
| Data sold to third parties | Never |
| API keys | Stored on your device, encrypted |
| Fact-check history | Stored on your device; synced only if you turn sync on |
| PubMed queries | Sent to NCBI |
| Article identifiers | Sent to the article databases and full-text sources above |
| Your email address (if set) | Sent to NCBI, Crossref, Unpaywall and OpenAlex |
| AI processing | Sent to the provider you choose |
| Local AI option | Yes (Ollama) |
