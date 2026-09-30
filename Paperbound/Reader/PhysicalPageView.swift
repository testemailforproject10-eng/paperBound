import CoreGraphics
import SwiftUI

struct PhysicalPageView: View {
    let location: ReadingLocation
    let environment: ReadingEnvironment
    let provider: PageImageProvider
    let spineShadowScale: Double
    let displaySize: CGSize
    let spine: PageEdge
    var pageIdentity: String?
    var safeFraction: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var reservedRegions: [CGRect] = []
    var pageRequest: PageImageRequest?
    var isPreview = false
    var isPageVisible = true
    var revealActivation: PageRevealActivation?
    var replayToken = 0
    var onImageReady: ((InkPreparationIdentity, UInt64) -> Void)?
    var onRevealComplete: ((InkPreparationIdentity, Date) -> Void)?
    var onFirstInkFrame: ((InkPreparationIdentity) -> Void)?
    var footstepVisitID: UUID?
    var onPaperReady: ((String, String, UUID) -> Void)?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: PageRenderResult?
    @State private var preparedPaper: CGImage?
    @State private var loadedRenderToken: String?
    @State private var failure: String?
    @State private var session: InkGPUSession?
    @State private var sessionKey: String?
    @State private var sessionIdentity: InkPreparationIdentity?
    @State private var currentIdentity: InkPreparationIdentity?
    @State private var previewVisit = UUID()
    @State private var previewStart: Date?
    @State private var completed = false
    @State private var gpuFailed = false
    @State private var suppressed = false

    private var imageRequest: PageImageRequest {
        pageRequest ?? PageImageRequest(
            location: location,
            pixelSize: PageRenderScale.pixelSize(for: displaySize, displayScale: displayScale,
                                                enchanted: environment.ink == .enchanted),
            spineShadowScale: spineShadowScale, spine: spine,
            safeFraction: safeFraction, reservedRegions: reservedRegions
        )
    }
    private var renderToken: String { provider.requestIdentifier(for: imageRequest, environment: environment) }
    private var state: PageRevealState {
        if isPreview {
            if completed || suppressed { return .finished }
            if let previewStart, let page {
                return .revealing(startDate: previewStart,
                                  durationSeconds: InkBehavior.enchanted.revealDurationSeconds(seed: page.revealSeed))
            }
            return .waiting
        }
        return revealActivation?.state ?? .finished
    }
    private var wantsSimulation: Bool {
        environment.ink == .enchanted && state != .finished && !completed && !suppressed
            && !reduceMotion && scenePhase == .active
    }
    private var visitToken: String {
        isPreview ? "preview:\(renderToken):\(replayToken)" : revealActivation?.visitID.uuidString ?? "static"
    }
    private var preparationIdentity: InkPreparationIdentity {
        InkPreparationIdentity(page: pageIdentity ?? "preview", render: renderToken,
                               visit: revealActivation?.visitID ?? previewVisit)
    }
    private var simulationKey: String {
        "\(renderToken)|\(preparationIdentity.visit)|\(visitToken)|\(loadedRenderToken ?? "unloaded")|\(page != nil)|\(wantsSimulation)|\(currentIdentity == preparationIdentity)"
    }

