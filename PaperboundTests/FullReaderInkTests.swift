import MetalKit
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import Paperbound

@MainActor final class FullReaderInkTests: XCTestCase {
    func testSettingsPickerStartsVisiblePreviewAndReplaysAfterReturn() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let container = try ModelContainer(for: Book.self, Bookmark.self, Highlight.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LibraryStore.unavailable()
        let name = "preview-controls-\(UUID()).pdf"
        let book = Book(title: "Preview regression", fileName: name, format: .pdf, contentFingerprint: name)
        let file = store.fileURL(for: book)
        try SampleLibrary.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        container.mainContext.insert(book)
        let suite = "preview-controls-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = ReaderViewModel(book: book, settings: settings, store: store, context: container.mainContext)
        await model.load()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ReaderView(book: book, model: model)
            .environment(settings).environment(LibraryEnvironment(store: store))
            .modelContainer(container).environment(\.scenePhase, .active))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; model.unload() }
        try await wait(model, "initial settlement") { model.paging.settledUnit == 0 }
        model.activePanel = .environment
        try await Task.sleep(for: .milliseconds(600))
        let picker = try XCTUnwrap(allSubviews(window).compactMap { $0 as? UISegmentedControl }.first)
        XCTAssertEqual(picker.selectedSegmentIndex, 0)
        // Drive the actual settings control, not a hand-created page activation.
        picker.selectedSegmentIndex = 1
        picker.sendActions(for: .valueChanged)
        try await wait(model, "settings control updates effect") { model.environment.ink == .enchanted }
        func previewCoordinator() -> InkSimulationView.Coordinator? {
            allSubviews(window).compactMap { $0 as? MTKView }
                .first(where: { $0.bounds.width < 200 })?.delegate as? InkSimulationView.Coordinator
        }
        try await wait(model, "preview starts GPU") { (previewCoordinator()?.session?.steps ?? 0) > 0 }
        do {
            let coordinator = try XCTUnwrap(previewCoordinator())
            let metal = try XCTUnwrap(coordinator.view)
            let frame = metal.convert(metal.bounds, to: window)
            XCTAssertTrue(window.bounds.contains(frame), "The preview must stay on screen while selecting its effect")
            // Check the enclosing list's viewport too: a view can be inside the
            // window but clipped outside the half-height settings sheet.
            var ancestor = metal.superview
            while let view = ancestor {
                if view is UIScrollView {
                    XCTAssertTrue(view.bounds.contains(metal.convert(metal.bounds, to: view)),
                                  "Selecting ink must not require scrolling the preview away")
                }
                ancestor = view.superview
            }
            let first = try XCTUnwrap(coordinator.session)
            XCTAssertLessThan(first.steps, 20)
            let blank = try await capturePreview(first, name: "Preview starts on paper")
            XCTAssertTrue(blank.allSatisfy { $0 >= 252 }, "The first simulated frame must be blank paper")
            try await Task.sleep(for: .milliseconds(900))
            XCTAssertGreaterThan(first.steps, 20)
            XCTAssertLessThan(first.steps, 65)
            let partial = try await capturePreview(first, name: "Preview pigment at one second")
            XCTAssertEqual(model.paging.visitCount, 0, "The reader waits while its preview animates")
            try await wait(model, "preview completes") { first.steps == InkGPUSession.totalSteps }
            let finished = try await capturePreview(first, name: "Preview finished print")
            let printChannels = finished.indices.filter { $0 % 4 != 3 && finished[$0] < 240 }
            XCTAssertFalse(printChannels.isEmpty)
            let absorbing = printChannels.filter { Int(partial[$0]) > Int(finished[$0]) + 8 && partial[$0] < 247 }
            XCTAssertGreaterThan(absorbing.count, printChannels.count / 10,
                                 "Real preview print must contain substantial partially deposited ink")
        } // Release the captured session before allocating a full spread.
        // Dismiss and reopen the real sheet with Enchanted Ink still selected.
        model.activePanel = nil
        try await wait(model, "reader completes after dismissal") { model.paging.completedVisits == 1 }
        model.activePanel = .environment
        try await wait(model, "reopened preview starts") { (previewCoordinator()?.session?.steps ?? 0) > 0 }
        let second = try XCTUnwrap(previewCoordinator()?.session)
        XCTAssertLessThan(second.steps, 20)
        model.activePanel = nil
        try await Task.sleep(for: .milliseconds(400))
    }

    private func capturePreview(_ session: InkGPUSession, name: String) async throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: session.paper.width, height: session.paper.height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget]
        let texture = try XCTUnwrap(session.resources.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(session.resources.queue.makeCommandBuffer())
        try session.encodeRender(into: command, pass: pass)
        try await InkGPUSession.submit(command)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        let image = try XCTUnwrap(CGImage(width: texture.width, height: texture.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: texture.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        return bytes
    }

    func testSettingsDismissalEdgeNavigationAndSliderThroughFullReader() async throws {
        try await exerciseReader(initiallyEnchanted: false, compact: false)
    }
    func testInitialOpeningAndNavigationAtPhoneSize() async throws {
        try await exerciseReader(initiallyEnchanted: true, compact: true)
    }
    private func exerciseReader(initiallyEnchanted: Bool, compact: Bool) async throws {
        setenv("PAPERBOUND_INK_TRACE", "1", 1)
        defer { unsetenv("PAPERBOUND_INK_TRACE") }
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let container = try ModelContainer(for: Book.self, Bookmark.self, Highlight.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let store = LibraryStore.unavailable()
        let name = "reader-navigation-\(UUID()).pdf"
        let book = Book(title: "Navigation regression", fileName: name, format: .pdf, contentFingerprint: name)
        let file = store.fileURL(for: book)
        try SampleLibrary.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        context.insert(book)
        let suite = "reader-navigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        if initiallyEnchanted { settings.defaultEnvironment.ink = .enchanted }
        let model = ReaderViewModel(book: book, settings: settings, store: store, context: context)
        await model.load()
        XCTAssertNil(model.loadError)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ReaderView(book: book, model: model)
            .environment(settings).environment(LibraryEnvironment(store: store))
            .modelContainer(container).environment(\.scenePhase, .active)
            .frame(width: compact ? 390 : nil, height: compact ? 844 : nil))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; model.unload() }
        let openingStart = ProcessInfo.processInfo.systemUptime
        try await wait(model, "initial page settles") { model.paging.settledUnit == 0 && model.lastSurfaceSize.width > 0 }
        try await Task.sleep(for: .milliseconds(500))
        if !initiallyEnchanted {
            model.activePanel = .environment
            try await Task.sleep(for: .milliseconds(500))
            model.environment.ink = .enchanted
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(model.paging.pendingReplay)
            XCTAssertEqual(model.paging.visitCount, 0, "The full page must wait for settings dismissal")
            model.activePanel = nil
        }
        try await wait(model, "settings starts visible GPU ink") { !model.paging.firstFrames.isEmpty }
        print("READER_FIRST_INK_MS \((ProcessInfo.processInfo.systemUptime - openingStart) * 1000) initiallyEnchanted=\(initiallyEnchanted) compact=\(compact)")
        try await wait(model, "settings visit completes") { model.paging.completedVisits == 1 }
        XCTAssertEqual(model.paging.visitCount, 1)
        let step = model.layout.mode == .spread ? 2 : 1
        model.advance(by: step) // Same action used by the page-edge gesture.
        try await wait(model, "forward edge tap completes") { model.paging.completedVisits == 2 }
        XCTAssertEqual(model.currentPageIndex, step)
        XCTAssertEqual(model.paging.visitCount, 2)
        model.advance(by: -step)
        try await wait(model, "cached backward edge tap completes") { model.paging.completedVisits == 3 }
        XCTAssertEqual(model.currentPageIndex, 0)
        let before = model.paging.visitCount
        model.sliderSelection = Double(model.pageCount - 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.paging.visitCount, before)
        XCTAssertEqual(model.currentPageIndex, 0)
        model.commitSlider()
        try await wait(model, "slider jump completes") { model.paging.completedVisits == 4 }
        let expected = model.layout.mode == .spread ? (model.pageCount - 1) / 2 * 2 : model.pageCount - 1
        XCTAssertEqual(model.currentPageIndex, expected)
        XCTAssertEqual(model.paging.visitCount, 4)
        XCTAssertEqual(model.paging.firstFrameCount,
                       model.layout.mode == .spread ? 6 + (model.pageCount.isMultiple(of: 2) ? 2 : 1) : 4)
        let scroll = try XCTUnwrap(allSubviews(window).compactMap { $0 as? UIScrollView }.first {
            $0.isScrollEnabled && $0.contentSize.width > $0.bounds.width * 1.5
        })
        XCTAssertTrue(scroll.panGestureRecognizer.allowedScrollTypesMask.contains(.continuous),
                      "The native pager must accept forwarded trackpad scroll events")
        // Actual scroll geometry, without injecting activation or a scroll phase.
        scroll.setContentOffset(CGPoint(x: -scroll.adjustedContentInset.left, y: scroll.contentOffset.y), animated: false)
        try await wait(model, "native backward scroll completes at page zero") { model.paging.completedVisits == 5 }
        XCTAssertEqual(model.currentPageIndex, 0)
        XCTAssertEqual(model.paging.source, .swipe)
        let visit = model.paging.sequence?.visitID
        model.environment.footstepsEnabled = true
        model.showsControls.toggle()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.paging.sequence?.visitID, visit)
        XCTAssertEqual(model.paging.visitCount, 5)
        print("FULL_READER_INK visits=\(model.paging.visitCount) completed=\(model.paging.completedVisits) frames=\(model.paging.firstFrameCount) mode=\(model.layout.mode)")
    }

    private func allSubviews(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    private func wait(_ model: ReaderViewModel, _ message: String,
                      until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        if !condition() {
            XCTFail("\(message): phase=\(String(describing: model.paging.sequence?.phase)) requested=\(String(describing: model.paging.requestedUnit)) settled=\(String(describing: model.paging.settledUnit)) observed=\(String(describing: model.paging.observedUnit)) eligible=\(String(describing: model.paging.sequence?.isEligible)) ready=\(String(describing: model.paging.sequence?.readyPageSeeds)) finish=\(String(describing: model.paging.lastFinishReason))")
            throw NSError(domain: "FullReaderInkTimeout", code: 1)
        }
    }
}
