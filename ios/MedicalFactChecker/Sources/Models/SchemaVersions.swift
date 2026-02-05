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

// MARK: - Schema Version 0 (Pre-versioning)

/// Schema version 0: Represents databases created before versioned schema was introduced.
///
/// This is a compatibility shim for databases created without VersionedSchema.
/// The models are identical to V1, but this version allows SwiftData to
/// recognize and migrate unversioned databases.
///
/// ## Why This Exists
///
/// When SwiftData creates a database without a VersionedSchema, it stores no
/// version metadata. When later trying to use staged migration, SwiftData
/// can't determine the starting version and fails with:
/// "Cannot use staged migration with an unknown model version."
///
/// By including V0 with version (0, 0, 0), we provide a fallback that matches
/// the unversioned schema structure, allowing migration to proceed.
enum SchemaV0: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(0, 0, 0)
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

// MARK: - Schema Version 1 (First versioned release)

/// Schema version 1: First explicitly versioned schema.
///
/// Identical to V0 but with explicit versioning. This represents the
/// baseline for the versioned schema system with:
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
/// - V0 → V1: No-op (schemas are identical, just adds version tracking)
/// - V1 → V2: Adds ProcessingCheckpoint table (lightweight migration)
///
/// ## Handling Unversioned Databases
///
/// Databases created before the VersionedSchema system have no version
/// metadata. SwiftData will attempt to match them against V0 based on
/// schema structure. The V0 → V1 migration is a no-op that simply
/// establishes version tracking.
enum MedicalFactCheckerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV0.self, SchemaV1.self, SchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV0toV1, migrateV1toV2]
    }

    /// Migration from V0 to V1: Establish version tracking.
    ///
    /// This is a lightweight migration with no actual schema changes.
    /// It exists to transition unversioned databases to the versioned system.
    static let migrateV0toV1 = MigrationStage.lightweight(
        fromVersion: SchemaV0.self,
        toVersion: SchemaV1.self
    )

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
