# Phase 2: Checkpointing and Progress Reporting

## Objective

Enable session resumption after interruption and provide real-time UI feedback during processing.

## Python Implementation

### 2.1 Checkpoint Storage

**File**: `src/bmlibrarian_lite/storage.py`

Add checkpoint table and methods:

```python
# Add to schema creation
CREATE_CHECKPOINTS_TABLE = """
CREATE TABLE IF NOT EXISTS processing_checkpoints (
    session_id TEXT NOT NULL,
    pmid TEXT NOT NULL,
    step TEXT NOT NULL,  -- 'scoring' or 'citation'
    result_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (session_id, pmid, step)
)
"""

class LiteStorage:
    # Add methods:

    def save_checkpoint(
        self,
        session_id: str,
        pmid: str,
        step: str,
        result: dict,
    ) -> None:
        """Save processing checkpoint for resumption."""
        with self._lock:
            self._conn.execute(
                """
                INSERT OR REPLACE INTO processing_checkpoints
                (session_id, pmid, step, result_json, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (session_id, pmid, step, json.dumps(result), datetime.now().isoformat()),
            )
            self._conn.commit()

    def load_checkpoint(
        self,
        session_id: str,
        pmid: str,
        step: str,
    ) -> Optional[dict]:
        """Load existing checkpoint if available."""
        row = self._conn.execute(
            """
            SELECT result_json FROM processing_checkpoints
            WHERE session_id = ? AND pmid = ? AND step = ?
            """,
            (session_id, pmid, step),
        ).fetchone()
        return json.loads(row[0]) if row else None

    def get_checkpointed_pmids(
        self,
        session_id: str,
        step: str,
    ) -> Set[str]:
        """Get PMIDs that have been checkpointed for a step."""
        rows = self._conn.execute(
            """
            SELECT pmid FROM processing_checkpoints
            WHERE session_id = ? AND step = ?
            """,
            (session_id, step),
        ).fetchall()
        return {row[0] for row in rows}
```

### 2.2 Progress Signal Protocol

**File**: `src/bmlibrarian_lite/gui/progress_signals.py` (new file)

```python
"""Progress reporting signals for parallel processing."""

from dataclasses import dataclass
from enum import Enum, auto
from typing import Optional
from PySide6.QtCore import QObject, Signal


class ProgressType(Enum):
    """Types of progress updates."""

    DOCUMENT_STARTED = auto()
    DOCUMENT_COMPLETED = auto()
    DOCUMENT_SKIPPED = auto()
    DOCUMENT_FAILED = auto()
    BATCH_COMPLETED = auto()
    PHASE_COMPLETED = auto()


@dataclass
class ProgressMessage:
    """Progress update message."""

    type: ProgressType
    pmid: Optional[str]
    step: str  # 'scoring' or 'citation'
    current: int
    total: int
    error: Optional[str] = None


class ProgressSignals(QObject):
    """Qt signals for progress updates."""

    document_progress = Signal(ProgressMessage)
    phase_completed = Signal(str, int)  # step, count
    error_occurred = Signal(str, str, str)  # pmid, step, error_message
```

### 2.3 Checkpointed Parallel Scoring

**File**: `src/bmlibrarian_lite/agents/parallel_scoring.py`

Add checkpointing support:

```python
async def score_documents_with_checkpointing(
    documents: List[LiteDocument],
    claim: str,
    session_id: str,
    storage: LiteStorage,
    agent_factory: Callable[[], ScoringAgent],
    max_concurrent: int,
    on_progress: Optional[Callable[[ProgressMessage], None]] = None,
) -> List[ScoringResult]:
    """
    Score documents with per-document checkpointing.

    Args:
        documents: List of documents to score.
        claim: The medical claim being fact-checked.
        session_id: Session identifier for checkpointing.
        storage: Storage instance for checkpoints.
        agent_factory: Factory function to create ScoringAgent instances.
        max_concurrent: Maximum number of concurrent requests.
        on_progress: Optional callback for progress updates.

    Returns:
        List of ScoringResult objects (including from checkpoints).
    """
    # Check for existing checkpoints
    checkpointed = storage.get_checkpointed_pmids(session_id, "scoring")
    to_process = [d for d in documents if d.pmid not in checkpointed]
    results = []

    # Load checkpointed results
    for doc in documents:
        if doc.pmid in checkpointed:
            checkpoint = storage.load_checkpoint(session_id, doc.pmid, "scoring")
            results.append(ScoringResult(
                document=doc,
                score=checkpoint["score"],
                rationale=checkpoint["rationale"],
            ))
            if on_progress:
                on_progress(ProgressMessage(
                    type=ProgressType.DOCUMENT_SKIPPED,
                    pmid=doc.pmid,
                    step="scoring",
                    current=len(results),
                    total=len(documents),
                ))

    # Process remaining documents
    semaphore = asyncio.Semaphore(max_concurrent)

    async def score_and_checkpoint(doc: LiteDocument) -> ScoringResult:
        async with semaphore:
            agent = agent_factory()
            result = await score_single_document_async(agent, doc, claim)

            # Save checkpoint immediately
            if not result.is_error:
                storage.save_checkpoint(
                    session_id,
                    doc.pmid,
                    "scoring",
                    {"score": result.score, "rationale": result.rationale},
                )

            if on_progress:
                on_progress(ProgressMessage(
                    type=ProgressType.DOCUMENT_FAILED if result.is_error else ProgressType.DOCUMENT_COMPLETED,
                    pmid=doc.pmid,
                    step="scoring",
                    current=len(results) + 1,
                    total=len(documents),
                    error=result.error,
                ))

            return result

    tasks = [score_and_checkpoint(doc) for doc in to_process]
    new_results = await asyncio.gather(*tasks)
    results.extend(new_results)

    return results
```

