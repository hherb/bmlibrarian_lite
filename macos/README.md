# MedicalFactCheckerMac

A native macOS application for medical fact-checking using PubMed and LLM APIs.

## Overview

This is a standalone macOS project separate from the iOS app. While both share the same conceptual foundation, this macOS version is designed to diverge with:

- **Local LLM processing** - Focus on local inference using Ollama or similar
- **PostgreSQL support** - Optional database backend for larger datasets
- **Enhanced local processing** - Leveraging Mac hardware capabilities

## Project Structure

```
macos/MedicalFactCheckerMac/
├── MedicalFactCheckerMac.xcodeproj/
├── Info.plist
├── MedicalFactCheckerMac.entitlements
└── Sources/
    ├── App/
    │   ├── MedicalFactCheckerMacApp.swift
    │   └── MacContentView.swift
    ├── Views/
    │   ├── FactCheck/
    │   ├── Report/
    │   ├── History/
    │   └── Settings/
    ├── Models/
    ├── Services/
    ├── Utilities/
    ├── MacConstants.swift
    ├── Assets.xcassets/
    └── Preview Content/
```

## Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## Building

1. Open `MedicalFactCheckerMac.xcodeproj` in Xcode
2. Select the `MedicalFactCheckerMac` scheme
3. Build and run (Cmd+R)

Alternatively, build from the command line:

```bash
cd macos/MedicalFactCheckerMac
xcodebuild -project MedicalFactCheckerMac.xcodeproj \
           -scheme MedicalFactCheckerMac \
           -configuration Debug \
           build
```

## Configuration

The app requires API credentials to function:

1. **LLM API Key** - Configure in Settings for OpenAI-compatible endpoints
2. **NCBI Email** - Recommended for PubMed API access

## Features

- **Fact Checking** - Enter medical claims and get evidence-based verification
- **PubMed Integration** - Searches biomedical literature via NCBI E-utilities
- **LLM Scoring** - Uses AI to score document relevance
- **Evidence Reports** - Generates structured reports with citations
- **Session History** - Browse and revisit past fact-checking sessions

## Future Roadmap

- Local LLM integration (Ollama, llama.cpp)
- PostgreSQL database backend
- Enhanced document processing
- Batch processing capabilities

## Related

- [iOS App](../ios/) - Mobile version for iPhone/iPad
- [Python Desktop](../) - Cross-platform Python/Qt version
