# Shared paper library 3d (macOS): the manual clear Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From the Library setting, MedicalFactChecker (macOS) lists the
library's papers, each with its files, their sizes and the apps that use
them, and removes a paper (its folder) or one file after a confirmation that
names the other apps still using it.

**Architecture:** A BioMedLit engine (`LibraryClear`, macOS) lists from one
bmlib scan and removes through bmlib's `removeFolder` / `removeFile` after a
fresh scan still lists what is removed (StudyAnalyzer's `library_clear.rs`,
the same rules). The app side notes each document whose library file is gone
(`LibraryMover.noteRemoved`, `noteLibraryFileLeft`); the Settings tab shows the
list and the confirmation.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, BmlibFFI (bmlib-ffi at
`747e7a80`, unchanged: `scan`, `folders`, `problems`, `removeFile`,
`removeFolder`), XCTest.

**Spec:** StudyAnalyzer's
`docs/superpowers/specs/2026-11-13-shared-paper-library-design.md` §4.8 and
§5.3; StudyAnalyzer's `crates/studyanalyzer-core/src/library_clear.rs` and
`src/lib/library.ts` for the rules and wording.

## Global Constraints

- Nothing is removed but on the user's confirmed request (§4.8).
- A fresh scan must still list the folder (and the file) before anything is
  removed: a list shown earlier may be stale. Otherwise nothing is removed and
  the reader is told the list is out of date.
- A folder name bmlib refuses (`BadName`) is not touched; the reader is asked
  to rename it. A folder removal that fails otherwise may be partly done, and
  the reader is told so.
- Removing a file leaves every record listing it, so each app reports it
  missing; this app notes its own documents (`libraryRemovedNote`) unless the
  same bytes are still in the library elsewhere. Nothing is downloaded again
  on its own (a later fetch runs the chain: bmlib's `newest_source` skips a
  file not on disk).
- Sizes are read from the disk (`FileManager`), nil when unreadable; shown
  with `ByteCountFormatter`.
- Every library and disk call runs off the main actor; `Document`s change
  only on it. Every FFI call keeps a catch-all `catch`; bmlib's text is kept.
- Copy in `BioMedLitConstants`; `#if os(macOS)`; iOS unchanged.

## Tasks

### Task 1: `LibraryClear` (BioMedLit)

- Create `Packages/BioMedLit/Sources/BioMedLit/Library/LibraryClear.swift`:
  `LibraryListedFile { name, size: UInt64?, usedBy: [String], usedHere }`,
  `LibraryListedPaper { folder, title, files }` (+ `size`, `usedBy`,
  `usedHere` over its files), `LibraryListing { papers, problems: [String] }`,
  `LibraryClear.list(_:installationID:)`, `LibraryClear.remove(_:folder:name:)`
  returning the removed files' references (from the records), and the pure
  wording: `sizeText`, `usersText`, `removeQuestion`.
- Constants: the clear's sentences.
- Tests `LibraryClearTests` on real libraries, another installation saving
  through the FFI: users and sizes; remove one file (others stay, records
  still list it); remove a paper; stale or made-up names refused with nothing
  removed (`..`, `../bmlib-library.json`); a refused folder name asks for a
  rename; the wording.

### Task 2: the app side

- `LibraryMover.noteRemoved(_:gone:)`: notes the documents whose library
  file is one of the removed ones.
- `LibraryController.listLibrary()` and `removeFromLibrary(folder:name:)`:
  off the main actor; after a removal, each document using a removed file
  that the library no longer holds (`path(of:)` nil) gets
  `libraryRemovedNote`; saved.
- Test in `LibraryMoverTests`.

### Task 3: the Settings tab

- *Papers in the Library* while reachable: *Show the Library's Papers* /
  *Read the List Again*; each paper with its size and users, *Remove
  Paper…*; each file with its size and users, *Remove File…*; an alert with
  `removeQuestion`, *Remove* (destructive) and *Keep It*; the outcome line;
  the scan's problems. The list is read again after every removal, a failed
  one too.

### Task 4: Docs

- HANDOVER (3d landed, click-through owed), CLAUDE.md's `Library/` line.

## As built

- At the pin (`747e7a80`) the scan does not report a folder bmlib cannot
  name (`con`) as a problem; `removeFolder` still refuses it, as tested.
- A removal whose documents' notes cannot be saved says it was removed
  (`libraryClearNotesNotSaved`), not 3c's "this app keeps its copies".
- The section is in `MacLibrarySettingsTab.swift` (no project-file edit).

## Owed: the click-through (sandboxed build)

1. With a library holding a few papers, *Show the Library's Papers*: titles,
   sizes and users; a paper StudyAnalyzer also uses names it.
2. *Remove File…* on a PDF this app uses: the confirmation names the other
   app; after it, the document's banner says the file was removed.
3. *Remove Paper…*: the folder is gone from Finder.
4. Delete a folder in Finder, then *Remove Paper…* on the stale list: it is
   refused and the list is read again.
