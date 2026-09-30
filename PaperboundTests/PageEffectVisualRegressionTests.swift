import XCTest
import SwiftUI
@testable import Paperbound

@MainActor final class PageEffectVisualRegressionTests: XCTestCase {
    func testOverlappingCharacterPartsReceiveOpacityOnlyOnce() throws {
        let black = UIGraphicsImageRenderer(size:CGSize(width:16,height:16)).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x:0,y:0,width:16,height:16))
        }.cgImage!
        let part = PageEffectArtworkPart(image:black,rect:CGRect(x:0,y:0,width:1,height:1),pivot:.zero,role:.body)
        let art = PageEffectArtwork(frames:["fixture":[black]],bytes:1024,parts:["fixture":[part,part]])
        let sprite = PageEffectSprite(asset:"fixture",frame:0,center:CGPoint(x:20,y:20),size:CGSize(width:20,height:20),
            angle:0,opacity:0.5,rig:.butterfly)
        let result = try render([sprite],art:art,size:CGSize(width:40,height:40),white:false)
        let alpha = result[(20*40+20)*4+3]
        XCTAssertEqual(Double(alpha),128,accuracy:2,"Overlapping parts must not darken to 75% opacity")
    }

    func testActualSnowIsVisibleOnWhitePaperAtReadingAndPreviewScale() async throws {
        let cache = PageEffectArtworkCache(), owner = UUID()
        let art = try await cache.acquire(.winterMargins,owner:owner)
        defer { Task { await cache.release(owner) } }
        for scale in [1.0,0.5] {
            let size = CGSize(width:320*scale,height:480*scale)
            let paper = CGRect(origin:.zero,size:size)
            let start = Date(timeIntervalSince1970:0)
            let c = PageEffectController(effect:.winterMargins,seed:2,surfaces:[paper],startedAt:start,scale:scale)
            var visibleFrames = 0
            for second in [3,4,6,8] {
                let pixels = try render(c.sprites(at:start.addingTimeInterval(Double(second))),art:art,size:size,white:true)
                let visiblePixels = stride(from:0,to:pixels.count,by:4).filter { pixels[$0] < 235 }.count
                if visiblePixels > 10 { visibleFrames += 1 }
            }
            XCTAssertGreaterThanOrEqual(visibleFrames,3,"Snow needs visible contrast and prompt arrival, including in the preview")
        }
    }

    func testQuestionSurpriseAndChatRenderDistinctBubbles() async throws {
        let cache = PageEffectArtworkCache(), owner = UUID()
        let art = try await cache.acquire(.marginCreatures,owner:owner)
        defer { Task { await cache.release(owner) } }
        var images: [[UInt8]] = []
        for kind in [PageEffectSocialCue.Kind.chat,.question,.surprise] {
            let sprite = PageEffectSprite(asset:"marginCreatures",frame:1,center:CGPoint(x:60,y:85),
                size:CGSize(width:60,height:60),angle:0,opacity:0.65,rig:.walker,activity:0,
                speech:1,bubble:kind)
            images.append(try render([sprite],art:art,size:CGSize(width:120,height:120),white:true))
        }
        for a in 0..<images.count {
            for b in (a+1)..<images.count {
                XCTAssertGreaterThan(zip(images[a],images[b]).filter { abs(Int($0)-Int($1)) > 15 }.count,40,
                    "The production Canvas must draw distinct, visible punctuation")
            }
        }
    }

    private func render(_ sprites: [PageEffectSprite], art: PageEffectArtwork, size: CGSize, white: Bool) throws -> [UInt8] {
        let renderer = ImageRenderer(content:Canvas { context,_ in
            PageEffectDrawing.draw(sprites,artwork:art,surfaces:[CGRect(origin:.zero,size:size)],reservedRegions:[],into:&context)
        }.frame(width:size.width,height:size.height).background(white ? Color.white : Color.clear))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        }
        return bytes
    }
}
