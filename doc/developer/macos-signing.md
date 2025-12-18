# macOS Code Signing and Notarization Guide

This guide explains how to sign and notarize BMLibrarian Lite for macOS distribution.

## Prerequisites

### 1. Apple Developer Account

You need an Apple Developer Program membership ($99/year):
- Enroll at [developer.apple.com/programs](https://developer.apple.com/programs/)

### 2. Developer ID Certificate

After enrolling, create a "Developer ID Application" certificate:

1. Open **Keychain Access** on your Mac
2. Go to **Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority**
3. Enter your email and select "Saved to disk"
4. Go to [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list)
5. Click "+" and select "Developer ID Application"
6. Upload the certificate request and download the certificate
7. Double-click to install in Keychain

Verify installation:
```bash
security find-identity -v -p codesigning | grep "Developer ID"
```

### 3. App-Specific Password (for Notarization)

1. Go to [appleid.apple.com](https://appleid.apple.com/)
2. Sign in and go to **Security → App-Specific Passwords**
3. Click "Generate an app-specific password"
4. Name it something like "bmlibrarian-notarize"
5. Save the generated password

### 4. Store Credentials in Keychain

Store notarization credentials securely:

```bash
xcrun notarytool store-credentials "bmlibrarian-notarize" \
    --apple-id "your@email.com" \
    --team-id "YOUR_TEAM_ID" \
    --password "xxxx-xxxx-xxxx-xxxx"
```

Find your Team ID at [developer.apple.com/account](https://developer.apple.com/account/) → Membership.

## Building and Signing

### Unsigned Build (for testing)

```bash
./scripts/build_macos.sh
```

### Signed and Notarized Build (for distribution)

```bash
./scripts/build_macos.sh --sign
```

This will:
1. Build the app with PyInstaller
2. Sign all binaries with your Developer ID certificate
3. Create a DMG
4. Sign the DMG
5. Submit to Apple for notarization
6. Staple the notarization ticket to the DMG

## Environment Variables

You can customize the signing process with environment variables:

```bash
# Specify a particular certificate (if you have multiple)
export DEVELOPER_ID="Developer ID Application: Your Name (TEAM_ID)"

# Use a different keychain profile name
export NOTARIZE_PASSWORD="my-notarize-profile"

# Then run the build
./scripts/build_macos.sh --sign
```

## Manual Signing (if needed)

If you need to sign manually:

### Sign the App Bundle

```bash
# Sign nested libraries first
find "dist/BMLibrarian Lite.app" -name "*.so" -o -name "*.dylib" | while read lib; do
    codesign --force --sign "Developer ID Application: Your Name (TEAM_ID)" \
        --options runtime \
        --entitlements assets/entitlements.plist \
        "$lib"
done

# Sign the main bundle
codesign --force --deep --sign "Developer ID Application: Your Name (TEAM_ID)" \
    --options runtime \
    --entitlements assets/entitlements.plist \
    "dist/BMLibrarian Lite.app"
```

### Verify Signature

```bash
codesign --verify --deep --strict --verbose=2 "dist/BMLibrarian Lite.app"
spctl --assess --type execute --verbose "dist/BMLibrarian Lite.app"
```

### Manual Notarization

```bash
# Submit for notarization
xcrun notarytool submit "dist/BMLibrarian-Lite-0.1.0.dmg" \
    --keychain-profile "bmlibrarian-notarize" \
    --wait

# Staple the ticket
xcrun stapler staple "dist/BMLibrarian-Lite-0.1.0.dmg"

# Verify
xcrun stapler validate "dist/BMLibrarian-Lite-0.1.0.dmg"
```

## Troubleshooting

### "Developer ID Application certificate not found"

- Make sure your certificate is installed in Keychain Access
- Check that it's not expired
- Run `security find-identity -v -p codesigning` to list available certificates

### "The signature is invalid"

- Ensure you're signing inside-out (nested components first)
- Make sure entitlements.plist is correct
- Try `codesign --force` to replace existing signatures

### "Notarization failed"

Check the notarization log:
```bash
xcrun notarytool log <submission-id> --keychain-profile "bmlibrarian-notarize"
```

Common issues:
- Missing hardened runtime entitlements
- Unsigned nested binaries
- Invalid Info.plist

### "App is damaged and can't be opened"

This usually means:
- The app isn't properly signed
- Notarization failed or wasn't stapled
- Try re-downloading the DMG

## Entitlements

The app uses these entitlements (see `assets/entitlements.plist`):

| Entitlement | Purpose |
|-------------|---------|
| `com.apple.security.network.client` | Network access for APIs |
| `com.apple.security.files.user-selected.read-write` | Open/save files via dialogs |
| `com.apple.security.files.downloads.read-write` | Access Downloads folder |
| `com.apple.security.cs.allow-unsigned-executable-memory` | Required for Python |
| `com.apple.security.cs.allow-dyld-environment-variables` | Required for Python |
| `com.apple.security.cs.disable-library-validation` | Required for bundled libraries |

## Distribution Checklist

Before releasing:

- [ ] Version number updated in `src/bmlibrarian_lite/__init__.py`
- [ ] Build with `./scripts/build_macos.sh --sign`
- [ ] Verify signing: `codesign --verify --deep --strict "dist/BMLibrarian Lite.app"`
- [ ] Verify notarization: `xcrun stapler validate "dist/BMLibrarian-Lite-X.Y.Z.dmg"`
- [ ] Test on a clean Mac (without your developer certificates)
- [ ] Upload DMG to GitHub Releases or distribution site
