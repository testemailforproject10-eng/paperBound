import SwiftUI
import ImageIO
import UIKit

struct PageEffectArtwork: @unchecked Sendable {
    let frames: [String: [CGImage]]
    let bytes: Int
    var parts: [String: [PageEffectArtworkPart]] = [:]
}

struct PageEffectArtworkPart {
    let image: CGImage
    let rect: CGRect
    let pivot: CGPoint
    let role: Role
    enum Role { case body, leftWing, rightWing, leftFoot, rightFoot }
}

/// Slice the chosen drawing once during asset preparation. Every frame of an
/// actor then uses the same silhouette and registration, with articulated parts.
private enum PageEffectRigArtwork {
    static func prepare(_ frames: [String:[CGImage]]) -> [String:[PageEffectArtworkPart]] {
        var result: [String:[PageEffectArtworkPart]] = [:]
        for (name,poses) in frames {
            let frame = name == "marginCreatures" ? 1 : 0
            guard poses.indices.contains(frame) else { continue }
            let source = poses[frame]
            func part(_ rect: CGRect, pivot: CGPoint, role: PageEffectArtworkPart.Role) -> PageEffectArtworkPart? {
                // Keep exact pixel edges; preserve the matching normalized rect.
                let pixelRect = CGRect(x:rect.minX*CGFloat(source.width),y:rect.minY*CGFloat(source.height),
                    width:rect.width*CGFloat(source.width),height:rect.height*CGFloat(source.height)).integral
                    .intersection(CGRect(x:0,y:0,width:source.width,height:source.height))
                guard let image = source.cropping(to:pixelRect) else { return nil }
                let actual = CGRect(x:pixelRect.minX/CGFloat(source.width),y:pixelRect.minY/CGFloat(source.height),
                                    width:pixelRect.width/CGFloat(source.width),height:pixelRect.height/CGFloat(source.height))
                return PageEffectArtworkPart(image:image,rect:actual,pivot:pivot,role:role)
            }
            var parts: [PageEffectArtworkPart?] = []
            if name == "enchantedButterflies" {
                parts = [
                    part(CGRect(x:0,y:0,width:0.535,height:1),pivot:CGPoint(x:0.535,y:0.52),role:.leftWing),
                    part(CGRect(x:0.535,y:0,width:0.465,height:1),pivot:CGPoint(x:0.535,y:0.52),role:.rightWing),
                    part(CGRect(x:0.505,y:0.38,width:0.055,height:0.45),pivot:.zero,role:.body)
                ]
            } else if name == "wonderlandCards" || name == "marginCreatures" {
                if name == "wonderlandCards" {
                    parts = [
                        part(CGRect(x:0.16,y:0.81,width:0.17,height:0.15),pivot:CGPoint(x:0.245,y:0.835),role:.leftFoot),
                        part(CGRect(x:0.555,y:0.835,width:0.23,height:0.14),pivot:CGPoint(x:0.60,y:0.85),role:.rightFoot),
                        part(CGRect(x:0,y:0,width:1,height:0.765),pivot:.zero,role:.body)
                    ]
                } else {
                    parts = [
                        part(CGRect(x:0.295,y:0.76,width:0.15,height:0.10),pivot:CGPoint(x:0.345,y:0.78),role:.leftFoot),
                        part(CGRect(x:0.69,y:0.73,width:0.145,height:0.11),pivot:CGPoint(x:0.715,y:0.77),role:.rightFoot),
                        part(CGRect(x:0,y:0,width:1,height:0.765),pivot:.zero,role:.body)
                    ]
                }
            }
            if !parts.isEmpty { result[name] = parts.compactMap { $0 } }
        }
        return result
    }
}

