import CoreGraphics
import Foundation
import MetalKit
import SwiftUI

enum InkGPUError: LocalizedError {
    case unavailable, allocation, invalidImages, budget, oversized, command(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Metal ink rendering is unavailable."
        case .allocation: return "Ink textures could not be allocated."
        case .invalidImages: return "Ink input images do not match."
        case .budget: return "The active ink texture budget is full."
        case .oversized: return "This page exceeds the ink texture budget at its minimum resolution."
        case .command(let message): return "Ink GPU command failed: \(message)"
        }
    }
}

/// Shared admission control includes uploaded images, both state buffers, and
/// moisture. Drawables belong to MTKView and are measured separately.
final class InkGPUBudget: @unchecked Sendable {
    static let shared = InkGPUBudget()
    static let limit = 64 * 1024 * 1024
    private let lock = NSLock()
    private var bytes = 0
    private var sessions = 0
    var allocatedBytes: Int { lock.withLock { bytes } }
    func reserve(_ cost: Int) throws {
        try lock.withLock {
            guard sessions < 2, cost <= Self.limit - bytes else { throw InkGPUError.budget }
            bytes += cost; sessions += 1
        }
    }
    func release(_ cost: Int) { lock.withLock { bytes -= cost; sessions -= 1 } }
}

final class InkGPUResources: @unchecked Sendable {
    static let prepared = Task.detached(priority: .userInitiated) { try InkGPUResources() }
    static func prewarm() { _ = prepared }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let clear: MTLComputePipelineState
    let initialize: MTLComputePipelineState
    let moisture: MTLComputePipelineState
    let deposit: MTLComputePipelineState
    let render: MTLRenderPipelineState

    private init() throws {
        let timing = InkMetrics.begin("Metal pipeline prewarm")
        defer { InkMetrics.end("Metal pipeline prewarm", timing) }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { throw InkGPUError.unavailable }
        self.device = device; self.queue = queue
        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw InkGPUError.unavailable }
            return try device.makeComputePipelineState(function: function)
        }
        clear = try compute("inkClear")
        initialize = try compute("inkInitialize")
        moisture = try compute("inkMoisture")
        deposit = try compute("inkDeposit")
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "inkVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "inkFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        render = try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

struct InkGPUUniforms {
    var seed: UInt32
    var transport: UInt32 = 1
    var width: UInt32
    var height: UInt32
}

/// Shared by raster sizing and allocation, including row alignment and the
/// temporary uploaded finished image. A pixel-count cap alone misses padding.
struct InkTextureLayout {
    let moistureWidth: Int
    let moistureHeight: Int
    let reservedBytes: Int

    init(width: Int, height: Int) {
        let scale = min(1, 512.0 / Double(max(width, height)))
        moistureWidth = max(1, Int(Double(width) * scale))
        moistureHeight = max(1, Int(Double(height) * scale))
        func cost(_ w: Int, _ h: Int, _ bpp: Int) -> Int { ((w * bpp + 255) / 256 * 256) * h }
        reservedBytes = cost(width, height, 4) * 2 + cost(width, height, 2) * 2
            + cost(width, height, 8) * 3 + cost(moistureWidth, moistureHeight, 2) * 2 + 65536 * 9
    }
    var fitsSpread: Bool { reservedBytes <= InkGPUBudget.limit / 2 }
}

/// A session is owned by one visit. Initialization runs off-main; subsequent
/// encoding is serial (the shared display scheduler or a test's fixed clock).
final class InkGPUSession: @unchecked Sendable {
    static let totalSteps = 120
    let resources: InkGPUResources
    let paper: MTLTexture
    private var uploadedFinished: MTLTexture?
    let targets: MTLTexture
    let moisture: [MTLTexture]
    let mobile: [MTLTexture]
    let deposited: [MTLTexture]
    let memoryCost: Int
    private(set) var initializationMilliseconds = 0.0
    private(set) var steps = 0
    private var bufferIndex = 0
    var uniforms: InkGPUUniforms

