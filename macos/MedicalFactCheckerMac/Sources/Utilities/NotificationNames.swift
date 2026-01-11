//
//  NotificationNames.swift
//  MedicalFactChecker
//
//  Shared notification names used across iOS and macOS apps.
//

import Foundation

extension Notification.Name {
    /// Posted when a document reference link is clicked in the report view.
    ///
    /// The notification's userInfo contains the clicked URL under the "url" key.
    static let documentReferenceClicked = Notification.Name("documentReferenceClicked")
}
