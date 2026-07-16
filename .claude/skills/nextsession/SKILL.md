---
name: nextsession
description: Use when starting or resuming a work session on the bmlibrarian_lite project, to load current project state and re-establish the coding rules and session workflow before doing any work.
disable-model-invocation: true
---

read HANDOVER.md and follow the instructions. Ask me if you have any questions.

Our general coding rules live in doc/llm/golden_rules.md (Python/PySide) and doc/llm/general_golden_rules.md (Swift/Kotlin) — read and honour the one(s) matching the platform you are working on. On top of those, follow this session workflow:

1. All tests for the platform(s) you touched must pass before committing, unless I explicitly give permission otherwise:
   - Python: `pytest tests/` (plus `ruff check .` and `mypy src/`)
   - iOS/macOS app: `cd ios/MedicalFactChecker && swift test`
   - Shared Swift package: `cd Packages/BioMedLit && swift test`
   - Android: `cd android/MedicalFactChecker && ./gradlew test`
   - If you changed iOS/macOS app sources, also verify the app still builds: `xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build` from `ios/MedicalFactChecker/`.
2. Before you start working, make sure HANDOVER.md represents the current state of progress and is up to date. If not, update it before you start.
3. Avoid technical debt — if you find an error, fix it when possible; otherwise lodge it as an issue on GitHub.
4. When you are done, update HANDOVER.md to reflect the current state of development and progress. Prune it to stay concise and under 500 lines if possible: remove sections for slices that have landed, focus on what still needs doing, and summarise briefly what has already been done. If you are not sure how to do this, ask me.
5. When the task is complete, commit all changes, push, and open a PR to the master branch. Link the PR to the relevant GitHub issue if applicable, and include a clear description of the changes made and any relevant context for reviewers. If you are not sure how to do this, ask me.
