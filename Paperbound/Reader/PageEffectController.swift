import Foundation
import CoreGraphics

struct PageEffectClock { var now: () -> Date = Date.init }

enum PageEffectBehavior: Equatable { case entering, greeting, resting, following, exiting, falling, flight, trail, ember, frost }

enum PageEffectRig: Equatable { case whole, butterfly, walker, flame }

struct PageEffectSprite: Equatable {
    var asset: String
    var frame: Int
    var center: CGPoint
    var size: CGSize
    var angle: Double
    var opacity: Double
    var actorID: Int = 0
    var rig: PageEffectRig = .whole
    var phase: Double = 0
    var activity: Double = 1
    var facing: Double = 1
    /// Ankle positions in body-size units, relative to the actor center.
    var feet: [CGPoint] = []
    var behavior: PageEffectBehavior = .flight
    var companionID: Int?
    var speech: Double = 0
    var nod: Double = 0
    var bubble: PageEffectSocialCue.Kind = .chat
    var surprise: Double = 0
}

/// Complete scenes are prepared ahead of time. Actor segments share identity,
/// position and stride through an encounter; each visitor then leaves the viewport.
final class PageEffectController {
    static let maximumSprites = 32
    let effect: PageEffect
    let seed: UInt64
    let surfaces: [CGRect]
    let reservedRegions: [CGRect]
    private let scale: CGFloat
    private let clock: PageEffectClock
    private let startedAt: Date
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var nextSegment = 0
    private var nextStart: TimeInterval = 0
    let viewport: CGRect
    private(set) var events: [Event] = []

    struct Event {
        var start: Double
        var duration: Double
        var movingFor: Double
        var route: PageEffectRoute
        var length: CGFloat
        var asset: String
        var actorID: Int
        var opacity: Double = 0.65
        var frame: Int = 0
        var rig: PageEffectRig = .whole
        var phaseOffset: Double = 0
        var initialDistance: Double = 0
        var persistent = false
        var turns: Double = 0
        var firstAppearance = false
        var behavior: PageEffectBehavior = .flight
        var restBehavior: PageEffectBehavior = .resting
        var companionID: Int?
        var attentionTarget: CGPoint?
        var timeSampled = false
        var flutterRate: Double = 1
        var startFacing: Double = 1
        var travelFacing: Double = 1
        var restFacing: Double = 1
        var socialCues: [PageEffectSocialCue] = []
        var encounterOffset: Double = 0
        var from: CGPoint { route.from }
        var to: CGPoint { route.to }
    }

    init(effect: PageEffect, seed: UInt64, surfaces: [CGRect], reservedRegions: [CGRect] = [],
         startedAt: Date, scale: CGFloat = 1, viewport: CGRect? = nil, clock: PageEffectClock = PageEffectClock()) {
        self.effect = effect; self.seed = seed
        self.surfaces = surfaces.filter { $0.width > 0 && $0.height > 0 }
        self.reservedRegions = reservedRegions; self.startedAt = startedAt
        self.scale = scale; self.clock = clock
        self.viewport = viewport ?? surfaces.reduce(CGRect.null) { $0.union($1) }
        nextStart = 0.35 + Double(seed % 1000)/1000*1.2
        prepare(through:24)
    }
    func elapsed(at date: Date) -> Double { max(0,(pausedAt ?? date).timeIntervalSince(startedAt)-pausedDuration) }
    func pause(at date: Date) { if pausedAt == nil { pausedAt = date } }
    func resume(at date: Date) {
        if let pausedAt { pausedDuration += max(0,date.timeIntervalSince(pausedAt)); self.pausedAt = nil }
    }
    func pause() { pause(at:clock.now()) }
    func resume() { resume(at:clock.now()) }
    func sprites() -> [PageEffectSprite] { sprites(at:clock.now()) }

    func prepare(through horizon: Double, discardingBefore cutoff: Double = 0) {
        guard effect.hasSpriteArtwork, !surfaces.isEmpty else { return }
        events.removeAll { $0.start+$0.duration < cutoff }
        while nextStart < horizon {
            let plan = PageEffectScenePlanner.plan(effect:effect,seed:seed,index:nextSegment,start:nextStart,
                surfaces:surfaces,viewport:viewport,scale:scale)
            for event in plan.events {
                if effect == .fallingRosePetals || effect == .winterMargins {
                    // Tall/stacked displays can keep particles alive much longer.
                    // Omit a proposed emission if its lifetime would overfill the
                    // scene; never hide a live particle and reveal it mid-flight.
                    let end = event.start+event.duration
                    let checkpoints = [event.start]+events.filter { $0.start >= event.start && $0.start < end }.map(\.start)
                    let fits = checkpoints.allSatisfy { time in
                        events.lazy.filter { $0.start <= time && time < $0.start+$0.duration }.count < Self.maximumSprites
                    }
                    guard fits else { continue }
                }
                events.append(event)
            }
            nextStart = plan.nextStart
            nextSegment += 1
        }
    }

