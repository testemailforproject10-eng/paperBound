//
//  SampleLibrary.swift
//  Paperbound
//
//  Generates a small PDF so a fresh install has something to read, and so the
//  feasibility claim — "a tear removes real letters and real artwork" — can be
//  checked immediately without hunting for a file.
//
//  The text is written for this app; the diagram is drawn with vectors. Nothing
//  here is third-party content.
//

import CoreGraphics
import CoreText
import Foundation
import SwiftData
import UIKit

enum SampleLibrary {

    static let title = "Notes on the Life of a Page"
    static let author = "Paperbound"

    /// 6 × 9 inches at 72 dpi — a book, not a letterhead.
    static let pageSize = CGSize(width: 432, height: 648)

    // MARK: - Installation

    @MainActor
    @discardableResult
    static func installIfNeeded(store: LibraryStore, context: ModelContext) throws -> Book? {
        let marker = "sample.\(SampleLibrary.title)"
        let existing = try context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.contentFingerprint == marker })
        )
        if let found = existing.first, store.fileExists(for: found) { return found }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperbound-sample-\(UUID().uuidString).pdf")
        try write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let outcome = try store.importFile(at: temporary, into: context)
        let book = outcome.book
        book.title = title
        book.author = author
        // A fixed fingerprint keeps the sample from being installed twice while
        // still letting the reader delete it for good.
        book.contentFingerprint = marker
        try context.save()
        return book
    }

    // MARK: - PDF generation

    static func write(to url: URL) throws {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextAuthor as String: author
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        let body = makeAttributedBody()
        let margin = CGSize(width: 54, height: 64)
        let textRect = CGRect(
            x: margin.width,
            y: margin.height,
            width: pageSize.width - margin.width * 2,
            height: pageSize.height - margin.height * 2 - 20
        )

        let data = renderer.pdfData { context in
            let framesetter = CTFramesetterCreateWithAttributedString(body)
            var characterIndex = 0
            var pageNumber = 1
            let totalLength = body.length

            while characterIndex < totalLength {
                context.beginPage()
                let cg = context.cgContext

                // CoreText draws bottom-up; the PDF context is top-down.
                cg.saveGState()
                cg.textMatrix = .identity
                cg.translateBy(x: 0, y: pageSize.height)
                cg.scaleBy(x: 1, y: -1)

                let flippedRect = CGRect(
                    x: textRect.minX,
                    y: pageSize.height - textRect.maxY,
                    width: textRect.width,
                    height: textRect.height
                )
                let path = CGPath(rect: flippedRect, transform: nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: characterIndex, length: 0),
                    path,
                    nil
                )
                CTFrameDraw(frame, cg)
                let visible = CTFrameGetVisibleStringRange(frame)
                cg.restoreGState()

                drawFolio(pageNumber: pageNumber, in: cg)

                if visible.length <= 0 { break }
                characterIndex += visible.length
                pageNumber += 1
            }

            // A page of artwork, so damage can be seen cutting through
            // something other than type.
            context.beginPage()
            drawDiagramPage(in: context.cgContext)
            drawFolio(pageNumber: pageNumber, in: context.cgContext)
        }

        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Text

    private static func makeAttributedBody() -> NSAttributedString {
        let result = NSMutableAttributedString()

        result.append(paragraph(title, style: .title))
        result.append(paragraph("A short book about paper, printed for testing", style: .subtitle))

        for section in sections {
            result.append(paragraph(section.heading, style: .heading))
            for text in section.paragraphs {
                result.append(paragraph(text, style: .body))
            }
        }
        return result
    }

    private enum TextStyle {
        case title, subtitle, heading, body
    }

    private static func paragraph(_ text: String, style: TextStyle) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        let font: UIFont
        var spacingBefore: CGFloat = 0

        switch style {
        case .title:
            font = UIFont(name: "Georgia-Bold", size: 26) ?? .boldSystemFont(ofSize: 26)
            paragraphStyle.alignment = .center
            paragraphStyle.paragraphSpacing = 6
            paragraphStyle.lineHeightMultiple = 1.1
        case .subtitle:
            font = UIFont(name: "Georgia-Italic", size: 12) ?? .italicSystemFont(ofSize: 12)
            paragraphStyle.alignment = .center
            paragraphStyle.paragraphSpacing = 28
        case .heading:
            font = UIFont(name: "Georgia-Bold", size: 14) ?? .boldSystemFont(ofSize: 14)
            paragraphStyle.alignment = .left
            paragraphStyle.paragraphSpacing = 8
            spacingBefore = 18
        case .body:
            font = UIFont(name: "Georgia", size: 11.5) ?? .systemFont(ofSize: 11.5)
            paragraphStyle.alignment = .justified
            paragraphStyle.firstLineHeadIndent = 16
            paragraphStyle.paragraphSpacing = 7
            paragraphStyle.lineHeightMultiple = 1.24
            paragraphStyle.hyphenationFactor = 0.9
        }
        paragraphStyle.paragraphSpacingBefore = spacingBefore

        return NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: UIColor(red: 0.09, green: 0.08, blue: 0.07, alpha: 1)
            ]
        )
    }

    private static func drawFolio(pageNumber: Int, in ctx: CGContext) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(
            string: "\(pageNumber)",
            attributes: [
                .font: UIFont(name: "Georgia", size: 9) ?? .systemFont(ofSize: 9),
                .paragraphStyle: style,
                .foregroundColor: UIColor(white: 0.25, alpha: 1)
            ]
        )
        let rect = CGRect(x: 0, y: pageSize.height - 44, width: pageSize.width, height: 16)
        UIGraphicsPushContext(ctx)
        text.draw(in: rect)
        UIGraphicsPopContext()
    }

    // MARK: - Artwork

    private static func drawDiagramPage(in ctx: CGContext) {
        let ink = UIColor(red: 0.10, green: 0.09, blue: 0.08, alpha: 1).cgColor
        let wash = UIColor(red: 0.42, green: 0.36, blue: 0.28, alpha: 0.35).cgColor

        // Caption
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let caption = NSAttributedString(
            string: "Figure 1 — A section through a bound signature",
            attributes: [
                .font: UIFont(name: "Georgia-Italic", size: 10) ?? .italicSystemFont(ofSize: 10),
                .paragraphStyle: style,
                .foregroundColor: UIColor(white: 0.2, alpha: 1)
            ]
        )
        UIGraphicsPushContext(ctx)
        caption.draw(in: CGRect(x: 40, y: 500, width: pageSize.width - 80, height: 40))
        UIGraphicsPopContext()

        ctx.saveGState()
        ctx.setLineWidth(1.1)
        ctx.setStrokeColor(ink)

        // A fan of sheets meeting at a spine.
        let spineX: CGFloat = 96
        let baseY: CGFloat = 300
        for index in 0..<9 {
            let offset = CGFloat(index) * 9
            let tip = CGPoint(x: pageSize.width - 70 - offset * 0.4, y: baseY - 96 + offset)
            ctx.move(to: CGPoint(x: spineX, y: baseY - 40 + offset * 0.55))
            ctx.addCurve(
                to: tip,
                control1: CGPoint(x: spineX + 110, y: baseY - 120 + offset),
                control2: CGPoint(x: pageSize.width - 190, y: baseY - 74 + offset)
            )
            ctx.strokePath()
        }

        // Spine block.
        ctx.setFillColor(wash)
        let spine = CGRect(x: spineX - 26, y: baseY - 122, width: 26, height: 150)
        ctx.fill(spine)
        ctx.setStrokeColor(ink)
        ctx.stroke(spine)

        // Stitching.
        ctx.setLineWidth(0.9)
        for index in 0..<5 {
            let y = spine.minY + 18 + CGFloat(index) * 28
            ctx.move(to: CGPoint(x: spine.minX + 5, y: y))
            ctx.addLine(to: CGPoint(x: spine.maxX + 30, y: y + 4))
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: spine.maxX + 28, y: y + 2, width: 4, height: 4))
        }

        // Callout labels.
        let labels: [(String, CGPoint)] = [
            ("head", CGPoint(x: 250, y: 152)),
            ("fore-edge", CGPoint(x: 300, y: 268)),
            ("tail", CGPoint(x: 232, y: 330)),
            ("spine", CGPoint(x: 40, y: 240))
        ]
        UIGraphicsPushContext(ctx)
        for (text, point) in labels {
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont(name: "Georgia-Italic", size: 9) ?? .italicSystemFont(ofSize: 9),
                    .foregroundColor: UIColor(white: 0.15, alpha: 1)
                ]
            )
            attributed.draw(at: point)
        }
        UIGraphicsPopContext()

        // Ruled measuring bar across the lower third — an obvious victim for a
        // tear, and an easy way to spot geometric drift between renders.
        ctx.setLineWidth(0.8)
        ctx.setStrokeColor(ink)
        let barY: CGFloat = 430
        ctx.move(to: CGPoint(x: 54, y: barY))
        ctx.addLine(to: CGPoint(x: pageSize.width - 54, y: barY))
        ctx.strokePath()
        for index in 0...12 {
            let x = 54 + CGFloat(index) * ((pageSize.width - 108) / 12)
            let height: CGFloat = index.isMultiple(of: 3) ? 12 : 6
            ctx.move(to: CGPoint(x: x, y: barY))
            ctx.addLine(to: CGPoint(x: x, y: barY - height))
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    // MARK: - Copy

    private struct Section {
        var heading: String
        var paragraphs: [String]
    }

    private static let sections: [Section] = [
        Section(
            heading: "I. What a sheet remembers",
            paragraphs: [
                "A page is not a surface. It is a compressed mat of fibres, each one laid down wet and dried under pressure, each one still holding the direction it was travelling when the sheet was formed. Tear a page slowly and it will separate along that grain; tear it quickly and it will not. The difference is visible from across a room, and it is the first thing that betrays a forgery.",
                "This matters to anyone drawing paper rather than photographing it. A torn edge is not a jagged line. It is a shallow ramp where the upper layer of fibre has pulled away from the lower, so that light entering the cut is scattered before it is reflected. The edge therefore reads brighter than the surrounding sheet, not darker, and the brightness falls off over perhaps a millimetre.",
                "The same is true of a hole. What makes a hole convincing is never its outline. It is the fact that something is visible through it — another sheet, a little further away, a little darker, with its own type showing faintly in the wrong place."
            ]
        ),
        Section(
            heading: "II. The economy of damage",
            paragraphs: [
                "Books do not wear evenly. The outer corner of the leaf, the one a thumb reaches for, goes first. The bound edge is protected and will still look new when the fore-edge has been handled to softness. Any system that scatters damage uniformly across a page will look wrong even to a reader who could not say why.",
                "Wear also accumulates. The corner that is soft today is torn next year and missing the year after. A generator that produces fresh damage on every viewing produces no sense of history at all; the page must be the same page each time it is opened, which means the randomness has to be seeded and the seed has to be kept.",
                "There is a second kind of memory: the damage belongs to the physical sheet, not to the text on it. If the type is reset at a larger size, the tear does not move to follow a particular word. It stays where the paper was torn, and different words fall under it."
            ]
        ),
        Section(
            heading: "III. Foxing, damp and the tide line",
            paragraphs: [
                "The rust-coloured spots that collect on old paper are usually iron impurities oxidising, sometimes fungal, and almost always clustered rather than spread. They favour the margins and the first and last leaves of a volume, where air reached most easily.",
                "Water damage announces itself differently. A drop spreading through paper carries dissolved material to the edge of its own advance and deposits it there, so the boundary of a damp stain is darker than its middle. That tide line is the single detail that separates a believable stain from a brown circle.",
                "Neither of these removes text. They sit over it, and the type remains legible through them. Confusing tinting with removal is the commonest mistake in aged-paper rendering: a stain should never erase a letter, and a tear should never merely shade one."
            ]
        ),
        Section(
            heading: "IV. Against the single vintage texture",
            paragraphs: [
                "The temptation is to acquire one high-resolution photograph of a beautiful old page and lay it under everything. It works on the first screen and fails on the second, because the eye finds repetition faster than it finds detail. The same coffee ring in the same corner of every page reads as wallpaper.",
                "A small library of parts does better: a handful of edge profiles, some fibre, a few stain shapes, a set of creases, and a rule for arranging them. From perhaps a dozen elements one can compose a thousand pages that never repeat, and each one can be reproduced exactly from four numbers.",
                "The constraint that makes this workable is determinism. Given the same book, the same sheet and the same chosen condition, the arrangement must come out identical every single time — on a cold launch, on another device, a year later. Anything less and the book stops being an object and becomes a slideshow."
            ]
        ),
        Section(
            heading: "V. What must stay reversible",
            paragraphs: [
                "Everything described here is a way of drawing. None of it is a way of editing. The imported file is copied once into the library folder and then read; the wear is computed at display time and thrown away when the page leaves the screen.",
                "That is the promise the whole idea rests on. A reader who has spent a month with a comfortably battered paperback must be able to tap once and see the document exactly as it was delivered — every letter present, every figure whole, selectable and searchable. If that tap is ever less than instant and less than complete, the effect is no longer a reading environment. It is damage.",
                "So the two paths are kept separate all the way down. One renders the document. The other renders paper, and asks the first for its pixels."
            ]
        )
    ]
}
