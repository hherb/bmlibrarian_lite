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

/// A secure value transformer for encoding and decoding String arrays.
///
/// This transformer explicitly allows `NSArray` and `NSString` classes for
/// `NSSecureCoding` compliance, resolving CoreData warnings about insecure
/// transformable properties.
///
/// Register this transformer before creating the ModelContainer:
/// ```swift
/// StringArrayTransformer.register()
/// ```
@objc(StringArrayTransformer)
final class StringArrayTransformer: NSSecureUnarchiveFromDataTransformer {

    /// The transformer name used in SwiftData `@Attribute` declarations.
    static let name = NSValueTransformerName(rawValue: "StringArrayTransformer")

    /// Classes allowed for secure unarchiving.
    override static var allowedTopLevelClasses: [AnyClass] {
        [NSArray.self, NSString.self]
    }

    /// The class of the value returned by the transformer.
    ///
    /// Required for proper SwiftData/CoreData integration.
    override class func transformedValueClass() -> AnyClass {
        NSArray.self
    }

    /// Indicates whether the transformer can reverse transformations.
    override class func allowsReverseTransformation() -> Bool {
        true
    }

    /// Register this transformer with the system.
    ///
    /// Call this once at app startup before creating the ModelContainer.
    static func register() {
        let transformer = StringArrayTransformer()
        ValueTransformer.setValueTransformer(transformer, forName: name)
    }
}
