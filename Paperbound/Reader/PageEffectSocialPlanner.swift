import Foundation
import CoreGraphics

/// Small, causal gestures prepared with the route, never randomized while drawing.
struct PageEffectSocialCue: Equatable {
    enum Kind: Equatable { case chat, question, surprise, nod }
    var start: Double
    var duration: Double
    var kind: Kind
    var targetID: Int?
    var end: Double { start + duration }

    func strength(at time: Double) -> Double {
        let age = time-start
        guard age >= 0, age < duration else { return 0 }
        return PageEffectMotion.ease(age/0.22)*PageEffectMotion.ease((duration-age)/0.35)
    }
}

enum PageEffectSocialPlanner {
    typealias Event = PageEffectController.Event

    static func plan(effect: PageEffect, seed: UInt64, index: Int, start: Double,
                     surfaces: [CGRect], viewport: CGRect, scale: CGFloat) -> PageEffectScenePlanner.Plan {
        var rng = EffectRandom(seed:StableHash.combine(seed,UInt64(index),0xC4A7))
        let rect = surfaces[rng.integer(0...(surfaces.count-1))]
        let count = rng.integer(2...4), base = index*100
        let direction = rng.integer(0...1) == 0 ? 1.0 : -1.0
        let speed = rng.value(22...29)*scale
        let spacing = min(38*scale,(rect.width-50*scale)/Double(count))
        let focus = CGPoint(x:rect.midX+rng.value(-0.12...0.12)*rect.width,
                            y:rect.minY+rng.value(0.35...0.72)*rect.height)
        // A shuffled subset takes part. Some visits are a completely unanswered
        // greeting; others have a pair chatting while companions walk straight on.
        var order = Array(0..<count)
        for i in stride(from:count-1,through:1,by:-1) { order.swapAt(i,rng.integer(0...i)) }
        let participantCount = rng.value(0...1) < 0.22 ? 1 : rng.integer(2...count)
        let participants = Array(order.prefix(participantCount))
        let passing = Array(order.dropFirst(participantCount))
        let meetings = (0..<count).map { lane in
            CGPoint(x:focus.x+(Double(lane)-Double(count-1)/2)*spacing,
                    y:focus.y+Double(lane%2)*10*scale)
        }
        func outside(_ side: Double, y: CGFloat) -> CGPoint {
            CGPoint(x:side > 0 ? viewport.maxX+70*scale : viewport.minX-70*scale,y:y)
        }
        var arrivals: [Event] = []
        var crossings: [Event] = []
        var conversationAt = start
        for lane in 0..<count {
            let from = outside(-direction,y:focus.y+rng.value(-55...55)*scale)
            let at = start+Double(lane)*rng.value(0.6...1.5)
            let isParticipant = participants.contains(lane)
            let meeting = meetings[lane]
            let to = isParticipant ? meeting : outside(direction,y:focus.y+rng.value(-60...60)*scale)
            // Bypass the stationary group by a shoe's width. No stop segment or
            // facing change is inserted for the character ignoring the exchange.
            let via = isParticipant ? CGPoint(x:(from.x+to.x)/2,y:(from.y+to.y)/2)
                : CGPoint(x:focus.x,y:focus.y+48*scale)
            let route = PageEffectRoute(points:[from,via,to])
            let duration = max(2,route.length/speed)
            var e = Event(start:at,duration:duration,movingFor:duration,route:route,
                length:29*scale,asset:effect.rawValue,actorID:base+lane)
            e.rig = .walker; e.frame = effect == .marginCreatures ? 1 : 0
            e.phaseOffset = rng.value(0...(2 * .pi)); e.persistent = true; e.firstAppearance = true
            e.behavior = .entering; e.restBehavior = .greeting
            e.startFacing = direction; e.travelFacing = direction; e.restFacing = direction
            if isParticipant {
                conversationAt = max(conversationAt,at+duration+0.8)
                arrivals.append(e)
            } else {
                // Find when this continuously moving visitor passes the gathering.
                let distance = route.samples.min { abs($0.point.x-focus.x) < abs($1.point.x-focus.x) }!.distance
                var low = 0.0, high = 1.0
                for _ in 0..<20 {
                    let mid = (low+high)/2
                    if PageEffectMotion.travel(mid) < distance/route.length { low = mid } else { high = mid }
                }
                e.encounterOffset = duration*(low+high)/2
                conversationAt = max(conversationAt,at+e.encounterOffset-0.8)
                crossings.append(e)
            }
        }
        for i in crossings.indices {
            crossings[i].start = conversationAt+0.8-crossings[i].encounterOffset+rng.value(0...0.6)
        }
        var cues: [Int:[PageEffectSocialCue]] = [:]
        var speaker = participants[0]
        var cursor = conversationAt
        let rounds = participantCount == 1 ? rng.integer(1...2) : rng.integer(2...5)
        for _ in 0..<rounds {
            let others = participants.filter { $0 != speaker }
            let recipient = others.isEmpty ? passing[0] : others[rng.integer(0...(others.count-1))]
            let question = participantCount == 1 || rng.value(0...1) < 0.48
            let duration = rng.value(1.15...2.15)
            cues[speaker,default:[]].append(.init(start:cursor,duration:duration,
                kind:question ? .question : .chat,targetID:base+recipient))
            if participantCount > 1 {
                let surprised = question && rng.value(0...1) < 0.72
                let reactionAt = cursor+duration*rng.value(0.45...0.75)
                let reactionLength = rng.value(0.8...1.4)
                cues[recipient,default:[]].append(.init(start:reactionAt,duration:reactionLength,
                    kind:surprised ? .surprise : .nod,targetID:base+speaker))
                cursor = max(cursor+duration,reactionAt+reactionLength)+rng.value(0.3...1.25)
                speaker = rng.value(0...1) < 0.75 ? recipient : participants[rng.integer(0...(participants.count-1))]
            } else {
                // The second question comes after the unanswered first one,
                // while the passerby continues without any reaction at all.
                cursor += duration+rng.value(0.8...1.4)
            }
        }
        var events = crossings
        var finished = crossings.map { $0.start+$0.duration }.max() ?? start
        for var entry in arrivals {
            let lane = entry.actorID-base
            entry.socialCues = cues[lane,default:[]]
            let partner = entry.socialCues.first?.targetID.map { $0-base } ?? participants[0]
            entry.companionID = base+partner
            entry.attentionTarget = meetings[partner]
            entry.restFacing = meetings[partner].x < meetings[lane].x ? -1 : 1
            // Independent departures: a quiet listener may leave while the
            // others continue. No universal end-of-chat barrier or lane order.
            let lastCue = entry.socialCues.map(\.end).max() ?? conversationAt
            let leaveAt = max(entry.start+entry.movingFor+1.5,lastCue+rng.value(0.9...3.2))
            entry.duration = leaveAt-entry.start
            events.append(entry)
            let exitDirection = rng.value(0...1) < 0.23 ? -direction : direction
            let exit = outside(exitDirection,y:focus.y+rng.value(-75...75)*scale)
            let guide = CGPoint(x:(meetings[lane].x+exit.x)/2,y:(meetings[lane].y+exit.y)/2)
            let route = PageEffectRoute(points:[meetings[lane],guide,exit],initialHeading:entry.route.endHeading)
            var leaving = Event(start:leaveAt,duration:max(2,route.length/speed),movingFor:max(2,route.length/speed),
                route:route,length:entry.length,asset:entry.asset,actorID:entry.actorID)
            leaving.rig = .walker; leaving.frame = entry.frame; leaving.phaseOffset = entry.phaseOffset
            leaving.initialDistance = entry.route.length; leaving.persistent = true
            leaving.startFacing = entry.restFacing; leaving.travelFacing = exitDirection; leaving.restFacing = exitDirection
            leaving.behavior = .exiting
            events.append(leaving)
            finished = max(finished,leaveAt+leaving.duration)
        }
        return .init(events:events,nextStart:finished+rng.value(2...8))
    }
}
