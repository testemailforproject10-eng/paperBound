import Foundation
import CoreGraphics

/// Plans complete arrivals, encounters and departures. Random choices and
/// particle integration happen here, never in the Canvas frame callback.
enum PageEffectScenePlanner {
    struct Plan {
        var events: [PageEffectController.Event]
        var nextStart: Double
    }
    typealias Event = PageEffectController.Event

    static func plan(effect: PageEffect, seed: UInt64, index: Int, start: Double,
                     surfaces: [CGRect], viewport: CGRect, scale: CGFloat) -> Plan {
        if effect == .marginCreatures || effect == .wonderlandCards {
            return PageEffectSocialPlanner.plan(effect:effect,seed:seed,index:index,start:start,
                surfaces:surfaces,viewport:viewport,scale:scale)
        }
        var rng = EffectRandom(seed:StableHash.combine(seed,UInt64(index),0x5CE_0E))
        var events: [Event] = []
        let rect = surfaces[rng.integer(0...(surfaces.count-1))]
        let opposite = surfaces.last ?? rect
        let idBase = index*100
        func point(_ r: CGRect, _ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x:r.minX+r.width*x,y:r.minY+r.height*y)
        }
        // Entrances use the outside of the complete viewport, never the gutter
        // or the interior edge of one sheet in a spread.
        func outside(edge: Int, fraction: Double, clearance: Double = 70) -> CGPoint {
            let margin = clearance*scale
            switch edge {
            case 0: return CGPoint(x:viewport.minX-margin,y:viewport.minY+viewport.height*fraction)
            case 1: return CGPoint(x:viewport.maxX+margin,y:viewport.minY+viewport.height*fraction)
            case 2: return CGPoint(x:viewport.minX+viewport.width*fraction,y:viewport.minY-margin)
            default: return CGPoint(x:viewport.minX+viewport.width*fraction,y:viewport.maxY+margin)
            }
        }
        func event(route: PageEffectRoute, at: Double, duration: Double, length: Double,
                   id: Int, asset: String? = nil) -> Event {
            Event(start:at,duration:duration,movingFor:duration,route:route,length:length*scale,
                  asset:asset ?? effect.rawValue,actorID:id,phaseOffset:rng.value(0...(2 * .pi)))
        }

