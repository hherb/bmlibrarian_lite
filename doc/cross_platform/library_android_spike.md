# Spike: can a picked folder back bmlib's library on Android? (#790)

**Answer: not as bmlib is today.** `PaperLibrary.open(root: String)` works on
paths through `std::fs`. On Android, a folder the user picks
(`ACTION_OPEN_DOCUMENT_TREE`, persisted grant) can be reached through the
document provider only, never by path. A shared library on Android therefore
needs bmlib to reach its files through a storage seam that Kotlin implements
over `DocumentsContract`. That is a bmlib change, made before any app work.

Measured 2026-11-16 on the `Medium_Phone_API_36.1` emulator (API 36), in the
debug app's own process (an instrumented test; `run-as` is no use here,
because its `runas_app` SELinux context is denied all of `/storage`, even the
app's own folder). The folder was `Documents/bmlib-spike`, holding a marker
and a PDF written by another UID (the shell), as a second app would leave
them.

## What the app can do by path

| Where | List | Read another app's file | Create, write, rename | Rename onto an existing name |
|---|---|---|---|---|
| `getExternalFilesDir()/lib` | yes | (no other app can write there) | yes | replaces (atomic) |
| `Documents/<folder>`, its own files | yes | — | yes | replaces |
| `Documents/<folder>`, another app's files | **hidden** (the folders show, the files do not) | **EACCES** | mkdir works | — |
| The same, **after the tree grant** | still hidden | **still EACCES** | — | — |
| `/proc/self/fd/N` of a provider-opened file | — | **EACCES** when reopened by path | — | — |

So the grant gives nothing to paths, and scoped storage hides every file
another app made, the library's marker, records and sources among them. (Not
measured: whether the raw fd number itself can be read by native code. It
would cover single-file reads only, never listing or writing.)

## What the app can do through the provider (`ExternalStorageProvider`)

Under the granted tree, all of these worked: list children, read the other
UID's marker and PDF, create a folder, create a dot-named temporary file,
write it (`"wt"`), rename it to a new name.

Two answers break bmlib's write rules (design §4.3):

- **Renaming onto an existing name does not replace it.** The provider
  renamed `.tmp2` to `rec (1).json` and left `rec.json` unchanged. bmlib's
  `atomic_write` (a record rewritten as temp + rename) has no equivalent.
- **Creating a document under an existing name is suffixed too** (`rec
  (2).json`). So `write_once` must compare the name it got with the name it
  asked for. If they differ, someone else wrote first: delete ours and check
  the existing file's digest.

## What a provider-backed library needs from bmlib

The library's file calls are almost all in `rust/bmlib/src/library/files.rs`
(listing, reading, `write_once`, `write_replace`, `create_dir_new`,
`rename`, removal, sync), plus a few direct `fs` calls in `scan.rs`. That is
the seam: a storage trait in bmlib, a `std::fs` implementation for today's
platforms, and a UniFFI foreign trait implemented in Kotlin over
`DocumentsContract`. Decisions it needs, each bmlib's:

1. **Replacing a record.** Two choices. The first: write a temporary file,
   delete the old record, rename the temporary into place. That leaves a
   window with no record, so another app's manual clear could find our
   files unused; a crash then leaves only the temporary file, which a later
   open has to recover. The second: rewrite in place with `"wt"`. A crash
   then leaves a short record, which reads as unreadable, and §4.8 already
   says an unreadable record means "others may use it". Neither is atomic.
2. **A lost create race** (the suffixed name above) is an expected outcome,
   not an error.
3. **Syncing data to disk** (`sync_dir`, `sync_name`) has no provider
   equivalent; it becomes a no-op behind the trait.
4. **Not every provider supports rename** (`FLAG_SUPPORTS_RENAME`). Cloud
   providers in particular may not. Either refuse such a folder at *Choose…*
   with a message, or write without a temporary file there.

## Other routes, and why not

- **A library in the app's own storage** (`getExternalFilesDir`): bmlib works
  unchanged, but no other app or sync tool can reach it, the Files app cannot
  show it (Android 11+), and uninstalling the app deletes it. It is a cache,
  not a shared library.
- **`MANAGE_EXTERNAL_STORAGE`** (all files access): paths would work, but
  Google Play allows it only for file managers, backup apps and similar.
  This app ships on Play.
- **A private copy synced to the picked folder by Kotlin**: two copies of
  every paper, plus a sync engine with its own conflicts. It rebuilds what a
  sync service already does.

## Not measured (owed before a plan)

- Providers other than `ExternalStorageProvider`: an SD card, Google Drive,
  a sync app's provider (rename support, listing freshness, offline files).
- How long a scan takes through the provider: every paper folder is a query
  and every record a read, each a binder call. Measure it on a library of a
  few thousand papers before designing the app's own index.
- A real phone (only the emulator was measured).

## The probe

An instrumented test in the app's process (deleted after the measurement). It
started `ActivityResultContracts.OpenDocumentTree()` from `MainActivity`'s
`activityResultRegistry` (via `ActivityScenario`, because Espresso 3.5.1
crashes on API 36, #806), with the initial URI
`DocumentsContract.buildDocumentUri("com.android.externalstorage.documents",
"primary:Documents/bmlib-spike")`. *Use this folder* and *Allow* were tapped
over `adb shell input tap`, at positions read from `uiautomator dump`. It
then tried each operation with `java.io.File` and with
`DocumentsContract`/`ContentResolver`, logging every result. The install used
`installDebug installDebugAndroidTest` plus `am instrument`, which keeps the
app's data; `connectedAndroidTest` uninstalls the app afterwards.