    static func prepare(page: PageRenderResult, admissionTimeout: Duration = .seconds(1)) async throws -> InkGPUSession {
        let resources = try await InkGPUResources.prepared.value
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            let layout = InkTextureLayout(width: page.image.width, height: page.image.height)
            guard layout.fitsSpread else { throw InkGPUError.oversized }
            // A canceled visit's command buffer can retain its textures until
            // completion. Wait for that lease rather than skip the next effect.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: admissionTimeout)
            let admissionTiming = InkMetrics.begin("GPU admission wait")
            do {
                while true {
                    try Task.checkCancellation()
                    do {
                        try InkGPUBudget.shared.reserve(layout.reservedBytes)
                        break
                    } catch InkGPUError.budget {
                        // Retiring work releases promptly. Retained/offscreen
                        // work must not leave the reader waiting indefinitely.
                        guard clock.now < deadline else { throw InkGPUError.budget }
                        try await Task.sleep(for: .milliseconds(8))
                    }
                }
            } catch {
                InkMetrics.end("GPU admission wait", admissionTiming)
                throw error
            }
            InkMetrics.end("GPU admission wait", admissionTiming)
            let timing = InkMetrics.begin("GPU initialization")
            defer { InkMetrics.end("GPU initialization", timing) }
            let session: InkGPUSession
            do {
                try Task.checkCancellation()
                session = try InkGPUSession(page: page, resources: resources, layout: layout)
            } catch {
                // Ownership transfers to the session only after initialization.
                InkGPUBudget.shared.release(layout.reservedBytes)
                throw error
            }
            guard let command = resources.queue.makeCommandBuffer() else { throw InkGPUError.allocation }
            guard let initializer = command.makeComputeCommandEncoder() else { throw InkGPUError.allocation }
            initializer.setComputePipelineState(resources.initialize)
            initializer.setTexture(session.paper, index: 0)
            initializer.setTexture(session.uploadedFinished, index: 1)
            initializer.setTexture(session.targets, index: 2)
            session.dispatch(initializer, width: session.paper.width, height: session.paper.height)
            initializer.endEncoding()
            for texture in session.moisture + session.mobile + session.deposited {
                guard let encoder = command.makeComputeCommandEncoder() else { throw InkGPUError.allocation }
                encoder.setComputePipelineState(resources.clear)
                encoder.setTexture(texture, index: 0)
                session.dispatch(encoder, width: texture.width, height: texture.height)
                encoder.endEncoding()
            }
            try await submit(command)
            session.uploadedFinished = nil
            session.initializationMilliseconds = (ProcessInfo.processInfo.systemUptime - timing.1) * 1000
            return session
        }
        return try await withTaskCancellationHandler {
            let session = try await task.value
            try Task.checkCancellation()
            return session
        } onCancel: { task.cancel() }
    }

    private init(page: PageRenderResult, resources: InkGPUResources, layout: InkTextureLayout) throws {
        guard let background = page.revealBackground,
              background.width == page.image.width, background.height == page.image.height
        else { throw InkGPUError.invalidImages }
        self.resources = resources
        let width = page.image.width, height = page.image.height
        uniforms = InkGPUUniforms(seed: UInt32(truncatingIfNeeded: page.revealSeed ^ (page.revealSeed >> 32)),
                                  width: UInt32(width), height: UInt32(height))
        let wetWidth = layout.moistureWidth, wetHeight = layout.moistureHeight
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, uploaded: Bool = false) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.storageMode = uploaded ? .shared : .private
            d.usage = uploaded ? [.shaderRead] : [.shaderRead, .shaderWrite]
            guard let t = resources.device.makeTexture(descriptor: d) else { throw InkGPUError.allocation }
            return t
        }
        // Admission already reserved this aligned upper bound.
        let reserved = layout.reservedBytes
        paper = try texture(.rgba8Unorm_srgb, width, height, uploaded: true)
        let finished = try texture(.rgba8Unorm_srgb, width, height, uploaded: true)
        uploadedFinished = finished
        targets = try texture(.rgba16Float, width, height)
        moisture = try (0..<2).map { _ in try texture(.r16Float, wetWidth, wetHeight) }
        mobile = try (0..<2).map { _ in try texture(.r16Float, width, height) }
        deposited = try (0..<2).map { _ in try texture(.rgba16Float, width, height) }
        let actual = ([paper, finished, targets] + moisture + mobile + deposited).reduce(0) { $0 + $1.allocatedSize }
        guard actual <= reserved else { throw InkGPUError.oversized }
        let uploadTiming = InkMetrics.begin("Texture upload")
        try Self.upload(background, to: paper)
        try Self.upload(page.image, to: finished)
        InkMetrics.end("Texture upload", uploadTiming)
        memoryCost = reserved
    }

    deinit { InkGPUBudget.shared.release(memoryCost) }

    private static func upload(_ image: CGImage, to texture: MTLTexture) throws {
        let row = image.width * 4
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: row,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw InkGPUError.allocation }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: row)
    }

    func encodeSteps(_ count: Int, into command: MTLCommandBuffer) throws {
        for _ in 0..<min(max(0, count), Self.totalSteps - steps) {
            let next = 1 - bufferIndex
            guard let wet = command.makeComputeCommandEncoder() else { throw InkGPUError.allocation }
            wet.setComputePipelineState(resources.moisture)
            wet.setTexture(moisture[bufferIndex], index: 0); wet.setTexture(moisture[next], index: 1)
            wet.setBytes(&uniforms, length: MemoryLayout<InkGPUUniforms>.stride, index: 0)
            dispatch(wet, width: moisture[0].width, height: moisture[0].height)
            wet.endEncoding()
            guard let ink = command.makeComputeCommandEncoder() else { throw InkGPUError.allocation }
            ink.setComputePipelineState(resources.deposit)
            ink.setTexture(targets, index: 0)
            for (offset, texture) in [mobile[bufferIndex], deposited[bufferIndex], moisture[next],
                                      mobile[next], deposited[next]].enumerated() {
                ink.setTexture(texture, index: offset + 2)
            }
            ink.setBytes(&uniforms, length: MemoryLayout<InkGPUUniforms>.stride, index: 0)
            dispatch(ink, width: paper.width, height: paper.height)
            ink.endEncoding()
            bufferIndex = next; steps += 1
        }
    }

    func encodeRender(into command: MTLCommandBuffer, pass: MTLRenderPassDescriptor) throws {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw InkGPUError.allocation }
        encoder.setRenderPipelineState(resources.render)
        encoder.setFragmentTexture(paper, index: 0)
        encoder.setFragmentTexture(deposited[bufferIndex], index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        // dispatchThreads requires nonuniform-threadgroup support. The Duo
        // simulator can reject it with an API-validation assertion, stopping
        // preparation before either page becomes ready. Every kernel guards its
        // texture bounds, so round up uniform groups on all supported devices.
        encoder.dispatchThreadgroups(MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }

    static func submit(_ command: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { buffer in
                if let error = buffer.error { continuation.resume(throwing: InkGPUError.command(error.localizedDescription)) }
                else { continuation.resume() }
            }
            command.commit()
        }
    }
}

