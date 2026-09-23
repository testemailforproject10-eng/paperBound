//
//  DeviceLayoutCoordinator.swift
//  Paperbound
//
//  Decides how many reading surfaces are on screen and how deep the spine
//  shadow falls. It takes *window geometry plus display identity* as its input,
//  never a device model.
//
//  On hinge hardware
//  -----------------
//  There are three sources of posture here, and the app uses the best one the
//  platform will give it. Each says how it knows, so the UI never claims more
//  than it has been told.
//
//  1. The hinge — `HingePostureProvider`, iOS 27.1 and later.
//     27.1 added `UIHingeInteraction`, reporting status (closed, partially
//     open, fully open) and an angle. It is the only source that can see the
//     partly-open posture, and the only one that works before the device has
//     ever been folded. See HingeSnapshot.swift.
//
//     The iOS 27.0 SDK this app was first written against had none of it —
//     its only `Hinge` symbols are private IOKit ones — which is why the two
//     fallbacks below exist and still carry the work on every earlier build.
//
//  2. Display identity — `DisplayPostureProvider`, any release.
//     The iPhone Duo device profile declares two integrated screens:
//
//         cover  1398 × 2034 @3x  →  466 × 678 pt
//         inner  2007 × 2853 @3x  →  669 × 951 pt
//
//     Folding moves the app's scene between them and `UIWindowScene.screen`
//     reports which one it is on. That is a fact rather than an inference, but
//     only once the scene has been seen on both.
//
//  3. Window geometry — `GeometryPostureProvider`, the floor.
//     A surface that is wide and short behaves like an open book. This is a
//     guess, and `reportsRealPosture` is false whenever it is what answered.
//

import CoreGraphics
import Foundation
import SwiftUI
import UIKit

// MARK: - Posture

enum DevicePosture: String, Sendable {
    /// One continuous reading surface — a normal phone or tablet.
    case flat
    /// A folding device that is closed: we are on its smaller cover display.
    case folded
    /// A folding device that is open, or a surface wide enough to read as one.
    case bookLike
    /// Not enough information; treated as flat.
    case unknown

    var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .folded: return "Folded"
        case .bookLike: return "Book posture"
        case .unknown: return "Unknown"
        }
    }
}

/// The seam a hinge API would slot into, and the seam display observation
/// already fills.
protocol PostureProviding {
    /// Regions the layout must keep content out of.
    func reservedRegions(in size: CGSize) -> [CGRect]
    func posture(in size: CGSize) -> DevicePosture
    /// True only when posture comes from something the platform actually
    /// reported, rather than from the shape of the window.
    var reportsRealPosture: Bool { get }
    /// Human-readable note for the posture row in the environment editor.
    var postureEvidence: String { get }
    /// How far open the hinge is: 0 shut, 1 pressed flat. `nil` unless the
    /// device actually reports an angle, which is every source but the hinge.
    var hingeOpenness: Double? { get }
}

extension PostureProviding {
    /// Nothing but a real hinge has an angle to report.
    var hingeOpenness: Double? { nil }
}

/// Works everywhere: infers posture from the shape of the window alone.
struct GeometryPostureProvider: PostureProviding {

    var reportsRealPosture: Bool { false }
    var postureEvidence: String { "from window size" }

    func reservedRegions(in size: CGSize) -> [CGRect] { [] }

    func posture(in size: CGSize) -> DevicePosture {
        guard size.width > 0, size.height > 0 else { return .unknown }
        // A surface that is both wide and short behaves like an open book.
        let ratio = size.width / size.height
        if ratio >= 1.30 && size.width >= 700 { return .bookLike }
        return .flat
    }
}

/// Uses the display the scene is actually on. On a device that reports more
/// than one screen — the Duo — this is a fact, not an inference.
struct DisplayPostureProvider: PostureProviding {

    let snapshot: DisplaySnapshot
    /// Used for the single-display fallback.
    private let fallback = GeometryPostureProvider()

    var reportsRealPosture: Bool { snapshot.hasMultipleDisplays }

    var postureEvidence: String {
        snapshot.hasMultipleDisplays
            ? "from \(snapshot.displayDescription)"
            : "from window size"
    }

