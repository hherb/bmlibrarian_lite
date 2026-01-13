//
//  StringArrayTransformer.swift
//  MedicalFactChecker
//
//  Secure value transformer for [String] arrays in SwiftData models.
//

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
