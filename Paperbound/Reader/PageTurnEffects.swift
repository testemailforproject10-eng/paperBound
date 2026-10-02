//
//  PageTurnEffects.swift
//  Paperbound
//
//  Draws a PageTurn. The unit effect holds a sheet in place against the
//  pager and shades the page beneath; the leaf effect curls or swings one
//  sheet. See PageTurnStyle.swift for the model.
//

import SwiftUI

/// Which part of a paging unit a sheet is.
enum PageTurnLeafRole: Equatable {
    /// The only sheet, or a spread divided top and bottom: it turns whole.
    case whole
    /// Left-hand sheet of a side-by-side spread.
    case left
    /// Right-hand sheet of a side-by-side spread.
    case right
}

struct PageTurnUnitEffect: ViewModifier {
    let turn: PageTurn?
    let pageWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if let turn, turn.beneathShade > 0 {
                    Color.black.opacity(turn.beneathShade).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                // A sheet sliding off another throws a soft edge shadow.
                if let turn, turn.style == .cover, turn.isLifting {
                    LinearGradient(
                        colors: [.black.opacity(0.22 * Double(1 - turn.lift)), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 22)
                    .offset(x: 22)
                    .allowsHitTesting(false)
                }
            }
            .offset(x: turn?.holdOffset(pageWidth: pageWidth) ?? 0)
    }
}

struct PageTurnLeafEffect: ViewModifier {
    let turn: PageTurn?
    let role: PageTurnLeafRole
    /// The sheet's rect in its unit.
    let rect: CGRect
    /// Right edge of the whole unit, where the right-hand sheet ends.
    let unitMaxX: CGFloat
    /// A still copy of the sheet for the curl to bend, or nil when none is
    /// ready (the sheet then turns without curling). Only asked for while
    /// curling.
    var curlFace: () -> AnyView? = { nil }

    // Every modifier is always applied and only its parameters change, all of
    // them no-ops at rest. Switching view structure as a turn starts or ends
    // would rebuild the page view underneath and throw away its loaded page.
    //
    // The curl shader never wraps the live sheet: a layer effect flattens its
    // content to an image, and the live sheet can hold a Metal view (the
    // Enchanted Ink reveal) that SwiftUI cannot flatten; it draws a "not
    // allowed" sign in its place, even with the effect disabled. So the curl
    // bends `curlFace` in an overlay that exists only mid-curl, and the live
    // sheet is hidden underneath it meanwhile.
    func body(content: Content) -> some View {
        let curl = curlLayer
        let face = curl == nil ? nil : curlFace()
        let swing = self.swing
        let uncovered = uncoveredWidth
        content
            .opacity(face == nil ? 1 : 0)
            .overlay(alignment: .topLeading) {
                if let curl, let face {
                    face
                        .frame(width: rect.width, height: rect.height)
                        .padding(.leading, curl.leadingPad)
                        .layerEffect(curl.shader, maxSampleOffset: CGSize(width: curl.reach, height: 0))
                        .padding(.leading, -curl.leadingPad)
                }
            }
            .clipShape(LeadingSlice(width: uncovered ?? .greatestFiniteMagnitude))
            .overlay(alignment: .leading) {
                // The landing leaf's edge throws a thin shadow onto the page
                // it is about to cover.
                let shadow = min(14, max(uncovered ?? 0, 0))
                LinearGradient(colors: [.clear, .black.opacity(0.16)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: shadow)
                    .offset(x: (uncovered ?? 0) - shadow)
                    .opacity(uncovered.map { $0 > 0 && $0 < rect.width } == true ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                Color.black.opacity(PageFlipGeometry.shade(forAngle: swing.degrees)).allowsHitTesting(false)
            }
            .rotation3DEffect(.degrees(swing.degrees), axis: (x: 0, y: 1, z: 0),
                              anchor: swing.anchor, perspective: 0.45)
            .opacity(swing.visible ? 1 : 0)
    }

    // MARK: Curl

    private struct CurlLayer {
        let shader: Shader
        /// How far the layer is widened to the left so the rolled-over part
        /// can be drawn across the facing page.
        let leadingPad: CGFloat
        let reach: CGFloat
    }

    private var curlLayer: CurlLayer? {
        guard let turn, turn.style == .curl, turn.isLifting else { return nil }
        switch role {
        case .whole:
            let geometry = PageCurlGeometry(lift: turn.lift, pageMinX: 0, pageMaxX: rect.width)
            return CurlLayer(
                shader: shader(geometry, pageMinX: 0, seamX: -.greatestFiniteMagnitude, backAlpha: 1),
                leadingPad: 0, reach: rect.width
            )
        case .right:
            let geometry = PageCurlGeometry(lift: turn.lift, pageMinX: rect.minX, pageMaxX: rect.maxX)
            return CurlLayer(
                shader: shader(geometry, pageMinX: rect.minX, seamX: rect.minX,
                               backAlpha: Self.landingBackAlpha(lift: turn.lift)),
                leadingPad: rect.minX, reach: rect.maxX
            )
        case .left:
            return nil
        }
    }

    /// For the left page of a curling spread: how much of it is still
    /// uncovered by the leaf landing on it. `nil` when nothing is landing.
    private var uncoveredWidth: CGFloat? {
        guard let turn, turn.style == .curl, turn.isLifting, role == .left else { return nil }
        let geometry = PageCurlGeometry(lift: turn.lift, pageMinX: rect.maxX, pageMaxX: unitMaxX)
        return min(max(geometry.backEdge(pageMaxX: unitMaxX), 0), rect.width)
    }

    private func shader(
        _ geometry: PageCurlGeometry, pageMinX: CGFloat, seamX: CGFloat, backAlpha: Double
    ) -> Shader {
        ShaderLibrary.pageCurl(
            .float4(pageMinX, 0, pageMinX + rect.width, rect.height),
            .float2(geometry.foldX, geometry.radius),
            .float(seamX),
            .float(backAlpha)
        )
    }

    /// The back of a turning leaf is the next left page. While it is in the
    /// air it reads as plain paper; as it lands, the real page fades through.
    static func landingBackAlpha(lift: CGFloat) -> Double {
        let t = min(max((Double(lift) - 0.55) / 0.4, 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    // MARK: Flip

    private var swing: (degrees: Double, anchor: UnitPoint, visible: Bool) {
        guard let turn, turn.style == .flip else { return (0, .center, true) }
        switch (role, turn.isLifting) {
        case (.right, true):
            return (PageFlipGeometry.liftingAngle(lift: turn.lift), .leading, turn.lift < 0.5)
        case (.left, false):
            return (PageFlipGeometry.landingAngle(covered: turn.covered), .trailing, turn.covered < 0.5)
        case (.whole, true):
            return (PageFlipGeometry.singleAngle(lift: turn.lift), .leading, true)
        default:
            return (0, .center, true)
        }
    }
}

/// The leading `width` points of a view. Wider than the view clips nothing.
private struct LeadingSlice: Shape {
    var width: CGFloat

    func path(in bounds: CGRect) -> Path {
        Path(CGRect(x: bounds.minX, y: bounds.minY,
                    width: min(width, bounds.width), height: bounds.height))
    }
}