    func reservedRegions(in size: CGSize) -> [CGRect] {
        // The honest reserved regions are the safe-area insets the system hands
        // us. On the Duo's cover screen that includes the strip the sensor bar
        // sits in; on a normal phone it is the status bar and home indicator.
        guard size.width > 0, size.height > 0 else { return [] }
        let insets = snapshot.safeAreaInsets
        var regions: [CGRect] = []
        if insets.top > 0 {
            regions.append(CGRect(x: 0, y: 0, width: size.width, height: insets.top))
        }
        if insets.bottom > 0 {
            regions.append(CGRect(x: 0, y: size.height - insets.bottom, width: size.width, height: insets.bottom))
        }
        if insets.left > 0 {
            regions.append(CGRect(x: 0, y: 0, width: insets.left, height: size.height))
        }
        if insets.right > 0 {
            regions.append(CGRect(x: size.width - insets.right, y: 0, width: insets.right, height: size.height))
        }
        return regions
    }

    func posture(in size: CGSize) -> DevicePosture {
        guard snapshot.hasMultipleDisplays else {
            return fallback.posture(in: size)
        }
        // We have seen this scene on more than one display, so the device
        // folds, and the smaller display is the cover.
        return snapshot.isOnLargestSeenScreen ? .bookLike : .folded
    }
}

/// Uses the hinge, when the device has one and the OS will talk about it.
///
/// This is the only provider that can report `.bookLike` for a device that is
/// *partly* open, and the only one that knows anything before the device has
/// been folded at least once. When the hinge says nothing — pre-27.1, no hinge,
/// or `.unknown` — every question falls through to display observation, which
/// falls through to window geometry in its turn.
struct HingePostureProvider: PostureProviding {

    let hinge: HingeSnapshot
    /// Answers everything the hinge cannot.
    let fallback: DisplayPostureProvider

    init(hinge: HingeSnapshot, display: DisplaySnapshot) {
        self.hinge = hinge
        self.fallback = DisplayPostureProvider(snapshot: display)
    }

    var reportsRealPosture: Bool {
        hinge.isReported || fallback.reportsRealPosture
    }

    var postureEvidence: String {
        hinge.isReported ? "from \(hinge.description)" : fallback.postureEvidence
    }

    /// Reserved regions are a window-geometry fact, not a hinge one: the hinge
    /// reports an angle, never which strip of the display is spoken for.
    func reservedRegions(in size: CGSize) -> [CGRect] {
        fallback.reservedRegions(in: size)
    }

    func posture(in size: CGSize) -> DevicePosture {
        switch hinge.status {
        case .closed:
            return .folded
        case .partiallyOpen, .fullyOpen:
            // Partly open is the book posture the brief asks for: the device
            // is standing like a book, and both are read as one.
            return .bookLike
        case .unavailable, .unknown:
            return fallback.posture(in: size)
        }
    }

    var hingeOpenness: Double? {
        hinge.isReported ? hinge.openness : nil
    }
}

// MARK: - Layout

enum ReadingSurfaceMode: String, Sendable {
    case single
    case spread
}

struct ReadingSurfaceLayout: Equatable, Sendable {
    var mode: ReadingSurfaceMode
    /// Width of the gutter as a fraction of the whole surface.
    var spineFraction: Double
    /// 0…1 multiplier handed to the compositor for spine shading.
    var spineShadowScale: Double
    var posture: DevicePosture
    var reservedRegions: [CGRect]
    var reportsRealPosture: Bool
    /// Why the posture reads the way it does, for the reader-facing row.
    var postureEvidence: String

    static let singlePage = ReadingSurfaceLayout(
        mode: .single,
        spineFraction: 0,
        spineShadowScale: 0.55,
        posture: .flat,
        reservedRegions: [],
        reportsRealPosture: false,
        postureEvidence: "from window size"
    )
}

enum SpreadPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case alwaysSingle
    case alwaysSpread

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .alwaysSingle: return "Single page"
        case .alwaysSpread: return "Two pages"
        }
    }
}

enum DeviceLayoutCoordinator {

    /// Floor, in points, under which a page in a spread is not worth drawing:
    /// below this, two pages are just two unreadable columns. This is only the
    /// first of the two bars a spread has to clear — see `spreadIsUsable`.
    static let minimumPageWidth: CGFloat = 320

