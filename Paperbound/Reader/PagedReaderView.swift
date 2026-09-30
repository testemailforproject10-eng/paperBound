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

    @State private var visibleUnit: Int?
    private var settledUnit: Int? { model.paging.settledUnit }
    @State private var prefetchDirection = 1
    private var revealSequence: EnchantedInkRevealSequence? { model.paging.sequence }
    private var incomingRevealUnit: Int? { model.paging.incomingUnit }
    @State private var didSettleInitialLayout = false
    @State private var scrollOffset: CGFloat = 0
    @State private var settledGeometryKey: String?
    @State private var footstepVisits: [Int: FootstepVisit] = [:]
    @State private var incomingFootstepUnit: Int?
    @State private var pagingInProgress = false
    @State private var zoomInProgress = false
    @State private var footstepGeometryTransition = false
    @State private var footstepGeometryRevision = 0
    @State private var footstepReplanTask: Task<Void, Never>?
    @State private var didInitialize = false
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

    private func makeFootstepVisit(
        for unit: Int, in size: CGSize, insets: EdgeInsets,
        reservedRegions: [CGRect], fraction: CGFloat
    ) {
        guard model.environment.footstepsEnabled, !reduceMotion,
              scenePhase == .active, unit >= 0, unit < unitCount else { return }
        if var existing = footstepVisits[unit] {
            existing.setVisibleFraction(fraction, at: Date())
            footstepVisits[unit] = existing
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
        var visit = FootstepVisit(unit: unit, visitID: UUID(), pageRenderTokens: tokens)
        visit.setVisibleFraction(fraction, at: Date())
        footstepVisits[unit] = visit
    }

    private func footstepPaperReady(
        pageIdentity: String, renderToken: String, visitID: UUID, in unit: Int
    ) {
        guard var visit = footstepVisits[unit] else { return }
        guard visit.paperReady(
            pageIdentity: pageIdentity, renderToken: renderToken,
            visitID: visitID, at: Date()
        ) else { return }
        if visit.startedAt != nil {
            InkMetrics.trace("Footsteps unit \(unit) started")
        }
        footstepVisits[unit] = visit
    }

    private func resetFootstepsForGeometry(
        in size: CGSize, insets: EdgeInsets, reservedRegions: [CGRect]
    ) {
        guard model.environment.footstepsEnabled else { return }
        footstepGeometryRevision += 1
        let revision = footstepGeometryRevision
        withAnimation(.easeOut(duration: 0.2)) { footstepGeometryTransition = true }
        footstepReplanTask?.cancel()
        footstepReplanTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, revision == footstepGeometryRevision else { return }
            footstepVisits.removeAll()
            incomingFootstepUnit = nil
            footstepGeometryTransition = false
            let current = settledUnit ?? unit(forPageIndex: model.currentPageIndex)
            makeFootstepVisit(
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
                            .id(unit)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleUnit)
            .scrollDisabled(committedZoom > 1.01)
            .frame(width: size.width, height: size.height)
            .clipped()
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
                makeFootstepVisit(
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
                resetFootstepsForGeometry(in: newSize, insets: insets, reservedRegions: surfaceReserved)
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
                resetFootstepsForGeometry(in: size, insets: insets, reservedRegions: surfaceReserved)
            }
            .onChange(of: displayScale) { _, _ in
                finishActiveRevealForLayoutChange()
                resetFootstepsForGeometry(in: size, insets: insets, reservedRegions: surfaceReserved)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    finishActiveRevealForLayoutChange()
                    footstepVisits.removeAll()
                    incomingFootstepUnit = nil
                } else {
                    makeFootstepVisit(
                        for: settledUnit ?? unit(forPageIndex: model.currentPageIndex),
                        in: size, insets: insets, reservedRegions: surfaceReserved,
                        fraction: 1
                    )
                }
            }
            .onChange(of: reduceMotion) { _, isEnabled in
                if isEnabled {
                    finishActiveRevealForLayoutChange()
                    footstepVisits.removeAll()
                } else {
                    makeFootstepVisit(
                        for: settledUnit ?? unit(forPageIndex: model.currentPageIndex),
                        in: size, insets: insets, reservedRegions: surfaceReserved,
                        fraction: 1
                    )
                }
            }
            .onChange(of: visibleUnit) { _, _ in
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
                            if let abandoned = incomingFootstepUnit,
                               abandoned != settledUnit {
                                footstepVisits.removeValue(forKey: abandoned)
                            }
                            incomingFootstepUnit = nil
                        } else {
                            incomingFootstepUnit = incoming.unit
                            makeFootstepVisit(
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
                    footstepVisits = footstepVisits.filter { $0.key == visibleUnit }
                    incomingFootstepUnit = nil
                    makeFootstepVisit(
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
                withAnimation(.easeInOut(duration: 0.28)) { visibleUnit = target }
            }
            .onChange(of: model.environment) { oldEnvironment, newEnvironment in
                if oldEnvironment.ink != newEnvironment.ink {
                    if newEnvironment.ink == .enchanted {
                        model.paging.deferReplay()
                    } else {
                        model.paging.disable()
                    }
                }
                if oldEnvironment.footstepsEnabled != newEnvironment.footstepsEnabled {
                    footstepVisits.removeAll()
                    incomingFootstepUnit = nil
                    if newEnvironment.footstepsEnabled {
                        makeFootstepVisit(
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
                resetFootstepsForGeometry(in: size, insets: insets, reservedRegions: surfaceReserved)
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
                    resetFootstepsForGeometry(in: size, insets: insets, reservedRegions: surfaceReserved)
                }
            }
            .onDisappear {
                footstepReplanTask?.cancel()
                footstepReplanTask = nil
                model.paging.finish(reason: "reader disappeared")
                footstepVisits.removeAll()
                incomingFootstepUnit = nil
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

        ZStack {
            model.environment.presentation.surroundColor.swiftUIColor

            let spacing = isSpread
                ? (model.layout.divisionAxis == .horizontal
                    ? size.height * CGFloat(model.layout.spineFraction)
                    : size.width * CGFloat(model.layout.spineFraction))
                : 0
            let pageLayout = model.layout.divisionAxis == .horizontal
                ? AnyLayout(VStackLayout(spacing: spacing))
                : AnyLayout(HStackLayout(spacing: spacing))

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
                            || unit == incomingFootstepUnit,
                        revealActivation: revealActivation,
                        onImageReady: { identity, seed in
                            model.paging.readiness(identity, seed: seed, at: Date())
                        },
                        onRevealComplete: { identity, startedAt in
                            model.paging.completed(identity, startedAt: startedAt, at: Date())
                        },
                        onFirstInkFrame: { identity in model.paging.firstFrame(identity) },
                        footstepVisitID: footstepVisits[unit]?.visitID,
                        onPaperReady: { pageIdentity, renderToken, visitID in
                            footstepPaperReady(
                                pageIdentity: pageIdentity, renderToken: renderToken,
                                visitID: visitID, in: unit
                            )
                        }
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
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            if model.environment.footstepsEnabled,
               !reduceMotion,
               let visit = footstepVisits[unit], visit.startedAt != nil {
                FootstepOverlayView(
                    visit: visit,
                    seed: StableHash.hash("\(model.book.id)|\(unit)|\(visit.visitID)"),
                    surfaces: overlayRects,
                    reservedRegions: overlayReserved,
                    size: size,
                    isDarkPaper: model.environment.invertsInk,
                    isPaused: pagingInProgress || zoomInProgress
                        || footstepGeometryTransition || scenePhase != .active
                )
                .id(visit.visitID)
                .opacity(footstepGeometryTransition ? 0 : 1)
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
        .contentShape(Rectangle())
        .simultaneousGesture(zoomGesture)
        .simultaneousGesture(panGesture, including: committedZoom > 1.01 ? .all : .subviews)
        .onTapGesture { point in
            handleTap(at: point, in: size)
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
