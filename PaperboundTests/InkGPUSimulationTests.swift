import CoreGraphics
import ImageIO
import MetalKit
import SwiftUI
import UIKit
import XCTest
@testable import Paperbound

@MainActor
final class InkGPUSimulationTests: XCTestCase {
    func testUserDuoRasterInitializesBothPagesWithoutFallback() async throws {
        let display = CGSize(width: 475, height: 670)
        let size = PageRenderScale.pixelSize(for: display, displayScale: 3, enchanted: true)
        let source = fixture()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        func resize(_ image: CGImage) -> CGImage {
            renderer.image { _ in UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size)) }.cgImage!
        }
        let page = PageRenderResult(image: resize(source.image),
            revealBackground: resize(source.revealBackground!), revealSeed: source.revealSeed)
        let first = try await InkGPUSession.prepare(page: page)
        let second = try await InkGPUSession.prepare(page: page)
        XCTAssertLessThanOrEqual(first.memoryCost + second.memoryCost, InkGPUBudget.limit)
        print("INK_DUO_ALIGNED_PREPARATION pixels=\(size) firstMS=\(first.initializationMilliseconds) secondMS=\(second.initializationMilliseconds)")
    }

    func testOccupiedGPUAdmissionFailsPromptlyInsteadOfWaitingForever() async throws {
        try InkGPUBudget.shared.reserve(1)
        try InkGPUBudget.shared.reserve(1)
        defer { InkGPUBudget.shared.release(1); InkGPUBudget.shared.release(1) }
        let start = ContinuousClock.now
        do {
            _ = try await InkGPUSession.prepare(page: fixture(), admissionTimeout: .milliseconds(30))
            XCTFail("An occupied admission pool must terminate preparation")
        } catch InkGPUError.budget {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testPreviewSelectionAndReplayRunFreshSimulation() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ink-preview-\(UUID()).pdf")
        try SampleLibrary.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let bookID = UUID()
        let engine = try PDFReadingEngine(documentID: bookID, fileURL: url, initialLocation: nil)
        try await engine.open()
        defer { engine.close() }
        let provider = PageImageProvider(engine: engine, bookID: bookID, bookSeed: 731)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        var environment = ReadingEnvironment.default
        var replay = 0
        var phase = ScenePhase.active
        var firstFrames: [InkPreparationIdentity] = []
        func preview() -> AnyView {
            AnyView(PhysicalPageView(
                location: .pdfPage(index: 0, yOffset: 0), environment: environment,
                provider: provider, spineShadowScale: 0, displaySize: CGSize(width: 104, height: 156),
                spine: .left, pageIdentity: "preview", isPreview: true, replayToken: replay,
                onFirstInkFrame: { firstFrames.append($0) }
            ).environment(\.scenePhase, phase))
        }
        let host = UIHostingController(rootView: preview())
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))
        for attempt in 0..<4 {
            if attempt == 2 { replay += 1 }
            if attempt == 3 {
                phase = .inactive
                host.rootView = preview()
                try await Task.sleep(for: .milliseconds(100))
                phase = .active
            }
            environment.ink = .enchanted
            host.rootView = preview()
            let deadline = Date().addingTimeInterval(3)
            while firstFrames.count <= attempt, Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(firstFrames.count, attempt + 1, "Preview attempt \(attempt) must draw actual simulated ink")
            let metal = try XCTUnwrap(metalViews(in: window).first)
            let coordinator = try XCTUnwrap(metal.delegate as? InkSimulationView.Coordinator)
            let session = try XCTUnwrap(coordinator.session)
            XCTAssertLessThan(session.steps, 20, "A new preview starts with paper, not completed pigment")
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertGreaterThan(session.steps, 20)
            XCTAssertLessThan(session.steps, InkGPUSession.totalSteps)
            try await Task.sleep(for: .seconds(3))
            XCTAssertEqual(session.steps, InkGPUSession.totalSteps)
            if attempt == 0 {
                environment.ink = .instant
                host.rootView = preview()
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertTrue(metalViews(in: window).isEmpty)
            }
        }
        XCTAssertEqual(Set(firstFrames.map(\.visit)).count, 4)
    }

    private func metalViews(in view: UIView) -> [MTKView] {
        (view as? MTKView).map { [$0] } ?? view.subviews.flatMap { metalViews(in: $0) }
    }

    func testOpenPageCanEnableDisableAndReenableProductionInk() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Ink is intentionally suppressed by Reduce Motion.")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ink-toggle-\(UUID()).pdf")
        try SampleLibrary.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let bookID = UUID()
        let engine = try PDFReadingEngine(documentID: bookID, fileURL: url, initialLocation: nil)
        try await engine.open()
        defer { engine.close() }
        let provider = PageImageProvider(engine: engine, bookID: bookID, bookSeed: 731)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let paperReady = expectation(description: "Instant page is open")
        var didPresentPaper = false
        var ready: XCTestExpectation?
        var finished: XCTestExpectation?
        var expectedVisit: UUID?
        var callbackVisits: [UUID] = []
        var host: UIHostingController<AnyView>!
        var environment = ReadingEnvironment.default
        func pageView(_ activation: PageRevealActivation?) -> AnyView {
            AnyView(PhysicalPageView(
                location: .pdfPage(index: 0, yOffset: 0), environment: environment,
                provider: provider, spineShadowScale: 0, displaySize: CGSize(width: 104, height: 156),
                spine: .left, pageIdentity: "page", revealActivation: activation,
                onImageReady: { identity, seed in
                    let visit = identity.visit
                    guard visit == expectedVisit else { return }
                    callbackVisits.append(visit)
                    ready?.fulfill(); ready = nil
                    host.rootView = pageView(PageRevealActivation(pageIdentity: identity.page, visitID: visit,
                        state: .revealing(startDate: Date(), durationSeconds: InkBehavior.enchanted.revealDurationSeconds(seed: seed))))
                },
                onRevealComplete: { identity, _ in
                    let visit = identity.visit
                    guard visit == expectedVisit else { return }
                    finished?.fulfill(); finished = nil
                },
                pageEffectVisitID: UUID(),
                onPaperReady: { _, _, _ in
                    guard !didPresentPaper else { return }
                    didPresentPaper = true
                    paperReady.fulfill()
                }
            ).environment(\.scenePhase, .active))
        }
        host = UIHostingController(rootView: pageView(nil))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; host = nil }
        await fulfillment(of: [paperReady], timeout: 5)
        for _ in 0..<2 {
            environment.ink = .enchanted
            let sequence = try XCTUnwrap(EnchantedInkRevealSequence.applyingInkChange(
                from: .instant, to: .enchanted, current: nil, unit: 0,
                pageIdentities: ["page"], animationsAllowed: true, at: Date()
            ))
            expectedVisit = sequence.visitID
            let initialized = expectation(description: "New visit initializes GPU")
            let complete = expectation(description: "New visit completes GPU ink")
            ready = initialized; finished = complete
            host.rootView = pageView(sequence.activation(for: "page"))
            await fulfillment(of: [initialized, complete], timeout: 8)
            environment.ink = .instant
            expectedVisit = nil
            host.rootView = pageView(nil)
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(Set(callbackVisits).count, 2, "Reenabling must initialize a fresh visit on the same page.")
    }

    func testUniformDispatchHandlesPartialEdgeGroups() async throws {
        let source = fixture()
        let bounds = CGRect(x: 0, y: 0, width: 95, height: 127)
        let page = PageRenderResult(image: try XCTUnwrap(source.image.cropping(to: bounds)),
            revealBackground: try XCTUnwrap(source.revealBackground?.cropping(to: bounds)), revealSeed: source.revealSeed)
        let session = try await InkGPUSession.prepare(page: page)
        print("INK_GPU_VALIDATION_DEVICE \(type(of: session.resources.device))")
        let blank = try await frame(session, at: 0)
        XCTAssertLessThanOrEqual(maxDifference(blank.bytes, rgba(page.revealBackground!)), 2)
        let finished = try await frame(session, at: 120)
        XCTAssertLessThanOrEqual(maxDifference(finished.bytes, rgba(page.image)), 2)
    }
    func testProductionMTKViewWaitsThenCompletesAndStops() async throws {
        let session = try await InkGPUSession.prepare(page: fixture())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let done = expectation(description: "GPU frame completion")
        var errors: [Error] = []
        let host = UIHostingController(rootView: InkSimulationView(session: session, startDate: nil,
            duration: 1.5, completion: { done.fulfill() }, failure: { errors.append($0) }))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.steps, 0, "Waiting must not advance the simulation.")
        host.rootView = InkSimulationView(session: session, startDate: Date(), duration: 1.5,
            completion: { done.fulfill() }, failure: { errors.append($0) })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(session.steps, InkGPUSession.totalSteps)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.steps, InkGPUSession.totalSteps)
    }

    func testFullResolutionSpreadBenchmark() async throws {
        let small = fixture()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 768, height: 1104), format: format)
        func enlarged(_ image: CGImage) -> CGImage {
            renderer.image { _ in UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: 768, height: 1104)) }.cgImage!
        }
        let page = PageRenderResult(image: enlarged(small.image),
            revealBackground: enlarged(small.revealBackground!), revealSeed: small.revealSeed)
        _ = try await InkGPUResources.prepared.value
        var initialization: [Double] = []
        for _ in 0..<20 {
            let session = try await InkGPUSession.prepare(page: page)
            initialization.append(session.initializationMilliseconds)
        }
        let first = try await InkGPUSession.prepare(page: page)
        let second = try await InkGPUSession.prepare(page: page)
        XCTAssertLessThanOrEqual(first.memoryCost + second.memoryCost, InkGPUBudget.limit)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: 768, height: 1104, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget]
        let targets = try (0..<2).map { _ in try XCTUnwrap(first.resources.device.makeTexture(descriptor: descriptor)) }
        var wall: [Double] = [], gpu: [Double] = []
        for _ in 0..<40 {
            let start = ProcessInfo.processInfo.systemUptime
            let command = try XCTUnwrap(first.resources.queue.makeCommandBuffer())
            for (index, session) in [first, second].enumerated() {
                try session.encodeSteps(3, into: command)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = targets[index]
                pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                try session.encodeRender(into: command, pass: pass)
            }
            try await InkGPUSession.submit(command)
            wall.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            gpu.append((command.gpuEndTime - command.gpuStartTime) * 1000)
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] }
        print("INK_GPU_FULL_RES_INIT_P95_MS \(p95(initialization)) samples=20")
        print("INK_GPU_SPREAD_FRAME_P95_MS wall=\(p95(wall)) gpu=\(p95(gpu)) stepsPerPage=3")
        print("INK_GPU_SPREAD_RESERVED_BYTES \(first.memoryCost + second.memoryCost) renderTargetsReported=\(targets.reduce(0) { $0 + $1.allocatedSize }) renderTargetLogicalBytes=6782976 uploadScratchPerPage=3391488")
    }

    func testActualGPUTransportDeterminismAndEndpoint() async throws {
        let page = fixture()
        var first: InkGPUSession? = try await InkGPUSession.prepare(page: page)
        var isolated: InkGPUSession? = try await InkGPUSession.prepare(page: page)
        isolated!.uniforms.transport = 0
        let blank = try await frame(first!, at: 0)
        XCTAssertLessThanOrEqual(maxDifference(blank.bytes, rgba(page.revealBackground!)), 2)
        let flowing = try await frame(first!, at: 24)
        let stopped = try await frame(isolated!, at: 24)
        XCTAssertGreaterThan(maxDifference(flowing.bytes, stopped.bytes), 5,
                             "Disabling neighbor exchange must change actual deposited pigment.")
        isolated = nil
        let repeated = try await InkGPUSession.prepare(page: page)
        let repeatFrame = try await frame(repeated, at: 24)
        XCTAssertEqual(flowing.bytes, repeatFrame.bytes)
        first = nil
        var previous = repeatFrame.bytes
        let target = rgba(page.image), paper = rgba(page.revealBackground!)
        for step in stride(from: 30, through: 120, by: 6) {
            let current = try await frame(repeated, at: step).bytes
            for i in current.indices where i % 4 != 3 {
                if target[i] < paper[i] { XCTAssertLessThanOrEqual(Int(current[i]), Int(previous[i]) + 2) }
                if target[i] > paper[i] { XCTAssertGreaterThanOrEqual(Int(current[i]), Int(previous[i]) - 2) }
                if target[i] == paper[i] { XCTAssertLessThanOrEqual(abs(Int(current[i]) - Int(paper[i])), 2) }
            }
            previous = current
        }
        XCTAssertLessThanOrEqual(maxDifference(previous, target), 2, "No final static-image snap.")
    }

    func testLightInkAndSeedVariationAndBounds() async throws {
        let page = fixture(dark: true)
        let first = try await InkGPUSession.prepare(page: page)
        let differentPage = PageRenderResult(image: page.image, revealBackground: page.revealBackground, revealSeed: 99)
        let second = try await InkGPUSession.prepare(page: differentPage)
        let firstMid = try await frame(first, at: 30)
        let secondMid = try await frame(second, at: 30)
        XCTAssertNotEqual(firstMid.bytes, secondMid.bytes)
        let end = try await frame(first, at: 120)
        XCTAssertLessThanOrEqual(maxDifference(end.bytes, rgba(page.image)), 2)
        XCTAssertLessThanOrEqual(InkGPUBudget.shared.allocatedBytes, InkGPUBudget.limit)
        XCTAssertThrowsError(try InkGPUBudget.shared.reserve(InkGPUBudget.limit))
    }

    func testMemoryLeaseReleasedAndCancellationBeforePreparation() async throws {
        let before = InkGPUBudget.shared.allocatedBytes
        var session: InkGPUSession? = try await InkGPUSession.prepare(page: fixture())
        XCTAssertGreaterThan(InkGPUBudget.shared.allocatedBytes, before)
        weak let reference = session
        session = nil
        // Metal completion callbacks may hold their command buffer until their
        // thread returns; no CPU/GPU polling is used in the production path.
        for _ in 0..<20 where reference != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(reference)
        XCTAssertEqual(InkGPUBudget.shared.allocatedBytes, before)
        let page = fixture()
        do {
            _ = try await InkGPUSession.prepare(page: PageRenderResult(
                image: page.image, revealBackground: nil, revealSeed: page.revealSeed))
            XCTFail("Missing pigment input must fail preparation")
        } catch InkGPUError.invalidImages {}
        XCTAssertEqual(InkGPUBudget.shared.allocatedBytes, before,
                       "Failed initialization must return its reserved GPU slot")
        // Exercise cancellation while GPU admission is blocked by a retiring
        // spread, rather than canceling an unrelated sleep before preparation.
        try InkGPUBudget.shared.reserve(1)
        try InkGPUBudget.shared.reserve(1)
        defer { InkGPUBudget.shared.release(1); InkGPUBudget.shared.release(1) }
        let task = Task { try await InkGPUSession.prepare(page: page) }
        try await Task.sleep(for: .milliseconds(25))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preparation was accepted") }
        catch is CancellationError {}
    }

    func testRealPageCapturesAndPreparationBenchmark() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ink-gpu-fixture.pdf")
        try SampleLibrary.write(to: url)
        let bookID = UUID(uuidString: "9A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
        let engine = try PDFReadingEngine(documentID: bookID, fileURL: url, initialLocation: nil)
        try await engine.open()
        defer { engine.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InkGPUValidation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        print("INK_GPU_CAPTURES \(folder.path)")
        var preparationMS: [Double] = []
        var initializationMS: [Double] = []
        let cases: [(String, ReadingEnvironment, Int)] = [
            ("text", .cleanPaper, 2), ("illustrated", .cleanPaper, engine.pageCount - 1),
            ("scanned-raster", .softCream, 2), ("damaged", .oldJournal, 2), ("dark", .nightPaper, 2)
        ]
        for (name, base, index) in cases {
            var environment = base; environment.ink = .enchanted
            if name == "damaged" { environment.condition = .damaged; environment.intensity = 0.85 }
            let location = ReadingLocation.pdfPage(index: index, yOffset: 0)
            var content = try await engine.renderPage(at: location, pixelSize: CGSize(width: 360, height: 540))
            if name == "scanned-raster" {
                // An actual image-only PDF fixture: no selectable text/OCR.
                let scannedURL = FileManager.default.temporaryDirectory.appendingPathComponent("ink-image-only.pdf")
                let bounds = CGRect(x: 0, y: 0, width: 360, height: 540)
                try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: scannedURL) { context in
                    context.beginPage(); UIImage(cgImage: content).draw(in: bounds)
                }
                let scanned = try PDFReadingEngine(documentID: UUID(), fileURL: scannedURL, initialLocation: nil)
                try await scanned.open()
                content = try await scanned.renderPage(at: .pdfPage(index: 0, yOffset: 0), pixelSize: bounds.size)
                XCTAssertTrue(scanned.text(at: .pdfPage(index: 0, yOffset: 0))?.isEmpty ?? true)
                scanned.close()
            }
            let request = PageCompositionRequest(content: content, pixelSize: CGSize(width: 360, height: 540),
                environment: environment,
                condition: DamageGenerator.generate(documentID: bookID, bookSeed: 123,
                    stablePageID: engine.stablePageID(for: location), environment: environment, spine: .left),
                spine: .left, textureSeed: 7300191)
            let start = ProcessInfo.processInfo.systemUptime
            let page = try await Task.detached { try await PageCompositor.shared.compositePage(request) }.value
            preparationMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let session = try await InkGPUSession.prepare(page: page)
            initializationMS.append(session.initializationMilliseconds)
            for (label, step) in [("000", 0), ("025", 30), ("050", 60), ("075", 90), ("0985", 120), ("100", 120)] {
                let capture = try await frame(session, at: step)
                try UIImage(cgImage: capture.image).pngData()!.write(to: folder.appendingPathComponent("\(name)-\(label).png"))
                if name == "text", let crop = capture.image.cropping(to: CGRect(x: 40, y: 80, width: 280, height: 150)) {
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let enlarged = UIGraphicsImageRenderer(size: CGSize(width: 1120, height: 600), format: format).image { _ in
                        UIImage(cgImage: crop).draw(in: CGRect(x: 0, y: 0, width: 1120, height: 600))
                    }
                    try enlarged.pngData()!.write(to: folder.appendingPathComponent("text-detail-\(label).png"))
                }
                if step == 120 {
                    XCTAssertLessThanOrEqual(maxDifference(capture.bytes, rgba(page.image)), 3, name)
                }
            }
        }
        print("INK_GPU_PREPARATION_MS \(preparationMS)")
        print("INK_GPU_INITIALIZATION_MS \(initializationMS)")
    }

    private func fixture(dark: Bool = false) -> PageRenderResult {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 128), format: format)
        let paper = renderer.image { c in
            (dark ? UIColor(red: 0.08, green: 0.10, blue: 0.13, alpha: 1) : .white).setFill()
            c.fill(CGRect(x: 0, y: 0, width: 96, height: 128))
            UIColor.gray.setFill(); c.fill(CGRect(x: 2, y: 2, width: 10, height: 5))
        }
        let print = renderer.image { c in
            paper.draw(at: .zero)
            (dark ? UIColor(red: 0.9, green: 0.7, blue: 0.5, alpha: 1) : .black).setStroke()
            c.cgContext.setLineWidth(5)
            c.cgContext.stroke(CGRect(x: 20, y: 23, width: 24, height: 82))
            c.cgContext.move(to: CGPoint(x: 20, y: 60)); c.cgContext.addLine(to: CGPoint(x: 42, y: 60)); c.cgContext.strokePath()
            UIColor(red: 0.15, green: 0.4, blue: 0.7, alpha: 1).setFill()
            c.fill(CGRect(x: 61, y: 40, width: 20, height: 50))
        }
        return PageRenderResult(image: print.cgImage!, revealBackground: paper.cgImage!, revealSeed: 7300191)
    }

    private func frame(_ session: InkGPUSession, at step: Int) async throws -> (bytes: [UInt8], image: CGImage) {
        let device = session.resources.device
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: session.paper.width, height: session.paper.height, mipmapped: false)
        d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: d))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(session.resources.queue.makeCommandBuffer())
        try session.encodeSteps(step - session.steps, into: command)
        try session.encodeRender(into: command, pass: pass)
        try await InkGPUSession.submit(command)
        var bgra = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bgra, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        for offset in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(offset, offset + 2) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bgra) as CFData))
        let image = try XCTUnwrap(CGImage(width: texture.width, height: texture.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: texture.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return (bgra, image)
    }
    private func rgba(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a,b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
}
