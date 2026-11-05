# bmlib sync ledger

`ledger.json` records what became of every change in bmlib (a separate Python
library with a Rust port) on each platform here, and the reverse: what this
repository has that bmlib lacks. The desktop imports only bmlib's retraction
rule (pinned in `pyproject.toml`), and the apps link only its Rust library
(pinned in `Packages/BioMedLit/Frameworks/BmlibFFI.pin.json`); everything else
bmlib and this repository share is ported by hand, so without the ledger a bmlib
fix that is not ported goes unnoticed.

## Shape

```json
{"schema": 1, "bmlib_commit": "<full 40-character sha>", "from_bmlib": [Entry], "to_bmlib": [Entry]}
```

- `from_bmlib` entries: `id`, `title`, `python`, `swift`, `android`, `issue`, `note`.
  `id` is `bmlib#N` for a bmlib issue, else `lite:<slug>` or
  `bmlib:<version-or-section>-<slug>`. The `<version-or-section>` is one of
  these:
  - a release (`0.8.0`);
  - a section of the bmlib plan (`s2.5`);
  - `unreleased`, for an `[Unreleased]` changelog entry that names no issue;
  - an issue number, for one part of that issue's change tracked on its own
    row (`bmlib:474-europepmc-pmid-only-lookup`).
- `to_bmlib` entries: the same, with a single `bmlib` status in place of the
  three platforms.
- Status is one of `owed`, `ported`, `equivalent`, `n/a`, `declined`.
- `declined` needs a `note` giving the reason.
- Issue numbers in bmlib and here are different trackers. `issue` is this
  repository's, when there is one; bmlib's are always written `bmlib#N`.

The script checks this shape. A malformed ledger makes it exit 2: a missing
key, an unknown status, a `declined` with no note, a repeated id, or a
`bmlib_commit` that isn't a full SHA.

## The check

```bash
# Against the pinned commit, as CI runs it (only CHANGELOG.md is read):
mkdir -p /tmp/bmlib-pinned
git -C ~/src/bmlib show \
    "$(python scripts/check_bmlib_ledger.py --print-commit):CHANGELOG.md" \
    > /tmp/bmlib-pinned/CHANGELOG.md
python scripts/check_bmlib_ledger.py --bmlib /tmp/bmlib-pinned

# Against a checkout as it stands, which is how a sync starts:
python scripts/check_bmlib_ledger.py --bmlib ~/src/bmlib
```

It reads the bold title of every `CHANGELOG.md` entry newer than
`## [0.10.0]`:

- **Issue numbers** come from the parenthesised group after the title. A range
  (`#165-#170`, or with an en dash) names every issue in it, up to 50.
  Pull requests (`PR #N`) and numbers in the body prose are not read. Every
  `bmlib#N` with no `from_bmlib` entry is listed.
- **An entry whose group names no issue** needs a `bmlib:<slug>` entry whose
  `title` is the changelog title. Differences in whitespace and a trailing
  period are ignored; every other character must match. An entry with no such
  ledger row is listed by its title.

If anything is listed, the check exits 1. Either way, it prints how many
entries each platform still owes.

It exits 2 when it can't read an input. Without this, a changelog it couldn't
read would pass as "nothing missing". The unreadable inputs are:

- a missing file;
- a malformed ledger;
- a changelog with no `## [0.10.0]` heading, or no `- **` entries;
- an entry bulleted `*` or `+`;
- a bold title that is never closed;
- a range that runs backwards or past the cap.

## How drift is seen

Two CI jobs run the same check against different bmlib commits:

- **Every pull request and push** (`Python tests` workflow, job
  `bmlib-ledger`) checks against `bmlib_commit`, the pinned commit. This
  catches an entry that was deleted, or a pin that was bumped without triage.
  It can't see bmlib move, because the pin doesn't move.
  - `actions/checkout` takes a commit only as its full SHA, so the ledger
    holds all 40 characters.
  - The step that reads the SHA fails on a malformed ledger. It never falls
    back to bmlib's default branch.
- **Weekly, and on demand** (`bmlib drift` workflow, Mondays 06:17 UTC, or
  *Run workflow*) checks against bmlib's `main`.
  - The run fails until the pin is bumped and the new entries are added. Its
    summary page names bmlib's head SHA and lists every id and title not yet
    triaged.
  - It never runs on a pull request, so bmlib moving never blocks a merge
    here.
  - GitHub emails a failed scheduled run to whoever last changed the
    workflow's cron.

Both jobs check out only `CHANGELOG.md` from the public `hherb/bmlib`
repository, with no token.

## Starting a sync

1. Bump `bmlib_commit` to the full SHA of the bmlib commit being synced
   against (`git -C ~/src/bmlib rev-parse <commit>`). The drift run's summary
   names bmlib's current head.
2. Run the check. Every new id and id-less title it lists must be triaged by
   adding an entry. Read each port before setting a status:
   - `owed` for a change to behaviour the ports mirror (JATS, transparency,
     full text, quality, llm, citations);
   - `n/a`, with a short note, for server-only modules, samplers, scripts and
     documentation.

   Lodge an issue here for a defect a port still has, and name it in `issue`.
3. CI stays red until every id and title has an entry.

An entry whose note says "unaudited at seeding" was triaged from the bmlib
changelog alone, without reading each port. Audit it when it's taken up.
