# Medical Fact Checker - macOS Companion App

A native macOS companion app for the Medical Fact Checker iOS app, providing the same AI-powered medical claim verification using PubMed literature and large language models.

## Features

- **Sidebar Navigation**: macOS-native navigation pattern with sidebar
- **Wide Screen Layout**: Two-column layouts optimized for larger Mac screens
- **Native Settings Window**: Standard macOS Settings/Preferences integration
- **Keyboard Navigation**: Full keyboard support for power users
- **Export Options**: PDF export, printing, and clipboard support
- **Shared Data Model**: Uses the same SwiftData models as the iOS app

## Architecture

The macOS app shares approximately 80% of its code with the iOS app:

### Shared Code (Models, Services, Utilities)
- `Models/` - SwiftData models (FactCheckSession, Document, Citation, etc.)
- `Services/` - LLMService, PubMedService, EmbeddingService, FactCheckWorkflow
- `Utilities/` - CostCalculator, ResponseParser, KeychainHelper, PDFExporter

### Platform-Specific Code
- `Sources/macOS/App/` - macOS app entry point and navigation
- `Sources/macOS/Views/` - macOS-optimized views

## Setting Up in Xcode

### Option 1: Add macOS Target to Existing Project

1. Open `MedicalFactChecker.xcodeproj` in Xcode
2. Go to **File > New > Target...**
3. Select **macOS > App** and click **Next**
4. Configure the target:
   - Product Name: `MedicalFactChecker-macOS`
   - Bundle Identifier: `com.bmlibrarian.MedicalFactChecker-macOS`
   - Interface: SwiftUI
   - Language: Swift
5. Click **Finish**

### Option 2: Create a New Xcode Project for macOS

1. Open Xcode and create a new project (**File > New > Project...**)
2. Select **macOS > App**
3. Configure:
   - Product Name: `MedicalFactChecker`
   - Organization Identifier: `com.bmlibrarian`
   - Interface: SwiftUI
   - Language: Swift
   - Storage: SwiftData
4. Add files from `Sources/macOS/` to the project
5. Add shared files from `Sources/Models/`, `Sources/Services/`, `Sources/Utilities/`

### Adding Files to the macOS Target

After creating the target, add the following file groups:

#### macOS-Specific Files (Sources/macOS/)
```
macOS/
├── App/
│   ├── MedicalFactCheckerMacApp.swift
│   └── MacContentView.swift
└── Views/
    ├── FactCheck/
    │   ├── MacFactCheckView.swift
    │   └── MacScoredDocumentsView.swift
    ├── Report/
    │   └── MacReportView.swift
    ├── History/
    │   └── MacHistoryView.swift
    └── Settings/
        └── MacSettingsView.swift
```

#### Shared Files (add to both iOS and macOS targets)
```
Models/
├── AppSettings.swift
├── Citation.swift
├── Document.swift
├── Enums.swift
├── EvidenceReport.swift
├── FactCheckSession.swift
├── LLMProvider.swift
└── UsageRecord.swift

Services/
├── EmbeddingService.swift
├── FactCheckWorkflow.swift
├── LLMService.swift
├── ModelFetchService.swift
└── PubMedService.swift

Utilities/
├── CostCalculator.swift
├── KeychainHelper.swift
├── PDFExporter.swift
└── ResponseParser.swift
```

### Build Settings

For the macOS target, ensure these settings:

1. **Deployment Target**: macOS 14.0
2. **App Sandbox**: Enable for Mac App Store distribution
3. **Hardened Runtime**: Enable for notarization
4. **Entitlements**:
   - `com.apple.security.network.client` - For API requests
   - `com.apple.security.keychain-access-groups` - For Keychain access

### Info.plist Configuration

Add to the macOS target's Info.plist:

```xml
<key>CFBundleDisplayName</key>
<string>Medical Fact Checker</string>
<key>LSApplicationCategoryType</key>
<string>public.app-category.medical</string>
<key>NSHumanReadableCopyright</key>
<string>Copyright 2026 BMLibrarian</string>
```

## Key Differences from iOS

### Navigation
- iOS: Tab-based navigation
- macOS: Sidebar navigation with NavigationSplitView

### Settings
- iOS: Settings tab in main app
- macOS: Separate Settings window (standard macOS pattern)

### Layout
- iOS: Single-column, mobile-optimized
- macOS: Multi-column, wide-screen optimized

### Controls
- iOS: Touch-friendly buttons
- macOS: Smaller controls, keyboard shortcuts

## Testing

Run the macOS app in Xcode:
1. Select the macOS target from the scheme picker
2. Select "My Mac" as the destination
3. Press Cmd+R to build and run

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- Swift 5.9 or later
