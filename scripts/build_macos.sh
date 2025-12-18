#!/bin/bash
#
# Build script for BMLibrarian Lite macOS DMG installer
#
# Usage:
#   ./scripts/build_macos.sh              # Build unsigned (for testing)
#   ./scripts/build_macos.sh --sign       # Build, sign, and notarize (for distribution)
#
# Requirements:
#   - Python 3.12+ with venv
#   - PyInstaller (installed automatically if missing)
#   - For signing: Apple Developer ID certificate installed in Keychain
#   - For notarization: App-specific password stored in Keychain
#
# Environment variables for signing (set these or use Keychain):
#   DEVELOPER_ID      - Your Developer ID Application certificate name
#                       e.g., "Developer ID Application: Your Name (TEAM_ID)"
#   APPLE_ID          - Your Apple ID email for notarization
#   TEAM_ID           - Your Apple Developer Team ID
#   NOTARIZE_PASSWORD - Keychain item name for app-specific password
#                       (create with: xcrun notarytool store-credentials)
#
# Output:
#   - dist/BMLibrarian Lite.app           - The macOS application bundle
#   - dist/BMLibrarian-Lite-X.Y.Z.dmg     - The DMG installer

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
SIGN_APP=false
for arg in "$@"; do
    case $arg in
        --sign)
            SIGN_APP=true
            shift
            ;;
    esac
done

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo -e "${GREEN}=== BMLibrarian Lite macOS Build ===${NC}"
echo "Project root: $PROJECT_ROOT"

# Get version from __init__.py
VERSION=$(grep -o '__version__ = "[^"]*"' src/bmlibrarian_lite/__init__.py | cut -d'"' -f2)
echo "Version: $VERSION"
echo "Signing: $SIGN_APP"

# Check for virtual environment
if [ ! -d ".venv" ]; then
    echo -e "${YELLOW}Creating virtual environment...${NC}"
    python3 -m venv .venv
fi

# Activate virtual environment
echo -e "${GREEN}Activating virtual environment...${NC}"
source .venv/bin/activate

# Ensure dependencies are installed
echo -e "${GREEN}Installing/updating dependencies...${NC}"
if command -v uv &> /dev/null; then
    uv pip install -e ".[dev]"
    uv pip install pyinstaller
else
    pip install -e ".[dev]"
    pip install pyinstaller
fi

# Clean previous builds
echo -e "${GREEN}Cleaning previous builds...${NC}"
rm -rf build/
rm -rf "dist/BMLibrarian Lite.app"
rm -rf "dist/BMLibrarian Lite"

# Build the app bundle
echo -e "${GREEN}Building macOS app bundle with PyInstaller...${NC}"
pyinstaller bmlibrarian_lite.spec --clean --noconfirm

# Verify the app was created
if [ ! -d "dist/BMLibrarian Lite.app" ]; then
    echo -e "${RED}Error: App bundle was not created!${NC}"
    exit 1
fi

echo -e "${GREEN}App bundle created: dist/BMLibrarian Lite.app${NC}"

# Get app size
APP_SIZE=$(du -sh "dist/BMLibrarian Lite.app" | cut -f1)
echo "App bundle size: $APP_SIZE"

# ============================================================
# Code Signing and Notarization (if --sign flag is provided)
# ============================================================
if [ "$SIGN_APP" = true ]; then
    echo ""
    echo -e "${BLUE}=== Code Signing ===${NC}"

    # Check for required environment variables or use defaults
    if [ -z "$DEVELOPER_ID" ]; then
        # Try to find a Developer ID certificate
        DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
    fi

    if [ -z "$DEVELOPER_ID" ]; then
        echo -e "${RED}Error: No Developer ID certificate found.${NC}"
        echo "Please set DEVELOPER_ID environment variable or install a Developer ID certificate."
        echo "Example: export DEVELOPER_ID=\"Developer ID Application: Your Name (TEAM_ID)\""
        exit 1
    fi

    echo "Using certificate: $DEVELOPER_ID"

    # Sign all nested components first (inside out signing)
    echo -e "${GREEN}Signing nested frameworks and libraries...${NC}"

    # Find and sign all .so, .dylib files
    find "dist/BMLibrarian Lite.app" -name "*.so" -o -name "*.dylib" | while read -r lib; do
        codesign --force --verify --verbose \
            --sign "$DEVELOPER_ID" \
            --options runtime \
            --entitlements "assets/entitlements.plist" \
            "$lib" 2>/dev/null || true
    done

    # Sign any nested .app bundles
    find "dist/BMLibrarian Lite.app" -name "*.app" -type d | while read -r app; do
        if [ "$app" != "dist/BMLibrarian Lite.app" ]; then
            codesign --force --verify --verbose \
                --sign "$DEVELOPER_ID" \
                --options runtime \
                --entitlements "assets/entitlements.plist" \
                "$app"
        fi
    done

    # Sign the main executable
    echo -e "${GREEN}Signing main executable...${NC}"
    codesign --force --verify --verbose \
        --sign "$DEVELOPER_ID" \
        --options runtime \
        --entitlements "assets/entitlements.plist" \
        "dist/BMLibrarian Lite.app/Contents/MacOS/BMLibrarian Lite"

    # Sign the entire app bundle
    echo -e "${GREEN}Signing app bundle...${NC}"
    codesign --force --verify --verbose \
        --sign "$DEVELOPER_ID" \
        --options runtime \
        --entitlements "assets/entitlements.plist" \
        --deep \
        "dist/BMLibrarian Lite.app"

    # Verify the signature
    echo -e "${GREEN}Verifying signature...${NC}"
    codesign --verify --deep --strict --verbose=2 "dist/BMLibrarian Lite.app"

    # Check if Gatekeeper would accept it
    echo -e "${GREEN}Checking Gatekeeper assessment...${NC}"
    spctl --assess --type execute --verbose "dist/BMLibrarian Lite.app" || true

    echo -e "${GREEN}Code signing complete!${NC}"