## Swift Implementation

### 2.1 Checkpoint Storage

**File**: `ios/MedicalFactChecker/Sources/Models/ProcessingCheckpoint.swift`

```swift
import Foundation
import SwiftData

@Model
class ProcessingCheckpoint {
    var sessionId: String
    var pmid: String
    var step: String  // "scoring" or "citation"
    var resultJSON: String
    var createdAt: Date

    init(sessionId: String, pmid: String, step: String, resultJSON: String) {
        self.sessionId = sessionId
        self.pmid = pmid
        self.step = step
        self.resultJSON = resultJSON
        self.createdAt = Date()
    }
}
```

### 2.2 Checkpoint Manager

**File**: `ios/MedicalFactChecker/Sources/Services/CheckpointManager.swift`

```swift
import Foundation
import SwiftData

actor CheckpointManager {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func saveCheckpoint(sessionId: String, pmid: String, step: String, result: Codable) throws {
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(result)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        let checkpoint = ProcessingCheckpoint(
            sessionId: sessionId,
            pmid: pmid,
            step: step,
            resultJSON: jsonString
        )

        modelContext.insert(checkpoint)
        try modelContext.save()
    }

    func loadCheckpoint<T: Codable>(sessionId: String, pmid: String, step: String) -> T? {
        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == sessionId && $0.pmid == pmid && $0.step == step
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoint = try? modelContext.fetch(descriptor).first,
              let data = checkpoint.resultJSON.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    func getCheckpointedPMIDs(sessionId: String, step: String) -> Set<String> {
        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == sessionId && $0.step == step
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoints = try? modelContext.fetch(descriptor) else {
            return []
        }

        return Set(checkpoints.map { $0.pmid })
    }
}
```

## Kotlin Implementation (Android)

### 2.1 Checkpoint Entity

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/local/entity/ProcessingCheckpointEntity.kt`

```kotlin
package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.Entity
import java.time.Instant

@Entity(
    tableName = "processing_checkpoints",
    primaryKeys = ["sessionId", "pmid", "step"]
)
data class ProcessingCheckpointEntity(
    val sessionId: String,
    val pmid: String,
    val step: String,
    val resultJson: String,
    val createdAt: Instant = Instant.now()
)
```

### 2.2 Checkpoint DAO

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/local/dao/ProcessingCheckpointDao.kt`

```kotlin
package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity

@Dao
interface ProcessingCheckpointDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun saveCheckpoint(checkpoint: ProcessingCheckpointEntity)

    @Query("SELECT * FROM processing_checkpoints WHERE sessionId = :sessionId AND pmid = :pmid AND step = :step")
    suspend fun loadCheckpoint(sessionId: String, pmid: String, step: String): ProcessingCheckpointEntity?

    @Query("SELECT pmid FROM processing_checkpoints WHERE sessionId = :sessionId AND step = :step")
    suspend fun getCheckpointedPmids(sessionId: String, step: String): List<String>

    @Query("DELETE FROM processing_checkpoints WHERE sessionId = :sessionId")
    suspend fun clearSession(sessionId: String)
}
```

### 2.3 Checkpoint Repository

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/repository/CheckpointRepository.kt`

```kotlin
package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.ProcessingCheckpointDao
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject

class CheckpointRepository @Inject constructor(
    private val checkpointDao: ProcessingCheckpointDao,
    private val json: Json
) {
    suspend fun <T> saveCheckpoint(sessionId: String, pmid: String, step: String, result: T) {
        val resultJson = json.encodeToString(result)
        checkpointDao.saveCheckpoint(
            ProcessingCheckpointEntity(
                sessionId = sessionId,
                pmid = pmid,
                step = step,
                resultJson = resultJson
            )
        )
    }

    suspend inline fun <reified T> loadCheckpoint(sessionId: String, pmid: String, step: String): T? {
        val checkpoint = checkpointDao.loadCheckpoint(sessionId, pmid, step)
        return checkpoint?.let { json.decodeFromString<T>(it.resultJson) }
    }

    suspend fun getCheckpointedPmids(sessionId: String, step: String): Set<String> {
        return checkpointDao.getCheckpointedPmids(sessionId, step).toSet()
    }

    suspend fun clearSession(sessionId: String) {
        checkpointDao.clearSession(sessionId)
    }
}
```

## Testing Phase 2

```bash
# Python tests
pytest tests/test_checkpointing.py -v
pytest tests/test_progress_signals.py -v

# Integration test: interrupt and resume
pytest tests/test_session_resumption.py -v
```

## Acceptance Criteria

- [ ] Checkpoints saved after each document processed
- [ ] Session resumption skips already-processed documents
- [ ] Progress bar updates per-document
- [ ] Document cards update status in real-time
- [ ] Interrupted sessions can be resumed
- [ ] Checkpoint storage doesn't impact performance significantly
