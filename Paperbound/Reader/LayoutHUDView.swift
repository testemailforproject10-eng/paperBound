//
//  LayoutHUDView.swift
//  Paperbound
//
//  A debug read-out of everything the layout coordinator saw.
//
//  It exists because folding hardware cannot be inspected any other way here:
//  neither Xcode 27.0 nor 27.1 gives the simulator a fold control, so the only
//  way to know what the app is really being handed on the Duo's cover screen is
//  to have the app say so and take a screenshot. The `hinge` row reports what
//  UIHingeInteraction said, including when it said nothing.
//
//  Debug builds only, and only with `-paperbound-demo-hud`.
//

#if DEBUG

import SwiftUI

struct LayoutHUDView: View {

    let model: ReaderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("surface", "\(fmt(model.lastSurfaceSize))")
            row("window", "\(fmt(model.display.snapshot.windowSize))")
            row("screen", "\(fmt(model.display.snapshot.screenSize)) @\(fmt(model.display.snapshot.scale))x")
            row("insets", insetText)
            row("displays", "\(model.display.snapshot.distinctScreensSeen) seen · \(model.display.snapshot.isOnLargestSeenScreen ? "largest" : "smaller")")
            row("hinge", hingeText)
            Divider().background(.white.opacity(0.3))
            row("posture", "\(model.layout.posture.displayName) (\(model.layout.postureEvidence))")
            row("reported", model.layout.reportsRealPosture ? "yes — platform" : "no — inferred")
            row("mode", model.layout.mode.rawValue)
            row("spine", "gutter \(fmt(model.layout.spineFraction)) · shadow \(fmt(model.layout.spineShadowScale))")
            row("reserved", "\(model.layout.reservedRegions.count) region(s)")
            row("pages", pageRectText)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        // Clear of the title bar so both can be read in one screenshot.
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 58, alignment: .leading)
            Text(value)
        }
    }

    /// The hinge says three different things and they must not be confused:
    /// the API is missing, the API is present but this device has no hinge, or
    /// the hinge reported.
    private var hingeText: String {
        let snapshot = model.hinge.snapshot
        switch snapshot.status {
        case .unavailable:
            return HingeObserver.isSupported ? "none on this device" : "no API before 27.1"
        case .unknown:
            return "present · position unknown"
        case .closed, .partiallyOpen, .fullyOpen:
            return "\(snapshot.status.rawValue) · \(fmt(snapshot.angle * 180 / .pi))°"
        }
    }

    private var insetText: String {
        let insets = model.display.snapshot.safeAreaInsets
        return "t\(fmt(insets.top)) l\(fmt(insets.left)) b\(fmt(insets.bottom)) r\(fmt(insets.right))"
    }

    private var pageRectText: String {
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: model.lastSurfaceSize,
            layout: model.layout,
            pageAspectRatio: model.pageAspectRatio
        )
        guard !rects.isEmpty else { return "—" }
        return rects
            .map { "\(fmt($0.width))×\(fmt($0.height))" }
            .joined(separator: " | ")
    }

    private func fmt(_ value: CGSize) -> String {
        "\(fmt(value.width))×\(fmt(value.height))"
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%g", (value * 10).rounded() / 10)
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%g", (value * 100).rounded() / 100)
    }
}

#endif