    static func layout(
        surfaceSize: CGSize,
        pageAspectRatio: Double,
        presentation: BookPresentation,
        preference: SpreadPreference,
        provider: PostureProviding = GeometryPostureProvider()
    ) -> ReadingSurfaceLayout {

        let posture = provider.posture(in: surfaceSize)
        let reserved = provider.reservedRegions(in: surfaceSize)
        let spineFraction = presentation.spineFraction

        let spreadFits = spreadIsUsable(
            surfaceSize: surfaceSize,
            pageAspectRatio: pageAspectRatio,
            spineFraction: spineFraction
        )

        let mode: ReadingSurfaceMode
        switch preference {
        case .alwaysSingle:
            mode = .single
        case .alwaysSpread:
            // Even "always" defers to whether two pages would be readable, and
            // a closed device never spreads across its cover screen.
            mode = (spreadFits && posture != .folded) ? .spread : .single
        case .automatic:
            if posture == .folded {
                mode = .single
            } else if spreadFits && (posture == .bookLike || surfaceSize.width >= 900) {
                mode = .spread
            } else {
                mode = .single
            }
        }

        // A deeper spine shadow reads as a book that is genuinely open; a
        // closed device reading on its cover screen should look like one sheet.
        let baseShadow: Double
        switch (mode, posture) {
        case (.spread, .bookLike): baseShadow = 1.0
        case (.spread, _): baseShadow = 0.85
        case (.single, .bookLike): baseShadow = 0.7
        case (.single, .folded): baseShadow = 0.4
        case (.single, _): baseShadow = 0.55
        }
        // ...and a real hinge angle, where one is reported, shapes it further.
        let shadowScale = shadowFlattenedByHinge(baseShadow, openness: provider.hingeOpenness)

        return ReadingSurfaceLayout(
            mode: mode,
            spineFraction: mode == .spread ? spineFraction : 0,
            spineShadowScale: shadowScale,
            posture: posture,
            reservedRegions: reserved,
            reportsRealPosture: provider.reportsRealPosture,
            postureEvidence: provider.postureEvidence
        )
    }

    /// How much of the gutter shadow survives as the device is pressed flat.
    ///
    /// Held half-open, a book has its deepest crease: the leaves fall away from
    /// the spine and the gutter sits in shadow. Pressed flat to 180°, the same
    /// spread has almost none. Posture already handles the closed end of the
    /// range, so this only shapes the open half.
    ///
    /// This is the one place the hinge *angle* is used. The header for
    /// `UIHinge.angle` says its rate and precision are system policy, so it is
    /// trusted for shading and for nothing that decides a layout.
    static let flatGutterRelief: Double = 0.25

    /// Returns `base` untouched when no angle was reported, which is every
    /// device without a hinge and every build before iOS 27.1.
    static func shadowFlattenedByHinge(_ base: Double, openness: Double?) -> Double {
        guard let openness else { return base }
        // Half-open is the deepest crease; 1.0 is flat.
        let flatness = min(max((openness - 0.5) / 0.5, 0), 1)
        return base * (1 - flatGutterRelief * flatness)
    }

    /// Whether two pages are worth drawing on this surface.
    ///
    /// Two conditions, both measured on the page *as it will actually be
    /// drawn* rather than on the box it sits in.
    ///
    /// 1. Each page clears `minimumPageWidth`. A short landscape phone has
    ///    plenty of width per column, but the fitted page ends up narrow —
    ///    exactly the case a spread should refuse.
    /// 2. The spread does not make the page *smaller than reading one page at
    ///    a time would*. Halving the width costs nothing once each half is
    ///    wide enough that the page is capped by the surface's height instead,
    ///    which is the same as saying the surface is proportioned at least as
    ///    wide as the open book it would draw.
    ///
    /// The second condition is what the iPhone Duo's two displays separate.
    /// Landscape (951 × 590) draws a 393pt page either way, so the spread is
    /// free. Portrait (669 × 860) draws 328pt pages against 573pt on one page:
    /// the reader would pay 43% of the page for a second column and get two
    /// fifths of the screen back as empty board. Without this, unfolding the
    /// device into portrait handed back a *smaller* page than the cover screen.
    private static func spreadIsUsable(
        surfaceSize: CGSize,
        pageAspectRatio: Double,
        spineFraction: Double
    ) -> Bool {
        guard surfaceSize.width > 0, surfaceSize.height > 0, pageAspectRatio > 0 else { return false }

        let singleWidth = fittedRect(
            in: CGRect(origin: .zero, size: surfaceSize),
            aspectRatio: pageAspectRatio
        ).width

        let usableWidth = surfaceSize.width * CGFloat(1 - spineFraction)
        let half = CGRect(x: 0, y: 0, width: usableWidth / 2, height: surfaceSize.height)
        let spreadWidth = fittedRect(in: half, aspectRatio: pageAspectRatio).width

        guard spreadWidth >= minimumPageWidth else { return false }
        // Half a point of slack absorbs the rounding, and nothing more.
        return spreadWidth >= singleWidth - 0.5
    }

