"""Tests for the CI no-new-findings gate (.github/scripts/lint_delta.py)."""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

PROJECT_ROOT = Path(__file__).parent.parent
SCRIPT_PATH = PROJECT_ROOT / ".github" / "scripts" / "lint_delta.py"


def _load_script() -> ModuleType:
    """Load lint_delta.py as a module (.github/scripts is not a package).

    Returns:
        The loaded lint_delta module.
    """
    spec = importlib.util.spec_from_file_location("lint_delta", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["lint_delta"] = module
    spec.loader.exec_module(module)
    return module


lint_delta = _load_script()


def make_finding(
    tool: str = "ruff",
    path: str = "src/a.py",
    line: int = 1,
    code: str = "D212",
    message: str = "Multi-line docstring summary should start at the first line",
):
    """Build a Finding with sensible defaults for the field under test.

    Args:
        tool: Producing tool name.
        path: Repository-relative file path.
        line: 1-indexed line number.
        code: Rule code.
        message: Diagnostic text.

    Returns:
        The constructed Finding.
    """
    return lint_delta.Finding(tool=tool, path=path, line=line, code=code, message=message)


class TestNewFindings:
    """The multiset delta that decides whether a change made things worse."""

    def test_identical_findings_are_not_new(self):
        """A change that alters nothing lint-visible reports no new findings."""
        findings = [make_finding(line=10), make_finding(path="src/b.py", line=3)]
        assert lint_delta.new_findings(findings, list(findings)) == []

    def test_added_finding_is_reported(self):
        """A finding present only at head is reported."""
        base = [make_finding()]
        added = make_finding(code="F401", message="`os` imported but unused")
        assert lint_delta.new_findings([*base, added], base) == [added]

    def test_removed_finding_is_not_reported(self):
        """Fixing a finding does not fail the gate."""
        base = [make_finding(), make_finding(code="F401", message="unused")]
        assert lint_delta.new_findings([base[0]], base) == []

    def test_line_shift_alone_is_not_new(self):
        """The property the whole gate rests on: identity excludes the line.

        Inserting code above a pre-existing finding moves it down the file.
        If line numbers were part of the identity, every such edit would
        report the untouched finding as new and the gate would be unusable.
        """
        base = [make_finding(line=10)]
        head = [make_finding(line=417)]
        assert lint_delta.new_findings(head, base) == []

    def test_extra_copy_in_same_file_is_new(self):
        """Going from two to three identical findings reports exactly one."""
        base = [make_finding(line=1), make_finding(line=2)]
        head = [make_finding(line=1), make_finding(line=2), make_finding(line=3)]
        introduced = lint_delta.new_findings(head, base)
        assert len(introduced) == 1
        assert introduced[0].line == 3

    def test_fewer_copies_is_not_new(self):
        """Removing one of several identical findings reports nothing."""
        base = [make_finding(line=1), make_finding(line=2)]
        assert lint_delta.new_findings([make_finding(line=1)], base) == []

    def test_same_message_in_another_file_is_new(self):
        """Identity includes the path, so a new offending file is caught."""
        base = [make_finding(path="src/a.py")]
        head = [make_finding(path="src/a.py"), make_finding(path="src/b.py")]
        assert lint_delta.new_findings(head, base) == [make_finding(path="src/b.py")]

    def test_same_code_different_message_is_new(self):
        """Two different problems sharing a rule code stay distinguishable."""
        base = [make_finding(code="F821", message="Undefined name `Citation`")]
        head = [*base, make_finding(code="F821", message="Undefined name `LiteDocument`")]
        assert len(lint_delta.new_findings(head, base)) == 1

    def test_findings_from_different_tools_do_not_offset(self):
        """A fixed ruff finding cannot mask a new mypy error."""
        base = [make_finding(tool="ruff", code="X", message="m")]
        head = [make_finding(tool="mypy", code="X", message="m")]
        assert lint_delta.new_findings(head, base) == head

    def test_reported_findings_carry_head_line_numbers(self):
        """Reviewers need the line in the code under review, not the base."""
        introduced = lint_delta.new_findings([make_finding(line=99)], [])
        assert introduced[0].line == 99


class TestParseRuff:
    """Parsing ruff's JSON payload."""

    def test_parses_code_message_and_relative_path(self, tmp_path):
        """Absolute paths collapse to repository-relative POSIX paths."""
        payload = json.dumps(
            [
                {
                    "filename": str(tmp_path / "src" / "a.py"),
                    "code": "D212",
                    "message": "Multi-line docstring summary",
                    "location": {"row": 12, "column": 1},
                }
            ]
        )
        (finding,) = lint_delta.parse_ruff(payload, tmp_path)
        assert (finding.tool, finding.path, finding.code, finding.line) == (
            "ruff",
            "src/a.py",
            "D212",
            12,
        )

    def test_empty_output_is_no_findings(self):
        """A clean ruff run prints nothing usable; that is zero findings."""
        assert lint_delta.parse_ruff("", Path(".")) == []

    def test_null_code_becomes_placeholder(self, tmp_path):
        """Syntax errors carry no rule code but must still be comparable."""
        payload = json.dumps(
            [
                {
                    "filename": str(tmp_path / "a.py"),
                    "code": None,
                    "message": "SyntaxError: unexpected token",
                    "location": {"row": 1, "column": 1},
                }
            ]
        )
        (finding,) = lint_delta.parse_ruff(payload, tmp_path)
        assert finding.code == lint_delta.UNKNOWN_CODE

    def test_invalid_json_raises(self):
        """Unparseable output must fail loudly, not read as zero findings."""
        with pytest.raises(ValueError, match="valid JSON"):
            lint_delta.parse_ruff("not json at all", Path("."))

    def test_non_list_payload_raises(self):
        """A JSON object where a list was promised is a broken invocation."""
        with pytest.raises(ValueError, match="expected a list"):
            lint_delta.parse_ruff('{"error": "boom"}', Path("."))


class TestParseMypy:
    """Parsing mypy's line-delimited JSON payload."""

    def test_parses_error_entries(self, tmp_path):
        """Errors become findings with their code and message intact."""
        line = json.dumps(
            {
                "file": "src/a.py",
                "line": 216,
                "column": 4,
                "message": '"LiteConfig" has no attribute "llm"',
                "code": "attr-defined",
                "severity": "error",
            }
        )
        (finding,) = lint_delta.parse_mypy(line, tmp_path)
        assert (finding.tool, finding.path, finding.code, finding.line) == (
            "mypy",
            "src/a.py",
            "attr-defined",
            216,
        )

    def test_notes_are_ignored(self, tmp_path):
        """Notes elaborate on an error already counted, so they are dropped."""
        note = json.dumps(
            {"file": "src/a.py", "line": 1, "message": "see docs", "code": None, "severity": "note"}
        )
        assert lint_delta.parse_mypy(note, tmp_path) == []

    def test_blank_lines_are_skipped(self, tmp_path):
        """Trailing newlines in the payload are not an error."""
        assert lint_delta.parse_mypy("\n\n", tmp_path) == []

    def test_non_json_line_raises(self, tmp_path):
        """A stray plain-text line means output we do not understand.

        Skipping it would shrink the head side and could hide a real finding,
        so the gate refuses to guess.
        """
        payload = json.dumps(
            {"file": "a.py", "line": 1, "message": "m", "code": "c", "severity": "error"}
        )
        with pytest.raises(ValueError, match="non-JSON line 2"):
            lint_delta.parse_mypy(f"{payload}\nmypy: internal error\n", tmp_path)


class TestAnnotation:
    """The GitHub Actions annotation rendered for each new finding."""

    def test_annotation_points_at_file_and_line(self):
        """Annotations must carry the file and line for inline rendering."""
        finding = make_finding(path="src/a.py", line=42, code="F401", message="unused import")
        assert finding.annotation() == (
            "::error file=src/a.py,line=42::ruff F401: unused import"
        )

    def test_percent_and_line_breaks_in_message_are_escaped(self):
        """GitHub decodes %25/%0D/%0A in workflow commands.

        A raw ``%`` (mypy errors about %-formatting, say) would render garbled
        and a raw newline would split the annotation in two.
        """
        finding = make_finding(message="expected '%s'\r\ngot nothing")
        assert finding.annotation().endswith(
            "ruff D212: expected '%25s'%0D%0Agot nothing"
        )

    def test_comma_and_colon_in_path_are_escaped(self):
        """Property values are comma-separated, so ``,`` and ``:`` cannot appear raw."""
        finding = make_finding(path="src/od,d:name.py", line=7)
        assert "file=src/od%2Cd%3Aname.py,line=7" in finding.annotation()


class TestCollect:
    """Guarding against a failed tool run being read as a clean result."""

    def test_tool_crash_raises_rather_than_reporting_zero(self, tmp_path, monkeypatch):
        """Exit status above 1 means the tool failed, not that it found nothing.

        Treating it as an empty finding list would make every subsequent
        comparison pass, which is the exact silent-green failure this gate
        exists to prevent.
        """

        def fake_run(command, cwd):
            return subprocess.CompletedProcess(
                command, returncode=2, stdout="", stderr="ruff: invalid config"
            )

        monkeypatch.setattr(lint_delta, "_run", fake_run)
        with pytest.raises(RuntimeError, match="exited 2"):
            lint_delta.collect("ruff", tmp_path)

    def test_unknown_tool_raises(self, tmp_path):
        """An unsupported tool name is a programming error, not a clean run."""
        with pytest.raises(RuntimeError, match="unknown tool"):
            lint_delta.collect("pylint", tmp_path)


class TestMergeBase:
    """Resolving the commit the change is measured against."""

    def test_missing_merge_base_raises(self, tmp_path, monkeypatch):
        """A shallow clone must fail the gate, not silently skip it."""

        def fake_run(command, cwd):
            return subprocess.CompletedProcess(
                command, returncode=128, stdout="", stderr="fatal: Not a valid object name"
            )

        monkeypatch.setattr(lint_delta, "_run", fake_run)
        with pytest.raises(RuntimeError, match="merge base"):
            lint_delta.merge_base(tmp_path, "origin/master")


class TestCompare:
    """Orchestration: each tool measured at head and at base, worktree cleaned up."""

    @pytest.fixture
    def two_commit_repo(self, tmp_path: Path) -> Path:
        """Create a repository whose HEAD edits a file over its parent commit.

        Returns:
            Path to the repository's working directory.
        """
        repo = tmp_path / "repo"
        repo.mkdir()

        def git(*argv: str) -> None:
            subprocess.run(["git", *argv], cwd=repo, check=True, capture_output=True, text=True)

        git("init")
        git("config", "user.email", "ci@example.invalid")
        git("config", "user.name", "CI")
        git("config", "commit.gpgsign", "false")
        (repo / "a.py").write_text("x = 1\n")
        git("add", "a.py")
        git("commit", "-m", "base")
        (repo / "a.py").write_text("x = 1\ny = 2\n")
        git("commit", "-am", "head")
        return repo

    def test_head_and_base_are_measured_and_diffed(self, two_commit_repo, monkeypatch):
        """The base run sees the merge-base tree, and only the delta is returned."""
        measured = []

        def fake_collect(tool, root):
            measured.append((tool, Path(root), (Path(root) / "a.py").read_text()))
            if Path(root) == two_commit_repo:
                return [make_finding(), make_finding(code="F401", message="`os` unused")]
            return [make_finding()]

        monkeypatch.setattr(lint_delta, "collect", fake_collect)
        introduced = lint_delta.compare(two_commit_repo, ["ruff"], "HEAD~1")

        assert [finding.code for finding in introduced] == ["F401"]
        (head_run,) = [entry for entry in measured if entry[1] == two_commit_repo]
        (base_run,) = [entry for entry in measured if entry[1] != two_commit_repo]
        assert head_run[2] == "x = 1\ny = 2\n"
        assert base_run[2] == "x = 1\n"
        assert not base_run[1].exists()

    def test_worktree_is_removed_even_when_a_tool_fails(self, two_commit_repo, monkeypatch):
        """The finally block must clean up after a tool run raises."""
        base_roots = []

        def failing_collect(tool, root):
            if Path(root) == two_commit_repo:
                return []
            base_roots.append(Path(root))
            raise RuntimeError("tool exploded")

        monkeypatch.setattr(lint_delta, "collect", failing_collect)
        with pytest.raises(RuntimeError, match="tool exploded"):
            lint_delta.compare(two_commit_repo, ["ruff"], "HEAD~1")
        (base_root,) = base_roots
        assert not base_root.exists()

    def test_no_stale_worktree_registration_survives(self, two_commit_repo, monkeypatch):
        """Repeated local runs must not accumulate .git/worktrees entries."""
        monkeypatch.setattr(lint_delta, "collect", lambda tool, root: [])
        lint_delta.compare(two_commit_repo, ["ruff"], "HEAD~1")
        listed = subprocess.run(
            ["git", "worktree", "list", "--porcelain"],
            cwd=two_commit_repo,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        # Only the main worktree remains; each entry opens with a "worktree" line.
        assert listed.count("worktree ") == 1


class TestMain:
    """End-to-end exit statuses."""

    def test_gate_failure_exits_two(self, monkeypatch):
        """When the gate cannot measure, it must not report success."""

        def boom(repo, tools, base_ref):
            raise RuntimeError("no worktree for you")

        monkeypatch.setattr(lint_delta, "compare", boom)
        assert lint_delta.main([]) == lint_delta.EXIT_GATE_ERROR

    def test_unexpected_crash_also_exits_two(self, monkeypatch, capsys):
        """A bug or tool schema change must exit 2, not 1.

        An unhandled traceback would terminate Python with exit status 1,
        which this script documents as "new findings reported" — CI would
        still fail, but with a status that lies about why.
        """

        def boom(repo, tools, base_ref):
            raise KeyError("message")

        monkeypatch.setattr(lint_delta, "compare", boom)
        assert lint_delta.main([]) == lint_delta.EXIT_GATE_ERROR
        assert "crashed" in capsys.readouterr().err

    def test_new_findings_exit_one(self, monkeypatch):
        """Introduced findings fail the build."""
        monkeypatch.setattr(lint_delta, "compare", lambda *_: [make_finding()])
        assert lint_delta.main([]) == lint_delta.EXIT_NEW_FINDINGS

    def test_no_new_findings_exit_zero(self, monkeypatch):
        """A change that adds no findings passes."""
        monkeypatch.setattr(lint_delta, "compare", lambda *_: [])
        assert lint_delta.main([]) == lint_delta.EXIT_OK

    def test_all_new_findings_are_printed(self, monkeypatch, capsys):
        """Golden rule 13: the log carries every finding, never a summary.

        GitHub only renders the first several annotations inline, so the log
        is the complete record a reviewer falls back to.
        """
        many = [make_finding(path=f"src/f{index}.py") for index in range(50)]
        monkeypatch.setattr(lint_delta, "compare", lambda *_: many)
        lint_delta.main([])
        printed = capsys.readouterr().out
        assert all(f"src/f{index}.py" in printed for index in range(50))