        if [.enchantedButterflies,.wanderingWisps,.littleHearthSpirit].contains(effect) {
            let hearth = effect == .littleHearthSpirit
            let count = rng.integer(1...(hearth ? 3 : 4))
            let edge = hearth ? 3 : rng.integer(0...3)
            let exitEdge = hearth ? 3 : (edge == 0 ? 1 : edge == 1 ? 0 : edge == 2 ? 3 : 2)
            let headingRight = edge != 1
            let entryFraction = rng.value(0.22...0.62)
            let focus = point(rect,rng.value(0.30...0.70),hearth ? 0.90 : rng.value(0.35...0.70))
            let spacing = max(12*scale,min(38*scale,(rect.width-60*scale)/Double(max(1,count-1))))
            let halfSpan = Double(count-1)*spacing/2
            let formationX = min(rect.maxX-halfSpan-25*scale,max(rect.minX+halfSpan+25*scale,focus.x))
            let length: Double = hearth ? 38 : 32
            let speed = rng.value(hearth ? 18...24 : effect == .wanderingWisps ? 24...36 : 30...44)*scale
            var meetings: [CGPoint] = []
            var entries: [Event] = []
            var latestArrival = start
            for lane in 0..<count {
                // Space companions along the direction of travel so they can
                // fall into line after their encounter without occupying one spot.
                let shift = (halfSpan-Double(lane)*spacing)*(headingRight ? 1 : -1)
                let meeting = CGPoint(x:formationX+shift,
                                      y:focus.y+Double(lane%2)*10*scale)
                meetings.append(meeting)
                let entrance = outside(edge:edge,fraction:hearth ? Double(lane+1)/Double(count+1)
                    : min(0.85,entryFraction+Double(lane)*0.06+rng.value(-0.02...0.02)))
                let drift = rng.value(-35...35)*scale
                let via = CGPoint(x:(entrance.x+meeting.x)/2+drift,y:(entrance.y+meeting.y)/2-drift*0.5)
                let route = PageEffectRoute(points:[entrance,via,meeting])
                let arrival = start+Double(lane)*rng.value(0.65...1.8)
                let duration = max(1.5,route.length/speed)
                var e = event(route:route,at:arrival,duration:duration,length:length,id:idBase+lane)
                e.rig = effect == .enchantedButterflies ? .butterfly : .flame
                e.persistent = true; e.firstAppearance = true; e.behavior = .entering
                e.travelFacing = meeting.x < entrance.x ? -1 : 1
                e.startFacing = e.travelFacing; e.restFacing = e.travelFacing
                e.restBehavior = .resting
                e.companionID = count > 1 ? idBase+(lane == 0 ? 1 : 0) : nil
                latestArrival = max(latestArrival,arrival+duration)
                entries.append(e)
            }
            let departure = latestArrival+rng.value(hearth ? 8...15 : 5...9)
            var finished = departure
            let exit = outside(edge:exitEdge,fraction:rng.value(0.20...0.80))
            for lane in 0..<count {
                var entry = entries[lane]
                let leaveAt = departure+Double(lane)*1.25
                entry.duration = leaveAt-entry.start
                if count > 1 {
                    let partner = lane.isMultiple(of:2) && lane+1 < count ? lane+1 : max(0,lane-1)
                    entry.attentionTarget = meetings[partner]
                    entry.companionID = idBase+partner
                    entry.restFacing = meetings[partner].x < meetings[lane].x ? -1 : 1
                }
                events.append(entry)
                let guide = hearth ? CGPoint(x:meetings[lane].x,y:viewport.maxY+20*scale)
                    : CGPoint(x:(focus.x+exit.x)/2,y:(focus.y+exit.y)/2)
                let route = PageEffectRoute(points:[meetings[lane],guide,exit],initialHeading:entry.route.endHeading)
                var leaving = event(route:route,at:leaveAt,duration:max(2,route.length/speed),length:length,id:idBase+lane)
                leaving.rig = entry.rig; leaving.frame = entry.frame; leaving.phaseOffset = entry.phaseOffset
                leaving.initialDistance = entry.route.length; leaving.persistent = true
                leaving.startFacing = entry.restFacing
                leaving.travelFacing = exit.x < meetings[lane].x ? -1 : 1
                leaving.restFacing = leaving.travelFacing
                leaving.behavior = lane == 0 ? .exiting : .following
                leaving.companionID = lane == 0 ? nil : idBase+lane-1
                events.append(leaving)
                finished = max(finished,leaveAt+leaving.duration)
                if hearth {
                    // Embers have a visible source: the settled flame, not an
                    // unrelated random point in the page interior.
                    for j in 0..<rng.integer(2...4) {
                        let at = latestArrival+Double(j)*2.2+Double(lane)*0.4
                        let end = CGPoint(x:meetings[lane].x+rng.value(-25...25)*scale,y:meetings[lane].y-80*scale)
                        var ember = event(route:PageEffectRoute(points:[meetings[lane],end]),at:at,duration:3,
                                          length:4,id:idBase+20+lane*5+j,asset:"pixieDust")
                        ember.opacity = 0.4; ember.behavior = .ember; ember.companionID = idBase+lane
                        events.append(ember)
                    }
                }
            }
            return Plan(events:events,nextStart:finished+rng.value(3...10))
        }

