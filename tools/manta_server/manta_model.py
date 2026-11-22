# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.


"""Loads the real MANTA model. Only functions here import torch, and only when called."""

from __future__ import annotations

import logging
import sys
from pathlib import Path

from manta_service import Predictor

logger = logging.getLogger(__name__)

EXPECTED_REVISION = "ae0db2a45edc065315001055d172e6b76cf60ba2"
METADATA_DIR = Path(".cache") / "huggingface" / "download"
METADATA_GLOB = "*.metadata"


def read_revision(model_dir: Path) -> str | None:
    """Reads the commit ``hf download --local-dir`` recorded.

    Args:
        model_dir: The downloaded model's directory.

    Returns:
        The first line of the first metadata file, or None when there is none.
    """
    for path in sorted((model_dir / METADATA_DIR).glob(METADATA_GLOB)):
        lines = path.read_text().splitlines()
        if lines and lines[0].strip():
            return lines[0].strip()
    return None


def fla_kernel_available() -> bool:
    """True when the flash-linear-attention kernel imports (transformers swallows failures)."""
    try:
        from fla.ops.gated_delta_rule import chunk_gated_delta_rule  # noqa: F401
    except Exception:
        return False
    return True


def torch_version() -> str:
    """The installed torch's version."""
    import torch

    return torch.__version__


def load_predictor(model_dir: Path, device: str) -> Predictor:
    """Loads MANTA onto a device.

    Args:
        model_dir: The downloaded model's directory (it carries the ``manta`` package).
        device: ``mps``, ``cuda`` or ``cpu``.

    Returns:
        The model, which answers ``predict(request)``.
    """
    sys.path.insert(0, str(model_dir))
    from manta import Manta

    return Manta.from_pretrained(str(model_dir), device=device)


def selftest_problem(cases: list[dict]) -> str | None:
    """Says why a self-test fixture cannot gate serving.

    Args:
        cases: The fixture's cases.

    Returns:
        A message when it is empty or a case lacks its reference value, else None.
    """
    if not cases:
        return "selftest.json has no cases"
    for i, case in enumerate(cases):
        key = "expected_score" if case.get("task") == "relevance" else "answer"
        if case.get(key) is None:
            return f"selftest.json case {i} has no {key}"
    return None
