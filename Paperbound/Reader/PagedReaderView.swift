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
import UIKit

enum PagePrefetchPolicy {
    static func nextUnit(after current: Int, count: Int, direction: Int) -> Int? {
        let candidate = current + (direction < 0 ? -1 : 1)
        return (0..<count).contains(candidate) ? candidate : nil
    }
}

struct PagedReaderView: View {

    let model: ReaderViewModel
    let provider: PageImageProvider

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings

    @State private var visibleUnit: Int?
    private var settledUnit: Int? { model.paging.settledUnit }
    @State private var prefetchDirection = 1
    private var revealSequence: EnchantedInkRevealSequence? { model.paging.sequence }
    private var incomingRevealUnit: Int? { model.paging.incomingUnit }
    @State private var didSettleInitialLayout = false
    @State private var scrollOffset: CGFloat = 0
    @State private var settledGeometryKey: String?
    @State private var pageEffectVisits: [Int: PageEffectVisit] = [:]
    @State private var incomingPageEffectUnit: Int?
    @State private var pagingInProgress = false
    @State private var zoomInProgress = false
    @State private var pageEffectGeometryTransition = false
    @State private var pageEffectGeometryRevision = 0
    @State private var pageEffectReplanTask: Task<Void, Never>?
    @State private var didInitialize = false
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero
    /// The selection handle under the finger, and how far the finger is from
    /// the point it is moving, so the text does not jump to the fingertip.
    @State private var handleGrab: (handle: SelectionHandle, offset: CGSize)?
    @State private var longPressStarted = false

    private var isSpread: Bool { model.layout.mode == .spread }

    /// Reduce Motion keeps the plain slide: no 3D swing, no curl.
    private var turnStyle: PageTurnStyle {
        reduceMotion ? .slide : settings.pageTurnStyle
    }

    /// Where `unit` is in a page turn, read off the pager's own offset.
    private func pageTurn(forUnit unit: Int, pageWidth: CGFloat) -> PageTurn? {
        guard turnStyle != .slide, didInitialize, pageWidth > 0, committedZoom <= 1.01 else { return nil }
        let position = CGFloat(unit) - scrollOffset / pageWidth
        var style = turnStyle
        // A live ink reveal is drawn by Metal outside SwiftUI, where a layer
        // effect cannot reach it. Turn that leaf as a cover instead.
        let liftingUnit = Int(floor(scrollOffset / pageWidth))
        if style == .curl, model.environment.ink == .enchanted,
           let sequence = revealSequence, sequence.unit == liftingUnit, sequence.phase != .finished {
            style = .cover
        }
        // Within half a point of a page boundary is rest. A turn that settles
        // a hair short must not leave the old sheet on top, catching taps.
        let restSlack = 0.5 / pageWidth
        let nearest = position.rounded()
        if abs(position - nearest) < restSlack { return nil }
        return PageTurn(style: style, position: position)
    }

    private func leafRole(index: Int, count: Int) -> PageTurnLeafRole {
        guard isSpread, count == 2, model.layout.divisionAxis != .horizontal else { return .whole }
        return index == 0 ? .left : .right
    }

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

    private func stablePageIdentity(for location: ReadingLocation) -> String {
        let identity: String
        if let engine = model.engine {
            identity = engine.stablePageID(for: location)
        } else if let pageIndex = location.pdfPageIndex {
            identity = "pdf:\(pageIndex)"
        } else {
            identity = "start"
        }
        return "\(model.book.id.uuidString)|\(identity)"
    }

    /// iOS 27.1 reports the Duo fold and active camera cutouts in the view's
    /// coordinate space. Earlier systems keep the existing safe-area path.
    private func hardwareReservedRegions(using geometry: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return hardwareDivisionRegions(using: geometry) + hardwareOcclusionRegions(using: geometry)
    }

    private func hardwareDivisionRegions(using geometry: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return geometry.reservedRegions(kind: .division).map(\.frame)
    }

    private func hardwareOcclusionRegions(using geometry: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return geometry.reservedRegions(kind: .occlusion).map(\.frame)
    }

    private func imageRequest(
        for location: ReadingLocation,
        pageRect: CGRect,
        in surfaceSize: CGSize,
        insets: EdgeInsets,
        reservedRegions: [CGRect]
    ) -> PageImageRequest {
        let pageIndex = location.pdfPageIndex ?? 0
        let locations = pages(inUnit: unit(forPageIndex: pageIndex))
        let position = locations.firstIndex(of: location) ?? 0
        let normalizedReserved = reservedRegions.compactMap { region -> CGRect? in
            let clipped = region.intersection(pageRect)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return CGRect(
                x: (clipped.minX - pageRect.minX) / pageRect.width,
                y: (clipped.minY - pageRect.minY) / pageRect.height,
                width: clipped.width / pageRect.width,
                height: clipped.height / pageRect.height
            )
        }
        return PageImageRequest(
            location: location,
            pixelSize: PageRenderScale.pixelSize(for: pageRect.size, displayScale: displayScale,
                                               enchanted: model.environment.ink == .enchanted),
            spineShadowScale: model.layout.spineShadowScale,
            spine: DeviceLayoutCoordinator.spineEdge(
                position: position,
                of: locations.count,
                pageIndex: pageIndex,
                divisionAxis: model.layout.divisionAxis
            ),
            safeFraction: safeFraction(
                for: pageRect,
                in: surfaceSize,
                insets: insets,
                reservedRegions: reservedRegions
            ),
            reservedRegions: normalizedReserved
        )
    }