/// Serial, off-main decoding. UI thumbnails are separate tiny bundled assets.
actor PageEffectArtworkCache {
    static let shared = PageEffectArtworkCache()
    static let byteLimit = 16 * 1024 * 1024
    private var entries: [PageEffect: PageEffectArtwork] = [:]
    private var owners: [UUID: PageEffect] = [:]
    private(set) var decodeCount = 0
    var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }

    func acquire(_ effect: PageEffect, owner: UUID) throws -> PageEffectArtwork {
        try Task.checkCancellation()
        if let entry = entries[effect] { owners[owner] = effect; return entry }
        let active = Set(owners.values)
        entries = entries.filter { active.contains($0.key) }
        var names = [effect.rawValue]
        if effect == .winterMargins { names.append("winterFrost") }
        if effect == .littleHearthSpirit { names.append("pixieDust") }
        var frames: [String: [CGImage]] = [:]
        var cost = 0
        for name in names {
            try Task.checkCancellation()
            guard let url = Bundle.main.url(forResource: "effect-\(name)", withExtension: "png"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let strip = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 768,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ArtworkError.missing(name) }
            let width = strip.width / 3
            let poses = (0..<3).compactMap { index in
                strip.cropping(to: CGRect(x: index*width, y: 0, width: width, height: strip.height))
            }
            guard poses.count == 3 else { throw ArtworkError.missing(name) }
            frames[name] = poses
            cost += strip.bytesPerRow * strip.height
        }
        let parts = PageEffectRigArtwork.prepare(frames)
        // Conservatively include cropped backing storage even where CoreGraphics
        // shares it with the original; the cache must never undercount the rig.
        cost += parts.values.flatMap { $0 }.reduce(0) { $0 + $1.image.bytesPerRow*$1.image.height }
        guard bytes + cost <= Self.byteLimit else { throw ArtworkError.budget }
        let result = PageEffectArtwork(frames: frames, bytes: cost, parts: parts)
        entries[effect] = result; owners[owner] = effect; decodeCount += 1
        return result
    }

    func release(_ owner: UUID) { owners.removeValue(forKey: owner) }
    func trim() { entries = entries.filter { Set(owners.values).contains($0.key) } }
    enum ArtworkError: Error { case missing(String), budget }
}

struct PageEffectOverlayView: View {
    let effect: PageEffect
    let visit: PageEffectVisit
    let seed: UInt64
    let surfaces: [CGRect]
    let reservedRegions: [CGRect]
    let size: CGSize
    let isDarkPaper: Bool
    let isPaused: Bool
    var artworkScale: CGFloat = 1

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var controller: PageEffectController?
    @State private var artwork: PageEffectArtwork?
    @State private var owner = UUID()
    @State private var failed = false

