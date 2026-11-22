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


"""Command line of the MANTA judging server: serve, make-selftest."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

import manta_ledger as ml
import manta_model as mm
import manta_protocol as mp
import manta_service as ms

logger = logging.getLogger("manta_server")

SELFTEST_PATH = Path(__file__).with_name("selftest.json")
DEFAULT_MODEL = Path("~/models/MANTA-4B")
DEFAULT_LEDGER = Path("~/.manta_server/ledger.db")
DEVICES = ("mps", "cuda", "cpu")
EXIT_REFUSED = 2


def _load_cases() -> list[dict]:
    if not SELFTEST_PATH.exists():
        return []
    return json.loads(SELFTEST_PATH.read_text(encoding="utf-8"))


def _revision(model_dir: Path, any_revision: bool) -> str:
    """The model revision, refusing a mismatch unless allowed."""
    found = mm.read_revision(model_dir)
    if found != mm.EXPECTED_REVISION and not any_revision:
        sys.exit(
            f"refusing to serve: model revision is {found}, expected {mm.EXPECTED_REVISION} "
            "(pass --any-revision to override)"
        )
    return found or "unknown"


def serve(args: argparse.Namespace) -> None:
    """Loads the model, runs the self-test and serves."""
    model_dir = args.model.expanduser()
    cases = _load_cases()
    problem = mm.selftest_problem(cases)
    if problem:
        sys.exit(f"refusing to serve: {problem}; run make-selftest first")
    revision = _revision(model_dir, args.any_revision)
    predictor = mm.load_predictor(model_dir, args.device)
    kernel = mm.fla_kernel_available()
    logger.info("fla kernel in use: %s", kernel)
    result = ms.self_test(predictor, cases)
    logger.info("self-test %s: %s", "passed" if result.passed else "FAILED", result.detail)
    service = ms.MantaService(
        predictor,
        ml.open_ledger(args.ledger.expanduser()),
        revision,
        {"torch": mm.torch_version(), "device": args.device, "fla_kernel": kernel},
        result,
    )
    server = ms.make_server(service, args.port)
    logger.info("serving on %s:%d", ms.BIND_HOST, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def make_selftest(args: argparse.Namespace) -> None:
    """Writes each fixture case's reference value from this model, in place."""
    cases = _load_cases()
    predictor = mm.load_predictor(args.model.expanduser(), args.device)
    for i, case in enumerate(cases):
        if case["task"] == ms.TASK_RELEVANCE:
            req = mp.relevance_request(
                f"selftest-{i}", case["question"], case["title"], case["abstract"]
            )
            probs = predictor.predict(req)["questions"][ms.Q_RELEVANCE]["probabilities"]
            case["expected_score"] = mp.expected_score(probs)
        else:
            req = mp.design_request(f"selftest-{i}", case["title"], case["abstract"])
            case["answer"] = predictor.predict(req)["questions"][ms.Q_DESIGN]["answer"]
        logger.info("case %d: %s", i, case.get("expected_score", case.get("answer")))
    SELFTEST_PATH.write_text(
        json.dumps(cases, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


def main(argv: list[str] | None = None) -> None:
    """Parses the command line and runs a command."""
    parser = argparse.ArgumentParser(description="MANTA judging server")
    sub = parser.add_subparsers(dest="command", required=True)
    for name, fn in (("serve", serve), ("make-selftest", make_selftest)):
        p = sub.add_parser(name)
        p.add_argument("--model", type=Path, default=DEFAULT_MODEL)
        p.add_argument("--device", choices=DEVICES, default="cpu" if name != "serve" else "mps")
        p.set_defaults(fn=fn)
        if name == "serve":
            p.add_argument("--port", type=int, default=ms.DEFAULT_PORT)
            p.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
            p.add_argument("--any-revision", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args.fn(args)


if __name__ == "__main__":
    main()
