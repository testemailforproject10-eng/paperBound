import CoreGraphics

/// A prepared arc-length table keeps speed independent of control-point spacing.
/// Headings are unwrapped once, so crossing -π/π cannot snap a sprite around.
struct PageEffectRoute {
    struct Sample {
        var point: CGPoint
        var distance: Double
        var heading: Double
    }
    let samples: [Sample]
    var length: Double { samples.last?.distance ?? 0 }
    var from: CGPoint { samples[0].point }
    var to: CGPoint { samples[samples.count-1].point }
    var endHeading: Double { samples[samples.count-1].heading }

    /// Equally spaced time samples prepared by the falling-particle integrator.
    init(timeSamples points: [CGPoint]) {
        precondition(points.count >= 2)
        var distance = 0.0
        var result: [Sample] = []
        for i in points.indices {
            let previous = points[max(0,i-1)], next = points[min(points.count-1,i+1)]
            if i > 0 { distance += hypot(points[i].x-previous.x,points[i].y-previous.y) }
            result.append(Sample(point:points[i],distance:distance,heading:atan2(next.y-previous.y,next.x-previous.x)))
        }
        samples = result
    }

    func at(timeFraction: Double) -> Sample {
        let position = max(0,min(1,timeFraction))*Double(samples.count-1)
        let i = min(samples.count-2,Int(position)), t = position-Double(i)
        let a = samples[i], b = samples[i+1]
        return Sample(point:CGPoint(x:a.point.x+(b.point.x-a.point.x)*t,y:a.point.y+(b.point.y-a.point.y)*t),
            distance:a.distance+(b.distance-a.distance)*t,heading:a.heading+(b.heading-a.heading)*t)
    }

    init(points: [CGPoint], initialHeading: Double? = nil) {
        precondition(points.count >= 2)
        var result: [Sample] = []
        var distance = 0.0
        var previous = points[0]
        var lastHeading = initialHeading ?? atan2(points[1].y-points[0].y, points[1].x-points[0].x)
        for segment in 0..<(points.count-1) {
            let a = points[segment], b = points[segment+1]
            let before = segment > 0 ? points[segment-1] : a
            let after = segment+2 < points.count ? points[segment+2] : b
            let reach = hypot(b.x-a.x,b.y-a.y) / 3
            let c1 = segment == 0 && initialHeading != nil
                ? CGPoint(x:a.x+cos(lastHeading)*reach,y:a.y+sin(lastHeading)*reach)
                : CGPoint(x:a.x+(b.x-before.x)/6,y:a.y+(b.y-before.y)/6)
            let c2 = CGPoint(x:b.x-(after.x-a.x)/6,y:b.y-(after.y-a.y)/6)
            for index in (segment == 0 ? 0 : 1)...48 {
                let t = Double(index)/48, q = 1-t
                let point = CGPoint(x:q*q*q*a.x+3*q*q*t*c1.x+3*q*t*t*c2.x+t*t*t*b.x,
                                    y:q*q*q*a.y+3*q*q*t*c1.y+3*q*t*t*c2.y+t*t*t*b.y)
                let dx = 3*q*q*(c1.x-a.x)+6*q*t*(c2.x-c1.x)+3*t*t*(b.x-c2.x)
                let dy = 3*q*q*(c1.y-a.y)+6*q*t*(c2.y-c1.y)+3*t*t*(b.y-c2.y)
                let raw = atan2(dy,dx)
                if hypot(dx,dy) > 0.0001 { lastHeading += atan2(sin(raw-lastHeading),cos(raw-lastHeading)) }
                distance += hypot(point.x-previous.x,point.y-previous.y)
                result.append(Sample(point:point,distance:distance,heading:lastHeading))
                previous = point
            }
        }
        samples = result
    }

    func at(distance: Double) -> Sample {
        let target = max(0,min(length,distance))
        var lower = 0, upper = samples.count-1
        while upper-lower > 1 {
            let middle = (upper+lower)/2
            if samples[middle].distance < target { lower = middle } else { upper = middle }
        }
        let a = samples[lower], b = samples[upper]
        let t = (target-a.distance)/max(0.000001,b.distance-a.distance)
        return Sample(point:CGPoint(x:a.point.x+(b.point.x-a.point.x)*t,y:a.point.y+(b.point.y-a.point.y)*t),
                      distance:target,heading:a.heading+(b.heading-a.heading)*t)
    }
}

/// Pure continuous functions shared by production drawing and continuity tests.
enum PageEffectMotion {
    /// During stance the contact distance is constant in the world. During the
    /// swing it advances one stride with a lifted, eased recovery, then replants.
    static func footContact(distance: Double, cycle: Double, offset: Double) -> (distance: Double, lift: Double) {
        let position = distance/cycle+offset
        let step = floor(position), phase = position-step, stance = 0.6
        let planted = (step-offset+stance/2)*cycle
        if phase < stance { return (planted,0) }
        let recovery = (phase-stance)/(1-stance)
        return (planted+ease(recovery)*cycle,pow(sin(.pi*recovery),2))
    }
    static func breeze(time: Double, altitude: Double) -> Double {
        16*sin(time*0.43+altitude*1.5)+7*sin(time*0.79-altitude*2)
    }
    static func ease(_ value: Double) -> Double {
        let t = max(0,min(1,value))
        return t*t*t*(t*(t*6-15)+10)
    }
    /// A short acceleration/braking ramp with a constant-speed middle.
    static func travel(_ value: Double) -> Double {
        let t = max(0,min(1,value)), ramp = 0.18
        if t < ramp { return (t/2-ramp*sin(.pi*t/ramp)/(2 * .pi))/(1-ramp) }
        if t > 1-ramp { return 1-travel(1-t) }
        return (t-ramp/2)/(1-ramp)
    }
    static func activity(age: Double, movingFor: Double) -> Double {
        ease(age/0.3) * (1-ease((age-movingFor+0.5)/0.5))
    }
    static func wingScale(phase: Double, activity: Double) -> Double {
        let open = 0.16 + 0.84*(0.5+0.5*cos(phase))
        return 0.88 + (open-0.88)*activity
    }
}
