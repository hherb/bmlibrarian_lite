---
name: fixall
description: Use when a code review has produced issues that need to be addressed and the pull request finalized on the bmlibrarian_lite project.
disable-model-invocation: true
allowed-tools: Read, Edit, Bash(git add *), Bash(git commit *), Bash(git push *), Bash(git status *), Bash(git diff *), Bash(gh issue *), Bash(gh pr *), Bash(pytest *), Bash(uv run pytest *), Bash(ruff *), Bash(mypy *), Bash(swift test*), Bash(swift build*), Bash(xcodebuild *), Bash(./gradlew *)

---

Address all issues identified in the code review one by one. If fixing them appears manageable within this session, fix them now. If not, lodge the issue on GitHub. Once all issues have been addressed, run the test suites for the platform(s) you touched:

- Python: `pytest tests/` (plus `ruff check .` and `mypy src/`)
- iOS/macOS app: `cd ios/MedicalFactChecker && swift test`
- Shared Swift package: `cd Packages/BioMedLit && swift test`
- Android: `cd android/MedicalFactChecker && ./gradlew test`
- If you changed iOS/macOS app sources, also verify the app still builds: `xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build` from `ios/MedicalFactChecker/`.

Then review the code changes thoroughly against doc/llm/golden_rules.md (Python/PySide) and doc/llm/general_golden_rules.md (Swift/Kotlin), whichever match the platforms touched. If satisfied no issues are left open, update HANDOVER.md ONLY if necessary to reflect these changes. Then commit and push the changes into the PR.
