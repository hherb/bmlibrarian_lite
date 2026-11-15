# Shared paper library, step 3a: MedicalFactChecker's Library setting (macOS) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The macOS app can be given a library folder. *Choose…* makes or
opens a bmlib library there and keeps a security-scoped bookmark. Launch
resolves the bookmark and holds access until the app quits. The setting
shows the library, or why it cannot be reached. Nothing is read from the
library or saved into it yet: that is step 3b.

**Architecture:** The xcframework is re-pinned to bmlib `ac16ee90`
(StudyAnalyzer's pin, past bmlib #777 and #779). A new BioMedLit folder,
`Sources/BioMedLit/Library/`, wraps bmlib-ffi's `PaperLibrary`. No BmlibCore
type is public, which is the house rule of `BmlibJATSAdapter.swift`. It has
three files:

- `LibraryInstallation`: the installation's id and label.
- `LibraryBookmark`: make and resolve a bookmark (macOS only).
- `LibraryAccess`: choose, resume and stop, plus the state the UI shows.

The app keeps the bookmark and the installation id in `AppSettings`
(UserDefaults, as every setting there). A new `LibraryController`
(`@Observable`, app side) resumes at launch, holds the access and stops it
at `NSApplication.willTerminateNotification`. A new Settings tab,
*Library*, shows the state and offers *Choose…* and *Stop using a library*.

**Tech Stack:** Swift 5.9+/SwiftUI, Foundation's `URL` bookmark API,
BmlibFFI (UniFFI 0.32.2), XCTest.

**Spec:** StudyAnalyzer's
`docs/superpowers/specs/2026-11-13-shared-paper-library-design.md`, §4.1
(choosing), §4.2 (the installation id and label), §4.6 (unreachable), §5.3
and §8 step 3. It lives in `~/src/studyanalyzer`; read it there.

## Global Constraints

- "Until a folder is chosen, an app works as it does today (its own
  storage). The setting says so and offers *Choose…*; nothing nags." (§4.1)
- "A folder that is neither (other files, no marker) is refused with a
  message." bmlib's `PaperLibrary.open` does this check (`NotALibrary`). Show
  its text; never re-implement it.
- The installation id is "a random UUID in lower case (bmlib refuses upper
  case, which Swift's `uuidString` gives) made at the app's first use of a
  library, kept in the app's settings". The record label is the app and
  the machine's name: "MedicalFactChecker on Horst's MacBook". bmlib
  requires `app` = `[a-z0-9]{1,40}` and a label of 1–200 chars with no
  control or bidi characters. The app is `medicalfactchecker`.
- "access started at launch, stopped at exit" (§4.1). Entitlement
  `com.apple.security.files.bookmarks.app-scope` is added (§5.3);
  `files.user-selected.read-write` is already there.