        switch effect {
        case .fallingRosePetals, .winterMargins:
            let snow = effect == .winterMargins
            let count = rng.integer(snow ? 5...13 : 2...9)
            let wind = rng.value(-18...18)*scale
            let windPhase = Double(seed % 10000)/1700
            var emission = start
            for lane in 0..<count {
                let depth = rng.value(0.65...1.25)
                let length = snow ? rng.value(14...23) : 25+14*(depth-0.65)/0.6
                let earlySnow = snow && lane < 3
                let sideEntry = earlySnow || rng.value(0...1) < 0.22
                let edge = earlySnow ? (rect.minX-viewport.minX < viewport.maxX-rect.maxX ? 0 : 1) : (wind < 0 ? 1 : 0)
                let entrance: CGPoint
                if earlySnow {
                    entrance = CGPoint(x:edge == 0 ? viewport.minX-30*scale : viewport.maxX+30*scale,
                        y:rect.minY+rect.height*(0.08+Double(lane)*0.06))
                } else {
                    entrance = sideEntry ? outside(edge:edge,fraction:rng.value(0.02...0.35),clearance:40)
                        : outside(edge:2,fraction:rng.value(0.06...0.94),clearance:40)
                }
                let flutter = rng.value(0.8...1.5), phase = rng.value(0...(2 * .pi))
                let fall = ParticleFlight.prepare(from:entrance,viewport:viewport,start:emission,
                    scale:scale,terminalSpeed:(snow ? 30 : 38)*depth*scale,
                    wind:wind,windPhase:windPhase,flutter:flutter,phase:phase,
                    sideEntry:sideEntry,snow:snow)
                var e = event(route:fall.route,at:emission,duration:fall.duration,length:length,id:idBase+lane)
                e.timeSampled = true; e.behavior = .falling; e.frame = rng.integer(0...2)
                e.opacity = snow ? 0.60 : 0.45; e.flutterRate = flutter; e.phaseOffset = phase
                e.turns = rng.value(-0.6...0.6)
                events.append(e)
                emission += rng.value(snow ? 0.15...0.9 : 0.2...1.3)
            }
            // A lull is allowed to empty the page. We don't replenish a target count.
            return Plan(events:events,nextStart:emission+rng.value(snow ? 5...13 : 6...18))
        case .paperMessengers, .floatingLanterns:
            let lantern = effect == .floatingLanterns
            let count = rng.integer(1...4), edge = lantern ? 3 : rng.integer(0...1)
            var finished = start
            for lane in 0..<count {
                let from = outside(edge:edge,fraction:rng.value(0.12...0.88))
                let to = outside(edge:lantern ? 2 : 1-edge,fraction:rng.value(0.12...0.88))
                let via = point(lane%2 == 0 ? rect : opposite,rng.value(0.30...0.70),rng.value(0.30...0.70))
                let duration = rng.value(lantern ? 20...30 : 12...18)
                let at = start+Double(lane)*rng.value(0.7...2.2)
                var e = event(route:PageEffectRoute(points:[from,via,to]),at:at,duration:duration,
                              length:rng.value(lantern ? 28...38 : 32...42),id:idBase+lane)
                e.behavior = .flight
                events.append(e); finished = max(finished,at+duration)
            }
            return Plan(events:events,nextStart:finished+rng.value(2...9))
        case .pixieDust:
            let edge = rng.integer(0...1)
            let route = PageEffectRoute(points:[outside(edge:edge,fraction:rng.value(0.1...0.9)),
                point(rect,0.35,0.30),point(opposite,0.65,0.65),outside(edge:1-edge,fraction:rng.value(0.1...0.9))])
            let flight = rng.value(10...16), count = rng.integer(18...28)
            for i in 0..<count {
                let fraction = Double(i)/Double(count-1)
                let p = route.at(distance:route.length*fraction).point
                let drift = CGPoint(x:p.x+8*scale,y:p.y+12*scale)
                var e = event(route:PageEffectRoute(points:[p,drift]),at:start+fraction*flight,
                              duration:rng.value(1...2),length:rng.value(6...11),id:idBase+i)
                e.frame = i%3; e.opacity = 0.45; e.behavior = .trail; e.companionID = idBase
                events.append(e)
            }
            return Plan(events:events,nextStart:start+flight+rng.value(3...10))
        default: return Plan(events:[],nextStart:start+30)
        }
    }
}

/// Semi-implicit drag integration at preparation time. Position samples retain
/// physical time, so a petal can accelerate, catch a gust and regain terminal fall.
enum ParticleFlight {
    static func prepare(from origin: CGPoint, viewport: CGRect, start: Double, scale: Double,
                        terminalSpeed: Double, wind: Double, windPhase: Double,
                        flutter: Double, phase: Double, sideEntry: Bool, snow: Bool)
        -> (route: PageEffectRoute, duration: Double) {
        let dt = 1.0/30
        var point = origin, points = [origin], vx = 0.0, vy = terminalSpeed*0.3
        let inward = origin.x < viewport.minX ? 1.0 : -1.0
        let maximumSteps = max(60,Int(((viewport.height+200*scale)/(terminalSpeed*(snow ? 1 : 0.62))+6)*30))
        for step in 1...maximumSteps {
            let age = Double(step)*dt, time = start+age
            let gust = wind+scale*(18*sin(time*0.37+windPhase)+8*sin(time*0.91+windPhase*0.7))
            let roll = age*flutter+phase
            let targetX = gust + scale*(snow ? 5 : 22)*sin(roll)
                + (sideEntry ? inward*55*scale*exp(-age/3) : 0)
            let targetY = terminalSpeed*(snow ? 1 : 0.62+0.38*abs(cos(roll)))
            vx += (targetX-vx)*(1-exp(-dt*1.6))
            vy += (targetY-vy)*(1-exp(-dt*1.2))
            point.x += vx*dt; point.y += vy*dt
            points.append(point)
            if point.y > viewport.maxY+80*scale { break }
        }
        return (PageEffectRoute(timeSamples:points),Double(points.count-1)*dt)
    }
}

struct EffectRandom {
    var seed: UInt64
    mutating func value(_ range: ClosedRange<Double>) -> Double {
        seed &+= 0x9E3779B97F4A7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return range.lowerBound+Double(z >> 11)/Double(UInt64(1)<<53)*(range.upperBound-range.lowerBound)
    }
    mutating func integer(_ range: ClosedRange<Int>) -> Int {
        min(range.upperBound,range.lowerBound+Int(value(0...1)*Double(range.count)))
    }
}
