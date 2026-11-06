---
name: finalcheck
description: Use for the final pre-merge pass on the current bmlibrarian_lite PR — review it, fix everything the review found, then drive GitHub CI to green.
disable-model-invocation: false
allowed-tools: Read, Edit, Bash(git *), Bash(gh *), Bash(pytest *), Bash(python *), Bash(python3 *), Bash(uv *), Bash(ruff *), Bash(mypy *), Bash(swift test*), Bash(swift build*), Bash(xcodebuild *), Bash(./gradlew *), Bash(actionlint *)
---
Run these steps in order on the PR for the current branch. First run `pwd && git branch --show-current &&
git worktree list`, and if the branch is checked out in another worktree, `cd` into it. Then find the PR
with `gh pr view --json number,url,headRefOid`. If there is none, stop and tell me.

1. **Review.** Invoke the `pr-review-toolkit:review-pr` skill via the Skill tool and let it finish.
2. **Fix.** First merge `origin/master` into the branch (`git fetch origin && git merge origin/master`) and
   resolve any conflicts. Then read `.claude/skills/fixall/SKILL.md` and follow it on the review's findings.
   It can only be invoked by the user, so do not call it through the Skill tool. It runs the suites for the
   platforms touched and ends by committing and pushing into the PR. Before moving on, confirm the push
   landed: `git fetch origin && git status -sb` must show no `ahead`, and the PR's `headRefOid` must equal
   `git rev-parse HEAD`. A deferred item gets no closing keyword before its number ("Deferred: #N", never
   "not fixed: #N"), in commits and in the PR body alike.
3. **Drive CI to green.** Loop:
   - Watch the checks for the pushed head commit with `gh pr checks --watch --fail-fast`. Checks can take a
     minute to register, so wait if it reports none yet. `xcode-project-guards.yml` is path-gated
     (`*.pbxproj`, shared schemes): it posts no check when those are untouched, and that is normal. The
     scheduled workflows (`bmlib-drift.yml`, `swift-integration-tests.yml`) never run on a PR.
   - All green → done. Report the PR URL and the final check list. The `protect_master` ruleset requires no
     status checks (`gh api repos/hherb/bmlibrarian_lite/rules/branches/master`), so "all green" means every
     check reported on the head commit passed, none pending.
   - A check failed → read the cause: `gh run list --branch "$(git branch --show-current)" --limit 5`, then
     `gh run view <run-id> --log-failed`. Reproduce it locally with the command the failing job runs
     (see `.github/workflows/`):
     - `pytest (Python 3.12)` → `python .github/scripts/qt_preflight.py && pytest tests/ -m "not integration" --strict-markers`
     - `No new ruff or mypy findings` → `git fetch origin master && python .github/scripts/lint_delta.py --base-ref origin/master`
     - `Every bmlib change has a ledger entry` → `git -C ~/src/bmlib worktree add --detach <dir> "$(python scripts/check_bmlib_ledger.py --print-commit)"`,
       then `python scripts/check_bmlib_ledger.py --bmlib <dir>`
     - `Gradle unit tests` → a bmlib worktree at `bmlibCommit` from `Packages/BioMedLit/Frameworks/BmlibFFI.pin.json`, then
       `cd android/MedicalFactChecker && BMLIB_DIR=<dir> ./gradlew testDebugUnitTest --console=plain --rerun-tasks`.
       The job also fails if a bmlib FFI test skips, and if `doc/cross_platform/retraction_parity/retraction_status.json`
       differs from `<dir>/tests/fixtures/retraction_status.json` (`cmp`).
     - `swift test (Packages/BioMedLit)` / `swift test (ios/MedicalFactChecker)` → `swift test` in that directory.
       Run one Swift build at a time: concurrent builds deadlock.
     - `xcodebuild (macOS app)` → in `ios/MedicalFactChecker`: `xcodebuild build -project MedicalFactChecker.xcodeproj
       -scheme MedicalFactChecker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
     - `Package refs stay in-repo, scheme stays shared` → `python3 .github/scripts/xcode_project_guards.py`
     - `Rebuild from the pin and compare` (`bmlib-xcframework.yml`) → read the workflow's header first. The
       committed xcframework must be that job's own build, so re-pin from its artifact as the header says.
       Never rebuild it locally and commit the result.
     - CodeQL → read the alert (`gh api repos/hherb/bmlibrarian_lite/code-scanning/alerts`) and fix the code.
     - a workflow file changed → `actionlint`

     Judge each command by its **exit code**, never by filtered output: `cmd | tail` reports `tail`'s
     status. Fix the root cause, using TDD where it is a code bug. Confirm the fix passes locally, commit
     with a message naming the CI failure, push, and loop again.
   - **CI-only failures.** CI installs the newest dependencies, not `uv.lock`'s. When Python passes locally,
     diff the dependency versions of the last green run against the red one first (PySide6 6.12 was #516).
     Python and Android run on `ubuntu-latest`: reproduce a Linux-only failure in Docker (`python:3.12`, or
     an arm64 Ubuntu image with gdb for a crash; start the daemon with `open -a Docker`). The Swift jobs run
     on `macos-15`: a failure that macOS 26+ does not show (SwiftData on older OSes) reproduces on an iOS 18
     simulator. Don't guess.
   - **A job CANCELLED with no log** hit its `timeout-minutes` or lost its runner. A 30-minute limit means a
     test hung. Treat it as a code bug and find the hang. Do not rerun it as a flake.
   - If the failure is not caused by the code (runner/infra outage, network flake, missing secret, or the
     `Claude Code Review` job failing on its token or quota), rerun once with `gh run rerun <run-id> --failed`.
     If it fails the same way again, stop and report rather than changing code to work around it. The
     Actions API returns empty or stale data during an outage, so re-query before concluding a run never
     happened.
   - Never "fix" CI by skipping or deleting tests (`pytest.mark.skip`, `XCTSkip`, `@Ignore`), by weakening
     lint/CI config, guards or `lint_delta.py`, by adding a `paths:` filter to any job, or by regenerating a
     contract fixture or the JATS corpus digests unread, without my explicit permission. If the same failure
     survives three fix attempts, stop and report what you tried.
4. **Not covered by CI.** Run these locally if the PR needs them, and include the results in the report:
   - `#if os(iOS)` code: no CI job builds the iOS target (#190), so run
     `xcodebuild -scheme MedicalFactChecker -destination 'platform=iOS Simulator,name=<device>' build` in
     `ios/MedicalFactChecker`.
   - The JATS parser: `cd Packages/BioMedLit && swift test --filter JATSXMLParserIntegrationTests` (live PMC,
     scheduled only in CI).
   - A live network path: `pytest tests/ -m integration` for the Python code touched.
