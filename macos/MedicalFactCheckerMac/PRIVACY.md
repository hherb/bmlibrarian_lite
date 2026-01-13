# Privacy Policy

**Medical Fact Checker**
Last Updated: January 2026

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
- **Fact-check history**: Your past sessions and reports
- **App settings**: Your preferences and configuration
- **API keys**: Stored securely in the iOS Keychain
- **Usage records**: Token counts and cost tracking for your budgets

## Third-Party Services

Medical Fact Checker connects to third-party services that you configure. These connections are necessary for the app to function and are initiated only when you perform a fact-check.

### PubMed / NCBI

When you run a fact-check, the app searches PubMed via the NCBI E-utilities API:

- **Data sent**: Search queries derived from your medical claim
- **Data received**: Article metadata (titles, abstracts, authors, publication info)
- **Privacy policy**: [NCBI Privacy Policy](https://www.ncbi.nlm.nih.gov/home/about/policies/)

Your email address (if configured) is sent to NCBI to identify your requests, as recommended by their API guidelines.

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
| AI processing | Sent to your chosen provider |
| Local AI option | Yes (Ollama) |
