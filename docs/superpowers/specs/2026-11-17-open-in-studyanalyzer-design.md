# Open in StudyAnalyzer (macOS, the full-text viewer)

The last step (step 4) of StudyAnalyzer's
`docs/superpowers/specs/2026-11-13-shared-paper-library-design.md` §8, built as
that spec's §5.4 says, with one scope cut, recorded below. Hand-off format:
StudyAnalyzer's `docs/handoff-format.md`.

## Why

A reader looking at a paper's full text in Medical Fact Checker wants to
question it in StudyAnalyzer without finding and opening the paper again. The
paper should arrive with the text Medical Fact Checker already has, and leave
no lasting copy behind. The shared library (steps 1–3, done) keeps the bytes
once.

## Goals, non-goals, anti-goals

- **Goal:** one **Open in StudyAnalyzer** button in the macOS full-text
  viewer's header actions, beside the share menu, opening the paper in
  StudyAnalyzer.
- **Non-goals (for now, the maintainer's call 2026-11-17):** the paper card's
  full-text row and context menu (§5.4 lists them; the same code serves them
  later); iOS (phase 4); the `studyanalyzer://` link.
- **Anti-goals:** a failure that says nothing; a hand-off file left behind for
  good; anything in the file StudyAnalyzer would refuse (checked against its
  fixtures).

## Approaches

1. **The hand-off file, opened with StudyAnalyzer** (chosen; decided in the
   library spec §5.4). It carries the title, sender name and full text, and
   the sandbox grants StudyAnalyzer that one file.
2. **The `studyanalyzer://open?…` link.** Rejected: it carries no title, no
   sender name and no text, and on macOS it works only once StudyAnalyzer is
   in /Applications.
3. **Send only the library digest.** Rejected: it does not work without a
   library, and the hand-off format would have to change. StudyAnalyzer
   already dedupes a hand-off's bytes against the library by digest.

## Design

- **`StudyAnalyzerHandoff`** in BioMedLit, pure Swift: from plain fields
  (pmid, doi, pmcid, title, an optional file of kind, bytes, name and source)
  it builds the `.studyanalyzer` JSON (format `studyanalyzer-handoff`,
  version 1, sender `MedicalFactChecker`). Base64 via
  `Data.base64EncodedString()` with no options; blank fields omitted;
  identifiers sent as stored (StudyAnalyzer checks each one and tells the
  reader of any it drops, so the sender does not repeat its rules). A file
  over 100 MiB (`MAX_HANDOFF_BYTES`' PDF) is not sent; the next source is.
  Tests compare it with StudyAnalyzer's fixtures (`ids_only`, `pdf`, `jats`
  in `crates/studyanalyzer-core/tests/fixtures/handoff/`), with copies placed
  in BioMedLit's test resources.
- **What it sends** (library spec §3). The library's JATS file if the
  document has one (`fullTextLibraryKind` jats, read with
  `FullTextLibrary.read`). Else, for a paper whose text came from JATS
  (Europe PMC, PMC's bucket) while the Mac is online: identifiers only, so
  StudyAnalyzer fetches the JATS itself. Else the local PDF
  (`localPDFFilePath`, or the library's PDF). Else the Markdown
  (`fullTextContent`), else the HTML. When offline: whatever it has, in that
  order. "Online" is an `NWPathMonitor` path status taken at the click.
- **Sending:** the file goes into a `StudyAnalyzerHandoff` folder in the
  app's temporary directory, named by a fresh UUID (`<uuid>.studyanalyzer`:
  a DOI is no safe file name, and the clean-up then touches only its own
  files), and is opened with
  `NSWorkspace.open(_:withApplicationAt:configuration:)`, so Launch Services
  grants StudyAnalyzer that one file. Hand-off files older than a minute are
  deleted on each send and at launch, so a quick second send never pulls the
  first file away before StudyAnalyzer has read it.
- **Shown** only when
  `NSWorkspace.urlForApplication(withBundleIdentifier: "com.bmlibrarian.studyanalyzer")`
  finds the app. A failure (the app gone, the open refused, the file not
  written, a library read failing) is shown in the viewer, never dropped.
  A library read that fails falls back to the next source in the order above,
  and the message says so.

## Left to the builder

The button's icon and label text, how the failure is shown in the viewer
(alert or inline), the mapping from `fullTextSource` to "came from JATS", and
the `source` string sent (the existing source badge's name).
