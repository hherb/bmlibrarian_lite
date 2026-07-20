#!/usr/bin/env python3
"""Fail a change that introduces *new* ruff or mypy findings.

Both baselines are far too large to demand a clean run (2081 ruff findings and
677 mypy errors when this was written), so the gate compares the findings on the
current checkout against the findings at the merge base and fails only on what
the change actually adds.

A finding is identified by ``(tool, path, code, message)`` — deliberately
*without* its line and column, so that inserting a line above a pre-existing
finding does not re-report it as new. Counts still matter: a file that grows
from two to three identical findings reports one new finding.

The base side is measured in a throwaway git worktree checked out at the merge
base. That worktree lives outside the repository, both so that ruff's ``.``
target at head does not scan it and so that removing it cannot touch the real
checkout.

Known limitation: renaming a file makes every finding it carries look new,
because the path is part of the identity. That is noisy but never unsafe, and
the alternative — matching findings across paths — would let a whole
non-compliant file be copied in unnoticed.

Exit codes: 0 no new findings, 1 new findings reported, 2 the gate itself
could not run (never treated as a pass).
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import traceback
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

EXIT_OK = 0
EXIT_NEW_FINDINGS = 1
EXIT_GATE_ERROR = 2

# ruff and mypy both exit 1 to mean "I ran fine and found problems"; anything
# above that is the tool itself failing and must not be read as an empty result.
TOOL_RAN_EXIT_CODES = (0, 1)

DEFAULT_BASE_REF = "origin/master"
RUFF_TARGET = "."
MYPY_TARGET = "src"
UNKNOWN_CODE = "?"


@dataclass(frozen=True)
class Finding:
    """One diagnostic emitted by ruff or mypy.

    Attributes:
        tool: Name of the tool that produced it ("ruff" or "mypy").
        path: Repository-relative path of the offending file.
        line: 1-indexed line, kept for reporting but excluded from identity.
        code: Rule code, e.g. "D212" or "no-any-return".
        message: Human-readable description of the problem.
    """

    tool: str
    path: str
    line: int
    code: str
    message: str

    @property
    def identity(self) -> tuple[str, str, str, str]:
        """Return the fields that decide whether two findings are the same one.

        Line and column are excluded so that unrelated edits shifting a finding
        up or down the file do not make it look new.

        Returns:
            The tuple ``(tool, path, code, message)``.
        """
        return (self.tool, self.path, self.code, self.message)

    def annotation(self) -> str:
        """Render this finding as a GitHub Actions error annotation.

        Returns:
            A ``::error …::`` line that GitHub renders against the source file.
        """
        return (
            f"::error file={_escape_annotation_property(self.path)},line={self.line}::"
            f"{self.tool} {self.code}: {_escape_annotation_message(self.message)}"
        )


def _escape_annotation_message(value: str) -> str:
    """Escape text for the message part of a GitHub workflow command.

    GitHub decodes ``%25``/``%0D``/``%0A`` sequences in workflow commands, so a
    message containing a literal ``%`` (mypy errors about %-formatting, say)
    would otherwise render garbled or split across lines.

    Args:
        value: Raw text to embed after the ``::`` separator.

    Returns:
        The text with ``%``, carriage returns and newlines escaped.
    """
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _escape_annotation_property(value: str) -> str:
    """Escape text for a property value of a GitHub workflow command.

    Property values live in a comma-separated list, so ``,`` and ``:`` need
    escaping on top of the message rules.

    Args:
        value: Raw property value, e.g. a file path.

    Returns:
        The value with ``%``, line breaks, ``:`` and ``,`` escaped.
    """
    return _escape_annotation_message(value).replace(":", "%3A").replace(",", "%2C")


def _relative_path(raw: str, root: Path) -> str:
    """Normalise a tool-reported path to a repository-relative POSIX path.

    Tools report absolute paths (ruff) or cwd-relative ones (mypy); both must
    collapse to the same string for head and base to be comparable.

    Args:
        raw: Path exactly as the tool reported it.
        root: Directory the tool was run from.

    Returns:
        The path relative to ``root`` where possible, else ``raw`` unchanged.
    """
    candidate = Path(raw)
    if not candidate.is_absolute():
        return candidate.as_posix()
    try:
        return candidate.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return candidate.as_posix()


def parse_ruff(stdout: str, root: Path) -> list[Finding]:
    """Parse ruff's ``--output-format json`` payload into findings.

    Args:
        stdout: Raw stdout from the ruff invocation.
        root: Directory ruff was run from, used to relativise paths.

    Returns:
        Findings in the order ruff reported them.

    Raises:
        ValueError: If the payload is not the JSON array ruff promises.
    """
    if not stdout.strip():
        return []
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise ValueError(f"ruff did not emit valid JSON: {exc}") from exc
    if not isinstance(payload, list):
        raise ValueError(f"ruff JSON payload was {type(payload).__name__}, expected a list")
    findings = []
    for item in payload:
        location = item.get("location") or {}
        findings.append(
            Finding(
                tool="ruff",
                path=_relative_path(item["filename"], root),
                line=int(location.get("row", 0)),
                # Syntax errors carry no rule code.
                code=item.get("code") or UNKNOWN_CODE,
                message=item["message"],
            )
        )
    return findings


def parse_mypy(stdout: str, root: Path) -> list[Finding]:
    """Parse mypy's ``--output json`` payload (one JSON object per line).

    Only ``error`` severities are kept: notes exist to elaborate on an error
    that is already counted, so counting them too would double-report.

    Args:
        stdout: Raw stdout from the mypy invocation.
        root: Directory mypy was run from, used to relativise paths.

    Returns:
        Findings in the order mypy reported them.

    Raises:
        ValueError: If any non-empty line is not valid JSON. Skipping such
            lines would silently shrink the head side and hide real findings.
    """
    findings = []
    for number, line in enumerate(stdout.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"mypy emitted a non-JSON line {number}: {line!r} ({exc})") from exc
        if item.get("severity") != "error":
            continue
        findings.append(
            Finding(
                tool="mypy",
                path=_relative_path(item["file"], root),
                line=int(item.get("line", 0)),
                code=item.get("code") or UNKNOWN_CODE,
                message=item["message"],
            )
        )
    return findings


def new_findings(head: list[Finding], base: list[Finding]) -> list[Finding]:
    """Return the head findings that the base does not already account for.

    This is a multiset difference over :attr:`Finding.identity`, so a file that
    goes from two to three identical findings yields exactly one new finding.
    The returned objects come from ``head``, keeping the line numbers that a
    reviewer needs.

    Args:
        head: Findings measured on the current checkout.
        base: Findings measured at the merge base.

    Returns:
        Newly introduced findings, in head order.
    """
    allowance = Counter(finding.identity for finding in base)
    seen: Counter[tuple[str, str, str, str]] = Counter()
    introduced = []
    for finding in head:
        seen[finding.identity] += 1
        if seen[finding.identity] > allowance[finding.identity]:
            introduced.append(finding)
    return introduced


def _run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    """Run a subprocess, capturing text output.

    Args:
        command: Argument vector to execute.
        cwd: Working directory for the process.

    Returns:
        The completed process.

    Raises:
        RuntimeError: If the executable is not on PATH.
    """
    try:
        return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        raise RuntimeError(f"{command[0]} is not installed or not on PATH") from exc


def collect(tool: str, root: Path) -> list[Finding]:
    """Run one tool over a checkout and return its findings.

    Args:
        tool: Either "ruff" or "mypy".
        root: Checkout to analyse.

    Returns:
        The findings the tool reported.

    Raises:
        RuntimeError: If the tool is unknown, could not be executed, or exited
            with a status meaning it failed rather than merely found problems.
        ValueError: If the tool's output could not be parsed.
    """
    if tool == "ruff":
        command = ["ruff", "check", RUFF_TARGET, "--output-format", "json"]
        parse = parse_ruff
    elif tool == "mypy":
        command = ["mypy", MYPY_TARGET, "--output", "json", "--no-error-summary", "--no-color-output"]
        parse = parse_mypy
    else:
        raise RuntimeError(f"unknown tool: {tool}")

    result = _run(command, root)
    if result.returncode not in TOOL_RAN_EXIT_CODES:
        raise RuntimeError(
            f"{tool} exited {result.returncode} in {root}, so its findings are unusable.\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return parse(result.stdout, root)


def merge_base(repo: Path, base_ref: str) -> str:
    """Resolve the merge base between HEAD and the base ref.

    Args:
        repo: Repository to query.
        base_ref: Branch or commit the change will merge into.

    Returns:
        The merge-base commit SHA.

    Raises:
        RuntimeError: If the merge base cannot be determined — for example when
            the checkout is shallow and does not contain the base branch.
    """
    result = _run(["git", "merge-base", "HEAD", base_ref], repo)
    if result.returncode != 0:
        raise RuntimeError(
            f"could not find the merge base of HEAD and {base_ref}: {result.stderr.strip()}\n"
            "A shallow clone is the usual cause; check out with fetch-depth: 0."
        )
    return result.stdout.strip()


def compare(repo: Path, tools: list[str], base_ref: str) -> list[Finding]:
    """Measure each tool at head and at the merge base and diff the results.

    Args:
        repo: The repository checked out at the change under test.
        tools: Tool names to run.
        base_ref: Branch or commit the change will merge into.

    Returns:
        Every newly introduced finding across all tools.

    Raises:
        RuntimeError: If the worktree or any tool run could not be completed.
    """
    base_sha = merge_base(repo, base_ref)
    # Created outside the repository so ruff's "." target at head cannot walk
    # into it and count the base sources twice.
    worktree = Path(tempfile.mkdtemp(prefix="lint-delta-base-"))
    try:
        added = _run(["git", "worktree", "add", "--detach", str(worktree), base_sha], repo)
        if added.returncode != 0:
            raise RuntimeError(f"could not create the base worktree: {added.stderr.strip()}")

        introduced = []
        for tool in tools:
            head_findings = collect(tool, repo)
            base_findings = collect(tool, worktree)
            fresh = new_findings(head_findings, base_findings)
            print(
                f"{tool}: {len(head_findings)} finding(s) at head, "
                f"{len(base_findings)} at base {base_sha[:12]}, {len(fresh)} new"
            )
            introduced.extend(fresh)
        return introduced
    finally:
        _run(["git", "worktree", "remove", "--force", str(worktree)], repo)
        shutil.rmtree(worktree, ignore_errors=True)
        # If the remove above failed, the rmtree leaves a stale entry in
        # .git/worktrees/; prune it so repeated local runs stay clean.
        _run(["git", "worktree", "prune"], repo)


def main(argv: list[str] | None = None) -> int:
    """Run the gate and return the process exit status.

    Args:
        argv: Command-line arguments, defaulting to ``sys.argv[1:]``.

    Returns:
        ``EXIT_OK``, ``EXIT_NEW_FINDINGS`` or ``EXIT_GATE_ERROR``.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base-ref",
        default=DEFAULT_BASE_REF,
        help=f"branch or commit the change merges into (default: {DEFAULT_BASE_REF})",
    )
    parser.add_argument(
        "--tool",
        dest="tools",
        action="append",
        choices=["ruff", "mypy"],
        help="tool to check; repeatable, defaults to both",
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="repository to analyse (default: the repository holding this script)",
    )
    args = parser.parse_args(argv)
    tools = args.tools or ["ruff", "mypy"]

    try:
        introduced = compare(args.repo, tools, args.base_ref)
    except (RuntimeError, ValueError) as exc:
        # A gate that cannot measure must fail; reporting "no new findings"
        # here would be indistinguishable from a genuinely clean change.
        print(f"::error::lint delta gate could not run: {exc}", file=sys.stderr)
        return EXIT_GATE_ERROR
    except Exception as exc:
        # Anything else is a bug in this script or a tool changing its output
        # schema (a KeyError, say). It must still exit 2: an unhandled
        # traceback would exit 1, which this script documents as "new findings
        # reported". The traceback is kept because, unlike the expected errors
        # above, the message alone will not say where the bug is.
        traceback.print_exc(file=sys.stderr)
        print(f"::error::lint delta gate crashed: {exc!r}", file=sys.stderr)
        return EXIT_GATE_ERROR

    if not introduced:
        print("No new ruff or mypy findings.")
        return EXIT_OK

    # Every finding is printed: the log is the complete record even though
    # GitHub renders only the first several annotations inline.
    print(f"\n{len(introduced)} new finding(s) introduced by this change:\n")
    for finding in introduced:
        print(finding.annotation())
    return EXIT_NEW_FINDINGS


if __name__ == "__main__":
    sys.exit(main())