- Every `PaperLibrary` call does disk I/O on the calling thread
  (bmlib-ffi's module doc). Call it off the main thread.
- `LibraryError`'s text is bmlib's own. Add
  `extension LibraryError: CustomStringConvertible {}` once, as the binding's
  doc (`bmlib_ffi.swift`, above `public enum LibraryError`) asks.
- A Rust panic reaches Swift as a plain `Error`. Every FFI call site keeps a
  catch-all `catch` (`BmlibJATSAdapter.swift` explains this).
- No magic numbers or strings: keys in `AppSettings.Keys`, library constants
  in `BioMedLitConstants` (Utilities/Constants.swift).
- Never truncate. A machine name that would make the label invalid (over
  200 characters, or only control characters) gives the bare app name
  instead of a cut one.
- Behave as StudyAnalyzer does (its `library_setting.rs`, `bookmark.rs`):
  - Refuse a folder in the Trash when it is chosen.
  - Read a bookmark that resolves into the Trash as lost.
  - Follow a moved or renamed folder.
  - Make a stale bookmark again.
  - A failed access start is lost only when sandboxed
    (`APP_SANDBOX_CONTAINER_ID` set). Unsandboxed, it is harmless.
- iOS joins in phase 4. The bookmark code is `#if os(macOS)`, and the iOS
  settings view is untouched.

## Out of scope (later PRs of step 3)

- **3b:** the fetch through the library: lookup by identifier, saving PDFs
  and JATS, `Document`'s digest and kind, sources *waiting for the library*,
  and the banner while unreachable. The banner comes with 3b, the first
  time an unreachable library changes anything.
- **3c:** moving the PDF cache in, and switching folders with a copy.
- **3d:** the manual clear.
- Desktop (Python) and Android adoption: their ledger rows become `owed`
  with an issue each (Task 1).

## Review Focus

1. **A folder chosen, then deleted or on an unplugged drive at the next
   launch.** The setting says it cannot be reached and why. The bookmark is
   kept, so plugging the drive back in and relaunching recovers it. Test:
   `testResumeOfDeletedFolderIsLostAndKeepsNoAccess` (Task 3).
2. **A folder renamed between launches.** It is followed, and the setting
   shows the new name. Test: `testResumeFollowsRenamedFolder` (Task 3).
3. **Choosing a folder of the user's own files.** It is refused with
   bmlib's message, and the previous library, if any, stays set. Tests:
   `testChooseRefusesFolderWithOtherFiles` (Task 3) and
   `testFailedChooseKeepsPreviousLibrary` (Task 4).
4. **Choosing a folder in the Trash.** Refused before anything is written.
   Test: `testChooseRefusesFolderInTrash` (Task 3).
5. **The installation id across launches.** Made once, lower case, and the
   same on every later launch, also after *Stop using a library* and
   choosing again. A new id would orphan this installation's records. Test:
   `testInstallationIDIsMadeOnceAndKept` (Task 4).

---

### Task 1: Re-pin BmlibFFI to bmlib `ac16ee90`; ledger rows

**Files:**
- Modify: `Packages/BioMedLit/Frameworks/BmlibFFI.pin.json`
- Replace (from the CI artifact): `Packages/BioMedLit/Frameworks/BmlibFFI.xcframework`,
  `Packages/BioMedLit/Sources/BmlibCore/bmlib_ffi.swift`,
  `android/MedicalFactChecker/app/src/main/java/org/bmlib/ffi/bmlib_ffi.kt`
- Modify: `doc/cross_platform/bmlib_sync/ledger.json`

**Interfaces:**
- Produces: `LibraryError.ForeignJats` in the Swift binding (bmlib #779),
  and the library calls listed in Task 3.

- [ ] **Step 1:** In the pin, set `bmlibCommit` to
  `ac16ee9083…` (run `git -C ~/src/bmlib rev-parse ac16ee90` for the full
  SHA). Check whether bmlib's `rust-toolchain`/CI moved rustc past 1.98.0
  at that commit; if it did, set `rustc` too. Commit, push the branch and
  open a **draft** PR so the `bmlib xcframework` workflow runs.
- [ ] **Step 2:** The run fails by design and uploads `bmlib-xcframework`.
  `gh run download <run-id> -n bmlib-xcframework`. Unpack `xcframework.tgz`
  as the workflow header (`.github/workflows/bmlib-xcframework.yml:11-22`)
  says, dSYMs included. Copy `treeSha256` and `xcode` from its
  `build.json` into the pin.
- [ ] **Step 3:** Verify:
  `python .github/scripts/xcframework_tree_sha256.py Packages/BioMedLit/Frameworks/BmlibFFI.xcframework --check Packages/BioMedLit/Frameworks/BmlibFFI.pin.json`
  exits 0, and the Android build's pin check passes:
  `cd android/MedicalFactChecker && BMLIB_DIR=<bmlib worktree at ac16ee90> ./gradlew test`.
- [ ] **Step 4:** Update the ledger.
  - Set `bmlib_commit` to the full SHA.
  - Add rows `bmlib#761` and `bmlib#766`, titled from bmlib's CHANGELOG
    entries.
  - In the library rows (`bmlib#755`, `#767`, `#768`, `#769`, `#761`,
    `#766`, `bmlib:unreleased-library-ffi`, `bmlib:unreleased-library`), set
    `swift` to `owed` with this repository's step-3 issue (Step 5).
  - Set `python` and `android` to `owed` with their own issues. Replace the
    note "Adopting it is the maintainer's call" with: "Decided 2026-11-15:
    every app uses the library wherever its platform allows."
  - Run the check the README gives (against the pinned changelog). Expected:
    exit 0.
- [ ] **Step 5:** Open three issues in `hherb/bmlibrarian_lite`, then put
  their numbers in Step 4's rows:
  - "Shared paper library: macOS app (step 3a–3d)"
  - "Shared paper library: desktop app"
  - "Shared paper library: Android (phase 4)"
- [ ] **Step 6:** Run every gate: `swift test` in `Packages/BioMedLit` and
  `ios/MedicalFactChecker`, the macOS `xcodebuild`, `pytest tests/test_bmlib_ledger.py`.
  Expected: all pass, and the `bmlib xcframework` job is green on the PR.
  Commit: `build(ffi): re-pin BmlibFFI to bmlib ac16ee90 (#761, #766)`.

### Task 2: `LibraryInstallation` (BioMedLit)

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Library/LibraryInstallation.swift`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift`
  (add `libraryAppName = "medicalfactchecker"`,
  `libraryAppDisplayName = "MedicalFactChecker"`, `libraryLabelMaxChars = 200`)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/LibraryInstallationTests.swift`

**Interfaces:**
- Produces:
  - `public enum LibraryInstallation`
  - `static func newID() -> String`: a lower-case UUID string.
  - `static func label(machineName: String?) -> String`
  - `static func isValidID(_ id: String) -> Bool`: `[a-z0-9-]{1,64}`. The
    app uses it to remake an id the defaults hold in another form.

- [ ] **Step 1: Write the failing tests**
  - `testNewIDIsLowerCaseUUID`: `newID()` has 36 chars, equals its
    `.lowercased()`, and `isValidID` is true for it.
  - `testLabelNamesAppAndMachine`: `label(machineName: "Horst's MacBook")`
    equals `"MedicalFactChecker on Horst's MacBook"`.
  - `testLabelWithoutMachineIsAppName`: `nil`, `""` and `"  \n"` give
    `"MedicalFactChecker"`.
  - `testLabelDropsControlAndBidiCharacters`: `"Mac\u{202E}Book\u{0007}"`
    gives `"MedicalFactChecker on MacBook"`.
  - `testOverlongMachineNameGivesAppName`: a 300-char name gives
    `"MedicalFactChecker"`. It is not cut.
  - `testLabelIsAcceptedByBmlib`: for each label above,
    `installationNew(app:id:label:)` does not throw. This test may import
    BmlibCore, as the Retraction tests do.
- [ ] **Step 2:** Run `swift test --filter LibraryInstallationTests` in
  `Packages/BioMedLit`. Expected: FAIL (no such type).
- [ ] **Step 3:** Implement. Bidi controls are the set bmlib's
  `is_bidi_control` refuses: U+200E, U+200F, U+202A–U+202E and
  U+2066–U+2069. Trim whitespace first.
- [ ] **Step 4:** Run the tests. Expected: PASS. Commit:
  `feat(library): the installation id and label`.

### Task 3: `LibraryBookmark` and `LibraryAccess` (BioMedLit, macOS)

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Library/LibraryBookmark.swift`
  (`#if os(macOS)`)
- Create: `Packages/BioMedLit/Sources/BioMedLit/Library/LibraryAccess.swift`
  (`#if os(macOS)`; the `LibraryError: CustomStringConvertible` extension
  goes here)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/LibraryAccessTests.swift`
  (`#if os(macOS)`)

**Interfaces:**
- Consumes: BmlibCore `PaperLibrary.open(root:)`, `LibraryError`.
- Produces:
  - `public struct ResolvedBookmark { public let url: URL; public let isStale: Bool }`.
  - `public enum LibraryBookmark`:
    - `static func make(for url: URL) throws -> Data`: `.withSecurityScope`.
    - `static func resolve(_ data: Data) throws -> ResolvedBookmark`:
      `[.withSecurityScope, .withoutUI]`.
  - `public final class LibraryAccess: @unchecked Sendable`. It holds the
    started URL and the internal `PaperLibrary`. Its members:
    - `public let folderURL: URL`
    - `public var folderName: String`
    - `public func stop()`: stops access once, and is safe to call twice.
      `deinit` calls it.
    - `internal let library: PaperLibrary`, for step 3b.
  - `public struct LibraryChoice { public let access: LibraryAccess; public let bookmark: Data }`.
  - `public enum LibraryResume`. Its cases:
    - `.held(LibraryAccess, renewedBookmark: Data?)`. The bookmark is made
      again on every resume that holds access, which covers both a stale
      bookmark and a moved folder. The caller stores it. It is nil only when
      remaking failed.
    - `.lost(reason: String)`
  - `public struct LibrarySetupError: Error, CustomStringConvertible { public let description: String }`.
  - `public enum LibrarySetup`:
    - `static func choose(_ url: URL, sandboxed: Bool = LibrarySetup.isSandboxed) throws -> LibraryChoice`
    - `static func resume(bookmark: Data, sandboxed: Bool = LibrarySetup.isSandboxed) -> LibraryResume`
    - `static var isSandboxed: Bool`: `APP_SANDBOX_CONTAINER_ID` is in the
      environment.

`choose` runs these steps in order:

1. Refuse a URL inside the Trash. Use
   `FileManager.default.url(for: .trashDirectory, in: .userDomainMask, …)`,
   comparing standardized, symlink-resolved paths by component prefix.
2. Start access.
3. `PaperLibrary.open(root:)`. bmlib creates the library in an empty folder
   and refuses a non-library folder.
4. Make the bookmark.

Any failure stops access and throws a `LibrarySetupError` with bmlib's or
Foundation's text, the folder named.

`resume` runs these steps in order:

1. Resolve. A failure is lost: "the folder could not be found (…)".
2. In the Trash is lost: "the folder is in the Trash; put it back, or
   choose another folder".
3. Start access. When `!started && sandboxed`, it is lost: "macOS did not
   grant access to the folder; choose it again".
4. `PaperLibrary.open`. On failure, stop access and return lost with
   bmlib's text.
5. Make the bookmark again. If that fails, log it, keep holding, and set
   `renewedBookmark` to nil. Log a stale bookmark first, as diagnostics.

- [ ] **Step 1: Write the failing tests.** Each test uses a fresh folder
  under `FileManager.default.temporaryDirectory`. Compare paths after
  `.resolvingSymlinksInPath()`: `/var` is `/private/var`.
  - `testBookmarkResolvesToItsFolder`: the resolved path matches, and
    `isStale` is false.
  - `testChooseMakesLibraryInEmptyFolder`: afterwards
    `bmlib-library.json` exists in the folder, and `folderName` is its last
    component.
  - `testChooseRefusesFolderWithOtherFiles`: a folder holding `notes.txt`
    throws, `description` is non-empty, and no marker is written.
  - `testChooseRefusesFolderInTrash`: a folder made under the user's
    Trash throws, and no marker is written. Skip with `XCTSkip` when the
    Trash URL is unavailable.
  - `testResumeFollowsRenamedFolder`: choose, then `moveItem` the folder
    to a new name. `resume` is `.held`, its `folderURL` is the new path,
    and `renewedBookmark` is non-nil.
  - `testResumeOfDeletedFolderIsLostAndKeepsNoAccess`: choose, then delete
    the folder. `resume` is `.lost` with a non-empty reason.
  - `testResumeOfGarbageIsLost`: `resume(bookmark: Data([1,2,3]))` is
    `.lost`.
  - `testResumeRefusedAccessIsLostOnlyWhenSandboxed`: test the pure
    decision `LibrarySetup.accessRefused(started:sandboxed:)` (internal,
    `@testable`). `(false, true)` is true, and the other three
    combinations are false.
  - `testStopTwiceIsSafe`.
- [ ] **Step 2:** Run `swift test --filter LibraryAccessTests`. Expected:
  FAIL.
- [ ] **Step 3:** Implement as above. Call the FFI inside `do { … } catch
  let e as LibraryError { … } catch { … }`.
- [ ] **Step 4:** Run the tests, then the full BioMedLit `swift test`.
  Expected: PASS. Commit: `feat(library): choose, resume and stop a library
  folder (macOS)`.

### Task 4: The app: settings, controller, Settings tab, entitlement

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Models/AppSettings.swift`. Add
  `libraryBookmark: Data?` and `libraryInstallationID: String?`, with keys
  `library_bookmark` and `library_installation_id`.
- Create: `ios/MedicalFactChecker/Sources/macOS/App/LibraryController.swift`
- Create: `ios/MedicalFactChecker/Sources/macOS/Views/Settings/MacLibrarySettingsTab.swift`
- Modify: `ios/MedicalFactChecker/Sources/macOS/Views/Settings/MacSettingsView.swift`.
  Add the *Library* tab after *Sync*.
- Modify: `ios/MedicalFactChecker/Sources/macOS/App/MedicalFactCheckerMacApp.swift`.
  Create the controller, resume at launch, stop on
  `willTerminateNotification`, and pass it in the environment.
- Modify: `ios/MedicalFactChecker/Sources/MedicalFactCheckerMac.entitlements`.
  Add `com.apple.security.files.bookmarks.app-scope` = true.
- Modify: `MedicalFactChecker.xcodeproj` (the two new files, via
  `add_macos_sources.rb` or Xcode). The `xcode-project-guards` job must
  stay green.
- Test: `ios/MedicalFactChecker/Tests/LibrarySettingsTests.swift`. The
  controller is macOS-only and the app's SwiftPM target excludes
  `Sources/macOS`, so keep the decisions pure in `AppSettings` and test
  them there.

**Interfaces:**
- Consumes: Task 2's `LibraryInstallation`, and Task 3's `LibrarySetup`,
  `LibraryAccess`, `LibraryResume` and `LibraryChoice`.
- Produces:
  - `AppSettings.libraryInstallationIDEnsured() -> String`. It returns the
    stored id when `LibraryInstallation.isValidID` holds; otherwise it
    makes one, stores it and returns it.
  - `@MainActor @Observable final class LibraryController`, used by 3b–3d:
    - `var state: LibraryState`
    - `var access: LibraryAccess?`
    - `func resumeAtLaunch() async`
    - `func choose(_ url: URL) async`
    - `func stopUsing()`
    - `func stopAccess()`
  - `public enum LibraryState: Equatable` in BioMedLit, with cases
    `.notChosen`, `.reachable(folderName: String, path: String)` and
    `.unreachable(reason: String)`.

Controller rules:

- **`resumeAtLaunch`** runs `LibrarySetup.resume` off the main actor
  (`Task.detached`). It stores a `renewedBookmark`, and logs and shows its
  outcome. `.lost` keeps the bookmark: a drive may come back.
- **`choose`** calls `libraryInstallationIDEnsured()` first, then runs
  `LibrarySetup.choose` off the main actor.
  - On success, it stops the old access, stores the new bookmark and holds
    the new access.
  - On failure, the previous bookmark, access and state stay unchanged,
    and the error shows under the button. Log it with
    `BioMedLitLib.logger` / the app logger, as the Retraction code does.
- **`stopUsing`** stops access and clears the bookmark (not the
  installation id), and the state becomes `.notChosen`. The library folder
  is never changed.

Tab copy:

- `.notChosen`: "No library folder is set. Papers are kept in this app's
  own storage." Offer *Choose…*.
- `.reachable`: the folder name, the path (selectable text), and
  *Choose another…*. Offer *Stop using this library* with an inline
  confirmation; `confirm()` dialogs are not used.
- `.unreachable`: "The library folder cannot be reached: <reason>", with
  *Choose…*.

*Choose…* is an `NSOpenPanel` with `canChooseDirectories = true`,
`canChooseFiles = false`, `canCreateDirectories = true` and
`prompt = "Use as Library"`.

- [ ] **Step 1: Write the failing tests** in `LibrarySettingsTests`, using
  a fresh `UserDefaults(suiteName:)`. If `AppSettings` reads only
  `.standard`, give `init` a `defaults: UserDefaults = .standard`
  parameter, as its `credentialFlags` already does.
  - `testInstallationIDIsMadeOnceAndKept`: the first call stores a valid
    id; a second call, and a fresh `AppSettings` on the same suite, return
    the same id.
  - `testUpperCaseStoredIDIsReplaced`: a stored `"ABC-DEF"` is replaced by
    a valid lower-case id.
  - `testBookmarkPersists`: setting `libraryBookmark` and making a fresh
    `AppSettings` reads it back; setting `nil` removes it.
  - `testFailedChooseKeepsPreviousLibrary`: test the pure function
    `LibraryState.after(choiceFailed:previous:)` in BioMedLit, which keeps
    the previous state. Add it with this task, so the rule is testable
    without the macOS controller.
- [ ] **Step 2:** Run `swift test --filter LibrarySettingsTests` in
  `ios/MedicalFactChecker`. Expected: FAIL.
- [ ] **Step 3:** Implement the settings, the controller, the tab, the
  app wiring and the entitlement.
- [ ] **Step 4:** Run both `swift test` suites and
  `xcodebuild build -project MedicalFactChecker.xcodeproj -scheme MedicalFactChecker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
  Expected: PASS and BUILD SUCCEEDED.
- [ ] **Step 5:** Click through (the maintainer's, if no agent can drive
  the window). Using a signed, sandboxed Debug build:
  - choose an empty folder, and the marker appears;
  - quit and relaunch, and it is still reachable;
  - rename the folder, relaunch, and the new name shows;
  - eject or delete it, relaunch, and the reason shows;
  - choose a folder of documents, and it is refused with the old one kept;
  - *Stop using this library*, then choose again, and the record files
    later carry the same installation id.

  Note in HANDOVER what was and was not clicked.
- [ ] **Step 6:** Commit: `feat(mac): the Library setting, its bookmark and
  launch access`.

### Task 5: Docs and hand-over

**Files:**
- Modify: `HANDOVER.md` (under 500 lines): the re-pin paragraph, the
  maintainer's decision (now taken, 2026-11-15), and 3a's state with 3b–3d
  next. Prune landed sections to stay under 500.
- Modify: `CLAUDE.md`'s BioMedLit section: add `Library/`
  (LibraryInstallation, LibraryBookmark, LibraryAccess).
- Modify: `ios/MedicalFactChecker/HELP.md` and `PRIVACY.md`. Add one
  paragraph each: the library is a folder the user picks; files stay on
  the user's disk; nothing is sent anywhere. Then re-run
  `website/build_privacy.py`.

- [ ] **Step 1:** Write the docs and reflow them to the files' width.
- [ ] **Step 2:** Run every gate again. Push, mark the PR ready, and make
  sure it links the macOS issue (`Part of #N`). CI must be green.
- [ ] **Step 3:** In StudyAnalyzer's HANDOVER and ROADMAP, note step 3a's PR.
