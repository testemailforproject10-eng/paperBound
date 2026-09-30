//
//  PageCompositor.swift
//  Paperbound
//
//  Builds one finished physical page.
//
//  Layer order, bottom to top:
//
//      neighbouring sheets in the stack
//      the sheet directly below  ← what a hole reveals
//      shadow cast by the torn edge onto that sheet
//      paper material of the current sheet
//      the document's own pixels (clipped by the cut mask)
//      stains, foxing, creases
//      fibre halo along every cut
//      lighting: tint, sweep, vignette, spine
//
//  Nothing in here can alter the source document: the content image arrives
//  already rendered, and the mask only decides which of its pixels survive.
//

import CoreGraphics
import CoreImage
import Foundation

struct PageCompositionRequest {
    /// The document page, already rasterized at sheet resolution.
    /// Transparent where nothing is printed.
    var content: CGImage?
    /// Size of the whole surface tile, in pixels.
    var pixelSize: CGSize
    var environment: ReadingEnvironment
    var condition: PageConditionData
    /// What a previous owner left on this sheet. Nil for an unannotated book,
    /// which is every book the app rendered before marginalia existed.
    var marginalia: PageMarginalia?
    /// Which edge is bound, for stack direction and spine shading.
    var spine: PageEdge
    /// Varies the paper texture from sheet to sheet.
    var textureSeed: UInt64
    /// Height / width of the document page, so the text block keeps the
    /// document's own proportions inside a sheet that fills the screen.
    var pageAspectRatio: Double = 648.0 / 432.0
    /// The visible part of the sheet, in unit coordinates. Paper is drawn to
    /// the sheet's edge; type is kept inside this.
    var safeFraction: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Hardware-reserved areas, normalized to the sheet. Foreground document
    /// pixels are clipped out of these regions on Duo.
    var reservedRegions: [CGRect] = []
    /// 0…1 multiplier on spine shadow depth. The layout coordinator raises this
    /// as a folding device approaches book posture.
    var spineShadowScale: Double = 1.0
}

/// The finished sheet and, only for Enchanted Ink, its matching clean-paper
/// sheet. These immutable images are the GPU simulation's preparation inputs.
struct PageRenderResult: @unchecked Sendable {
    let image: CGImage
    let revealBackground: CGImage?
    let revealSeed: UInt64

    init(image: CGImage, revealBackground: CGImage?, revealSeed: UInt64) {
        self.image = image
        self.revealBackground = revealBackground
        self.revealSeed = revealSeed
    }

    var memoryCost: Int {
        image.bytesPerRow * image.height
            + (revealBackground.map { $0.bytesPerRow * $0.height } ?? 0)
    }
}

final class PageCompositor: @unchecked Sendable {

