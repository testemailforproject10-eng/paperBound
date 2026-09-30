import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import Paperbound

/// Exports the production controller + Canvas renderer over real sample PDF pages.
/// These deterministic clips complement the hosted full-reader integration tests.
@MainActor final class PageEffectCaptureTests: XCTestCase {
    func testCaptureAllEffectsAndVerifyCanvasClipping() async throws {
        try await capture(effects:PageEffect.allCases.filter(\.hasSpriteArtwork),seed:731)
    }

    func testCaptureCompanionEncounter() async throws {
        let surfaces = [CGRect(x:16,y:54,width:300,height:420),CGRect(x:332,y:54,width:300,height:420)]
        var mixed: UInt64?, ignored: UInt64?
        for seed in UInt64(0)..<100 {
            let c = PageEffectController(effect:.marginCreatures,seed:seed,surfaces:surfaces,
                startedAt:Date(timeIntervalSince1970:0),viewport:CGRect(x:0,y:40,width:640,height:440))
            let first = c.events.filter { $0.firstAppearance && $0.actorID < 100 }
            let stopped = first.filter { $0.duration > $0.movingFor }
            if mixed == nil && stopped.count >= 2 && stopped.count < first.count && stopped.flatMap(\.socialCues).contains(where:{ $0.kind == .surprise }) { mixed = seed }
            if ignored == nil && stopped.count == 1 { ignored = seed }
            if mixed != nil && ignored != nil { break }
        }
        let mixedSeed = try XCTUnwrap(mixed), ignoredSeed = try XCTUnwrap(ignored)
        print("ENCOUNTER_REVIEW mixed=\(mixedSeed) ignored=\(ignoredSeed)")
        try await capture(effects:[.marginCreatures],seed:mixedSeed,suffix:"-encounter")
        try await capture(effects:[.marginCreatures],seed:ignoredSeed,suffix:"-ignored")
    }

    private func capture(effects: [PageEffect], seed: UInt64, suffix: String = "") async throws {
        let folder = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("PageEffectReview")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("effect-review.pdf")
        try SampleLibrary.write(to:pdf)
        defer { try? FileManager.default.removeItem(at:pdf) }
        let engine = try PDFReadingEngine(documentID:UUID(),fileURL:pdf,initialLocation:nil)
        try await engine.open()
        defer { engine.close() }
        let pages = try await [engine.renderPage(at:.pdfPage(index:1,yOffset:0),pixelSize:CGSize(width:300,height:420)),
                               engine.renderPage(at:.pdfPage(index:2,yOffset:0),pixelSize:CGSize(width:300,height:420))]
        let surfaces = [CGRect(x:16,y:54,width:300,height:420),CGRect(x:332,y:54,width:300,height:420)]
        let reserved = [CGRect(x:300,y:54,width:10,height:20)]
        let size = CGSize(width:800,height:530)
        let cache = PageEffectArtworkCache()
        var stills: [UIImage] = []
        for effect in effects {
            let owner = UUID()
            let art = try await cache.acquire(effect,owner:owner)
            let start = Date(timeIntervalSince1970:0)
            let controller = PageEffectController(effect:effect,seed:seed,surfaces:surfaces,
                reservedRegions:reserved,startedAt:start,viewport:CGRect(x:0,y:40,width:640,height:440))
            let gifURL = folder.appendingPathComponent("\(effect.rawValue)\(suffix).gif")
            let seconds = effect == .marginCreatures || effect == .wonderlandCards ? 60 : 30
            let frameCount = seconds*30
            let conversation = controller.events.flatMap(\.socialCues).first { $0.kind == .surprise }?.start ?? controller.events.flatMap(\.socialCues).first?.start
            let stillFrame = min(frameCount-1,Int(((conversation ?? 9.3)+0.7)*30))
            let gif = try XCTUnwrap(CGImageDestinationCreateWithURL(gifURL as CFURL,UTType.gif.identifier as CFString,frameCount,nil))
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
            for frame in 0..<frameCount {
                let time = Double(frame)/30
                if frame.isMultiple(of:90) { controller.prepare(through:time+24,discardingBefore:time-1) }
                let sprites = controller.sprites(at:start.addingTimeInterval(time))
                let detail = CGRect(x:640,y:90,width:150,height:240)
                let overlay = ImageRenderer(content:Canvas { context,_ in
                    var pageContext = context
                    PageEffectDrawing.draw(sprites,artwork:art,surfaces:surfaces,reservedRegions:reserved,into:&pageContext)
                    if var actor = sprites.first(where:{ $0.speech > 0 && $0.asset == effect.rawValue }) ?? sprites.first(where:{ $0.asset == effect.rawValue }) {
                        actor.center = CGPoint(x:detail.midX,y:detail.midY+20)
                        let enlargement = (actor.rig == .walker ? 100.0 : 128.0)/max(actor.size.width,actor.size.height)
                        actor.size.width *= enlargement; actor.size.height *= enlargement
                        actor.opacity = 1
                        var detailContext = context
                        PageEffectDrawing.draw([actor],artwork:art,surfaces:[detail],reservedRegions:[],into:&detailContext)
                    }
                }.frame(width:size.width,height:size.height))
                overlay.scale = 1
                let foreground = try XCTUnwrap(overlay.cgImage)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                let image = UIGraphicsImageRenderer(size:size,format:format).image { context in
                    UIColor(white:0.93,alpha:1).setFill(); context.fill(CGRect(origin:.zero,size:size))
                    for i in 0..<2 { UIColor.white.setFill(); context.fill(surfaces[i]); UIImage(cgImage:pages[i]).draw(in:surfaces[i]) }
                    UIImage(cgImage:foreground).draw(at:.zero)
                    ("\(effect.title) · \(String(format:"%.2f",time)) s" as NSString).draw(at:CGPoint(x:16,y:14),withAttributes:[.font:UIFont.boldSystemFont(ofSize:18),.foregroundColor:UIColor.black])
                    ("Motion detail" as NSString).draw(at:CGPoint(x:648,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:13),.foregroundColor:UIColor.darkGray])
                    ("Production Canvas • real sample PDF • fixed seed • 30 fps review capture" as NSString).draw(at:CGPoint(x:16,y:495),withAttributes:[.font:UIFont.systemFont(ofSize:12),.foregroundColor:UIColor.darkGray])
                }
                if frame == stillFrame {
                    try image.pngData()!.write(to:folder.appendingPathComponent("\(effect.rawValue)\(suffix).png"))
                    stills.append(image)
                    // Canvas outside paper is transparent, including the fold.
                    let data = try XCTUnwrap(foreground.dataProvider?.data)
                    let bytes = CFDataGetBytePtr(data)!
                    let x = 324, y = 200
                    XCTAssertEqual(bytes[y*foreground.bytesPerRow+x*4+3],0)
                }
                CGImageDestinationAddImage(gif,image.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/30]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(gif))
            await cache.release(owner); await cache.trim()
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let contact = UIGraphicsImageRenderer(size:CGSize(width:1600,height:2650),format:format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x:0,y:0,width:1600,height:2650))
            for (i,image) in stills.enumerated() { image.draw(in:CGRect(x:(i%2)*800,y:(i/2)*530,width:800,height:530)) }
        }
        if suffix.isEmpty { try contact.pngData()!.write(to:folder.appendingPathComponent("contact-sheet.png")) }
        print("PAGE_EFFECT_REVIEW \(folder.path)")
    }
}
