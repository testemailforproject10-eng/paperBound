//
//  PhysicalPageView.swift
//  Paperbound
//
//  One composited sheet. Asks the provider for a bitmap at the exact pixel size
//  it is about to occupy, shows the cached one immediately if there is one, and
//  never blocks the main thread while a new one is built.
//

import CoreGraphics
import SwiftUI

struct PhysicalPageView: View {

    let location: ReadingLocation
    let environment: ReadingEnvironment
    let provider: PageImageProvider
    let spineShadowScale: Double
    let displaySize: CGSize
    /// Which edge the binding holds. In a spread both leaves are bound toward
    /// the gutter, so this cannot be derived from the page index alone.
    let spine: PageEdge
    /// The visible part of this sheet, in unit coordinates. Paper is drawn to
    /// the sheet's edge; type is kept inside this.
    var safeFraction: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    @Environment(\.displayScale) private var displayScale

    @State private var image: CGImage?
    @State private var failure: String?

    private var renderScale: CGFloat {
        PageRenderScale.scale(for: displaySize, displayScale: displayScale)
    }

    private var pixelSize: CGSize {
        PageRenderScale.pixelSize(for: displaySize, displayScale: displayScale)
    }

    /// Any change to this string means the sheet must be rebuilt.
    private var renderToken: String {
        let pageID = location.pdfPageIndex.map(String.init) ?? "start"
        return "\(pageID)|\(environment.renderIdentity)|\(Int(pixelSize.width))x\(Int(pixelSize.height))|\(Int(spineShadowScale * 10))|\(spine.rawValue)|\(safeToken)"
    }

    /// Bucketed to whole percent so a point of layout jitter cannot thrash the
    /// cache, the same way the pixel size is bucketed.
    private var safeToken: String {
        func pct(_ value: CGFloat) -> Int { Int((value * 100).rounded()) }
        return "\(pct(safeFraction.minX)),\(pct(safeFraction.minY)),\(pct(safeFraction.width)),\(pct(safeFraction.height))"
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: renderScale)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .task(id: renderToken) {
            await loadImage()
        }
    }

    private var placeholder: some View {
        ZStack {
            environment.material.baseColor.swiftUIColor
            if let failure {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text(failure)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(environment.material.fiberColor.swiftUIColor)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipShape(
            RoundedRectangle(
                cornerRadius: environment.presentation.sheetCornerRadius * min(displaySize.width, displaySize.height)
            )
        )
    }

    private func loadImage() async {
        guard displaySize.width > 1, displaySize.height > 1 else { return }

        // A sheet already in the cache should appear on this frame, not after
        // an await — otherwise every swipe back flashes a placeholder.
        if let cached = provider.cachedImage(
            for: location,
            environment: environment,
            pixelSize: pixelSize,
            spineShadowScale: spineShadowScale,
            spine: spine,
            safeFraction: safeFraction
        ) {
            image = cached
            failure = nil
            return
        }

        do {
            let built = try await provider.image(
                for: location,
                environment: environment,
                pixelSize: pixelSize,
                spineShadowScale: spineShadowScale,
                spine: spine,
                safeFraction: safeFraction
            )
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                image = built
            }
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}
