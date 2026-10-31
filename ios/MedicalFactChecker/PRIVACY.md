# Privacy Policy

**Medical Fact Checker**
Last Updated: October 2026

## Overview

Medical Fact Checker is designed with privacy in mind. We do not collect, store, or share any personal information on our servers. All data processing happens on your device or through the third-party APIs you choose to configure.

## Data Collection

### What We Do NOT Collect

- We do not collect personal information
- We do not collect usage analytics
- We do not track your location
- We do not use advertising trackers
- We do not sell or share any data

### What Stays On Your Device

All of the following data is stored locally on your device and never transmitted to us:

- **Medical claims and queries**: The text you enter for fact-checking
- **Fact-check history**: Your past sessions and reports, and the retraction status found for each paper
- **Full texts you upload**: Files you choose to upload are read on the device and stored with the paper
- **App settings**: Your preferences and configuration
- **API keys**: Stored securely in the iOS Keychain
- **Usage records**: Token counts and cost tracking for your budgets

## Third-Party Services

Medical Fact Checker connects to the third-party services below. These connections are necessary for the app to function. They are made when you run a fact-check or open, analyse or re-check its documents, except the Retraction Watch download, which the app refreshes on its own over Wi-Fi.

### PubMed / NCBI

When you run a fact-check, the app searches PubMed via the NCBI E-utilities API:

- **Data sent**: Search queries derived from your medical claim
- **Data received**: Article metadata (titles, abstracts, authors, publication info)
- **Privacy policy**: [NCBI Privacy Policy](https://www.ncbi.nlm.nih.gov/home/about/policies/)

Your email address (if configured) is sent to NCBI to identify your requests, as recommended by their API guidelines. The same address is sent to Crossref, Unpaywall and OpenAlex, which ask for one for the same reason. If you have not set one, a generic address of the app's is sent instead.

### Article Databases and Full-Text Sources

To find articles and read their full text, the app asks these services about the articles a search found. What is sent is the article's identifiers (DOI, PubMed ID, PMC ID) or, for Europe PMC, the search query; never your claim's wording beyond that query.

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

None of these services receives your API keys for AI providers, your fact-check history, or anything about you beyond the email address named above and your device's network address, which any internet request reveals.

### LLM API Providers

The app sends data to the AI provider you select for document scoring and report generation:

| Provider | What's Sent | Privacy Policy |
|----------|-------------|----------------|
| Anthropic | Prompts with medical claims and article abstracts | [anthropic.com/privacy](https://www.anthropic.com/privacy) |
| OpenAI | Prompts with medical claims and article abstracts | [openai.com/privacy](https://openai.com/privacy) |
| DeepSeek | Prompts with medical claims and article abstracts | [deepseek.com/privacy](https://www.deepseek.com/privacy) |
| Groq | Prompts with medical claims and article abstracts | [groq.com/privacy](https://groq.com/privacy-policy) |
| Mistral | Prompts with medical claims and article abstracts | [mistral.ai/privacy](https://mistral.ai/terms/#privacy-policy) |
| Ollama | Prompts sent to your local server | No external transmission |
| Custom | Prompts sent to your configured endpoint | Depends on your provider |

**Important**: When using cloud-based AI providers, your medical claims and the article abstracts retrieved from PubMed are sent to their servers for processing. Review each provider's privacy policy and data retention practices before use.

### Local Processing (Ollama)

If you use Ollama, all AI processing happens locally on your Mac. No data is sent to external AI services.

### On-Device Embedding Scoring

When embedding scoring is enabled, semantic similarity calculations use Apple's NLEmbedding framework and run entirely on your device. No data is sent externally for this feature.

### iCloud (optional)

If you turn on iCloud sync, your fact-check history is stored in your own iCloud account through Apple's CloudKit, so your other devices can read it. We have no access to it. See [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).

## Data Security

- **API Keys**: Stored in the iOS Keychain, Apple's secure credential storage
- **Local Data**: Protected by iOS data protection and your device passcode/biometrics
- **Network Traffic**: All API connections use HTTPS encryption

## Data Retention

- **On your device**: Data persists until you delete the app or clear history
- **Third-party services**: Refer to each provider's data retention policies
- **We retain nothing**: We have no servers and store no user data

## Children's Privacy

This app is not intended for use by children under 13. We do not knowingly collect information from children.

## Your Rights

Since all data is stored locally on your device, you have complete control:

- **Access**: View your data in the app's History tab
- **Delete**: Clear individual sessions or all history
- **Export**: Share or export reports as PDF
- **Portability**: Your data is on your device

## Changes to This Policy

We may update this privacy policy from time to time. Changes will be reflected in the "Last Updated" date above. Continued use of the app after changes constitutes acceptance of the updated policy.

## Contact

For privacy questions or concerns, please open an issue at:
https://github.com/hherb/bmlibrarian_lite/issues

## Summary

| Aspect | Status |
|--------|--------|
| Personal data collection | None |
| Analytics/tracking | None |
| Data sold to third parties | Never |
| API keys | Stored locally in Keychain |
| Fact-check history | Stored locally on device |
| PubMed queries | Sent to NCBI |
| Article identifiers | Sent to the article databases and full-text sources above |
| Your email address (if set) | Sent to NCBI, Crossref, Unpaywall and OpenAlex |
| AI processing | Sent to your chosen provider |
| Local AI option | Yes (Ollama) |
