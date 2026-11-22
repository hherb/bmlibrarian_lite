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

"""The MANTA shadow stage: judge each LLM-scored paper beside the LLM.

``observe`` only enqueues; one daemon worker does the HTTP and the storing,
so scoring never waits for, or fails because of, MANTA. Nothing the reader
sees changes.
"""

from __future__ import annotations

import logging
import queue
import threading
import time
from dataclasses import dataclass, replace
from datetime import UTC, datetime

from .analysis_failures import redact_secrets
from .config import LiteConfig
from .constants import MANTA_ERROR_MAX_CHARS
from .data_models import LiteDocument
from .manta_client import MantaClient, MantaRefused, MantaUnreachable
from .manta_store import (
    OUTCOME_FAILED,
    OUTCOME_JUDGED,
    OUTCOME_UNREACHABLE,
    MantaRow,
)
from .storage import LiteStorage

logger = logging.getLogger(__name__)

DRAIN_POLL_SECONDS = 0.02


@dataclass(frozen=True)
class _Item:
    """One paper waiting for its judgement."""

    question: str
    document: LiteDocument
    llm_score: int
    llm_model: str


class MantaShadow:
    """Judges observed papers on a background thread and stores the result."""

    def __init__(self, client: MantaClient, storage: LiteStorage, server_url: str) -> None:
        """Starts the worker.

        Args:
            client: The MANTA client.
            storage: Where rows are kept.
            server_url: The server's address, recorded on each row.
        """
        self._client = client
        self._storage = storage
        self._url = server_url
        self._queue: queue.Queue[_Item] = queue.Queue()
        threading.Thread(target=self._run, name="manta-shadow", daemon=True).start()

    def observe(
        self, question: str, document: LiteDocument, llm_score: int, llm_model: str
    ) -> None:
        """Queue a paper the LLM scored. Never blocks, never raises."""
        try:
            self._queue.put(_Item(question, document, llm_score, llm_model))
        except Exception:  # noqa: BLE001 - the shadow must never touch scoring
            logger.warning("MANTA shadow could not queue a paper", exc_info=True)

    def drain(self, timeout: float) -> bool:
        """Wait until every queued paper is done; False on timeout (tests)."""
        deadline = time.monotonic() + timeout
        while self._queue.unfinished_tasks:
            if time.monotonic() >= deadline:
                return False
            time.sleep(DRAIN_POLL_SECONDS)
        return True

    def _run(self) -> None:
        """The worker loop: no item can end it."""
        while True:
            item = self._queue.get()
            try:
                self._process(item)
            except Exception:  # noqa: BLE001 - one bad item must not kill the worker
                logger.warning("MANTA shadow failed on a paper", exc_info=True)
            finally:
                self._queue.task_done()

    def _failure(self, outcome: str, error: str, base: MantaRow) -> MantaRow:
        """The row of an attempt that gave no judgement."""
        return replace(base, outcome=outcome, error=redact_secrets(error)[:MANTA_ERROR_MAX_CHARS])

    def _process(self, item: _Item) -> None:
        """Judge, store, post the reference, mark it posted."""
        doc = item.document
        base = MantaRow(
            document_id=doc.id,
            question=item.question,
            outcome=OUTCOME_FAILED,
            server_url=self._url,
            judged_at=datetime.now(UTC).isoformat(),
        )
        try:
            j = self._client.judge(item.question, doc)
        except MantaUnreachable as e:
            self._storage.record_manta_judgement(
                self._failure(OUTCOME_UNREACHABLE, str(e) or "unreachable", base)
            )
            return
        except MantaRefused as e:
            self._storage.record_manta_judgement(self._failure(OUTCOME_FAILED, e.message, base))
            return
        except Exception as e:  # noqa: BLE001 - the client can raise other requests errors
            self._storage.record_manta_judgement(
                self._failure(OUTCOME_FAILED, str(e) or type(e).__name__, base)
            )
            return
        row = replace(
            base,
            outcome=OUTCOME_JUDGED,
            judgement_id=j.judgement_id,
            revision=j.revision,
            expected_score=j.expected_score,
            relevance_probabilities=j.relevance_probabilities,
            verdict=j.verdict,
            cutoff=j.cutoff,
            design=j.design,
            design_probability=j.design_probability,
            design_probabilities=j.design_probabilities,
            seconds=j.seconds,
            truncated=j.truncated,
        )
        self._storage.record_manta_judgement(row)
        try:
            self._client.reference(j.judgement_id, item.llm_model, item.llm_score, doc)
        except Exception as e:  # noqa: BLE001 - never changes the stored outcome
            logger.warning(f"MANTA reference not posted for {doc.id}: {redact_secrets(str(e))}")
            return
        self._storage.record_manta_judgement(replace(row, reference_posted=True))


_shadows: dict[str, MantaShadow] = {}
_lock = threading.Lock()


def shadow_for(config: LiteConfig) -> MantaShadow | None:
    """The process-wide shadow for the configured server; None when off.

    Args:
        config: The configuration; ``manta.url`` empty means off.
    """
    url = config.manta.url
    if not url:
        return None
    with _lock:
        if url not in _shadows:
            _shadows[url] = MantaShadow(MantaClient(url), LiteStorage(config), url)
        return _shadows[url]


def _reset_for_tests() -> None:
    """Forget every cached shadow (their daemon threads idle on)."""
    with _lock:
        _shadows.clear()
