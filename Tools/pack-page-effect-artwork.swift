// Asset packaging only: split generated poses, retain alpha, resize for runtime.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Docs/page-effect-artwork.json"))) as! [String: Any]
let assets = manifest["assets"] as! [[String: String]]
func writePNG(_ image: CGImage, _ url: URL) throws {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PNG", code: 1) }
}
for item in assets {
    let name = item["name"]!
    let url = URL(fileURLWithPath: item["path"]!)
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let original = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let w = original.width, h = original.height
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(original, in: CGRect(x: 0,y: 0,width: w,height: h))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let occupied = (0..<w).map { x in (0..<h).reduce(0) { $0 + (pixels[($1*w+x)*4+3] > 32 ? 1 : 0) } }
    // Locate the transparent gutter nearest each requested cell boundary.
    func split(_ target: Int) -> Int {
        let candidates = (target-w/9)...(target+w/9)
        return candidates.min { a,b in
            let ca = occupied[max(0,a-4)...min(w-1,a+4)].reduce(0,+)
            let cb = occupied[max(0,b-4)...min(w-1,b+4)].reduce(0,+)
            return ca == cb ? abs(a-target) < abs(b-target) : ca < cb
        }!
    }
    let cuts = [0,split(w/3),split(2*w/3),w]
    let atlas = CGContext(data:nil,width:768,height:256,bitsPerComponent:8,bytesPerRow:768*4,
                         space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    atlas.interpolationQuality = .high
    for i in 0..<3 {
        let crop = original.cropping(to:CGRect(x:cuts[i],y:0,width:cuts[i+1]-cuts[i],height:h))!
        let ratio = min(248.0/Double(crop.width),248.0/Double(crop.height))
        let cw = Double(crop.width)*ratio, ch = Double(crop.height)*ratio
        atlas.draw(crop,in:CGRect(x:Double(i*256)+(256-cw)/2,y:(256-ch)/2,width:cw,height:ch))
    }
    let packed = atlas.makeImage()!
    try writePNG(packed,root.appendingPathComponent("Paperbound/Resources/PageEffects/effect-\(name).png"))
    if name != "winterFrost" {
        let folder = root.appendingPathComponent("Paperbound/Assets.xcassets/EffectThumb-\(name).imageset")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let thumb = CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:64*4,
                              space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        thumb.interpolationQuality = .high
        thumb.draw(packed.cropping(to:CGRect(x:0,y:0,width:256,height:256))!,in:CGRect(x:0,y:0,width:64,height:64))
        try writePNG(thumb.makeImage()!,folder.appendingPathComponent("thumbnail.png"))
        try Data("{\"images\":[{\"filename\":\"thumbnail.png\",\"idiom\":\"universal\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}".utf8).write(to:folder.appendingPathComponent("Contents.json"))
    }
    print("\(name): alpha=\(original.alphaInfo.rawValue), pose cuts=\(cuts), packed 768x256")
}
