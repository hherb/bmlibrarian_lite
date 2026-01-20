#!/usr/bin/env python3
"""
Code Statistics Generator for BMLibrarian Lite Projects.

Generates markdown-formatted statistics about lines of code, comments,
documentation, and code structure for all project components.

Usage:
    python scripts/codestats.py              # All projects
    python scripts/codestats.py --ios        # iOS only
    python scripts/codestats.py --macos      # macOS only
    python scripts/codestats.py --android    # Android only
    python scripts/codestats.py --bmll       # Python desktop app only
    python scripts/codestats.py --ios --android  # Multiple projects
"""

import argparse
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Generator


@dataclass
class FileStats:
    """Statistics for a single file."""

    path: Path
    total_lines: int = 0
    code_lines: int = 0
    comment_lines: int = 0
    blank_lines: int = 0
    doc_lines: int = 0
    functions: list[int] = field(default_factory=list)
    classes: list[int] = field(default_factory=list)


@dataclass
class ProjectStats:
    """Aggregated statistics for a project."""

    name: str
    files: list[FileStats] = field(default_factory=list)

    @property
    def total_lines(self) -> int:
        return sum(f.total_lines for f in self.files)

    @property
    def code_lines(self) -> int:
        return sum(f.code_lines for f in self.files)

    @property
    def comment_lines(self) -> int:
        return sum(f.comment_lines for f in self.files)

    @property
    def blank_lines(self) -> int:
        return sum(f.blank_lines for f in self.files)

    @property
    def doc_lines(self) -> int:
        return sum(f.doc_lines for f in self.files)

    @property
    def file_count(self) -> int:
        return len(self.files)

    @property
    def all_functions(self) -> list[int]:
        result = []
        for f in self.files:
            result.extend(f.functions)
        return sorted(result, reverse=True)

    @property
    def all_classes(self) -> list[int]:
        result = []
        for f in self.files:
            result.extend(f.classes)
        return sorted(result, reverse=True)


def find_files(
    root: Path, extensions: tuple[str, ...], exclude_dirs: set[str] | None = None
) -> Generator[Path, None, None]:
    """Find all files with given extensions under root directory."""
    if exclude_dirs is None:
        exclude_dirs = set()

    for dirpath, dirnames, filenames in os.walk(root):
        # Filter out excluded directories
        dirnames[:] = [d for d in dirnames if d not in exclude_dirs]

        for filename in filenames:
            if filename.endswith(extensions):
                yield Path(dirpath) / filename


def analyze_python_file(filepath: Path) -> FileStats:
    """Analyze a Python file for code statistics."""
    stats = FileStats(path=filepath)

    try:
        content = filepath.read_text(encoding="utf-8", errors="ignore")
    except (OSError, UnicodeDecodeError):
        return stats

    lines = content.split("\n")
    stats.total_lines = len(lines)

    in_docstring = False
    docstring_char = None
    current_indent = 0
    function_starts: list[tuple[int, int]] = []  # (start_line, indent)
    class_starts: list[tuple[int, int]] = []  # (start_line, indent)

    for i, line in enumerate(lines):
        stripped = line.strip()

        # Blank line
        if not stripped:
            stats.blank_lines += 1
            continue

        # Handle docstrings
        if not in_docstring:
            if stripped.startswith('"""') or stripped.startswith("'''"):
                docstring_char = stripped[:3]
                if stripped.count(docstring_char) >= 2 and len(stripped) > 3:
                    # Single-line docstring
                    stats.doc_lines += 1
                else:
                    in_docstring = True
                    stats.doc_lines += 1
                continue
        else:
            stats.doc_lines += 1
            if docstring_char and docstring_char in stripped:
                in_docstring = False
                docstring_char = None
            continue

        # Comment line
        if stripped.startswith("#"):
            stats.comment_lines += 1
            continue

        # Code line
        stats.code_lines += 1

        # Track function/class definitions
        indent = len(line) - len(line.lstrip())

        # Close any functions/classes that have ended
        while function_starts and function_starts[-1][1] >= indent:
            start_line, _ = function_starts.pop()
            stats.functions.append(i - start_line)

        while class_starts and class_starts[-1][1] >= indent:
            start_line, _ = class_starts.pop()
            stats.classes.append(i - start_line)

        if stripped.startswith("def "):
            function_starts.append((i, indent))
        elif stripped.startswith("class "):
            class_starts.append((i, indent))

    # Close any remaining functions/classes
    for start_line, _ in function_starts:
        stats.functions.append(len(lines) - start_line)
    for start_line, _ in class_starts:
        stats.classes.append(len(lines) - start_line)

    return stats


