import XCTest
import SwiftUI
import SwiftData
@testable import Paperbound

/// Cold means a new reader/engine/page cache, not a freshly booted process.
@MainActor final class PageEffectLoadingBenchmarkTests: XCTestCase {
    func testTenColdReaderOpeningsAndThirtyCachedTurnsPerEffect() async throws {
        let container = try ModelContainer(for:Book.self, Bookmark.self, Highlight.self,
            configurations:ModelConfiguration(isStoredInMemoryOnly:true))
        let store = LibraryStore.unavailable()
        let name = "page-effects-benchmark-\(UUID()).pdf"
        let book = Book(title:"Page effect benchmark",fileName:name,format:.pdf,contentFingerprint:name)
        let file = store.fileURL(for:book)
        try SampleLibrary.write(to:file)
        defer { try? FileManager.default.removeItem(at:file) }
        container.mainContext.insert(book)
        let suite = "effect-benchmark-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let settings = AppSettings(defaults:defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        var results: [[String:Any]] = []
        for effect in PageEffect.allCases {
            var cold: [Double] = [], warm: [Double] = []
            for run in 0..<10 {
                var environment = ReadingEnvironment.cleanPaper; environment.pageEffect = effect
                book.savedEnvironment = environment; book.savedLocation = .pdfPage(index:0,yOffset:0)
                await PageEffectArtworkCache.shared.trim()
                PageEffectDiagnostics.shared.clearPaperReadiness()
                let begin = ProcessInfo.processInfo.systemUptime
                let model = ReaderViewModel(book:book,settings:settings,store:store,context:container.mainContext)
                await model.load()
                let window = UIWindow(windowScene:scene)
                window.rootViewController = UIHostingController(rootView:ReaderView(book:book,model:model)
                    .environment(settings).environment(LibraryEnvironment(store:store)).modelContainer(container)
                    .environment(\.scenePhase,.active))
                window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil; model.unload() }
                try await ready(model,book:book,page:0)
                cold.append((latestTime(book:book,page:0,spread:model.layout.mode == .spread)-begin)*1000)
                if run == 9 {
                    let step = model.layout.mode == .spread ? 2 : 1
                    // Warm both destinations before measuring cached revisits.
                    for destination in [step,0] {
                        PageEffectDiagnostics.shared.clearPaperReadiness()
                        model.go(toPageIndex:destination)
                        try await ready(model,book:book,page:destination)
                        try await Task.sleep(for:.milliseconds(350))
                    }
                    for turn in 0..<30 {
                        let destination = turn.isMultiple(of:2) ? step : 0
                        PageEffectDiagnostics.shared.clearPaperReadiness()
                        let turnStart = ProcessInfo.processInfo.systemUptime
                        model.go(toPageIndex:destination)
                        try await ready(model,book:book,page:destination)
                        warm.append((latestTime(book:book,page:destination,spread:model.layout.mode == .spread)-turnStart)*1000)
                        try await Task.sleep(for:.milliseconds(350))
                    }
                }
                window.isHidden = true; window.rootViewController = nil; model.unload()
                try await Task.sleep(for:.milliseconds(30))
            }
            func p95(_ values:[Double]) -> Double { values.sorted()[Int(ceil(Double(values.count)*0.95))-1] }
            let row: [String:Any] = ["effect":effect.rawValue,"coldReaderMS":cold,"cachedTurnMS":warm,
                                   "coldP95":p95(cold),"cachedP95":p95(warm)]
            results.append(row)
            print("PAGE_EFFECT_LOADING \(effect.rawValue) cold_p95=\(p95(cold)) cached_p95=\(p95(warm))")
        }
        let output = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("PageEffectReview/loading-benchmark.json")
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:results,options:.prettyPrinted).write(to:output)
    }

    private func latestTime(book:Book,page:Int,spread:Bool) -> TimeInterval {
        let times = PageEffectDiagnostics.shared.paperTimes
        return (page...(page+(spread ? 1:0))).compactMap { times["\(book.id.uuidString)|pdf:\($0)"] }.max() ?? 0
    }
    private func ready(_ model:ReaderViewModel,book:Book,page:Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let pages = page...(page+(model.layout.mode == .spread ? 1:0))
            if model.currentPageIndex == page && pages.allSatisfy({ PageEffectDiagnostics.shared.paperTimes["\(book.id.uuidString)|pdf:\($0)"] != nil }) { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Page \(page) did not become ready")
        throw NSError(domain:"PageEffectBenchmark",code:1)
    }
}
