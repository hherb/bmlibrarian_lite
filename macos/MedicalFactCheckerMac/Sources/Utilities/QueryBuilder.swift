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

// NOTE: This file re-exports types from the BioMedLit package for backward compatibility.
// The actual implementation is in Packages/BioMedLit/Sources/BioMedLit/Models/StructuredQuery.swift
//
// The package QueryBuilderFactory, PubMedQueryBuilder, and EuropePMCQueryBuilder now incorporate
// the improvements that were previously only in this local file:
// - Exclude-list approach for publication types (more robust than include-list)
// - Date range support in generated queries
// - buildAll() method for multi-provider queries
// - Conditional keyword quoting (only multi-word keywords are quoted)

import Foundation
@_exported import enum BioMedLit.QueryBuilderFactory
@_exported import enum BioMedLit.PubMedQueryBuilder
@_exported import enum BioMedLit.EuropePMCQueryBuilder