def analyze_swift_file(filepath: Path) -> FileStats:
    """Analyze a Swift file for code statistics."""
    stats = FileStats(path=filepath)

    try:
        content = filepath.read_text(encoding="utf-8", errors="ignore")
    except (OSError, UnicodeDecodeError):
        return stats

    lines = content.split("\n")
    stats.total_lines = len(lines)

    in_block_comment = False
    in_doc_comment = False
    brace_stack: list[tuple[str, int, int]] = []  # (type, start_line, brace_count)

    for i, line in enumerate(lines):
        stripped = line.strip()

        # Blank line
        if not stripped:
            stats.blank_lines += 1
            continue

        # Handle block comments
        if not in_block_comment and not in_doc_comment:
            if stripped.startswith("/**"):
                in_doc_comment = True
                stats.doc_lines += 1
                if "*/" in stripped[3:]:
                    in_doc_comment = False
                continue
            elif stripped.startswith("/*"):
                in_block_comment = True
                stats.comment_lines += 1
                if "*/" in stripped[2:]:
                    in_block_comment = False
                continue
        elif in_doc_comment:
            stats.doc_lines += 1
            if "*/" in stripped:
                in_doc_comment = False
            continue
        elif in_block_comment:
            stats.comment_lines += 1
            if "*/" in stripped:
                in_block_comment = False
            continue

        # Single-line doc comment (///)
        if stripped.startswith("///"):
            stats.doc_lines += 1
            continue

        # Single-line comment
        if stripped.startswith("//"):
            stats.comment_lines += 1
            continue

        # Code line
        stats.code_lines += 1

        # Track functions/classes/structs
        # Simple brace counting approach
        func_match = re.match(r"(func|init)\s+", stripped)
        class_match = re.match(r"(class|struct|enum|extension)\s+", stripped)

        if func_match and "{" in stripped:
            brace_count = stripped.count("{") - stripped.count("}")
            if brace_count > 0:
                brace_stack.append(("func", i, brace_count))
        elif class_match and "{" in stripped:
            brace_count = stripped.count("{") - stripped.count("}")
            if brace_count > 0:
                brace_stack.append(("class", i, brace_count))
        elif brace_stack:
            # Update brace count
            brace_diff = stripped.count("{") - stripped.count("}")
            item_type, start_line, count = brace_stack[-1]
            new_count = count + brace_diff

            if new_count <= 0:
                brace_stack.pop()
                length = i - start_line + 1
                if item_type == "func":
                    stats.functions.append(length)
                else:
                    stats.classes.append(length)
            else:
                brace_stack[-1] = (item_type, start_line, new_count)

    return stats


