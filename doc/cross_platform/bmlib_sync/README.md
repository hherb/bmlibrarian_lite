# bmlib sync ledger

`ledger.json` records what became of every change in bmlib (a separate Python
library with a Rust port) on each platform here, and the reverse: what this
repository has that bmlib lacks. Nothing imports bmlib, so without the ledger a
bmlib fix that is not ported by hand goes unnoticed.

## Shape

```json
{"schema": 1, "bmlib_commit": "<full 40-character sha>", "from_bmlib": [Entry], "to_bmlib": [Entry]}
```

- `from_bmlib` entries: `id`, `title`, `python`, `swift`, `android`, `issue`, `note`.
  `id` is `bmlib#N` for a bmlib issue, else `lite:<slug>` or
  `bmlib:<version-or-section>-<slug>`.
- `to_bmlib` entries: the same, with a single `bmlib` status in place of the
  three platforms.
- Status is one of `owed`, `ported`, `equivalent`, `n/a`, `declined`.
- `declined` needs a `note` giving the reason.
- Issue numbers in bmlib and here are different trackers. `issue` is this
  repository's, when there is one; bmlib's are always written `bmlib#N`.

## The check

```bash
python scripts/check_bmlib_ledger.py --bmlib ~/src/bmlib
```

It reads the bold title line of every `CHANGELOG.md` entry newer than
`## [0.10.0]` and takes the issue numbers from the parenthesised group after
the title (pull requests, `PR #N`, and numbers in the body prose are not
read). It exits 1 and lists every `bmlib#N` with no `from_bmlib` entry, then
prints how much is still `owed` per platform.

CI runs it in the `Python tests` workflow, after the tests and whether or not
they passed. It checks out the public `hherb/bmlib` repository at
`bmlib_commit`, so no token or secret is needed. `actions/checkout` takes a
commit only as its full SHA, so the ledger holds all 40 characters, never an
abbreviation (`tests/test_bmlib_ledger.py` fails on one).

## Starting a sync

1. Bump `bmlib_commit` to the full SHA of the bmlib commit being synced
   against (`git -C ~/src/bmlib rev-parse <commit>`).
2. Run the check. Every new id it lists must be triaged: add an entry, with
   `owed` for a change to behaviour the ports mirror (JATS, transparency,
   full text, quality, llm, citations), and `n/a` with a short note for
   server-only modules, samplers, scripts and documentation.
3. CI stays red until every id has an entry.

Entries seeded as "unaudited at seeding" were marked `owed` from the bmlib
changelog alone, without reading each port. Audit them when they are taken up.
