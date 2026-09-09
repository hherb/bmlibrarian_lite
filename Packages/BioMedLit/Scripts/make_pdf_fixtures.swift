#!/usr/bin/env swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

// Regenerates the PDF fixtures in Tests/BioMedLitTests/Fixtures/PDF.
//
// Run from the package root:  swift Scripts/make_pdf_fixtures.swift
//
// Not byte-reproducible: CGContext embeds a run-varying /ID and, for
// encrypted.pdf, fresh encryption key material on every run, so re-running
// this against an unchanged fixture set still diffs all four files. The
// diff is spurious — semantically equivalent output, and the regenerated
// set passes the same tests — read it as such rather than as evidence
// something changed.
//
// CoreGraphics and CoreText only, so this needs no dependency and no Xcode
// project. Text is drawn with CoreText rather than as an image, because the
// whole point of three of these four files is that PDFKit can get the text
// back out.
import CoreGraphics
import CoreText
import Foundation

let pageSize = CGRect(x: 0, y: 0, width: 612, height: 792)

/// Draw one line of text near the top of the current page.
func draw(_ text: String, in context: CGContext, y: CGFloat = 700) {
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let attributed = NSAttributedString(
        string: text,
        attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 72, y: y)
    CTLineDraw(line, context)
}

/// Write a PDF whose pages are produced by `body`.
func makePDF(named name: String, auxiliaryInfo: CFDictionary? = nil, body: (CGContext) -> Void) {
    let url = URL(fileURLWithPath: "Tests/BioMedLitTests/Fixtures/PDF/\(name)")
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: nil, auxiliaryInfo) else {
        fatalError("could not create a PDF context for \(name)")
    }
    body(context)
    context.closePDF()
    print("wrote \(url.path)")
}

// 1. An ordinary one-page article. The text is what the extractor must recover.
makePDF(named: "ordinary.pdf") { context in
    var box = pageSize
    context.beginPage(mediaBox: &box)
    draw("Randomised trial of an intervention.", in: context, y: 700)
    draw("Methods: we enrolled 120 patients.", in: context, y: 670)
    context.endPage()
}

// 2. Two pages where the second carries no text at all: the shape of a partial
//    extraction, which must not read as a whole article.
makePDF(named: "mixed.pdf") { context in
    var box = pageSize
    context.beginPage(mediaBox: &box)
    draw("Page one carries prose.", in: context, y: 700)
    context.endPage()
    context.beginPage(mediaBox: &box)
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 72, y: 400, width: 200, height: 200))
    context.endPage()
}

// 3. No text anywhere: a scan, which yields nothing and must say so.
makePDF(named: "imageonly.pdf") { context in
    var box = pageSize
    context.beginPage(mediaBox: &box)
    context.setFillColor(CGColor(gray: 0.2, alpha: 1))
    context.fill(CGRect(x: 72, y: 400, width: 300, height: 300))
    context.endPage()
}

// 4. Password-protected: a *user* password, which is what actually blocks
//    reading. bmlib is explicit that this is a *failed* result and not an
//    empty successful one, so that a locked file is never logged as a scan.
let encryption: CFDictionary = [
    kCGPDFContextUserPassword as String: "secret",
    kCGPDFContextOwnerPassword as String: "owner",
] as CFDictionary
makePDF(named: "encrypted.pdf", auxiliaryInfo: encryption) { context in
    var box = pageSize
    context.beginPage(mediaBox: &box)
    draw("You should not be able to read this.", in: context, y: 700)
    context.endPage()
}

// 5. The negative control for #4, and the reason the guard checks `isLocked`
//    alone. An *owner* password restricts permissions — printing, copying —
//    without blocking reads, so this file is encrypted and extracts perfectly.
//    PDFKit reports `isLocked == false, isEncrypted == true` for it, so a guard
//    widened to `isEncrypted` rejects a readable article. bmlib rejects on
//    `needs_pass` for exactly this reason (DECISIONS.md, "the PDF converter"),
//    and carries the same negative control so that neither guard is a check
//    that cannot fail.
let ownerOnly: CFDictionary = [
    kCGPDFContextOwnerPassword as String: "owner",
] as CFDictionary
makePDF(named: "ownerpassword.pdf", auxiliaryInfo: ownerOnly) { context in
    var box = pageSize
    context.beginPage(mediaBox: &box)
    draw("An owner password restricts permissions, not reading.", in: context, y: 700)
    draw("Methods: we enrolled 120 patients.", in: context, y: 670)
    context.endPage()
}