def analyze_kotlin_file(filepath: Path) -> FileStats:
    """Analyze a Kotlin file for code statistics."""
    stats = FileStats(path=filepath)

    try:
        content = filepath.read_text(encoding="utf-8", errors="ignore")
    except (OSError, UnicodeDecodeError):
        return stats

    lines = content.split("\n")
    stats.total_lines = len(lines)

    in_block_comment = False
    in_doc_comment = False
    brace_stack: list[tuple[str, int, int]] = []

    for i, line in enumerate(lines):
        stripped = line.strip()

        if not stripped:
            stats.blank_lines += 1
            continue

        # Handle block comments
        if not in_block_comment and not in_doc_comment:
            if stripped.startswith("/**"):
                in_doc_comment = True
                stats.doc_lines += 1
                if "*/" in stripped[3:]:
                    in_doc_comment = False
                continue
            elif stripped.startswith("/*"):
                in_block_comment = True
                stats.comment_lines += 1
                if "*/" in stripped[2:]:
                    in_block_comment = False
                continue
        elif in_doc_comment:
            stats.doc_lines += 1
            if "*/" in stripped:
                in_doc_comment = False
            continue
        elif in_block_comment:
            stats.comment_lines += 1
            if "*/" in stripped:
                in_block_comment = False
            continue

        # Single-line comment
        if stripped.startswith("//"):
            stats.comment_lines += 1
            continue

        # Code line
        stats.code_lines += 1

        # Track functions/classes
        func_match = re.match(r"(fun|override\s+fun)\s+", stripped)
        class_match = re.match(r"(class|object|interface|enum\s+class|sealed\s+class)\s+", stripped)

        if func_match and "{" in stripped:
            brace_count = stripped.count("{") - stripped.count("}")
            if brace_count > 0:
                brace_stack.append(("func", i, brace_count))
        elif class_match and "{" in stripped:
            brace_count = stripped.count("{") - stripped.count("}")
            if brace_count > 0:
                brace_stack.append(("class", i, brace_count))
        elif brace_stack:
            brace_diff = stripped.count("{") - stripped.count("}")
            item_type, start_line, count = brace_stack[-1]
            new_count = count + brace_diff

            if new_count <= 0:
                brace_stack.pop()
                length = i - start_line + 1
                if item_type == "func":
                    stats.functions.append(length)
                else:
                    stats.classes.append(length)
            else:
                brace_stack[-1] = (item_type, start_line, new_count)

    return stats


def analyze_project(
    name: str,
    root: Path,
    extensions: tuple[str, ...],
    analyzer: callable,
    exclude_dirs: set[str] | None = None,
) -> ProjectStats:
    """Analyze all files in a project."""
    if exclude_dirs is None:
        exclude_dirs = {"__pycache__", ".git", "build", "DerivedData", ".gradle", "node_modules"}

    stats = ProjectStats(name=name)

    for filepath in find_files(root, extensions, exclude_dirs):
        file_stats = analyzer(filepath)
        if file_stats.total_lines > 0:
            stats.files.append(file_stats)

    # Sort files by total lines (largest first)
    stats.files.sort(key=lambda f: f.total_lines, reverse=True)

    return stats


def format_number(n: int) -> str:
    """Format a number with thousands separator."""
    return f"{n:,}"


def format_percentage(part: int, total: int) -> str:
    """Format a percentage."""
    if total == 0:
        return "0.0%"
    return f"{100 * part / total:.1f}%"


