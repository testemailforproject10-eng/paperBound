import XCTest
import SwiftUI
import SwiftData
@testable import Paperbound

@MainActor final class FullReaderPageEffectTests: XCTestCase {
    func testSwitchingAllEffectsDoesNotPreparePagesOrRestartInk() async throws {
        let container = try ModelContainer(for:Book.self, Bookmark.self, Highlight.self,
            configurations:ModelConfiguration(isStoredInMemoryOnly:true))
        let store = LibraryStore.unavailable()
        let name = "page-effects-\(UUID()).pdf"
        let book = Book(title:"Page effects",fileName:name,format:.pdf,contentFingerprint:name)
        let file = store.fileURL(for:book)
        try SampleLibrary.write(to:file)
        defer { try? FileManager.default.removeItem(at:file) }
        container.mainContext.insert(book)
        let suite = "page-effects-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let settings = AppSettings(defaults:defaults)
        let model = ReaderViewModel(book:book,settings:settings,store:store,context:container.mainContext)
        await model.load()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:ReaderView(book:book,model:model)
            .environment(settings).environment(LibraryEnvironment(store:store)).modelContainer(container)
            .environment(\.scenePhase,.active))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; model.unload() }
        try await wait("initial settlement") { model.paging.settledUnit == 0 && model.lastSurfaceSize.width > 0 }
        for ink in [InkBehavior.instant,.enchanted] {
            if model.environment.ink != ink { model.environment.ink = ink }
            if ink == .enchanted { try await wait("enchanted completion") { model.paging.completedVisits > 0 } }
            // Allow directional neighbor preparation to finish before comparing.
            try await Task.sleep(for:.seconds(1))
            let provider = try XCTUnwrap(model.provider)
            let preparations = provider.preparationCount
            let visit = model.paging.sequence?.visitID
            let visits = model.paging.visitCount
            for effect in PageEffect.allCases where effect.hasSpriteArtwork {
                model.environment.pageEffect = effect
                try await wait("\(ink) / \(effect)") {
                    PageEffectDiagnostics.shared.snapshots.values.contains { $0.effect == effect && $0.frames > 2 && $0.sprites > 0 }
                }
                XCTAssertEqual(provider.preparationCount,preparations,"\(effect) triggered PDF/compositor work")
                XCTAssertEqual(model.paging.sequence?.visitID,visit)
                XCTAssertEqual(model.paging.visitCount,visits)
            }
            model.environment.pageEffect = .none
            try await wait("disabled overlay cleanup") { PageEffectDiagnostics.shared.snapshots.isEmpty }
        }
        // Same action as edge navigation, then a nonadjacent slider commit.
        model.environment.pageEffect = .paperMessengers
        model.advance(by:model.layout.mode == .spread ? 2 : 1)
        try await wait { model.currentPageIndex > 0 }
        try await wait { PageEffectDiagnostics.shared.snapshots.values.contains { $0.effect == .paperMessengers && $0.frames > 2 } }
        model.sliderSelection = Double(model.pageCount-1)
        model.commitSlider()
        try await wait { model.currentPageIndex >= model.pageCount-2 }
    }

    private func wait(_ message: String = "navigation", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { try await Task.sleep(for:.milliseconds(50)) }
        guard condition() else { XCTFail("Full reader page effect did not reach \(message): \(PageEffectDiagnostics.shared.snapshots)"); throw NSError(domain:"EffectTimeout",code:1) }
    }
}
