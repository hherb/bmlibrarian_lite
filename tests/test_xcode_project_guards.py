"""Tests for the Xcode project guards (.github/scripts/xcode_project_guards.py)."""

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

PROJECT_ROOT = Path(__file__).parent.parent
SCRIPT_PATH = PROJECT_ROOT / ".github" / "scripts" / "xcode_project_guards.py"


def _load_script() -> ModuleType:
    """Load xcode_project_guards.py as a module (.github/scripts is not a package).

    Returns:
        The loaded xcode_project_guards module.
    """
    spec = importlib.util.spec_from_file_location("xcode_project_guards", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["xcode_project_guards"] = module
    spec.loader.exec_module(module)
    return module


xcode_project_guards = _load_script()


def _write_pbxproj(tmp_path: Path, body: str) -> Path:
    """Write a minimal pbxproj containing the given section body.

    Args:
        tmp_path: Directory to write into.
        body: Lines to place between the Begin/End section markers.

    Returns:
        Path to the written project.pbxproj.
    """
    path = tmp_path / "project.pbxproj"
    path.write_text(
        "// !$*UTF8*$!\n"
        "{\n"
        "\tobjects = {\n"
        "/* Begin PBXFileReference section */\n"
        f"{body}"
        "/* End PBXFileReference section */\n"
        "\t};\n"
        "}\n"
    )
    return path


def test_unique_identifiers_report_nothing(tmp_path: Path) -> None:
    """Distinct object identifiers are not flagged."""
    pbxproj = _write_pbxproj(
        tmp_path,
        "\t\tA1000099000 /* A.swift */ = {isa = PBXFileReference; };\n"
        "\t\tA1000099001 /* B.swift */ = {isa = PBXFileReference; };\n",
    )

    assert xcode_project_guards.duplicate_object_ids(pbxproj) == []


def test_a_reused_identifier_is_reported(tmp_path: Path) -> None:
    """The #182 trap: a new object given an identifier that already exists.

    One definition wins for every reference, so the file compiles for the
    targets the winner belongs to and silently vanishes from the others.
    """
    pbxproj = _write_pbxproj(
        tmp_path,
        "\t\tA1000099000 /* A.swift */ = {isa = PBXFileReference; };\n"
        "\t\tA1000099000 /* B.swift */ = {isa = PBXFileReference; };\n",
    )

    assert xcode_project_guards.duplicate_object_ids(pbxproj) == ["A1000099000"]


def test_a_repeated_identifier_is_reported_once(tmp_path: Path) -> None:
    """Three definitions of one identifier are still a single finding."""
    pbxproj = _write_pbxproj(
        tmp_path,
        "\t\tA1000099000 /* A.swift */ = {isa = PBXFileReference; };\n"
        "\t\tA1000099000 /* B.swift */ = {isa = PBXFileReference; };\n"
        "\t\tA1000099000 /* C.swift */ = {isa = PBXFileReference; };\n",
    )

    assert xcode_project_guards.duplicate_object_ids(pbxproj) == ["A1000099000"]


def test_nested_dictionaries_are_not_definitions(tmp_path: Path) -> None:
    """A target id keying `TargetAttributes` is a reference, not a definition.

    This is why the scan is anchored to the two-tab indent Xcode writes real
    object definitions at: `A1000000001` legitimately appears both as the
    `PBXNativeTarget` and, more deeply indented, as an attributes key.
    """
    pbxproj = _write_pbxproj(
        tmp_path,
        "\t\tA1000000001 /* App */ = {isa = PBXNativeTarget; };\n"
        "\t\t\t\t\tA1000000001 = {\n"
        "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        "\t\t\t\t\t};\n",
    )

    assert xcode_project_guards.duplicate_object_ids(pbxproj) == []


def test_lowercase_dictionary_keys_are_not_definitions(tmp_path: Path) -> None:
    """`buildSettings = {` has the shape of a definition but is not one."""
    pbxproj = _write_pbxproj(
        tmp_path,
        "\t\tbuildSettings = {\n"
        "\t\t};\n"
        "\t\tbuildSettings = {\n"
        "\t\t};\n",
    )

    assert xcode_project_guards.duplicate_object_ids(pbxproj) == []


def test_definitions_outside_a_section_are_ignored(tmp_path: Path) -> None:
    """Only the Begin/End section blocks hold object definitions."""
    path = tmp_path / "project.pbxproj"
    path.write_text(
        "\t\tA1000099000 /* stray */ = {isa = PBXFileReference; };\n"
        "\t\tA1000099000 /* stray */ = {isa = PBXFileReference; };\n"
    )

    assert xcode_project_guards.duplicate_object_ids(path) == []


def test_the_checked_in_project_is_clean() -> None:
    """The repository's own project must satisfy the guard."""
    pbxproj = (
        PROJECT_ROOT
        / "ios/MedicalFactChecker/MedicalFactChecker.xcodeproj/project.pbxproj"
    )

    assert xcode_project_guards.duplicate_object_ids(pbxproj) == []