def generate_distribution_table(values: list[int], label: str, top_n: int = 10) -> str:
    """Generate a distribution table for values."""
    if not values:
        return f"No {label.lower()} found.\n"

    lines = [
        f"| Rank | Lines |",
        f"|------|-------|",
    ]

    for i, length in enumerate(values[:top_n], 1):
        lines.append(f"| {i} | {length} |")

    if len(values) > top_n:
        lines.append(f"| ... | ({len(values) - top_n} more) |")

    # Add summary stats
    avg = sum(values) / len(values)
    median = sorted(values)[len(values) // 2]
    lines.append("")
    lines.append(f"**Total {label}:** {len(values)} | **Avg:** {avg:.1f} lines | **Median:** {median} lines | **Max:** {max(values)} lines")

    return "\n".join(lines)


def generate_file_size_table(files: list[FileStats], base_path: Path, top_n: int = 15) -> str:
    """Generate a table of file sizes."""
    if not files:
        return "No files found.\n"

    lines = [
        "| Rank | File | Total | Code | Comments | Docs | Blank |",
        "|------|------|-------|------|----------|------|-------|",
    ]

    for i, f in enumerate(files[:top_n], 1):
        try:
            rel_path = f.path.relative_to(base_path)
        except ValueError:
            rel_path = f.path.name

        lines.append(
            f"| {i} | {rel_path} | {f.total_lines} | {f.code_lines} | {f.comment_lines} | {f.doc_lines} | {f.blank_lines} |"
        )

    if len(files) > top_n:
        remaining = len(files) - top_n
        remaining_lines = sum(f.total_lines for f in files[top_n:])
        lines.append(f"| ... | ({remaining} more files) | {remaining_lines} | | | | |")

    return "\n".join(lines)


def generate_project_report(stats: ProjectStats, base_path: Path) -> str:
    """Generate a markdown report for a project."""
    lines = [
        f"## {stats.name}",
        "",
        "### Summary",
        "",
        "| Metric | Value | Percentage |",
        "|--------|-------|------------|",
        f"| **Total Files** | {format_number(stats.file_count)} | - |",
        f"| **Total Lines** | {format_number(stats.total_lines)} | 100% |",
        f"| **Code Lines** | {format_number(stats.code_lines)} | {format_percentage(stats.code_lines, stats.total_lines)} |",
        f"| **Comment Lines** | {format_number(stats.comment_lines)} | {format_percentage(stats.comment_lines, stats.total_lines)} |",
        f"| **Documentation Lines** | {format_number(stats.doc_lines)} | {format_percentage(stats.doc_lines, stats.total_lines)} |",
        f"| **Blank Lines** | {format_number(stats.blank_lines)} | {format_percentage(stats.blank_lines, stats.total_lines)} |",
        "",
        "### File Size Distribution (Largest to Smallest)",
        "",
        generate_file_size_table(stats.files, base_path),
        "",
        "### Function Length Distribution",
        "",
        generate_distribution_table(stats.all_functions, "Functions"),
        "",
        "### Class/Struct Length Distribution",
        "",
        generate_distribution_table(stats.all_classes, "Classes/Structs"),
        "",
    ]

    return "\n".join(lines)


def generate_summary_table(all_stats: list[ProjectStats]) -> str:
    """Generate a summary comparison table across all projects."""
    lines = [
        "## Cross-Project Comparison",
        "",
        "| Project | Files | Total Lines | Code | Comments | Docs | Blank |",
        "|---------|-------|-------------|------|----------|------|-------|",
    ]

    for stats in all_stats:
        lines.append(
            f"| {stats.name} | {stats.file_count} | {format_number(stats.total_lines)} | "
            f"{format_number(stats.code_lines)} ({format_percentage(stats.code_lines, stats.total_lines)}) | "
            f"{format_number(stats.comment_lines)} ({format_percentage(stats.comment_lines, stats.total_lines)}) | "
            f"{format_number(stats.doc_lines)} ({format_percentage(stats.doc_lines, stats.total_lines)}) | "
            f"{format_number(stats.blank_lines)} ({format_percentage(stats.blank_lines, stats.total_lines)}) |"
        )

    # Totals row
    total_files = sum(s.file_count for s in all_stats)
    total_lines = sum(s.total_lines for s in all_stats)
    total_code = sum(s.code_lines for s in all_stats)
    total_comments = sum(s.comment_lines for s in all_stats)
    total_docs = sum(s.doc_lines for s in all_stats)
    total_blank = sum(s.blank_lines for s in all_stats)

    lines.append(
        f"| **TOTAL** | {total_files} | {format_number(total_lines)} | "
        f"{format_number(total_code)} ({format_percentage(total_code, total_lines)}) | "
        f"{format_number(total_comments)} ({format_percentage(total_comments, total_lines)}) | "
        f"{format_number(total_docs)} ({format_percentage(total_docs, total_lines)}) | "
        f"{format_number(total_blank)} ({format_percentage(total_blank, total_lines)}) |"
    )

    return "\n".join(lines)


def main() -> None:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Generate code statistics for BMLibrarian Lite projects"
    )
    parser.add_argument("--ios", action="store_true", help="Include iOS project")
    parser.add_argument("--macos", action="store_true", help="Include macOS project")
    parser.add_argument("--android", action="store_true", help="Include Android project")
    parser.add_argument("--bmll", action="store_true", help="Include Python desktop app")
    parser.add_argument("--swift-package", action="store_true", help="Include BioMedLit Swift package")

    args = parser.parse_args()

    # If no specific project selected, analyze all
    if not any([args.ios, args.macos, args.android, args.bmll, args.swift_package]):
        args.ios = args.macos = args.android = args.bmll = args.swift_package = True

    # Find project root
    script_path = Path(__file__).resolve()
    project_root = script_path.parent.parent

    all_stats: list[ProjectStats] = []
    exclude_dirs = {
        "__pycache__",
        ".git",
        "build",
        "DerivedData",
        ".gradle",
        "node_modules",
        ".venv",
        "venv",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        "*.egg-info",
    }

    # Analyze Python desktop app
    if args.bmll:
        python_root = project_root / "src"
        if python_root.exists():
            stats = analyze_project(
                "BMLibrarian Lite (Python)",
                python_root,
                (".py",),
                analyze_python_file,
                exclude_dirs,
            )
            all_stats.append(stats)

    # Analyze iOS app
    if args.ios:
        ios_root = project_root / "ios" / "MedicalFactChecker"
        if ios_root.exists():
            stats = analyze_project(
                "MedicalFactChecker (iOS)",
                ios_root,
                (".swift",),
                analyze_swift_file,
                exclude_dirs,
            )
            all_stats.append(stats)

    # Analyze macOS app
    if args.macos:
        macos_root = project_root / "macos" / "MedicalFactCheckerMac"
        if macos_root.exists():
            stats = analyze_project(
                "MedicalFactChecker (macOS)",
                macos_root,
                (".swift",),
                analyze_swift_file,
                exclude_dirs,
            )
            all_stats.append(stats)

    # Analyze Swift package
    if args.swift_package:
        package_root = project_root / "Packages" / "BioMedLit"
        if package_root.exists():
            stats = analyze_project(
                "BioMedLit (Swift Package)",
                package_root,
                (".swift",),
                analyze_swift_file,
                exclude_dirs,
            )
            all_stats.append(stats)

    # Analyze Android app
    if args.android:
        android_root = project_root / "android" / "MedicalFactChecker"
        if android_root.exists():
            stats = analyze_project(
                "MedicalFactChecker (Android)",
                android_root,
                (".kt", ".java"),
                analyze_kotlin_file,
                exclude_dirs,
            )
            all_stats.append(stats)

    # Generate report
    print("# BMLibrarian Lite Code Statistics")
    print()
    print(f"*Generated from: `{project_root}`*")
    print()

    if len(all_stats) > 1:
        print(generate_summary_table(all_stats))
        print()
        print("---")
        print()

    for stats in all_stats:
        if stats.name == "BMLibrarian Lite (Python)":
            base = project_root / "src"
        elif stats.name == "MedicalFactChecker (iOS)":
            base = project_root / "ios" / "MedicalFactChecker"
        elif stats.name == "MedicalFactChecker (macOS)":
            base = project_root / "macos" / "MedicalFactCheckerMac"
        elif stats.name == "BioMedLit (Swift Package)":
            base = project_root / "Packages" / "BioMedLit"
        else:
            base = project_root / "android" / "MedicalFactChecker"

        print(generate_project_report(stats, base))
        print("---")
        print()


if __name__ == "__main__":
    main()