    static let shared = PageCompositor()

    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private init() {
        self.ciContext = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB()
        ])
    }

    // MARK: - Drawing helpers

    /// Draws a bitmap the right way up.
    ///
    /// The whole compositor works in a y-down space so that normalized damage
    /// coordinates map straight through. `CGContext.draw(_:in:)` orients images
    /// along +y, which in that space points down the page — so every bitmap
    /// needs its own local flip, or the document comes out mirrored.
    private func drawImage(_ image: CGImage, in rect: CGRect, into ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // MARK: - Geometry shared with the render pipeline

    /// Where the sheet sits inside its surface tile.
    ///
    /// The sheet fills the tile. Paper reaches the edge of the space it is
    /// given, so on screen it reaches the bezel and the display's own rounded
    /// corners clip it; nothing here needs to know the device's corner radius.
    static func sheetRect(in surface: CGRect, presentation: BookPresentation) -> CGRect {
        surface
    }

    /// Where the document is drawn inside the sheet: the page at its own
    /// proportions, inset by the presentation's margin.
    ///
    /// `surfaceInset` used to hold the sheet away from the edge of the screen.
    /// It now does the job that number always described better — the margin of
    /// paper around the text block — so a hardcover still carries a wider
    /// margin than a minimal presentation, but as part of the page rather than
    /// as dead board around it.
    ///
    /// The renderer rasterizes the document at exactly this size, so content
    /// and mask continue to share one coordinate system and tears cannot drift.
    /// `safeFraction` is the part of the sheet the reader can actually see,
    /// in unit coordinates. Paper fills the whole screen, reserved regions
    /// included, but type must not run under a sensor strip or a home
    /// indicator, so the text block is fitted inside this box rather than
    /// inside the sheet. Unit coordinates keep it free of any pixel/point
    /// confusion on the way through the render pipeline.
    /// `extraInset` is additional margin, in the same units as the
    /// presentation's own: a fraction of the shorter side. A marginalia style
    /// asks for it, because a book meant to be written in has wide margins and
    /// without them there is nowhere for a mark to legally go.
    static func contentRect(
        in sheet: CGRect,
        presentation: BookPresentation,
        pageAspectRatio: Double,
        safeFraction: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        extraInset: Double = 0,
        contentMargin: Double? = nil
    ) -> CGRect {
        guard sheet.width > 0, sheet.height > 0 else { return sheet }

        let safe = CGRect(
            x: sheet.minX + safeFraction.minX * sheet.width,
            y: sheet.minY + safeFraction.minY * sheet.height,
            width: sheet.width * safeFraction.width,
            height: sheet.height * safeFraction.height
        )
        guard safe.width > 0, safe.height > 0 else { return sheet }

        let unit = min(safe.width, safe.height)
        let margin = CGFloat(contentMargin ?? (presentation.surfaceInset + max(0, extraInset))) * unit
        let box = safe.insetBy(dx: margin, dy: margin)
        guard box.width > 0, box.height > 0, pageAspectRatio > 0 else { return box }

        var width = box.width
        var height = width * CGFloat(pageAspectRatio)
        if height > box.height {
            height = box.height
            width = height / CGFloat(pageAspectRatio)
        }
        return CGRect(
            x: box.minX + (box.width - width) / 2,
            y: box.minY + (box.height - height) / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Entry point

    /// Production reader path: source pixels on plain white, with no paper
    /// texture, damage, annotations, tint, shadows or ink color conversion.
    func compositeReaderPage(
        _ request: PageCompositionRequest,
        paperReady: (@Sendable (CGImage) async -> Void)? = nil
    ) async throws -> PageRenderResult {
        try Task.checkCancellation()
        let width = max(1, Int(request.pixelSize.width.rounded()))
        let height = max(1, Int(request.pixelSize.height.rounded()))
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ReadingEngineError.renderFailed("could not allocate the page bitmap") }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let surface = CGRect(x: 0, y: 0, width: width, height: height)
        let paperTiming = InkMetrics.begin("Paper composite")
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(surface)
        var background: CGImage?
        if request.environment.ink == .enchanted {
            guard let paper = ctx.makeImage() else {
                throw ReadingEngineError.renderFailed("could not create the plain paper image")
            }
            background = paper
        }
        InkMetrics.end("Paper composite", paperTiming)
        if let background { await paperReady?(background) }
        try Task.checkCancellation()
        let timing = InkMetrics.begin("Finished composite")
        defer { InkMetrics.end("Finished composite", timing) }
        ctx.saveGState()
        ctx.addRect(surface)
        for region in request.reservedRegions {
            ctx.addRect(CGRect(
                x: region.minX * surface.width, y: region.minY * surface.height,
                width: region.width * surface.width, height: region.height * surface.height
            ))
        }
        ctx.clip(using: .evenOdd)
        if let content = request.content {
            let rect = Self.contentRect(
                in: surface, presentation: .minimal,
                pageAspectRatio: request.pageAspectRatio,
                safeFraction: request.safeFraction, contentMargin: 0
            )
            ctx.interpolationQuality = .high
            drawImage(content, in: rect, into: ctx)
        }
        ctx.restoreGState()
        try Task.checkCancellation()
        guard let image = ctx.makeImage() else {
            throw ReadingEngineError.renderFailed("could not create the finished page image")
        }
        return PageRenderResult(image: image, revealBackground: background,
                                revealSeed: request.textureSeed)
    }

    func composite(_ request: PageCompositionRequest) -> CGImage? {
        composite(request, includesDocumentContent: true)
    }

    /// Builds the page pair needed by the live ink effect. Both passes use the
    /// same deterministic inputs, so paper, wear, lighting, and annotations
    /// line up pixel for pixel.
    func compositePage(
        _ request: PageCompositionRequest,
        paperReady: (@Sendable (CGImage) async -> Void)? = nil
    ) async throws -> PageRenderResult {
        var background: CGImage?
        if request.environment.ink == .enchanted {
            let timing = InkMetrics.begin("Paper composite")
            background = composite(request, includesDocumentContent: false)
            InkMetrics.end("Paper composite", timing)
            try Task.checkCancellation()
            guard let background else {
                throw ReadingEngineError.renderFailed("compositor produced no clean-paper page")
            }
            await paperReady?(background)
        }
        let timing = InkMetrics.begin("Finished composite")
        defer { InkMetrics.end("Finished composite", timing) }
        let finished = composite(request, includesDocumentContent: true)
        try Task.checkCancellation()
        guard let finished else {
            throw ReadingEngineError.renderFailed("compositor produced no finished page")
        }
        return PageRenderResult(
            image: finished,
            revealBackground: background,
            revealSeed: request.textureSeed
        )
    }

    private func composite(
        _ request: PageCompositionRequest,
        includesDocumentContent: Bool
    ) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let width = max(1, Int(request.pixelSize.width.rounded()))
        let height = max(1, Int(request.pixelSize.height.rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Work in a y-down coordinate system so that normalized damage
        // coordinates (origin top-left) map straight through.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        let surface = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let presentation = request.environment.presentation
        let sheetRect = Self.sheetRect(in: surface, presentation: presentation)
        guard sheetRect.width > 4, sheetRect.height > 4 else { return nil }

        let cornerRadius = CGFloat(presentation.sheetCornerRadius) * min(sheetRect.width, sheetRect.height)
        let subtractive = request.condition.subtractiveDamage
        let sheetOutline = RaggedPath.sheetPath(in: sheetRect, cornerRadius: cornerRadius)
        let cutOutline = subtractive.isEmpty
            ? sheetOutline
            : RaggedPath.cutSheetPath(in: sheetRect, cornerRadius: cornerRadius, subtractive: subtractive)

        // Order matters here. The drop shadow needs an opaque sheet to cast
        // from, so it goes down *first* — if it ran after the under-sheet it
        // would repaint the holes in full-strength paper and flatten them.
        drawStack(ctx, sheetRect: sheetRect, cornerRadius: cornerRadius, request: request)
        drawSheetDropShadow(ctx, sheetPath: sheetOutline, request: request)
        drawUnderSheet(ctx, sheetPath: sheetOutline, sheetRect: sheetRect, request: request)
        guard !Task.isCancelled else { return nil }
        drawCutBase(
            ctx,
            sheetPath: sheetOutline,
            cutPath: cutOutline,
            request: request,
            hasCuts: !subtractive.isEmpty
        )

        // Everything from here on lives strictly inside the surviving paper.
        //
        // Two clips, not one. Cut-outs deliberately overshoot the sheet edge so
        // tears clear the boundary cleanly, but under the even-odd rule that
        // overshoot counts as *inside* — clipping to the sheet outline first
        // intersects it away, so nothing is ever drawn beyond the page.
        ctx.saveGState()
        ctx.addPath(sheetOutline)
        ctx.clip()
        ctx.addPath(cutOutline)
        ctx.clip(using: .evenOdd)

        drawPaperMaterial(ctx, rect: sheetRect, request: request)
        guard !Task.isCancelled else { return nil }
        // The document keeps its own proportions inside a sheet that now fills
        // the screen, so the paper shows as a margin around the text block the
        // way it does in a bound book.
        let textBlock = Self.contentRect(
            in: sheetRect,
            presentation: presentation,
            pageAspectRatio: request.pageAspectRatio,
            safeFraction: request.safeFraction,
            extraInset: request.environment.marginalia.marginWidth
        )
        if includesDocumentContent {
            drawContent(ctx, rect: textBlock, request: request)
        }

        // Marginalia goes above the document and below the ageing: someone
        // wrote on a printed page, and the page has been ageing ever since.
        //
        // Field marks first — underlines belong under the ageing but over the
        // words — then frame marks, which the renderer clips away from the text
        // block. That clip is the frame/field rule, enforced by geometry rather
        // than trusted to the generator that placed them.
        if let marginalia = request.marginalia {
            MarginaliaRenderer.drawField(
                ctx,
                marginalia: marginalia,
                style: request.environment.marginalia,
                sheetRect: sheetRect,
                palette: request.environment.palette
            )
            MarginaliaRenderer.drawMargin(
                ctx,
                marginalia: marginalia,
                style: request.environment.marginalia,
                sheetRect: sheetRect,
                contentRect: textBlock,
                palette: request.environment.palette
            )
        }

        drawSurfaceDamage(ctx, rect: sheetRect, request: request)
        guard !Task.isCancelled else { return nil }

        ctx.restoreGState()

        drawFibreEdges(
            ctx,
            sheetRect: sheetRect,
            sheetPath: sheetOutline,
            cutPath: cutOutline,
            subtractive: subtractive,
            request: request
        )
        guard !Task.isCancelled else { return nil }

        // Lighting covers the whole leaf, holes included. The lamp falls on the
        // sheet below too, so a hole in a shaded corner must read *darker* than
        // the paper around it — lighting only the surviving paper makes every
        // hole glow, which is the giveaway that it was painted on.
        ctx.saveGState()
        ctx.addPath(sheetOutline)
        ctx.clip()
        drawLighting(ctx, rect: sheetRect, request: request)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    // MARK: - Stack behind the sheet

    private func drawStack(
        _ ctx: CGContext,
        sheetRect: CGRect,
        cornerRadius: CGFloat,
        request: PageCompositionRequest
    ) {
        let depth = request.environment.presentation.visibleStackDepth
        guard depth > 0 else { return }

        let unit = min(sheetRect.width, sheetRect.height)
        let step = max(0.6, unit * 0.0032)
        let base = request.environment.palette.base

        // Sheets fan away from the binding.
        let direction: CGVector
        switch request.spine {
        case .left: direction = CGVector(dx: 1, dy: 0)
        case .right: direction = CGVector(dx: -1, dy: 0)
        case .top: direction = CGVector(dx: 0, dy: 1)
        case .bottom: direction = CGVector(dx: 0, dy: -1)
        }

        for layer in stride(from: depth, through: 1, by: -1) {
            let distance = CGFloat(layer) * step
            let rect = sheetRect
                .offsetBy(dx: direction.dx * distance, dy: direction.dy * distance + distance * 0.35)
                .insetBy(dx: distance * 0.25, dy: distance * 0.1)
            let shade = 1.0 - Double(layer) * 0.055
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: step * 0.8),
                blur: step * 2.2,
                color: RGBAColor(0, 0, 0, 0.28).cgColor
            )
            ctx.addPath(RaggedPath.sheetPath(in: rect, cornerRadius: cornerRadius))
            ctx.setFillColor(base.scaled(by: max(0.4, shade)).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    // MARK: - The sheet revealed by holes

    private func drawUnderSheet(
        _ ctx: CGContext,
        sheetPath: CGPath,
        sheetRect: CGRect,
        request: PageCompositionRequest
    ) {
        let material = request.environment.material
        let palette = request.environment.palette
        ctx.saveGState()
        ctx.addPath(sheetPath)
        ctx.clip()

        // Nudged and darkened so the layer below reads as a separate sheet
        // rather than as the same page showing through itself. The gap has to
        // be generous: lighting is applied over the whole leaf afterwards, so
        // a subtle difference here survives as an even subtler one on screen.
        let underRect = sheetRect.offsetBy(dx: sheetRect.width * 0.004, dy: sheetRect.height * 0.004)
        ctx.setFillColor(palette.base.scaled(by: 0.66).cgColor)
        ctx.fill(sheetRect)

        if let texture = PaperTextureFactory.shared.texture(
            material: material,
            substrate: request.environment.substrate,
            pixelSize: underRect.size,
            seed: request.textureSeed &+ 0x9E37
        ) {
            ctx.saveGState()
            ctx.setAlpha(0.7)
            ctx.setBlendMode(.multiply)
            drawImage(texture, in: underRect, into: ctx)
            ctx.restoreGState()
        }

        // A faint ghost of type on the sheet below, so holes do not look like
        // they open onto blank stock in the middle of a book.
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setAlpha(0.12)
        if let content = request.content {
            let ghostRect = underRect.insetBy(dx: -sheetRect.width * 0.02, dy: -sheetRect.height * 0.02)
            drawImage(content, in: ghostRect, into: ctx)
        }
        ctx.restoreGState()

        ctx.restoreGState()
    }

    // MARK: - Sheet base + the shadow it casts into its own tears

    /// The shadow the whole leaf casts onto the stack underneath it.
    private func drawSheetDropShadow(
        _ ctx: CGContext,
        sheetPath: CGPath,
        request: PageCompositionRequest
    ) {
        let unit = min(request.pixelSize.width, request.pixelSize.height)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: max(1, unit * 0.004)),
            blur: max(2, unit * 0.012),
            color: RGBAColor(0, 0, 0, 0.35).cgColor
        )
        ctx.addPath(sheetPath)
        ctx.setFillColor(request.environment.palette.base.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Lays down the surviving paper and, with it, the shadow that paper casts
    /// into its own tears.
    ///
    /// Filling the cut shape with the even-odd rule while clipped to the uncut
    /// outline means the shadow falls on the sheet below — which is the whole
    /// reason a hole reads as a hole instead of as a shape painted on a page.
    private func drawCutBase(
        _ ctx: CGContext,
        sheetPath: CGPath,
        cutPath: CGPath,
        request: PageCompositionRequest,
        hasCuts: Bool
    ) {
        guard hasCuts else { return }
        let unit = min(request.pixelSize.width, request.pixelSize.height)

        ctx.saveGState()
        ctx.addPath(sheetPath)
        ctx.clip()
        ctx.setShadow(
            offset: CGSize(width: max(0.5, unit * 0.0018), height: max(0.5, unit * 0.0026)),
            blur: max(2.0, unit * 0.011),
            color: RGBAColor(0, 0, 0, 0.72).cgColor
        )
        ctx.addPath(cutPath)
        ctx.setFillColor(request.environment.palette.base.cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // MARK: - Paper

    private func drawPaperMaterial(
        _ ctx: CGContext,
        rect: CGRect,
        request: PageCompositionRequest
    ) {
        let material = request.environment.material
        let palette = request.environment.palette
        ctx.setFillColor(palette.base.cgColor)
        ctx.fill(rect)

        guard let texture = PaperTextureFactory.shared.texture(
            material: material,
            substrate: request.environment.substrate,
            pixelSize: rect.size,
            seed: request.textureSeed
        ) else { return }
        ctx.saveGState()
        ctx.setBlendMode(.normal)
        drawImage(texture, in: rect, into: ctx)
        ctx.restoreGState()
    }

    // MARK: - Document content

    private func drawContent(
        _ ctx: CGContext,
        rect: CGRect,
        request: PageCompositionRequest
    ) {
        guard let content = request.content else { return }

        ctx.saveGState()
        if !request.reservedRegions.isEmpty {
            let surface = CGRect(origin: .zero, size: request.pixelSize)
            ctx.addRect(surface)
            for region in request.reservedRegions {
                ctx.addRect(CGRect(
                    x: region.minX * surface.width,
                    y: region.minY * surface.height,
                    width: region.width * surface.width,
                    height: region.height * surface.height
                ))
            }
            ctx.clip(using: .evenOdd)
        }
        // Asked of the environment rather than the material: a bronze plate or
        // a dark leather board needs inverted type just as dark stock does,
        // and only the substrate knows how dark it ended up.
        if request.environment.invertsInk {
            // Dark stock: invert so black type becomes light, then screen it on.
            if let inverted = invert(content) {
                ctx.setBlendMode(.screen)
                ctx.setAlpha(0.92)
                drawImage(inverted, in: rect, into: ctx)
            } else {
                ctx.setBlendMode(.normal)
                drawImage(content, in: rect, into: ctx)
            }
        } else {
            // Multiply means unprinted areas keep the paper, printed areas sit
            // *in* the paper rather than on a white rectangle over it.
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(inkOpacity(for: request.environment))
            drawImage(content, in: rect, into: ctx)
        }
        ctx.restoreGState()
    }

    /// Older stock reads better with slightly faded ink.
    private func inkOpacity(for environment: ReadingEnvironment) -> CGFloat {
        switch environment.material {
        case .white, .cream: return 1.0
        case .aged: return 0.94
        case .parchment: return 0.90
        case .dark: return 1.0
        }
    }

    private func invert(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    // MARK: - Stains, foxing, creases

    private func drawSurfaceDamage(
        _ ctx: CGContext,
        rect: CGRect,
        request: PageCompositionRequest
    ) {
        let palette = request.environment.palette
        for element in request.condition.surfaceDamage {
            switch element {
            case let .stain(stain):
                drawStain(ctx, stain: stain, rect: rect, palette: palette)
            case let .foxing(foxing):
                drawFoxing(ctx, foxing: foxing, rect: rect, palette: palette)
            case let .crease(crease):
                drawCrease(ctx, crease: crease, rect: rect, palette: palette)
            case let .char(burn):
                drawChar(ctx, burn: burn, rect: rect, palette: palette)
            case let .crack(crack):
                drawCrack(ctx, crack: crack, rect: rect, palette: palette)
            case let .patina(patina):
                drawPatina(ctx, patina: patina, rect: rect, palette: palette)
            case let .scratch(scratch):
                drawScratch(ctx, scratch: scratch, rect: rect, palette: palette)
            case .edgeTear, .lostCorner, .hole, .chip:
                continue
            }
        }
    }

    // MARK: - Burns, cracks, patina, scratches

    /// The scorch around a burn.
    ///
    /// Drawn whether or not the burn went through: a hole with no browning
    /// around it reads as a punch, and the ring is what says *fire*. When the
    /// burn did go through, the cut mask has already removed the core, so this
    /// only ever paints the surviving rim.
    private func drawChar(
        _ ctx: CGContext,
        burn: Char,
        rect: CGRect,
        palette: SubstratePalette
    ) {
        let unit = min(rect.width, rect.height)
        let center = CGPoint(
            x: rect.minX + CGFloat(burn.center.x) * rect.width,
            y: rect.minY + CGFloat(burn.center.y) * rect.height
        )
        let scorch = CGFloat(burn.scorchRadius) * unit
        guard scorch > 1 else { return }

        let core = CGFloat(burn.coreRadius) * unit
        // Three bands out from the core: black rim, brown char, yellow halo.
        // The proportions matter more than the colours; this is what a burn
        // through paper actually looks like from the front.
        let rim = RGBAColor(hex: 0x120C06)
        let charred = RGBAColor(hex: 0x4A2A10)
        let halo = palette.stain.blended(with: RGBAColor(hex: 0x9A6A28), amount: 0.7)

        let rimStop = max(0.02, min(0.9, Double(core / max(core, scorch))))
        let colors = [
            rim.withAlpha(0.92).cgColor,
            rim.withAlpha(0.78).cgColor,
            charred.withAlpha(0.55).cgColor,
            halo.withAlpha(0.34 * burn.bleed).cgColor,
            halo.withAlpha(0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: [0, CGFloat(rimStop), CGFloat(rimStop) + 0.18, 0.72, 1]
        ) else { return }

        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: scorch,
            options: []
        )
        ctx.restoreGState()
    }

    /// A fracture: a dark opening with a lit lip on one side, the same two-pass
    /// trick the crease uses, but tighter and without the soft falloff.
    private func drawCrack(
        _ ctx: CGContext,
        crack: Crack,
        rect: CGRect,
        palette: SubstratePalette
    ) {
        let unit = min(rect.width, rect.height)
        let path = RaggedPath.crackPath(crack, in: rect)
        let width = max(0.7, CGFloat(crack.width) * unit)

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // The opening.
        ctx.setBlendMode(.multiply)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(RGBAColor(0.10, 0.08, 0.06, crack.depth * 0.85).cgColor)
        ctx.addPath(path)
        ctx.strokePath()

        // The lit lip, offset by half a width toward the light.
        ctx.setBlendMode(.screen)
        ctx.setLineWidth(width * 0.55)
        ctx.setStrokeColor(palette.core.withAlpha(crack.depth * 0.42).cgColor)
        ctx.translateBy(x: -width * 0.5, y: -width * 0.5)
        ctx.addPath(path)
        ctx.strokePath()

        ctx.restoreGState()
    }

    /// Oxidation creeping across metal. Unlike foxing it spreads in fields, so
    /// it is one soft mass rather than a cluster of spots.
    private func drawPatina(
        _ ctx: CGContext,
        patina: Patina,
        rect: CGRect,
        palette: SubstratePalette
    ) {
        let unit = min(rect.width, rect.height)
        let center = CGPoint(
            x: rect.minX + CGFloat(patina.center.x) * rect.width,
            y: rect.minY + CGFloat(patina.center.y) * rect.height
        )
        let radius = CGFloat(patina.radius) * unit
        guard radius > 1 else { return }

        let tint = palette.stain.blended(with: RGBAColor(hex: 0x3E6B52), amount: patina.oxidation)
        let edge = CGFloat(0.45 + (1 - patina.softness) * 0.4)
        let colors = [
            tint.withAlpha(patina.opacity).cgColor,
            tint.withAlpha(patina.opacity * 0.82).cgColor,
            tint.withAlpha(patina.opacity * 0.35).cgColor,
            tint.withAlpha(0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: [0, edge, edge + 0.25, 1]
        ) else { return }

        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius,
            options: []
        )
        ctx.restoreGState()
    }

    /// A scored line. On tarnished metal it exposes bright stock underneath,
    /// which is what makes a scratch read as recent rather than as a drawn mark.
    private func drawScratch(
        _ ctx: CGContext,
        scratch: Scratch,
        rect: CGRect,
        palette: SubstratePalette
    ) {
        let unit = min(rect.width, rect.height)
        let path = RaggedPath.scratchPath(scratch, in: rect)
        let width = max(0.6, CGFloat(scratch.width) * unit)

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if scratch.exposesCore {
            ctx.setBlendMode(.screen)
            ctx.setLineWidth(width)
            ctx.setStrokeColor(palette.core.withAlpha(scratch.depth * 0.80).cgColor)
            ctx.addPath(path)
            ctx.strokePath()

            // A shadow on one side gives the groove depth.
            ctx.setBlendMode(.multiply)
            ctx.setLineWidth(width * 0.7)
            ctx.setStrokeColor(RGBAColor(0.15, 0.12, 0.09, scratch.depth * 0.5).cgColor)
            ctx.translateBy(x: width * 0.45, y: width * 0.45)
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.setBlendMode(.multiply)
            ctx.setLineWidth(width)
            ctx.setStrokeColor(RGBAColor(0.18, 0.14, 0.10, scratch.depth * 0.62).cgColor)
            ctx.addPath(path)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    private func drawStain(
        _ ctx: CGContext,
        stain: Stain,
        rect: CGRect,
        palette: SubstratePalette
    ) {
        let unit = min(rect.width, rect.height)
        let center = CGPoint(
            x: rect.minX + CGFloat(stain.center.x) * rect.width,
            y: rect.minY + CGFloat(stain.center.y) * rect.height
        )
        let radius = CGFloat(stain.radius) * unit
        guard radius > 1 else { return }

        let tint = palette.stain.blended(with: RGBAColor(hex: 0x7A5A2E), amount: stain.warmth * 0.5)
        // A defined tide line at the rim is what makes a damp mark believable.
        let rimLocation = CGFloat(0.55 + (1 - stain.softness) * 0.35)
        let colors = [
            tint.withAlpha(stain.opacity * 0.55).cgColor,
            tint.withAlpha(stain.opacity).cgColor,
            tint.withAlpha(stain.opacity * 1.12).cgColor,
            tint.withAlpha(0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: [0, rimLocation * 0.8, rimLocation, 1]
        ) else { return }

        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius,
            options: []
        )
        ctx.restoreGState()
    }

    private func drawFoxing(
        _ ctx: CGContext,
        foxing: Foxing,
        rect: CGRect,
        palette: SubstratePalette
    ) {
        let unit = min(rect.width, rect.height)
        let center = CGPoint(
            x: rect.minX + CGFloat(foxing.center.x) * rect.width,
            y: rect.minY + CGFloat(foxing.center.y) * rect.height
        )
        let clusterRadius = CGFloat(foxing.radius) * unit
        var rng = SplitMix64(seed: foxing.seed)
        let tint = palette.stain.blended(with: RGBAColor(hex: 0x8C5A22), amount: 0.6)

        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        for _ in 0..<foxing.count {
            let angle = CGFloat(rng.double(in: 0...(2 * .pi)))
            // sqrt keeps spots evenly spread rather than bunched at the centre.
            let distance = clusterRadius * CGFloat(sqrt(rng.unit()))
            let spot = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let spotRadius = CGFloat(rng.double(in: 0.006...0.022)) * unit
            let alpha = foxing.opacity * rng.double(in: 0.5...1.2)
            let colors = [
                tint.withAlpha(alpha).cgColor,
                tint.withAlpha(alpha * 0.4).cgColor,
                tint.withAlpha(0).cgColor
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors,
                locations: [0, 0.6, 1]
            ) else { continue }
            ctx.drawRadialGradient(
                gradient,
                startCenter: spot, startRadius: 0,
                endCenter: spot, endRadius: max(1, spotRadius),
                options: []
            )
        }
        ctx.restoreGState()
    }

    private func drawCrease(
        _ ctx: CGContext,
        crease: Crease,
        rect: CGRect,
        palette: SubstratePalette
    ) {
        let unit = min(rect.width, rect.height)
        let path = RaggedPath.creasePath(crease, in: rect)
        let width = max(0.8, CGFloat(crease.width) * unit)

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Valley: the fold itself.
        ctx.setBlendMode(.multiply)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(RGBAColor(0.35, 0.30, 0.24, crease.strength * 0.30).cgColor)
        ctx.addPath(path)
        ctx.strokePath()

        // Ridge: the lit side, one line-width away.
        ctx.setBlendMode(.screen)
        ctx.setLineWidth(width * 0.7)
        ctx.setStrokeColor(palette.core.withAlpha(crease.strength * 0.35).cgColor)
        ctx.translateBy(x: -width * 0.55, y: -width * 0.55)
        ctx.addPath(path)
        ctx.strokePath()

        ctx.restoreGState()
    }

    // MARK: - Fibre along the cuts

    private func drawFibreEdges(
        _ ctx: CGContext,
        sheetRect: CGRect,
        sheetPath: CGPath,
        cutPath: CGPath,
        subtractive: [DamageElement],
        request: PageCompositionRequest
    ) {
        guard !subtractive.isEmpty else { return }
        let palette = request.environment.palette
        let unit = min(sheetRect.width, sheetRect.height)
        let paths = RaggedPath.cutoutPaths(in: sheetRect, subtractive: subtractive)

        // Fibre only ever appears on paper that still exists — same two-clip
        // rule as the sheet body, so a stroke cannot escape past the page edge.
        ctx.saveGState()
        ctx.addPath(sheetPath)
        ctx.clip()
        ctx.addPath(cutPath)
        ctx.clip(using: .evenOdd)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // Exposed cross-section: a bright, slightly ragged lip.
        ctx.setBlendMode(.normal)
        ctx.setLineWidth(max(1.2, unit * 0.0045))
        ctx.setStrokeColor(palette.core.withAlpha(0.85).cgColor)
        for path in paths {
            ctx.addPath(path)
        }
        ctx.strokePath()

        // Loose fibre just inside the lip.
        ctx.setBlendMode(.multiply)
        ctx.setLineWidth(max(2.0, unit * 0.010))
        ctx.setStrokeColor(palette.fiber.withAlpha(0.30).cgColor)
        for path in paths {
            ctx.addPath(path)
        }
        ctx.strokePath()

        // Dirt worked into the torn edge over time.
        ctx.setLineWidth(max(3.0, unit * 0.020))
        ctx.setStrokeColor(palette.stain.withAlpha(0.14).cgColor)
        for path in paths {
            ctx.addPath(path)
        }
        ctx.strokePath()

        ctx.restoreGState()
    }

    // MARK: - Lighting

    private func drawLighting(
        _ ctx: CGContext,
        rect: CGRect,
        request: PageCompositionRequest
    ) {
        let lighting = request.environment.lighting

        if lighting.tint.alpha > 0 {
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(lighting.tint.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
        }

        if lighting.gradientStrength > 0 {
            let dark = 1.0 - lighting.gradientStrength
            let colors = [
                RGBAColor(1, 1, 1, 1).cgColor,
                RGBAColor(dark, dark * 0.99, dark * 0.96, 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.setBlendMode(.multiply)
                ctx.clip(to: rect)
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.minX, y: rect.minY),
                    end: CGPoint(x: rect.maxX, y: rect.maxY),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                ctx.restoreGState()
            }
        }

        if lighting.vignetteStrength > 0 {
            let dark = 1.0 - lighting.vignetteStrength
            let colors = [
                RGBAColor(1, 1, 1, 1).cgColor,
                RGBAColor(dark, dark * 0.985, dark * 0.96, 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.35, 1]) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                ctx.saveGState()
                ctx.setBlendMode(.multiply)
                ctx.clip(to: rect)
                ctx.drawRadialGradient(
                    gradient,
                    startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: hypot(rect.width, rect.height) / 2,
                    options: [.drawsAfterEndLocation]
                )
                ctx.restoreGState()
            }
        }

        drawSpineShading(ctx, rect: rect, request: request)
    }

    private func drawSpineShading(
        _ ctx: CGContext,
        rect: CGRect,
        request: PageCompositionRequest
    ) {
        guard request.environment.presentation.showsSpine else { return }
        let strength = (0.34 * request.spineShadowScale).clamped(to: 0...0.9)
        guard strength > 0.01 else { return }

        let dark = 1.0 - strength
        let colors = [
            RGBAColor(dark, dark * 0.97, dark * 0.93, 1).cgColor,
            RGBAColor(1, 1, 1, 1).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }

        let reach = min(rect.width, rect.height) * 0.22
        let start: CGPoint
        let end: CGPoint
        switch request.spine {
        case .left:
            start = CGPoint(x: rect.minX, y: rect.midY)
            end = CGPoint(x: rect.minX + reach, y: rect.midY)
        case .right:
            start = CGPoint(x: rect.maxX, y: rect.midY)
            end = CGPoint(x: rect.maxX - reach, y: rect.midY)
        case .top:
            start = CGPoint(x: rect.midX, y: rect.minY)
            end = CGPoint(x: rect.midX, y: rect.minY + reach)
        case .bottom:
            start = CGPoint(x: rect.midX, y: rect.maxY)
            end = CGPoint(x: rect.midX, y: rect.maxY - reach)
        }

        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.clip(to: rect)
        ctx.drawLinearGradient(
            gradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation]
        )
        ctx.restoreGState()
    }
}