    private func prefetchRequests(
        after unit: Int,
        direction: Int,
        in surfaceSize: CGSize,
        insets: EdgeInsets,
        reservedRegions: [CGRect]
    ) -> [PageImageRequest] {
        guard let candidate = PagePrefetchPolicy.nextUnit(
            after: unit, count: unitCount, direction: direction
        ) else { return [] }
        let locations = pages(inUnit: candidate)
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: surfaceSize,
            layout: model.layout,
            pageAspectRatio: model.pageAspectRatio
        )
        var requests: [PageImageRequest] = []
        for (index, location) in locations.enumerated() {
            guard rects.indices.contains(index) else { continue }
            requests.append(imageRequest(
                for: location,
                pageRect: rects[index],
                in: surfaceSize,
                insets: insets,
                reservedRegions: reservedRegions
            ))
        }
        return requests
    }

    private func beginRevealSequence(
        for unit: Int, source: ReaderNavigationRequest.Source,
        in size: CGSize, insets: EdgeInsets, reservedRegions: [CGRect], force: Bool = false
    ) {
        let locations = pages(inUnit: unit)
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: size, layout: model.layout, pageAspectRatio: model.pageAspectRatio
        )
        var renders: [String: String] = [:]
        for (index, location) in locations.enumerated() where rects.indices.contains(index) {
            renders[stablePageIdentity(for: location)] = provider.requestIdentifier(
                for: imageRequest(for: location, pageRect: rects[index], in: size,
                                  insets: insets, reservedRegions: reservedRegions),
                environment: model.environment
            )
        }
        model.paging.request(unit: unit, pages: locations.map(stablePageIdentity(for:)),
                             renders: renders, source: source,
                             enchanted: model.environment.ink == .enchanted,
                             animationsAllowed: !reduceMotion && scenePhase == .active,
                             force: force)
    }

    private func finishActiveRevealForLayoutChange() {
        model.paging.finish(reason: "layout or lifecycle transition")
    }

    private func makePageEffectVisit(
        for unit: Int, in size: CGSize, insets: EdgeInsets,
        reservedRegions: [CGRect], fraction: CGFloat
    ) {
        guard model.environment.pageEffect.isAnimated, !reduceMotion,
              scenePhase == .active, unit >= 0, unit < unitCount else { return }
        if var existing = pageEffectVisits[unit] {
            existing.setVisibleFraction(fraction, at: Date())
            pageEffectVisits[unit] = existing
            return
        }
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: size, layout: model.layout, pageAspectRatio: model.pageAspectRatio
        )
        var tokens: [String: String] = [:]
        for (index, location) in pages(inUnit: unit).enumerated() where rects.indices.contains(index) {
            let request = imageRequest(
                for: location, pageRect: rects[index], in: size,
                insets: insets, reservedRegions: reservedRegions
            )
            tokens[stablePageIdentity(for: location)] = provider.requestIdentifier(
                for: request, environment: model.environment
            )
        }
        var visit = PageEffectVisit(unit: unit, visitID: UUID(), pageRenderTokens: tokens)
        visit.setVisibleFraction(fraction, at: Date())
        pageEffectVisits[unit] = visit
    }

    private func pageEffectPaperReady(
        pageIdentity: String, renderToken: String, visitID: UUID, in unit: Int
    ) {
        guard var visit = pageEffectVisits[unit] else { return }
        guard visit.paperReady(
            pageIdentity: pageIdentity, renderToken: renderToken,
            visitID: visitID, at: Date()
        ) else { return }
        if visit.startedAt != nil {
            InkMetrics.trace("PageEffects unit \(unit) started")
        }
        pageEffectVisits[unit] = visit
    }

    private func resetPageEffectsForGeometry(
        in size: CGSize, insets: EdgeInsets, reservedRegions: [CGRect]
    ) {
        guard model.environment.pageEffect.isAnimated else { return }
        pageEffectGeometryRevision += 1
        let revision = pageEffectGeometryRevision
        withAnimation(.easeOut(duration: 0.2)) { pageEffectGeometryTransition = true }
        pageEffectReplanTask?.cancel()
        pageEffectReplanTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, revision == pageEffectGeometryRevision else { return }
            pageEffectVisits.removeAll()
            incomingPageEffectUnit = nil
            pageEffectGeometryTransition = false
            let current = settledUnit ?? unit(forPageIndex: model.currentPageIndex)
            makePageEffectVisit(
                for: current, in: size, insets: insets,
                reservedRegions: reservedRegions, fraction: 1
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let size = CGSize(
                width: geometry.size.width + insets.leading + insets.trailing,
                height: geometry.size.height + insets.top + insets.bottom
            )
            let hardwareReserved = hardwareReservedRegions(using: geometry)
            let hardwareDivision = hardwareDivisionRegions(using: geometry)
            let surfaceReserved = hardwareReserved.map {
                $0.offsetBy(dx: insets.leading, dy: insets.top)
            }
            let surfaceDivision = hardwareDivision.map {
                $0.offsetBy(dx: insets.leading, dy: insets.top)
            }
            let neighbors = prefetchRequests(
                after: visibleUnit ?? unit(forPageIndex: model.currentPageIndex),
                direction: prefetchDirection,
                in: size, insets: insets, reservedRegions: surfaceReserved
            )
            let prefetchIdentity = neighbors.map {
                provider.requestIdentifier(for: $0, environment: model.environment)
            }.joined(separator: ";")
            let geometryKey = "\(size)|\(insets)|\(surfaceReserved)|\(model.layout.mode)|\(displayScale)"
            let settlementKey = "\(geometryKey)|\(model.activePanel?.rawValue ?? "closed")|\(model.isPanelPresented)|\(model.environment.ink)|\(scenePhase)"
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<max(unitCount, 0), id: \.self) { unit in
                        spreadView(unit: unit, in: size, insets: insets, reservedRegions: surfaceReserved)
                            .frame(width: size.width, height: size.height)
                            .zIndex(pageTurn(forUnit: unit, pageWidth: size.width)?.zIndex(isSpread: isSpread) ?? 0)
                            .id(unit)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleUnit)
            // While text is selected, a drag moves a handle; it must not turn
            // the page out from under it. An open mark has no handles, so a
            // swipe still turns the page, and the turn closes the mark.
            .scrollDisabled(committedZoom > 1.01 || model.textSelection.selection != nil)
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay(alignment: .topLeading) {
                annotationOverlay(in: size, insets: insets, avoiding: surfaceReserved)
            }
            .offset(x: -insets.leading, y: -insets.top)
            .ignoresSafeArea()
            .background(model.environment.presentation.surroundColor.swiftUIColor)
            .task(id: prefetchIdentity) {
                provider.prefetch(neighbors, environment: model.environment)
            }
            .task(id: settlementKey) {
                guard model.activePanel == nil, !model.isPanelPresented, scenePhase == .active else { return }
                // Coalesce the same initial/sheet geometry changes as page loading.
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard !Task.isCancelled else { return }
                settledGeometryKey = geometryKey
                if !didSettleInitialLayout || model.paging.pendingReplay {
                    let initial = !didSettleInitialLayout
                    didSettleInitialLayout = true
                    model.paging.consumeReplay()
                    let current = unit(forPageIndex: model.currentPageIndex)
                    beginRevealSequence(for: current, source: initial ? .opening : .settings,
                                        in: size, insets: insets, reservedRegions: surfaceReserved,
                                        force: true)
                    let fraction = max(0, 1 - abs(scrollOffset / max(1, size.width) - CGFloat(current)))
                    model.paging.observe(unit: current, fraction: fraction, at: Date())
                    if fraction >= 0.999 { model.paging.settle(unit: current, at: Date()) }
                }
            }
            .onChange(of: model.activePanel) { _, panel in
                if panel != nil {
                    // The settings preview must not queue behind two hidden
                    // reader sessions. Finish them before allocating its session.
                    model.paging.finish(reason: "panel presented")
                }
            }
            .onAppear {
                model.updateLayout(
                    for: size,
                    hardwareReservedRegions: surfaceReserved,
                    divisionRegions: surfaceDivision
                )
                let initial = unit(forPageIndex: model.currentPageIndex)
                visibleUnit = initial
                model.paging.relocate(unit: initial)
                didInitialize = true
                #if DEBUG
                runAnnotationDemo()
                // Turns one page by itself, for capturing a turn from the
                // simulator, which cannot synthesize a swipe.
                if let delay = ProcessInfo.processInfo.environment["PAPERBOUND_AUTO_TURN"].flatMap(Double.init) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        model.advance(by: isSpread ? 2 : 1)
                    }
                }
                #endif
                makePageEffectVisit(
                    for: initial, in: size, insets: insets,
                    reservedRegions: surfaceReserved, fraction: 1
                )
            }
            .onChange(of: size) { _, newSize in
                model.updateLayout(
                    for: newSize,
                    hardwareReservedRegions: surfaceReserved,
                    divisionRegions: surfaceDivision
                )
                // Keep the reader on the same page across a resize or a fold.
                finishActiveRevealForLayoutChange()
                resetPageEffectsForGeometry(in: newSize, insets: insets, reservedRegions: surfaceReserved)
                let current = unit(forPageIndex: model.currentPageIndex)
                if visibleUnit != current {
                    visibleUnit = current
                }
                model.paging.relocate(unit: current)
            }
            .onChange(of: hardwareReserved) { _, _ in
                model.updateLayout(
                    for: size,
                    hardwareReservedRegions: surfaceReserved,
                    divisionRegions: surfaceDivision
                )
                finishActiveRevealForLayoutChange()
                resetPageEffectsForGeometry(in: size, insets: insets, reservedRegions: surfaceReserved)
            }
            .onChange(of: displayScale) { _, _ in
                finishActiveRevealForLayoutChange()
                resetPageEffectsForGeometry(in: size, insets: insets, reservedRegions: surfaceReserved)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    finishActiveRevealForLayoutChange()
                    pageEffectVisits.removeAll()
                    incomingPageEffectUnit = nil
                } else {
                    makePageEffectVisit(
                        for: settledUnit ?? unit(forPageIndex: model.currentPageIndex),
                        in: size, insets: insets, reservedRegions: surfaceReserved,
                        fraction: 1
                    )
                }
            }
            .onChange(of: reduceMotion) { _, isEnabled in
                if isEnabled {
                    finishActiveRevealForLayoutChange()
                    pageEffectVisits.removeAll()
                } else {
                    makePageEffectVisit(
                        for: settledUnit ?? unit(forPageIndex: model.currentPageIndex),
                        in: size, insets: insets, reservedRegions: surfaceReserved,
                        fraction: 1
                    )
                }
            }
            .onChange(of: model.textSelection.isActive) { _, active in
                if active, model.showsControls {
                    withAnimation(.easeInOut(duration: 0.2)) { model.showsControls = false }
                }
            }
            .onChange(of: visibleUnit) { _, _ in
                model.textSelection.clear()
                resetZoom()
            }
            .onScrollGeometryChange(for: CGFloat.self) { scrollGeometry in
                scrollGeometry.contentOffset.x + scrollGeometry.contentInsets.leading
            } action: { oldOffset, newOffset in
                scrollOffset = newOffset
                InkMetrics.trace("Scroll offset=\(newOffset) delta=\(newOffset - oldOffset)")
                if didInitialize, didSettleInitialLayout, settledGeometryKey == geometryKey, size.width > 0 {
                    let position = newOffset / size.width
                    if model.paging.isProgrammatic, let target = model.paging.requestedUnit {
                        model.paging.observe(unit: target, fraction: max(0, 1 - abs(position - CGFloat(target))), at: Date())
                    } else if let incoming = PageTurnVisibility.incomingPage(
                        offset: newOffset, direction: newOffset - oldOffset,
                        pageWidth: size.width, unitCount: unitCount
                    ) {
                        if incoming.unit != settledUnit, revealSequence?.unit != incoming.unit {
                            beginRevealSequence(for: incoming.unit, source: .swipe,
                                                in: size, insets: insets, reservedRegions: surfaceReserved)
                        }
                        model.paging.observe(unit: incoming.unit, fraction: incoming.fraction, at: Date())
                    }
                    let boundary = Int(position.rounded())
                    if abs(position - CGFloat(boundary)) < 0.001,
                       boundary >= 0, boundary < unitCount,
                       model.paging.settle(unit: boundary, at: Date()) {
                        model.reportVisible(pageIndex: isSpread ? boundary * 2 : boundary)
                        if !pagingInProgress, visibleUnit != boundary { visibleUnit = boundary }
                    }
                }
                if didInitialize, size.width > 0 {
                    let delta = newOffset - oldOffset
                    if let incoming = PageTurnVisibility.incomingPage(
                        offset: newOffset, direction: delta,
                        pageWidth: size.width, unitCount: unitCount
                    ) {
                        if incoming.unit == settledUnit {
                            if let abandoned = incomingPageEffectUnit,
                               abandoned != settledUnit {
                                pageEffectVisits.removeValue(forKey: abandoned)
                            }
                            incomingPageEffectUnit = nil
                        } else {
                            incomingPageEffectUnit = incoming.unit
                            makePageEffectVisit(
                                for: incoming.unit, in: size, insets: insets,
                                reservedRegions: surfaceReserved, fraction: incoming.fraction
                            )
                        }
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                pagingInProgress = phase != .idle
                if phase == .idle, settledGeometryKey == geometryKey, let visibleUnit {
                    if let settledUnit, settledUnit != visibleUnit {
                        prefetchDirection = visibleUnit > settledUnit ? 1 : -1
                    }
                    let actual = Int((scrollOffset / max(1, size.width)).rounded())
                    if actual >= 0, actual < unitCount,
                       model.paging.settle(unit: actual, at: Date()) {
                        model.reportVisible(pageIndex: isSpread ? actual * 2 : actual)
                        if self.visibleUnit != actual { self.visibleUnit = actual }
                    }
                    pageEffectVisits = pageEffectVisits.filter { $0.key == visibleUnit }
                    incomingPageEffectUnit = nil
                    makePageEffectVisit(
                        for: visibleUnit, in: size, insets: insets,
                        reservedRegions: surfaceReserved, fraction: 1
                    )
                }
            }
            .onChange(of: model.navigationRequest) { _, request in
                guard let request else { return }
                let target = unit(forPageIndex: request.pageIndex)
                guard target != settledUnit || model.paging.requestedUnit != nil else { return }
                beginRevealSequence(for: target, source: request.source,
                                    in: size, insets: insets, reservedRegions: surfaceReserved)
                resetZoom()
                withAnimation(.easeInOut(duration: programmaticTurnDuration)) { visibleUnit = target }
            }
            .onChange(of: model.environment) { oldEnvironment, newEnvironment in
                if oldEnvironment.ink != newEnvironment.ink {
                    if newEnvironment.ink == .enchanted {
                        model.paging.deferReplay()
                    } else {
                        model.paging.disable()
                    }
                }
                if oldEnvironment.pageEffect != newEnvironment.pageEffect {
                    pageEffectVisits.removeAll()
                    incomingPageEffectUnit = nil
                    if newEnvironment.pageEffect.isAnimated {
                        makePageEffectVisit(
                            for: settledUnit ?? unit(forPageIndex: model.currentPageIndex),
                            in: size, insets: insets, reservedRegions: surfaceReserved,
                            fraction: 1
                        )
                    }
                }
            }
            .onChange(of: model.layout.mode) { _, _ in
                let current = unit(forPageIndex: model.currentPageIndex)
                finishActiveRevealForLayoutChange()
                resetPageEffectsForGeometry(in: size, insets: insets, reservedRegions: surfaceReserved)
                if visibleUnit != current {
                    visibleUnit = current
                }
                model.paging.relocate(unit: current)
            }
            // A hinge update is not a size change: closing a device onto its
            // cover screen resizes the window, but opening it to an angle need
            // not. Without this the layout keeps whatever posture it inferred
            // before the first hinge report ever arrived.
            .onChange(of: model.hinge.snapshot) { _, _ in
                let previousLayout = model.layout
                model.updateLayout(
                    for: size,
                    hardwareReservedRegions: surfaceReserved,
                    divisionRegions: surfaceDivision
                )
                if model.layout.changesPagePlacement(comparedTo: previousLayout) {
                    finishActiveRevealForLayoutChange()
                    resetPageEffectsForGeometry(in: size, insets: insets, reservedRegions: surfaceReserved)
                }
            }
            .onDisappear {
                pageEffectReplanTask?.cancel()
                pageEffectReplanTask = nil
                model.paging.finish(reason: "reader disappeared")
                pageEffectVisits.removeAll()
                incomingPageEffectUnit = nil
            }
        }
    }

    // MARK: - One paging unit

    /// The visible part of one sheet, in unit coordinates: the sheet
    /// intersected with the safe area, divided through by the sheet.
    private func safeFraction(
        for rect: CGRect,
        in size: CGSize,
        insets: EdgeInsets,
        reservedRegions: [CGRect] = []
    ) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard rect.width > 0, rect.height > 0 else { return whole }
        let safe = CGRect(
            x: insets.leading,
            y: insets.top,
            width: size.width - insets.leading - insets.trailing,
            height: size.height - insets.top - insets.bottom
        )
        return PageContentGeometry.readableFraction(
            for: rect,
            within: safe,
            excluding: reservedRegions
        )
    }

    @ViewBuilder
    private func spreadView(
        unit: Int,
        in size: CGSize,
        insets: EdgeInsets,
        reservedRegions: [CGRect]
    ) -> some View {
        let locations = pages(inUnit: unit)
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: size,
            layout: model.layout,
            pageAspectRatio: model.pageAspectRatio
        )
        let turn = pageTurn(forUnit: unit, pageWidth: size.width)

        ZStack {
            // Mid-turn the board would hide the sheet beneath; the pager
            // already paints it behind every unit.
            model.environment.presentation.surroundColor.swiftUIColor
                .opacity(turn == nil ? 1 : 0)

            // Leaves meet at the spine; the crease is drawn over the seam below.
            let pageLayout = model.layout.divisionAxis == .horizontal
                ? AnyLayout(VStackLayout(spacing: 0))
                : AnyLayout(HStackLayout(spacing: 0))

            let overlayOffset = !isSpread ? (rects.first?.origin ?? .zero) : .zero
            let overlayRects = isSpread ? Array(rects.prefix(locations.count))
                : rects.prefix(1).map { CGRect(origin: .zero, size: $0.size) }
            let overlayReserved = reservedRegions.map {
                $0.offsetBy(dx: -overlayOffset.x, dy: -overlayOffset.y)
            }

            ZStack(alignment: .topLeading) {
            pageLayout {
                ForEach(Array(locations.enumerated()), id: \.offset) { index, location in
                    let rect = rects.indices.contains(index) ? rects[index] : CGRect(origin: .zero, size: size)
                    let pageIdentity = stablePageIdentity(for: location)
                    let revealActivation = revealSequence?.unit == unit
                        ? revealSequence?.activation(for: pageIdentity)
                        : nil
                    let pageRequest = imageRequest(
                        for: location,
                        pageRect: rect,
                        in: size,
                        insets: insets,
                        reservedRegions: reservedRegions
                    )
                    PhysicalPageView(
                        location: location,
                        environment: model.environment,
                        provider: provider,
                        spineShadowScale: model.layout.spineShadowScale,
                        displaySize: rect.size,
                        spine: DeviceLayoutCoordinator.spineEdge(
                            position: index,
                            of: locations.count,
                            pageIndex: location.pdfPageIndex ?? 0,
                            divisionAxis: model.layout.divisionAxis
                        ),
                        pageIdentity: pageIdentity,
                        safeFraction: pageRequest.safeFraction,
                        reservedRegions: pageRequest.reservedRegions,
                        pageRequest: pageRequest,
                        isPageVisible: unit == (visibleUnit ?? self.unit(forPageIndex: model.currentPageIndex))
                            || unit == settledUnit || unit == incomingRevealUnit
                            || unit == incomingPageEffectUnit,
                        revealActivation: revealActivation,
                        onImageReady: { identity, seed in
                            model.paging.readiness(identity, seed: seed, at: Date())
                        },
                        onRevealComplete: { identity, startedAt in
                            model.paging.completed(identity, startedAt: startedAt, at: Date())
                        },
                        onFirstInkFrame: { identity in model.paging.firstFrame(identity) },
                        pageEffectVisitID: pageEffectVisits[unit]?.visitID,
                        onPaperReady: { pageIdentity, renderToken, visitID in
                            pageEffectPaperReady(
                                pageIdentity: pageIdentity, renderToken: renderToken,
                                visitID: visitID, in: unit
                            )
                        }
                    )
                    .overlay(alignment: .topLeading) {
                        // Under Enchanted Ink the marks wait for the text: hidden
                        // on the blank page, then fading in as the ink flows.
                        let awaitingInk = revealActivation?.state == .waiting
                        let inkStartsIn: Double = {
                            guard case .revealing(let start, _) = revealActivation?.state else { return 0 }
                            return max(0, start.timeIntervalSinceNow)
                        }()
                        annotationLayer(for: location, sheet: rect.size, request: pageRequest)
                            .opacity(awaitingInk ? 0 : 1)
                            .animation(awaitingInk ? nil : .easeIn(duration: 2.4).delay(inkStartsIn),
                                       value: awaitingInk)
                    }
                    .modifier(PageTurnLeafEffect(
                        turn: turn,
                        role: leafRole(index: index, count: locations.count),
                        rect: rect,
                        unitMaxX: rects.last?.maxX ?? size.width,
                        curlFace: {
                            guard let page = provider.cachedPage(for: pageRequest, environment: model.environment)
                            else { return nil }
                            return AnyView(
                                Image(decorative: page.image, scale: 1).resizable().interpolation(.high)
                                    .frame(width: rect.width, height: rect.height)
                                    .overlay(alignment: .topLeading) {
                                        annotationLayer(for: location, sheet: rect.size, request: pageRequest)
                                    }
                            )
                        }
                    ))
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
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            if isSpread, let seam = DeviceLayoutCoordinator.seam(in: size, layout: model.layout) {
                SpineCreaseView(
                    axis: seam.axis,
                    foldWidth: seam.width,
                    depth: model.layout.spineShadowScale,
                    pronounced: model.environment.presentation.showsSpine
                )
                .frame(
                    width: seam.axis == .vertical ? SpineCreaseView.reach(for: seam.width) : size.width,
                    height: seam.axis == .vertical ? size.height : SpineCreaseView.reach(for: seam.width)
                )
                .position(
                    x: seam.axis == .vertical ? seam.line : size.width / 2,
                    y: seam.axis == .vertical ? size.height / 2 : seam.line
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if model.environment.pageEffect.isAnimated,
               !reduceMotion,
               let visit = pageEffectVisits[unit], visit.startedAt != nil {
                PageEffectOverlayView(
                    effect: model.environment.pageEffect,
                    visit: visit,
                    seed: StableHash.hash("\(model.book.id)|\(unit)|\(visit.visitID)"),
                    surfaces: overlayRects,
                    reservedRegions: overlayReserved,
                    size: size,
                    isDarkPaper: model.environment.invertsInk,
                    isPaused: pagingInProgress || zoomInProgress
                        || pageEffectGeometryTransition || scenePhase != .active
                        || model.activePanel != nil || model.isPanelPresented
                )
                .id(visit.visitID)
                .opacity(pageEffectGeometryTransition || turn != nil ? 0 : 1)
            }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(committedZoom * zoom, anchor: .center)
            .offset(
                x: committedPan.width + pan.width
                    + (!isSpread && model.layout.divisionAxis != .horizontal ? (rects.first?.minX ?? 0) : 0),
                y: committedPan.height + pan.height
                    + (!isSpread && model.layout.divisionAxis == .horizontal ? (rects.first?.minY ?? 0) : 0)
            )
        }
        .modifier(PageTurnUnitEffect(turn: turn, pageWidth: size.width))
        .contentShape(Rectangle())
        .simultaneousGesture(zoomGesture)
        .simultaneousGesture(panGesture, including: committedZoom > 1.01 ? .all : .subviews)
        .gesture(selectionPressRecognizer(unit: unit, in: size, insets: insets, reservedRegions: reservedRegions))
        .simultaneousGesture(
            handleDragGesture(unit: unit, in: size, insets: insets, reservedRegions: reservedRegions),
            including: model.textSelection.selection != nil ? .all : .subviews
        )
        .onTapGesture { point in
            handleTap(at: point, unit: unit, in: size, insets: insets, reservedRegions: reservedRegions)
        }
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = value.magnification
                zoomInProgress = true
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
                zoomInProgress = false
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard committedZoom > 1.01 else { return }
                pan = value.translation
                zoomInProgress = true
            }
            .onEnded { value in
                guard committedZoom > 1.01 else { return }
                committedPan = CGSize(
                    width: committedPan.width + value.translation.width,
                    height: committedPan.height + value.translation.height
                )
                pan = .zero
                zoomInProgress = false
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

    /// How long a tap or a jump takes to turn the page, in the current style.
    private var programmaticTurnDuration: Double {
        #if DEBUG
        // Slows every programmatic turn so a single turn can be captured
        // frame by frame from the simulator.
        if let seconds = ProcessInfo.processInfo.environment["PAPERBOUND_TURN_SECONDS"].flatMap(Double.init) {
            return seconds
        }
        #endif
        return turnStyle.programmaticDuration
    }

    private func handleTap(
        at point: CGPoint, unit: Int, in size: CGSize, insets: EdgeInsets, reservedRegions: [CGRect]
    ) {
        if committedZoom > 1.01 {
            resetZoom()
            return
        }
        if handleAnnotationTap(at: point, unit: unit, in: size, insets: insets,
                               reservedRegions: reservedRegions) {
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

    // MARK: - Annotations

    private struct PageGeometry {
        let pageIndex: Int
        /// The sheet, in surface coordinates.
        let frame: CGRect
        /// The text block, in the sheet's own coordinates.
        let textBlock: CGRect

        func unitPoint(forSurface point: CGPoint) -> CGPoint {
            PageTextFrame.unitPoint(
                forView: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), in: textBlock
            )
        }

        func surfaceRect(forUnit rect: CGRect) -> CGRect {
            PageTextFrame.viewRect(forUnit: rect, in: textBlock).offsetBy(dx: frame.minX, dy: frame.minY)
        }
    }

    /// A sheet's marks and, when it is on this sheet, the live selection.
    private func annotationLayer(
        for location: ReadingLocation, sheet: CGSize, request: PageImageRequest
    ) -> some View {
        let pageIndex = location.pdfPageIndex ?? 0
        let selection = model.textSelection.selection
        return PageAnnotationLayer(
            marks: model.marks(onPage: pageIndex),
            selection: selection?.pageIndex == pageIndex ? selection : nil,
            textBlock: textBlock(forPage: pageIndex, sheet: sheet, safeFraction: request.safeFraction),
            emphasizedMarkID: model.textSelection.editingMarkID,
            isDarkPaper: model.environment.invertsInk
        )
        .frame(width: sheet.width, height: sheet.height)
    }

    private func textBlock(forPage pageIndex: Int, sheet: CGSize, safeFraction: CGRect) -> CGRect {
        PageTextFrame.textBlock(in: sheet, pageAspectRatio: model.pageAspectRatio(forPage: pageIndex),
                                safeFraction: safeFraction)
    }

    /// Where each sheet of a unit sits. In every layout the sheets land on
    /// the surface exactly at their `surfaceRects`, which is what the tap
    /// and press gestures on the unit report points in.
    private func pageGeometries(
        unit: Int, in size: CGSize, insets: EdgeInsets, reservedRegions: [CGRect]
    ) -> [PageGeometry] {
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: size, layout: model.layout, pageAspectRatio: model.pageAspectRatio
        )
        return pages(inUnit: unit).enumerated().compactMap { index, location in
            guard rects.indices.contains(index), let pageIndex = location.pdfPageIndex else { return nil }
            let rect = rects[index]
            let request = imageRequest(for: location, pageRect: rect, in: size,
                                       insets: insets, reservedRegions: reservedRegions)
            return PageGeometry(
                pageIndex: pageIndex, frame: rect,
                textBlock: textBlock(forPage: pageIndex, sheet: rect.size, safeFraction: request.safeFraction)
            )
        }
    }

    private var currentUnit: Int { visibleUnit ?? unit(forPageIndex: model.currentPageIndex) }

    /// Long press selects a word; keep the finger down and drag to extend
    /// by whole words. The page is the one the press started on.
    private func selectionPressRecognizer(
        unit: Int, in size: CGSize, insets: EdgeInsets, reservedRegions: [CGRect]
    ) -> SelectionPressRecognizer {
        func page(at point: CGPoint) -> (PageGeometry, PageTextSelector)? {
            let geometries = pageGeometries(unit: unit, in: size, insets: insets,
                                            reservedRegions: reservedRegions)
            guard let page = geometries.first(where: { $0.frame.contains(point) }),
                  let selector = model.textSelector(forPage: page.pageIndex) else { return nil }
            return (page, selector)
        }
        return SelectionPressRecognizer(
            isEnabled: committedZoom <= 1.01,
            onBegan: { start in
                guard handleGrab == nil, let (page, selector) = page(at: start) else { return }
                longPressStarted = true
                if model.textSelection.beginLongPress(on: selector, at: page.unitPoint(forSurface: start)) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            },
            onMoved: { start, location in
                guard longPressStarted, let (page, selector) = page(at: start) else { return }
                model.textSelection.continueLongPress(on: selector, to: page.unitPoint(forSurface: location))
            },
            onEnded: {
                if longPressStarted {
                    longPressStarted = false
                    model.textSelection.endDrag()
                }
            }
        )
    }

    /// Dragging a selection handle. Only claims touches that start on a knob.
    private func handleDragGesture(
        unit: Int, in size: CGSize, insets: EdgeInsets, reservedRegions: [CGRect]
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let selection = model.textSelection.selection,
                      let page = pageGeometries(unit: unit, in: size, insets: insets,
                                                reservedRegions: reservedRegions)
                        .first(where: { $0.pageIndex == selection.pageIndex }),
                      let selector = model.textSelector(forPage: page.pageIndex) else { return }
                let start = CGPoint(x: value.startLocation.x - page.frame.minX,
                                    y: value.startLocation.y - page.frame.minY)
                if handleGrab == nil {
                    guard !longPressStarted,
                          let handle = TextSelectionOverlay.handle(
                            at: start, lineRects: selection.lineRects, textBlock: page.textBlock),
                          let anchors = TextSelectionOverlay.handlePoints(
                            lineRects: selection.lineRects, textBlock: page.textBlock)
                    else { return }
                    // Aim at the middle of the line the handle stands on, not
                    // at its knob, so the text under the handle stays put.
                    let line = handle == .start ? selection.lineRects.first : selection.lineRects.last
                    let lineHeight = (line?.height ?? 0) * page.textBlock.height
                    let anchor = handle == .start ? anchors.start : anchors.end
                    let target = CGPoint(
                        x: anchor.x + (handle == .start ? 1 : -1),
                        y: anchor.y + (handle == .start ? lineHeight / 2 : -lineHeight / 2)
                    )
                    handleGrab = (handle, CGSize(width: target.x - start.x, height: target.y - start.y))
                    model.textSelection.beginHandleDrag(handle)
                }
                guard let grab = handleGrab else { return }
                let point = CGPoint(x: value.location.x + grab.offset.width,
                                    y: value.location.y + grab.offset.height)
                model.textSelection.dragHandle(on: selector, to: page.unitPoint(forSurface: point))
            }
            .onEnded { _ in
                if handleGrab != nil {
                    handleGrab = nil
                    model.textSelection.endDrag()
                }
            }
    }

    /// Taps that belong to annotating: on the selection (grow to the
    /// sentence), off it (dismiss), or on a saved mark (open it). Returns
    /// false when the tap is the reader's: turning a page or the controls.
    private func handleAnnotationTap(
        at point: CGPoint, unit: Int, in size: CGSize, insets: EdgeInsets, reservedRegions: [CGRect]
    ) -> Bool {
        let session = model.textSelection
        let geometries = pageGeometries(unit: unit, in: size, insets: insets, reservedRegions: reservedRegions)
        if let selection = session.selection {
            if let page = geometries.first(where: { $0.pageIndex == selection.pageIndex }),
               selection.lineRects.contains(where: {
                   page.surfaceRect(forUnit: $0).insetBy(dx: -6, dy: -6).contains(point)
               }),
               let selector = model.textSelector(forPage: page.pageIndex) {
                session.expandToSentence(on: selector)
            } else {
                session.clear()
            }
            return true
        }
        if session.editingMarkID != nil {
            session.clear()
            return true
        }
        guard let page = geometries.first(where: { $0.frame.contains(point) }) else { return false }
        // Newest on top, so a mark made over another opens first.
        let hit = model.marks(onPage: page.pageIndex).reversed().first { mark in
            mark.lineRects.contains { page.surfaceRect(forUnit: $0).insetBy(dx: -4, dy: -4).contains(point) }
        }
        guard let hit else { return false }
        session.edit(markID: hit.id, onPage: page.pageIndex)
        return true
    }

    @ViewBuilder
    private func annotationOverlay(in size: CGSize, insets: EdgeInsets, avoiding: [CGRect]) -> some View {
        let session = model.textSelection
        let geometries = pageGeometries(unit: currentUnit, in: size, insets: insets, reservedRegions: avoiding)
        let container = CGRect(
            x: insets.leading, y: insets.top,
            width: size.width - insets.leading - insets.trailing,
            height: size.height - insets.top - insets.bottom
        ).insetBy(dx: 8, dy: 8)
        let loupePoint: CGPoint? = session.loupe.flatMap { loupe in
            geometries.first { $0.pageIndex == loupe.pageIndex }.map { page in
                PageTextFrame.viewPoint(forUnit: loupe.point, in: page.textBlock)
                    .applying(CGAffineTransform(translationX: page.frame.minX, y: page.frame.minY))
            }
        }
        ReaderAnnotationOverlay(
            bar: annotationBar(geometries: geometries),
            loupePoint: loupePoint,
            surfaceSize: size,
            container: container,
            avoiding: avoiding,
            onStyle: { style in applyMark(style: style) },
            onColor: { color in applyMark(color: color) },
            onCopy: copyAnnotationText,
            onDelete: {
                if let id = session.editingMarkID {
                    model.deleteHighlight(id)
                    session.clear()
                } else if let selection = session.selection {
                    // Keep the selection, so the cleared text can be marked afresh.
                    model.deleteHighlights(model.highlights(overlapping: selection).map(\.id))
                }
            }
        )
    }

    private func annotationBar(geometries: [PageGeometry]) -> ReaderAnnotationOverlay.Bar? {
        let session = model.textSelection
        guard !session.isDragging else { return nil }
        if let selection = session.selection,
           let page = geometries.first(where: { $0.pageIndex == selection.pageIndex }) {
            let covered = model.highlights(overlapping: selection)
            return ReaderAnnotationOverlay.Bar(
                mode: .create,
                style: covered.last?.style ?? model.lastHighlightStyle,
                color: covered.last?.color ?? model.lastHighlightColor,
                chosenStyles: Set(covered.map(\.style)),
                chosenColors: Set(covered.map(\.color)),
                canRemove: !covered.isEmpty,
                anchor: union(of: selection.lineRects, on: page)
            )
        }
        if let id = session.editingMarkID, let highlight = model.highlight(withID: id),
           let page = geometries.first(where: { $0.pageIndex == session.editingPageIndex }) {
            return ReaderAnnotationOverlay.Bar(
                mode: .edit, style: highlight.style, color: highlight.color,
                chosenStyles: [highlight.style], chosenColors: [highlight.color], canRemove: true,
                anchor: union(of: highlight.normalizedRects, on: page)
            )
        }
        return nil
    }

    private func union(of lineRects: [CGRect], on page: PageGeometry) -> CGRect {
        lineRects.map(page.surfaceRect(forUnit:)).reduce(CGRect.null) { $0.union($1) }
    }

    /// Style and colour taps toggle what is on the text.
    ///
    /// On a selection: a style already under it comes off; a new style goes
    /// on in the colour already there. A colour recolours the marks under the
    /// selection, or marks it fresh when there are none. The selection stays
    /// open so the bar keeps showing what the text now carries.
    ///
    /// On an open mark: its own style again removes it; anything else restyles
    /// it in place.
    private func applyMark(style: HighlightStyle? = nil, color: HighlightColor? = nil) {
        let session = model.textSelection
        if let id = session.editingMarkID {
            if let style, model.highlight(withID: id)?.style == style {
                model.deleteHighlight(id)
                session.clear()
            } else {
                model.restyleHighlight(id, style: style, color: color)
            }
            return
        }
        guard let selection = session.selection else { return }
        let covered = model.highlights(overlapping: selection)
        if let style {
            let matching = covered.filter { $0.style == style }
            if matching.isEmpty {
                model.addHighlight(selection, style: style,
                                   color: covered.last?.color ?? model.lastHighlightColor)
            } else {
                model.deleteHighlights(matching.map(\.id))
            }
        } else if let color {
            if covered.isEmpty {
                model.addHighlight(selection, style: model.lastHighlightStyle, color: color)
            } else {
                covered.forEach { model.restyleHighlight($0.id, color: color) }
            }
        }
    }

    private func copyAnnotationText() {
        let session = model.textSelection
        let text = session.selection?.text
            ?? session.editingMarkID.flatMap { model.highlight(withID: $0)?.quotedText }
        if let text, !text.isEmpty { UIPasteboard.general.string = text }
        // Long enough to read the bar's "Copied" before it goes.
        let selection = session.selection?.range
        let editing = session.editingMarkID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard session.selection?.range == selection, session.editingMarkID == editing else { return }
            session.clear()
        }
    }

    #if DEBUG
    /// Puts a selection, the loupe, sample marks or an open mark on the
    /// current page, for screenshots: the simulator cannot long-press.
    ///
    ///   PAPERBOUND_DEMO_MARKS=1          one mark per style, one sentence each
    ///   PAPERBOUND_DEMO_SELECT=x,y[,x,y] long-press at a unit point, then drag
    ///   PAPERBOUND_DEMO_LOUPE=1          keep the finger "down" so the loupe shows
    ///   PAPERBOUND_DEMO_EDIT=1           open the first mark on the page
    private func runAnnotationDemo() {
        let environment = ProcessInfo.processInfo.environment
        let wanted = ["PAPERBOUND_DEMO_MARKS", "PAPERBOUND_DEMO_SELECT", "PAPERBOUND_DEMO_EDIT"]
        guard wanted.contains(where: { environment[$0] != nil }) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard let pageIndex = pages(inUnit: currentUnit).first?.pdfPageIndex,
                  let selector = model.textSelector(forPage: pageIndex) else { return }
            if environment["PAPERBOUND_DEMO_MARKS"] == "1", model.marks(onPage: pageIndex).isEmpty {
                var cursor = 0
                for (index, style) in HighlightStyle.allCases.enumerated() {
                    guard let sentence = selector.sentenceSelection(
                        containing: NSRange(location: cursor, length: 1)) else { break }
                    let color = HighlightColor.allCases[index % HighlightColor.allCases.count]
                    model.addHighlight(sentence, style: style, color: color)
                    cursor = sentence.range.location + sentence.range.length + 1
                }
            }
            if let raw = environment["PAPERBOUND_DEMO_SELECT"] {
                let values = raw.split(separator: ",").compactMap { Double($0) }
                if values.count >= 2 {
                    model.textSelection.beginLongPress(on: selector, at: CGPoint(x: values[0], y: values[1]))
                    if values.count >= 4 {
                        model.textSelection.continueLongPress(on: selector, to: CGPoint(x: values[2], y: values[3]))
                    }
                    if environment["PAPERBOUND_DEMO_LOUPE"] != "1" { model.textSelection.endDrag() }
                }
            } else if environment["PAPERBOUND_DEMO_EDIT"] == "1",
                      let mark = model.marks(onPage: pageIndex).first {
                model.textSelection.edit(markID: mark.id, onPage: pageIndex)
            }
        }
    }
    #endif
}
