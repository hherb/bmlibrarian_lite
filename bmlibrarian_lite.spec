# -*- mode: python ; coding: utf-8 -*-
"""
PyInstaller spec file for BMLibrarian Lite macOS app bundle.

Build with:
    pyinstaller bmlibrarian_lite.spec

This creates a standalone .app bundle in the dist/ directory.
"""

import sys
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, collect_submodules

# Get the project root directory
project_root = Path(SPECPATH)
src_dir = project_root / "src"

block_cipher = None

# Collect all modules from packages that have complex structures
fastembed_datas, fastembed_binaries, fastembed_hiddenimports = collect_all('fastembed')
sqlite_vec_datas, sqlite_vec_binaries, sqlite_vec_hiddenimports = collect_all('sqlite_vec')
onnxruntime_hiddenimports = collect_submodules('onnxruntime')

# Hidden imports required for the application
hidden_imports = [
    # PySide6 modules
    "PySide6.QtCore",
    "PySide6.QtGui",
    "PySide6.QtWidgets",
    "PySide6.QtNetwork",
    # SQLite
    "sqlite3",
    # Posthog telemetry
    "posthog",
    # Tokenizers and HuggingFace
    "tokenizers",
    "huggingface_hub",
    # Anthropic
    "anthropic",
    "httpx",
    "httpcore",
    # Ollama
    "ollama",
    # Other dependencies
    "pysbd",
    "markdown",
    "pygments",
    "requests",
    "backoff",
    "dotenv",
    # PDF processing
    "fitz",  # PyMuPDF
    # Standard library that might be missed
    "json",
    "logging",
    "threading",
    "pathlib",
    "dataclasses",
    "typing",
    "re",
    "datetime",
    "uuid",
    "hashlib",
    "base64",
    "urllib.parse",
    "xml.etree.ElementTree",
]

# Add collected hidden imports
hidden_imports.extend(fastembed_hiddenimports)
hidden_imports.extend(sqlite_vec_hiddenimports)
hidden_imports.extend(onnxruntime_hiddenimports)

# Data files to include
datas = [
    # Include the source package
    (str(src_dir / "bmlibrarian_lite"), "bmlibrarian_lite"),
    # Include resources (icons, splash screen)
    (str(src_dir / "bmlibrarian_lite" / "resources"), "bmlibrarian_lite/resources"),
]

# Add collected data files
datas.extend(fastembed_datas)
datas.extend(sqlite_vec_datas)

# Binary files (native libraries)
binaries = []
binaries.extend(fastembed_binaries)
binaries.extend(sqlite_vec_binaries)

a = Analysis(
    [str(project_root / "scripts" / "run_gui.py")],
    pathex=[str(src_dir)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hidden_imports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # Exclude unnecessary modules to reduce size
        "tkinter",
        "test",
        "unittest",
        "pydoc",
        "doctest",
        "lib2to3",
        "idlelib",
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="BMLibrarian Lite",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,  # No console window for GUI app
    disable_windowed_traceback=False,
    argv_emulation=True,  # macOS: allow drag-drop files onto app
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name="BMLibrarian Lite",
)

app = BUNDLE(
    coll,
    name="BMLibrarian Lite.app",
    icon="assets/icon.icns",
    bundle_identifier="me.proton.bmlibrarian.lite",
    version="0.2.0",
    info_plist={
        "CFBundleName": "BMLibrarian Lite",
        "CFBundleDisplayName": "BMLibrarian Lite",
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "0.2.0",
        "CFBundleIdentifier": "me.proton.bmlibrarian.lite",
        "CFBundlePackageType": "APPL",
        "CFBundleSignature": "????",
        "CFBundleExecutable": "BMLibrarian Lite",
        "NSHighResolutionCapable": True,
        "NSRequiresAquaSystemAppearance": False,  # Support dark mode
        "LSMinimumSystemVersion": "10.15",
        "NSHumanReadableCopyright": "Copyright © 2024 Horst Herb. GPL-3.0 License.",
        # Privacy descriptions (required for notarization)
        "NSNetworkVolumesUsageDescription": "BMLibrarian Lite needs network access to search PubMed and communicate with AI providers.",
        "NSDocumentsFolderUsageDescription": "BMLibrarian Lite needs access to your Documents folder to save and load research files.",
        "NSDownloadsFolderUsageDescription": "BMLibrarian Lite needs access to your Downloads folder to import PDF documents.",
        "CFBundleDocumentTypes": [
            {
                "CFBundleTypeName": "PDF Document",
                "CFBundleTypeExtensions": ["pdf"],
                "CFBundleTypeRole": "Viewer",
            },
            {
                "CFBundleTypeName": "Text Document",
                "CFBundleTypeExtensions": ["txt", "md"],
                "CFBundleTypeRole": "Viewer",
            },
        ],
    },
)
