//
//  PagedReaderView.swift
//  Paperbound
//
//  The physical reading surface: a horizontally paged strip of sheets, one or
//  two at a time depending on what the layout coordinator decided.
//
//  Page turns stay tap- and swipe-driven. Device posture changes what is shown,
//  never how you turn a page.
//

import SwiftUI

struct PagedReaderView: View {

    let model: ReaderViewModel
    let provider: PageImageProvider

    @Environment(\.displayScale) private var displayScale

    @State private var visibleUnit: Int?
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero

    private var isSpread: Bool { model.layout.mode == .spread }

    private var unitCount: Int {
        guard model.pageCount > 0 else { return 0 }
        return isSpread ? (model.pageCount + 1) / 2 : model.pageCount
    }

    private func pages(inUnit unit: Int) -> [ReadingLocation] {
        guard isSpread else {
            return [.pdfPage(index: unit, yOffset: 0)]
        }
        let left = unit * 2
        let right = left + 1
        var result: [ReadingLocation] = [.pdfPage(index: left, yOffset: 0)]
        if right < model.pageCount {
            result.append(.pdfPage(index: right, yOffset: 0))
        }
        return result
    }

    private func unit(forPageIndex index: Int) -> Int {
        isSpread ? index / 2 : index
    }

    var body: some View {
        GeometryReader { geometry in
            // Paper fills the whole window, reserved regions included, so the
            // page reaches the bezel on all four sides and the display's own
            // corners clip it. Type is kept off those regions per sheet by
            // `safeFraction`, so nothing readable sits under the Duo's sensor
            // strip, the home indicator, or the control bars when they show.
            let insets = geometry.safeAreaInsets
            let size = CGSize(
                width: geometry.size.width + insets.leading + insets.trailing,
                height: geometry.size.height + insets.top + insets.bottom
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<max(unitCount, 0), id: \.self) { unit in
                        spreadView(unit: unit, in: size, insets: insets)
                            .frame(width: size.width, height: size.height)
                            .id(unit)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleUnit)
            .scrollDisabled(committedZoom > 1.01)
            // Each unit is exactly one window wide and the scroll view is
            // clipped to it, so the next unit cannot show through as a sliver
            // of a third page the way it did through the Duo's reserved strip.
            .frame(width: size.width, height: size.height)
            .clipped()
            .offset(x: -insets.leading, y: -insets.top)
            .ignoresSafeArea()
            .background(model.environment.presentation.surroundColor.swiftUIColor)
            .onAppear {
                model.updateLayout(for: size)
                visibleUnit = unit(forPageIndex: model.currentPageIndex)
            }
            .onChange(of: size) { _, newSize in
                model.updateLayout(for: newSize)
                // Keep the reader on the same page across a resize or a fold.
                visibleUnit = unit(forPageIndex: model.currentPageIndex)
            }
            .onChange(of: visibleUnit) { _, newValue in
                guard let newValue else { return }
                let pageIndex = isSpread ? newValue * 2 : newValue
                model.reportVisible(pageIndex: pageIndex)
                resetZoom()
                provider.prefetch(
                    around: .pdfPage(index: pageIndex, yOffset: 0),
                    radius: isSpread ? 3 : 2,
                    environment: model.environment,
                    pixelSize: pixelHint(for: size),
                    spineShadowScale: model.layout.spineShadowScale
                )
            }
            .onChange(of: model.currentPageIndex) { _, newValue in
                let target = unit(forPageIndex: newValue)
                if visibleUnit != target {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        visibleUnit = target
                    }
                }
            }
            .onChange(of: model.environment) { _, _ in
                model.updateLayout(for: size)
            }
            // A hinge update is not a size change: closing a device onto its
            // cover screen resizes the window, but opening it to an angle need
            // not. Without this the layout keeps whatever posture it inferred
            // before the first hinge report ever arrived.
            .onChange(of: model.hinge.snapshot) { _, _ in
                model.updateLayout(for: size)
            }
        }
    }

    // MARK: - One paging unit

    /// The visible part of one sheet, in unit coordinates: the sheet
    /// intersected with the safe area, divided through by the sheet.
    private func safeFraction(for rect: CGRect, in size: CGSize, insets: EdgeInsets) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard rect.width > 0, rect.height > 0 else { return whole }
        let safe = CGRect(
            x: insets.leading,
            y: insets.top,
            width: size.width - insets.leading - insets.trailing,
            height: size.height - insets.top - insets.bottom
        )
        let visible = rect.intersection(safe)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return whole }
        return CGRect(
            x: (visible.minX - rect.minX) / rect.width,
            y: (visible.minY - rect.minY) / rect.height,
            width: visible.width / rect.width,
            height: visible.height / rect.height
        )
    }

    @ViewBuilder
    private func spreadView(unit: Int, in size: CGSize, insets: EdgeInsets) -> some View {
        let locations = pages(inUnit: unit)
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: size,
            layout: model.layout,
            pageAspectRatio: model.pageAspectRatio
        )

        ZStack {
            model.environment.presentation.surroundColor.swiftUIColor

            HStack(spacing: isSpread ? size.width * CGFloat(model.layout.spineFraction) : 0) {
                ForEach(Array(locations.enumerated()), id: \.offset) { index, location in
                    let rect = rects.indices.contains(index) ? rects[index] : CGRect(origin: .zero, size: size)
                    PhysicalPageView(
                        location: location,
                        environment: model.environment,
                        provider: provider,
                        spineShadowScale: model.layout.spineShadowScale,
                        displaySize: rect.size,
                        spine: DeviceLayoutCoordinator.spineEdge(
                            position: index,
                            of: locations.count,
                            pageIndex: location.pdfPageIndex ?? 0
                        ),
                        safeFraction: safeFraction(for: rect, in: size, insets: insets)
                    )
                }
                // A spread whose last page is missing (odd page count) keeps the
                // remaining sheet on its own side rather than re-centring it.
                if isSpread && locations.count == 1 {
                    Color.clear
                        .frame(
                            width: rects.indices.contains(1) ? rects[1].width : 0,
                            height: rects.indices.contains(1) ? rects[1].height : 0
                        )
                }
            }
            .scaleEffect(committedZoom * zoom, anchor: .center)
            .offset(x: committedPan.width + pan.width, y: committedPan.height + pan.height)
        }
        .contentShape(Rectangle())
        .gesture(zoomGesture)
        .simultaneousGesture(panGesture)
        .onTapGesture { point in
            handleTap(at: point, in: size)
        }
    }

    private func pixelHint(for size: CGSize) -> CGSize {
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: size,
            layout: model.layout,
            pageAspectRatio: model.pageAspectRatio
        )
        let rect = rects.first ?? CGRect(origin: .zero, size: size)
        return PageRenderScale.pixelSize(for: rect.size, displayScale: displayScale)
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = value.magnification
            }
            .onEnded { value in
                let next = (committedZoom * value.magnification).clamped(to: 1...4)
                withAnimation(.easeOut(duration: 0.18)) {
                    committedZoom = next
                    zoom = 1
                    if next <= 1.01 {
                        committedPan = .zero
                        pan = .zero
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard committedZoom > 1.01 else { return }
                pan = value.translation
            }
            .onEnded { value in
                guard committedZoom > 1.01 else { return }
                committedPan = CGSize(
                    width: committedPan.width + value.translation.width,
                    height: committedPan.height + value.translation.height
                )
                pan = .zero
            }
    }

    private func resetZoom() {
        guard committedZoom != 1 || committedPan != .zero else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            committedZoom = 1
            zoom = 1
            committedPan = .zero
            pan = .zero
        }
    }

    private func handleTap(at point: CGPoint, in size: CGSize) {
        if committedZoom > 1.01 {
            resetZoom()
            return
        }
        let edge = size.width * 0.28
        if point.x < edge {
            model.advance(by: isSpread ? -2 : -1)
        } else if point.x > size.width - edge {
            model.advance(by: isSpread ? 2 : 1)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                model.showsControls.toggle()
            }
        }
    }
}
