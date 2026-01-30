// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import SwiftData

// MARK: - Schema Version 1 (Original)

/// Original schema without ProcessingCheckpoint.
///
/// This represents the initial release schema with:
/// - FactCheckSession
/// - Document
/// - Citation
/// - EvidenceReport
/// - UsageRecord
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
        ]
    }
}

// MARK: - Schema Version 2 (Add ProcessingCheckpoint)

/// Schema version 2: Adds ProcessingCheckpoint for background processing support.
///
/// New model added:
/// - ProcessingCheckpoint: Stores processing state for resumable sessions
///
/// ## CloudKit Compatibility
///
/// The ProcessingCheckpoint model class has default values for all properties
/// (required for CloudKit). This is a code-level concern, not a schema change -
/// the database structure remains the same whether properties have defaults or not.
enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
            ProcessingCheckpoint.self,
        ]
    }
}

// MARK: - Migration Plan

/// Migration plan for upgrading the database schema.
///
/// Handles migrations between schema versions:
/// - V1 → V2: Adds ProcessingCheckpoint table (lightweight migration)
enum MedicalFactCheckerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Migration from V1 to V2: Add ProcessingCheckpoint.
    ///
    /// This is a lightweight migration since we're only adding a new model
    /// with no relationships to existing models. SwiftData handles this
    /// automatically - no data transformation needed.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )
}