    /// The rectangle each visible **sheet** gets, in the surface's coordinate
    /// space. Sheets fill the surface edge to edge: a reader wants the paper to
    /// reach the bezel, and letterboxing a sheet inside a dark board wastes the
    /// display without making the book any more convincing. What keeps the page
    /// honest is `readableRects` below, which keeps the *text block* at the
    /// document's own proportions inside the sheet — exactly the margin a real
    /// book has.
    ///
    /// Because the sheet fills the screen, the display's own rounded corners
    /// clip it, so the page corners match the device without the app having to
    /// know the corner radius.
    static func surfaceRects(
        in size: CGSize,
        layout: ReadingSurfaceLayout,
        pageAspectRatio: Double
    ) -> [CGRect] {
        guard size.width > 0, size.height > 0 else { return [] }

        switch layout.mode {
        case .single:
            return [CGRect(origin: .zero, size: size)]
        case .spread:
            let gutter = size.width * CGFloat(layout.spineFraction)
            let half = (size.width - gutter) / 2
            return [
                CGRect(x: 0, y: 0, width: half, height: size.height),
                CGRect(x: half + gutter, y: 0, width: half, height: size.height)
            ]
        }
    }

    /// The readable area inside each sheet: the document at its own proportions.
    ///
    /// This, not the sheet, is what "how big is the page" means to a reader, and
    /// it is what `spreadIsUsable` measures when it decides whether a second
    /// page is worth drawing.
    static func readableRects(
        in size: CGSize,
        layout: ReadingSurfaceLayout,
        pageAspectRatio: Double
    ) -> [CGRect] {
        surfaceRects(in: size, layout: layout, pageAspectRatio: pageAspectRatio)
            .map { fittedRect(in: $0, aspectRatio: pageAspectRatio) }
    }

    /// Which edge of a sheet is held by the binding, for a sheet drawn at
    /// `position` in a spread of `count` pages.
    ///
    /// In an open book both leaves are bound toward the middle: the left one on
    /// its right edge, the right one on its left. Deriving this from the page
    /// index alone gets it inside out for one of the two, which puts the
    /// binding — and the damage protection that follows it — on the outer edges
    /// and tears the gutter where a real book is least worn.
    static func spineEdge(position: Int, of count: Int, pageIndex: Int) -> PageEdge {
        guard count > 1 else {
            // Single page: alternate, so turning a leaf swaps which edge is
            // bound, the way recto and verso do.
            return pageIndex.isMultiple(of: 2) ? .left : .right
        }
        return position == 0 ? .right : .left
    }

    /// Largest rect of the given aspect ratio (height / width) centred in `bounds`.
    static func fittedRect(in bounds: CGRect, aspectRatio: Double) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, aspectRatio > 0 else { return bounds }
        var width = bounds.width
        var height = width * CGFloat(aspectRatio)
        if height > bounds.height {
            height = bounds.height
            width = height / CGFloat(aspectRatio)
        }
        return CGRect(
            x: bounds.minX + (bounds.width - width) / 2,
            y: bounds.minY + (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }
}

// MARK: - Known iPhone Duo geometry

/// The Duo's two displays, as the device profile reports them. Used by tests
/// and by the snapshot renderer so the unfolded layout can be exercised on a
/// machine where the simulator offers no way to fold.
///
/// These are *reference values for verification*, never a device check: no code
/// path branches on them at runtime.
enum DuoDisplayReference {
    /// 1398 × 2034 @3x.
    static let coverScreen = CGSize(width: 466, height: 678)
    /// 2007 × 2853 @3x.
    static let innerScreen = CGSize(width: 669, height: 951)

    static var innerScreenLandscape: CGSize {
        CGSize(width: innerScreen.height, height: innerScreen.width)
    }
}