@MainActor
private final class InkDisplayScheduler: NSObject {
    static let shared = InkDisplayScheduler()
    private var clients = NSHashTable<InkSimulationView.Coordinator>.weakObjects()
    private var link: CADisplayLink?
    func add(_ client: InkSimulationView.Coordinator) {
        clients.add(client)
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }
    func remove(_ client: InkSimulationView.Coordinator) {
        clients.remove(client)
        if clients.allObjects.isEmpty { link?.invalidate(); link = nil }
    }
    @objc private func tick() { for client in clients.allObjects { client.tick() } }
}

struct InkSimulationView: UIViewRepresentable {
    let session: InkGPUSession
    let startDate: Date?
    let duration: Double
    let completion: () -> Void
    let failure: (Error) -> Void
    var firstFrame: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: session.resources.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: session.paper.width, height: session.paper.height)
        view.isOpaque = false; view.backgroundColor = .clear
        view.isPaused = true; view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        c.session = session; c.start = startDate; c.duration = duration
        c.completion = completion; c.failure = failure; c.firstFrame = firstFrame
        if startDate != nil { InkDisplayScheduler.shared.add(c) }
        else { InkDisplayScheduler.shared.remove(c); view.draw() }
    }
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.cancelled = true
        InkDisplayScheduler.shared.remove(coordinator)
        view.delegate = nil; coordinator.session = nil
    }
    @MainActor final class Coordinator: NSObject, MTKViewDelegate {
        weak var view: MTKView?
        var session: InkGPUSession?
        var start: Date?
        var duration = 3.5
        var firstFrame: (() -> Void)?
        var completion: (() -> Void)?
        var failure: ((Error) -> Void)?
        var busy = false
        var cancelled = false
        private var firstInk = false
        func tick() { if !busy && !cancelled { view?.draw() } }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // SwiftUI can first update a waiting MTKView before it has a size.
            // Present paper after layout even though no display link is running.
            Task { @MainActor [weak self] in self?.tick() }
        }
        func draw(in view: MTKView) {
            guard !busy, !cancelled, let session,
                  let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
            guard let command = session.resources.queue.makeCommandBuffer() else {
                InkDisplayScheduler.shared.remove(self); failure?(InkGPUError.allocation); return
            }
            busy = true
            do {
                if let start {
                    let elapsed = max(0, Date().timeIntervalSince(start))
                    let wanted = min(InkGPUSession.totalSteps, Int(elapsed / (duration * 0.985) * Double(InkGPUSession.totalSteps)))
                    try session.encodeSteps(min(4, max(0, wanted - session.steps)), into: command)
                }
                try session.encodeRender(into: command, pass: pass)
                command.present(drawable)
                command.addCompletedHandler { [weak self] buffer in
                    let error = buffer.error
                    Task { @MainActor in
                        guard let self, !self.cancelled else { return }
                        self.busy = false
                        if let error {
                            InkDisplayScheduler.shared.remove(self)
                            self.failure?(error)
                        } else {
                            if !self.firstInk, session.steps > 0 {
                                self.firstInk = true; InkMetrics.event("First ink presentation"); self.firstFrame?()
                            }
                            if session.steps == InkGPUSession.totalSteps,
                               let start = self.start, Date().timeIntervalSince(start) >= self.duration {
                                InkDisplayScheduler.shared.remove(self)
                                self.completion?()
                            }
                        }
                    }
                }
                command.commit()
            } catch {
                busy = false; InkDisplayScheduler.shared.remove(self); failure?(error)
            }
        }
    }
}