fi

# ============================================================
# Create DMG
# ============================================================
echo ""
echo -e "${BLUE}=== Creating DMG ===${NC}"

DMG_NAME="BMLibrarian-Lite-${VERSION}.dmg"
rm -f "dist/$DMG_NAME"

# Create DMG using hdiutil
DMG_TEMP="dist/dmg_temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"

# Copy app to temp directory
cp -R "dist/BMLibrarian Lite.app" "$DMG_TEMP/"

# Create symlink to Applications
ln -s /Applications "$DMG_TEMP/Applications"

# Create DMG
hdiutil create -volname "BMLibrarian Lite" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "dist/$DMG_NAME"

# Clean up temp directory
rm -rf "$DMG_TEMP"

if [ ! -f "dist/$DMG_NAME" ]; then
    echo -e "${RED}Error: DMG creation failed!${NC}"
    exit 1
fi

DMG_SIZE=$(du -sh "dist/$DMG_NAME" | cut -f1)
echo -e "${GREEN}DMG created: dist/$DMG_NAME (${DMG_SIZE})${NC}"

# ============================================================
# Sign and Notarize DMG (if --sign flag is provided)
# ============================================================
if [ "$SIGN_APP" = true ]; then
    echo ""
    echo -e "${BLUE}=== Signing DMG ===${NC}"

    codesign --force --verify --verbose \
        --sign "$DEVELOPER_ID" \
        "dist/$DMG_NAME"

    echo -e "${GREEN}DMG signed!${NC}"

    # Notarization
    echo ""
    echo -e "${BLUE}=== Notarization ===${NC}"

    # Check for notarization credentials
    if [ -z "$NOTARIZE_PASSWORD" ]; then
        NOTARIZE_PASSWORD="bmlibrarian-notarize"  # Default keychain profile name
    fi

    # Check if the keychain profile exists
    if xcrun notarytool history --keychain-profile "$NOTARIZE_PASSWORD" &>/dev/null; then
        echo "Using keychain profile: $NOTARIZE_PASSWORD"

        echo -e "${GREEN}Submitting for notarization (this may take several minutes)...${NC}"
        xcrun notarytool submit "dist/$DMG_NAME" \
            --keychain-profile "$NOTARIZE_PASSWORD" \
            --wait

        # Staple the notarization ticket to the DMG
        echo -e "${GREEN}Stapling notarization ticket...${NC}"
        xcrun stapler staple "dist/$DMG_NAME"

        # Verify stapling
        xcrun stapler validate "dist/$DMG_NAME"

        echo -e "${GREEN}Notarization complete!${NC}"
    else
        echo -e "${YELLOW}Keychain profile '$NOTARIZE_PASSWORD' not found.${NC}"
        echo ""
        echo "To set up notarization credentials, run:"
        echo -e "${BLUE}  xcrun notarytool store-credentials \"$NOTARIZE_PASSWORD\" \\${NC}"
        echo -e "${BLUE}    --apple-id \"your@email.com\" \\${NC}"
        echo -e "${BLUE}    --team-id \"YOUR_TEAM_ID\" \\${NC}"
        echo -e "${BLUE}    --password \"app-specific-password\"${NC}"
        echo ""
        echo "Then re-run this script with --sign to notarize."
        echo ""
        echo -e "${YELLOW}DMG is signed but NOT notarized.${NC}"
    fi
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo "App bundle: dist/BMLibrarian Lite.app"
echo "DMG installer: dist/$DMG_NAME"

if [ "$SIGN_APP" = true ]; then
    echo ""
    echo "The app has been signed with: $DEVELOPER_ID"
    if xcrun notarytool history --keychain-profile "$NOTARIZE_PASSWORD" &>/dev/null 2>&1; then
        echo "The DMG has been notarized and stapled."
        echo ""
        echo -e "${GREEN}Ready for distribution!${NC}"
    else
        echo -e "${YELLOW}The DMG is signed but NOT notarized.${NC}"
    fi
else
    echo ""
    echo -e "${YELLOW}Note: This build is UNSIGNED.${NC}"
    echo "Users will need to right-click → Open to bypass Gatekeeper."
    echo ""
    echo "To create a signed and notarized build:"
    echo "  ./scripts/build_macos.sh --sign"
fi

echo ""
echo "To test the app:"
echo "  open \"dist/BMLibrarian Lite.app\""
echo ""
echo "To install manually:"
echo "  cp -R \"dist/BMLibrarian Lite.app\" /Applications/"