    func sprites(at date: Date) -> [PageEffectSprite] {
        let time = elapsed(at:date)
        return events.lazy.filter { time >= $0.start && time < $0.start+$0.duration }
            .prefix(Self.maximumSprites).map { e in
                let age = time-e.start
                let ambient = effect == .fallingRosePetals || effect == .winterMargins || effect == .floatingLanterns
                let fraction = min(1,age/max(0.001,e.movingFor))
                let progress = ambient ? fraction : PageEffectMotion.travel(fraction)
                let sample = e.timeSampled ? e.route.at(timeFraction:fraction) : e.route.at(distance:progress*e.route.length)
                let activity = PageEffectMotion.activity(age:age,movingFor:e.movingFor)
                let phase = time*2 * .pi + e.phaseOffset
                let traveled = e.initialDistance + sample.distance
                var center = sample.point
                var width = e.length, height = e.length, angle = 0.0
                var gait = phase
                var facing = 1.0
                var feet: [CGPoint] = []
                if e.rig == .walker {
                    let creature = effect == .marginCreatures
                    let cycle = e.length*(creature ? 0.42 : 0.65)
                    gait = traveled/cycle * 2 * .pi + e.phaseOffset
                    center.y -= e.length*0.018*(1-cos(gait*2))*activity
                    // Turn only at an intentional stop/start, not whenever a
                    // curved route's tangent happens to cross the vertical axis.
                    if age < e.movingFor {
                        facing = e.startFacing+(e.travelFacing-e.startFacing)*PageEffectMotion.ease(age/0.7)
                    } else {
                        facing = e.travelFacing+(e.restFacing-e.travelFacing)*PageEffectMotion.ease((age-e.movingFor)/0.7)
                    }
                    feet = (0..<2).map { side in
                        let foot = PageEffectMotion.footContact(distance:traveled,cycle:cycle,
                            offset:e.phaseOffset/(2 * .pi)+Double(side)*0.5)
                        let contact = e.route.at(distance:foot.distance-e.initialDistance).point
                        let neutralX = side == 0 ? -0.10 : 0.10
                        let baseY = creature ? 0.32 : 0.39
                        let walkingX = (contact.x-sample.point.x)/e.length + (side == 0 ? -0.06 : 0.06)
                        let walkingY = baseY+(contact.y-center.y)/e.length-foot.lift*(creature ? 0.07 : 0.10)
                        return CGPoint(x:neutralX+(walkingX-neutralX)*activity,
                            y:baseY+(walkingY-baseY)*activity)
                    }
                } else if e.rig == .butterfly {
                    gait = phase*2.1
                    center.y += sin(phase*0.24)*3.5*scale*activity
                    angle = sample.heading + .pi/2 + 0.08*sin(phase)*activity
                } else if e.rig == .flame {
                    gait = phase
                    if effect == .wanderingWisps { center.y += sin(phase*0.17)*5*scale }
                } else {
                    switch effect {
                    case .paperMessengers:
                        angle = sample.heading
                        let ahead = e.route.at(distance:min(e.route.length,sample.distance+8*scale)).heading
                        height *= 1-min(0.4,abs(ahead-sample.heading)*1.8)
                    case .floatingLanterns:
                        center.x += sin(phase*0.3)*8*scale
                        angle = 0.1*sin(phase*0.3-0.5)
                    case .fallingRosePetals:
                        let roll = age*e.flutterRate+e.phaseOffset
                        width *= 0.28+0.72*abs(cos(roll))
                        angle = e.turns+0.7*sin(roll)+0.14*sin(roll*2.3)
                    case .winterMargins:
                        if e.asset != "winterFrost" { angle = age*0.2+e.turns }
                    case .pixieDust: angle = e.turns
                    default: break
                    }
                }
                var opacity = e.opacity
                if e.persistent {
                    if e.firstAppearance { opacity *= PageEffectMotion.ease(age/0.45) }
                } else {
                    opacity *= PageEffectMotion.ease(age/0.4) * PageEffectMotion.ease((e.duration-age)/0.7)
                    if e.asset == "winterFrost" { opacity *= pow(sin(.pi*age/e.duration),2) }
                }
                if e.asset == "winterFrost" { opacity *= 0.55+0.45*sin(time*0.24+e.phaseOffset)*sin(time*0.24+e.phaseOffset) }
                opacity *= PageEffectMotion.ease(time/0.6)
                let cue = e.socialCues.first { time >= $0.start && time < $0.end }
                let strength = cue?.strength(at:time) ?? 0
                let cueAge = time-(cue?.start ?? time)
                let isNod = cue?.kind == .nod
                let surprise = cue?.kind == .surprise ? strength*pow(max(0,sin(.pi*min(1,cueAge/0.8))),2) : 0
                // A small recoil/stretch belongs to the surprised torso; planted
                // feet stay put and the gesture returns smoothly to neutral.
                let nod = isNod ? strength*sin(cueAge*5) : strength*0.3*sin(cueAge*4)
                return PageEffectSprite(asset:e.asset,frame:e.frame,center:center,
                    size:CGSize(width:width,height:height),angle:angle,opacity:opacity,
                    actorID:e.actorID,rig:e.rig,phase:gait,activity:activity,facing:facing,feet:feet,
                    behavior:age < e.movingFor ? e.behavior : e.restBehavior,companionID:e.companionID,
                    speech:isNod ? 0 : strength,nod:nod,bubble:cue?.kind ?? .chat,surprise:surprise)
            }
    }

}