    var body: some View {
        Group {
            if effect == .footsteps, scenePhase == .active, !reduceMotion {
                FootstepOverlayView(visit: visit, seed: seed, surfaces: surfaces,
                    reservedRegions: reservedRegions, size: size, isDarkPaper: isDarkPaper,
                    isPaused: isPaused, artworkScale: artworkScale)
            } else if effect.hasSpriteArtwork, scenePhase == .active, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1/30, paused: isPaused || controller == nil || failed)) { timeline in
                    let sprites = controller?.sprites(at: timeline.date) ?? []
                    let images = artwork
                    Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
                        guard let artwork = images else { return }
                        let begin = ProcessInfo.processInfo.systemUptime
                        PageEffectDrawing.draw(sprites, artwork: artwork,
                                               surfaces: surfaces, reservedRegions: reservedRegions, isDarkPaper:isDarkPaper, into: &context)
                        PageEffectDiagnostics.shared.record(visit: visit.visitID, effect: effect,
                            sprites: sprites.count, milliseconds: (ProcessInfo.processInfo.systemUptime-begin)*1000)
                    }
                }
                .task(id: "\(visit.visitID)|\(effect.rawValue)|\(isPaused)") {
                    guard !isPaused, let started = visit.startedAt else { return }
                    do {
                        if artwork == nil {
                            let requestOwner = UUID()
                            let images = try await PageEffectArtworkCache.shared.acquire(effect, owner: requestOwner)
                            guard !Task.isCancelled else {
                                await PageEffectArtworkCache.shared.release(requestOwner)
                                return
                            }
                            owner = requestOwner
                            artwork = images
                        }
                        if controller == nil {
                            // Artwork arrival never skips the opening pose.
                            controller = PageEffectController(effect: effect, seed: seed, surfaces: surfaces,
                                reservedRegions: reservedRegions, startedAt: max(started, Date()), scale: artworkScale,
                                viewport:CGRect(origin:.zero,size:size))
                        }
                        controller?.resume(at: Date())
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(3))
                            guard let controller else { break }
                            let elapsed = controller.elapsed(at: Date())
                            controller.prepare(through: elapsed + 24, discardingBefore: elapsed - 1)
                        }
                    } catch is CancellationError { /* lifecycle cancellation */ }
                    catch { failed = true; NSLog("Page effect %@ unavailable: %@", effect.rawValue, String(describing: error)) }
                }
                .onChange(of: isPaused) { _, paused in
                    if paused { controller?.pause(at: Date()) }
                    else { controller?.resume(at: Date()) }
                }
                .onDisappear {
                    controller = nil; artwork = nil
                    PageEffectDiagnostics.shared.remove(visit.visitID)
                    let releasedOwner = owner
                    Task { await PageEffectArtworkCache.shared.release(releasedOwner) }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum PageEffectDrawing {
    static func draw(_ sprites: [PageEffectSprite], artwork: PageEffectArtwork, surfaces: [CGRect],
                     reservedRegions: [CGRect], isDarkPaper: Bool = false, into context: inout GraphicsContext) {
        // Apply all reservations as one union mask to avoid even-odd overlap holes.
        var paper = Path()
        for rect in surfaces { paper.addRect(rect) }
        context.clip(to: paper)
        for region in reservedRegions {
            context.clip(to: Path(region), options: .inverse)
        }
        for sprite in sprites {
            guard let poses = artwork.frames[sprite.asset], poses.indices.contains(sprite.frame) else { continue }
            // Blend the complete character once. Applying opacity separately to
            // intersecting limbs/wings/flame paths produces dark seams and flashes.
            var composite = context
            composite.opacity = sprite.opacity
            if sprite.rig == .whole {
                // A single particle image needs no intermediate compositing group.
                composite.translateBy(x:sprite.center.x,y:sprite.center.y)
                composite.rotate(by:.radians(sprite.angle))
                var image = composite.resolve(Image(decorative:poses[sprite.frame],scale:1))
                if sprite.asset == "winterMargins" {
                    image.shading = .color(isDarkPaper
                        ? Color(red:0.78,green:0.9,blue:1)
                        : Color(red:0.27,green:0.43,blue:0.59))
                }
                composite.draw(image,in:CGRect(x:-sprite.size.width/2,y:-sprite.size.height/2,
                                              width:sprite.size.width,height:sprite.size.height))
                continue
            }
            composite.drawLayer { layer in
                layer.opacity = 1
                layer.translateBy(x:sprite.center.x,y:sprite.center.y)
                layer.rotate(by:.radians(sprite.angle))
                if sprite.rig == .flame {
                    PageEffectFlameDrawing.draw(sprite,into:&layer)
                } else if sprite.rig != .whole, let parts = artwork.parts[sprite.asset] {
                    if sprite.rig == .walker { drawLegs(sprite,into:&layer) }
                    for part in parts { drawPart(part,sprite:sprite,context:layer) }
                    if sprite.speech > 0 { drawSpeech(sprite,into:layer) }
                }
            }
        }
    }

    private static func drawSpeech(_ sprite: PageEffectSprite, into context: GraphicsContext) {
        var local = context; local.opacity = sprite.speech
        let w = sprite.size.width, h = sprite.size.height
        let rect = CGRect(x:-w*0.45+sprite.facing*w*0.25,y:-h*0.98,width:w*0.9,height:h*0.43)
        let bubble = Path(roundedRect:rect,cornerRadius:w*0.14)
        let ink = Color(red:0.25,green:0.22,blue:0.18)
        local.fill(bubble,with:.color(Color(white:0.98)))
        local.stroke(bubble,with:.color(ink),lineWidth:max(0.3,w*0.024))
        var tail = Path()
        tail.move(to:CGPoint(x:rect.midX-3*w/30,y:rect.maxY))
        tail.addLine(to:CGPoint(x:rect.midX-5*w/30,y:rect.maxY+4*w/30))
        local.stroke(tail,with:.color(ink),style:StrokeStyle(lineWidth:w*0.025,lineCap:.round))
        if sprite.bubble == .question || sprite.bubble == .surprise {
            let cx = rect.midX, top = rect.minY+h*0.08
            var mark = Path()
            if sprite.bubble == .question {
                mark.move(to:CGPoint(x:cx-w*0.085,y:top+h*0.065))
                mark.addCurve(to:CGPoint(x:cx+w*0.075,y:top+h*0.09),
                    control1:CGPoint(x:cx-w*0.09,y:top-h*0.035),
                    control2:CGPoint(x:cx+w*0.15,y:top-h*0.035))
                mark.addQuadCurve(to:CGPoint(x:cx,y:top+h*0.19),
                    control:CGPoint(x:cx,y:top+h*0.12))
            } else {
                mark.move(to:CGPoint(x:cx,y:top))
                mark.addLine(to:CGPoint(x:cx,y:top+h*0.18))
            }
            local.stroke(mark,with:.color(ink),style:StrokeStyle(lineWidth:w*0.045,lineCap:.round))
            local.fill(Path(ellipseIn:CGRect(x:cx-w*0.025,y:top+h*0.255-w*0.025,
                width:w*0.05,height:w*0.05)),with:.color(ink))
        } else {
            for i in -1...1 {
                let dot = CGRect(x:rect.midX+Double(i)*w*0.16-w*0.035,y:rect.midY-w*0.035,
                                 width:w*0.07,height:w*0.07)
                local.fill(Path(ellipseIn:dot),with:.color(ink))
            }
        }
    }

    private static func drawLegs(_ sprite: PageEffectSprite, into context: inout GraphicsContext) {
        let w = sprite.size.width, h = sprite.size.height
        for (i,foot) in sprite.feet.enumerated() {
            let hip = CGPoint(x:(i == 0 ? -0.07 : 0.07)*w*sprite.facing,y:0.23*h)
            let ankle = CGPoint(x:foot.x*w,y:foot.y*h)
            let dx = ankle.x-hip.x, dy = ankle.y-hip.y
            let distance = max(0.001,hypot(dx,dy))
            let segment = max(h*(sprite.asset == "wonderlandCards" ? 0.125 : 0.09),distance*0.501)
            let bend = 0.65*sqrt(max(0,segment*segment-distance*distance/4))
            let knee = CGPoint(x:(hip.x+ankle.x)/2+dy/distance*bend,
                               y:(hip.y+ankle.y)/2-dx/distance*bend)
            var leg = Path(); leg.move(to:hip); leg.addLine(to:knee); leg.addLine(to:ankle)
            context.stroke(leg,with:.color(Color(red:0.16,green:0.13,blue:0.11)),
                style:StrokeStyle(lineWidth:w*(sprite.asset == "wonderlandCards" ? 0.047 : 0.025),lineCap:.round,lineJoin:.round))
        }
    }

    private static func drawPart(_ part: PageEffectArtworkPart, sprite: PageEffectSprite,
                                 context: GraphicsContext) {
        var local = context
        let w = sprite.size.width, h = sprite.size.height
        let pivot = CGPoint(x:(part.pivot.x-0.5)*w,y:(part.pivot.y-0.5)*h)
        let rect = CGRect(x:(part.rect.minX-0.5)*w,y:(part.rect.minY-0.5)*h,
                          width:part.rect.width*w,height:part.rect.height*h)
        switch part.role {
        case .leftWing, .rightWing:
            local.translateBy(x:pivot.x,y:pivot.y)
            local.scaleBy(x:PageEffectMotion.wingScale(phase:sprite.phase,activity:sprite.activity),y:1)
            local.translateBy(x:-pivot.x,y:-pivot.y)
        case .leftFoot, .rightFoot:
            let index = part.role == .leftFoot ? 0 : 1
            guard sprite.feet.indices.contains(index) else { return }
            let foot = sprite.feet[index]
            local.translateBy(x:foot.x*w,y:foot.y*h)
            local.scaleBy(x:sprite.facing,y:1)
            local.translateBy(x:-pivot.x,y:-pivot.y)
        case .body:
            if sprite.rig == .walker {
                local.translateBy(x:0,y:0.23*h)
                local.rotate(by:.radians((sprite.nod*0.12-sprite.surprise*0.18)*sprite.facing))
                local.scaleBy(x:sprite.facing,y:1+sprite.speech*0.025+sprite.surprise*0.09)
                local.translateBy(x:0,y:-0.23*h)
            }
            if sprite.asset == "wonderlandCards" {
                // Follow the sloping card hem, excluding the old legs/boot tips.
                var torso = Path(CGRect(x:-w/2,y:-h/2,width:w,height:h*0.66))
                var hem = Path()
                let points = [CGPoint(x:0.29,y:0.66),CGPoint(x:0.70,y:0.66),
                              CGPoint(x:0.69,y:0.77),CGPoint(x:0.34,y:0.74),CGPoint(x:0.29,y:0.70)]
                hem.addLines(points.map { CGPoint(x:($0.x-0.5)*w,y:($0.y-0.5)*h) }); hem.closeSubpath()
                torso.addPath(hem); local.clip(to:torso)
            }
        }
        local.draw(Image(decorative:part.image,scale:1),in:rect)
    }
}