    var body: some View {
        ZStack {
            if let page, loadedRenderToken == renderToken {
                content(page)
            } else if let preparedPaper {
                image(preparedPaper)
                    .onAppear { InkMetrics.event("First paper presentation") }
                loading
            } else {
                Color.white
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).padding()
                } else { loading }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .task(id: "\(renderToken)|\(isPageVisible)") { await loadPage() }
        .task(id: simulationKey) { await prepareSimulation() }
        .task(id: "\(visitToken)|\(gpuFailed)|\(String(describing: state))") {
            // Failure shows finished content immediately, but the pager still
            // receives a valid completion for this visit at its own deadline.
            guard gpuFailed, case .revealing(let start, let duration) = state else { return }
            do { try await Task.sleep(for: .seconds(max(0, duration - Date().timeIntervalSince(start)))) }
            catch { return }
            finish()
        }
        .onChange(of: preparationIdentity, initial: true) { _, identity in
            currentIdentity = identity
            session = nil; sessionKey = nil; sessionIdentity = nil
        }
        .onChange(of: visitToken) { _, _ in
            completed = false; gpuFailed = false; suppressed = false; previewStart = nil
            if isPreview { resetPreview() }
        }
        .onAppear {
            if isPreview { resetPreview() }
            reportPaperReady()
        }
        .onChange(of: footstepVisitID) { _, _ in reportPaperReady() }
        .onChange(of: loadedRenderToken) { _, _ in reportPaperReady() }
        .onChange(of: revealActivation) { _, activation in
            if activation?.state == .finished { session = nil; sessionKey = nil }
            reportReady()
        }
        .onChange(of: reduceMotion) { _, value in if value { finishImmediately() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { finishImmediately() }
            else if isPreview { resetPreview() }
        }
        .onDisappear { session = nil; sessionKey = nil }
    }

    @ViewBuilder private func content(_ page: PageRenderResult) -> some View {
        if wantsSimulation, !gpuFailed, let background = page.revealBackground {
            if let session, sessionKey == simulationKey {
                let timing = timingForState
                let identity = preparationIdentity
                InkSimulationView(session: session, startDate: timing.start, duration: timing.duration,
                                  completion: { if currentIdentity == identity { finish() } },
                                  failure: { if currentIdentity == identity { failGPU($0) } },
                                  firstFrame: { if currentIdentity == identity { onFirstInkFrame?(identity) } })
                    .id(simulationKey)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .allowsHitTesting(false)
            } else { image(background).onAppear { InkMetrics.event("First paper presentation") } }
            if state == .waiting { loading }
        } else {
            image(page.image).onAppear { InkMetrics.event("Finished page presentation") }
        }
    }

    private var timingForState: (start: Date?, duration: Double) {
        if case .revealing(let start, let duration) = state { return (start, duration) }
        return (nil, 3.5)
    }
    private var loading: some View {
        ProgressView().controlSize(.small).tint(environment.material.fiberColor.swiftUIColor)
    }
    private func image(_ value: CGImage) -> some View {
        Image(decorative: value, scale: 1).resizable().interpolation(.high)
            .frame(width: displaySize.width, height: displaySize.height)
    }

    private func loadPage() async {
        guard displaySize.width > 1, displaySize.height > 1 else { return }
        let token = renderToken
        if loadedRenderToken == token, page != nil { reportPaperReady(); return }
        session = nil; sessionKey = nil; previewStart = nil
        completed = false; gpuFailed = false; suppressed = false
        preparedPaper = nil; failure = nil
        loadedRenderToken = nil
        page = provider.cachedPage(for: imageRequest, environment: environment)
        if page != nil {
            loadedRenderToken = token
            reportPaperReady()
            return
        }
        guard isPageVisible else { return }
        do {
            // Initial safe-area/spread layout can change several times in one
            // frame. Cancel superseded geometry before starting expensive work.
            try await Task.sleep(for: .milliseconds(80))
            let result = try await provider.page(for: imageRequest, environment: environment) { paper in
                guard renderToken == token else { return }
                preparedPaper = paper
                loadedRenderToken = token
                reportPaperReady()
            }
            guard !Task.isCancelled, renderToken == token else { return }
            page = result; preparedPaper = nil
            loadedRenderToken = token
            reportPaperReady()
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, renderToken == token else { return }
            preparedPaper = nil; failure = error.localizedDescription
        }
    }

    private func prepareSimulation() async {
        let key = simulationKey
        InkMetrics.trace("Prepare page=\(preparationIdentity.page) visit=\(preparationIdentity.visit) wants=\(wantsSimulation) loaded=\(loadedRenderToken == renderToken) identity=\(currentIdentity == preparationIdentity) page=\(page != nil)")
        session = nil; sessionKey = nil
        let identity = preparationIdentity
        guard wantsSimulation, let page, !gpuFailed,
              loadedRenderToken == renderToken, currentIdentity == identity else { return }
        do {
            let built = try await InkGPUSession.prepare(page: page)
            guard !Task.isCancelled, simulationKey == key, currentIdentity == identity else { return }
            session = built; sessionKey = key; sessionIdentity = identity
            InkMetrics.event("Simulation ready")
            if isPreview { previewStart = Date() }
            reportReady()
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, simulationKey == key, currentIdentity == identity else { return }
            failGPU(error)
        }
    }

    private func reportReady() {
        guard let activation = revealActivation, activation.state == .waiting,
              let page, loadedRenderToken == renderToken,
              currentIdentity == preparationIdentity,
              (session != nil && sessionIdentity == preparationIdentity) || gpuFailed || reduceMotion else { return }
        onImageReady?(preparationIdentity, page.revealSeed)
    }
    private func reportPaperReady() {
        guard isPageVisible,
              let footstepVisitID,
              let pageIdentity,
              loadedRenderToken == renderToken,
              preparedPaper != nil || page != nil else { return }
        InkMetrics.trace("Footsteps paper ready \(pageIdentity) visit=\(footstepVisitID)")
        onPaperReady?(pageIdentity, renderToken, footstepVisitID)
    }
    private func failGPU(_ error: Error) {
        InkMetrics.trace("GPU fallback page=\(preparationIdentity.page) render=\(renderToken) visit=\(preparationIdentity.visit) error=\(error.localizedDescription)")
        NSLog("Enchanted Ink fallback: %@", error.localizedDescription)
        session = nil; sessionKey = nil; gpuFailed = true
        if isPreview { completed = true }
        reportReady()
    }
    private func resetPreview() {
        // A replay/selection/return to the thumbnail is a new simulation, even
        // when its immutable page images came from the cache.
        previewVisit = UUID(); previewStart = nil
        completed = false; gpuFailed = false; suppressed = false
        session = nil; sessionKey = nil; sessionIdentity = nil
    }
    private func finishImmediately() {
        suppressed = true; completed = true; session = nil; sessionKey = nil
    }
    private func finish() {
        completed = true; session = nil; sessionKey = nil
        guard let activation = revealActivation,
              case .revealing(let start, _) = activation.state else { return }
        onRevealComplete?(preparationIdentity, start)
    }
}
