//
//  PaperTexture.swift
//  Paperbound
//
//  Procedural paper stock.
//
//  Deliberately *not* a packaged photograph of a vintage page. Two reasons:
//  a single full-page scan repeats visibly across a book, and shipping
//  third-party paper scans without a licence is not an option. Instead the
//  material is built from three noise octaves — broad mottling, directional
//  fibre, fine grain — which tile differently per seed and cost nothing to
//  redistribute.
//
//  If licensed scans are acquired later, `PaperTextureFactory` is the single
//  place that has to change.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

final class PaperTextureFactory {

    static let shared = PaperTextureFactory()

    private let context: CIContext
    private let cache = NSCache<NSString, CGImage>()
    private let lock = NSLock()

    private init() {
        self.context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB()
        ])
        cache.countLimit = 24
    }

    func purge() {
        cache.removeAllObjects()
    }

    /// A sheet of paper at (approximately) `pixelSize`.
    ///
    /// Sizes are bucketed to 64px so that scrolling through pages at slightly
    /// different layouts reuses one texture; stretching noise by a few percent
    /// is invisible and the cache hit rate matters far more.
    func texture(
        material: PaperMaterial,
        substrate: Substrate = .paper,
        pixelSize: CGSize,
        seed: UInt64
    ) -> CGImage? {
        let bucketed = CGSize(
            width: max(64, (pixelSize.width / 64).rounded(.up) * 64),
            height: max(64, (pixelSize.height / 64).rounded(.up) * 64)
        )
        let key = "\(substrate.rawValue)-\(material.rawValue)-\(Int(bucketed.width))x\(Int(bucketed.height))-\(seed % 997)" as NSString

        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let built = build(material: material, substrate: substrate, pixelSize: bucketed, seed: seed)
        else { return nil }

        lock.lock()
        cache.setObject(built, forKey: key)
        lock.unlock()
        return built
    }

    // MARK: - Construction

    private func build(
        material: PaperMaterial,
        substrate: Substrate,
        pixelSize: CGSize,
        seed: UInt64
    ) -> CGImage? {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        guard
            let mottle = noiseLayer(rect: rect, seed: seed, kind: .mottle),
            let fibre = noiseLayer(rect: rect, seed: seed &+ 0x5151, kind: .fibre),
            let grain = noiseLayer(rect: rect, seed: seed &+ 0xA2A2, kind: .grain)
        else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Grain and fibre are the material's, scaled by what the sheet is
        // made of: stone is coarse where vellum is nearly smooth, and cloth
        // has more visible fibre than any paper.
        let palette = substrate.palette(for: material)
        let grainStrength = material.grainStrength * substrate.grainScale
        let fiberStrength = material.fiberStrength * substrate.fiberScale

        ctx.setFillColor(palette.base.cgColor)
        ctx.fill(rect)

        // Broad tonal variation: the thing that most separates real stock from
        // a flat fill. Multiply keeps it from ever brightening past the base.
        ctx.saveGState()
        ctx.setAlpha(CGFloat(0.35 + grainStrength))
        ctx.setBlendMode(.multiply)
        ctx.draw(mottle, in: rect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setAlpha(CGFloat(fiberStrength))
        ctx.setBlendMode(.softLight)
        ctx.draw(fibre, in: rect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setAlpha(CGFloat(grainStrength))
        ctx.setBlendMode(.overlay)
        ctx.draw(grain, in: rect)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private enum NoiseKind {
        case mottle
        case fibre
        case grain
    }

    private func noiseLayer(rect: CGRect, seed: UInt64, kind: NoiseKind) -> CGImage? {
        // CIRandomGenerator is a deterministic function of position, so shifting
        // the sampling window by a seed-derived offset gives reproducible
        // variation without any hidden global state.
        let generator = CIFilter.randomGenerator()
        guard var image = generator.outputImage else { return nil }

        let offsetX = CGFloat(seed % 8192)
        let offsetY = CGFloat((seed >> 13) % 8192)
        image = image.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        // Bound the image *before* any blur. The generator's extent is infinite,
        // and handing an infinite extent to a blur makes Core Image try to work
        // over an unbounded region. Crop to the area the blur will actually read,
        // then clamp so the blur has edge pixels to sample.
        let blurRadius = radius(for: kind, in: rect)
        let margin = ceil(blurRadius * 3) + 2
        image = image
            .cropped(to: rect.insetBy(dx: -margin, dy: -margin))
            .clampedToExtent()

        // Desaturate; the three RGB channels of the generator are independent
        // noise and colour speckle is not what paper looks like.
        image = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: contrast(for: kind),
            kCIInputBrightnessKey: brightness(for: kind)
        ])

        switch kind {
        case .mottle:
            image = image.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: blurRadius
            ])
            // Blur pushes everything to mid-grey; pull the range back out.
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 2.6,
                kCIInputBrightnessKey: 0.30
            ])
        case .fibre:
            image = image.applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: blurRadius,
                kCIInputAngleKey: 0.18
            ])
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 3.4,
                kCIInputBrightnessKey: 0.05
            ])
        case .grain:
            image = image.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: blurRadius
            ])
        }

        let cropped = image.cropped(to: rect)
        return context.createCGImage(cropped, from: rect)
    }

    private func radius(for kind: NoiseKind, in rect: CGRect) -> CGFloat {
        let shortSide = min(rect.width, rect.height)
        switch kind {
        // Capped: beyond about 30px the mottling is indistinguishable, and the
        // blur cost grows with the radius for no visible gain.
        case .mottle: return min(30, max(8, shortSide * 0.06))
        case .fibre: return min(20, max(6, shortSide * 0.02))
        case .grain: return 0.55
        }
    }

    private func contrast(for kind: NoiseKind) -> Double {
        switch kind {
        case .mottle: return 1.0
        case .fibre: return 1.6
        case .grain: return 1.1
        }
    }

    private func brightness(for kind: NoiseKind) -> Double {
        switch kind {
        case .mottle: return 0.0
        case .fibre: return -0.12
        case .grain: return 0.0
        }
    }
}
