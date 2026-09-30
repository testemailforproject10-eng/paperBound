import SwiftUI

/// Small vector flames, evaluated continuously. The base stays anchored while
/// several independent tongues stretch upward and curl in the same draft.
/// No image frames, texture slicing, dynamic blur, or simulation buffers.
enum PageEffectFlameDrawing {
    struct Tongue: Equatable {
        var tip: CGPoint
        var leftShoulder: CGPoint
        var rightShoulder: CGPoint
        var width: Double
    }

    static func tongue(time: Double, lane: Int) -> Tongue {
        let phase = time*2.4 + Double(lane)*2.37
        let height = 0.62 + 0.13*sin(phase*1.71) + 0.07*sin(phase*3.13+1)
        let draft = 0.11*sin(phase*1.23) + 0.06*sin(phase*2.91)
        return Tongue(tip:CGPoint(x:draft*1.7,y:0.44-height),
            leftShoulder:CGPoint(x:-0.20+draft,y:0.20-0.08*sin(phase*2.1)),
            rightShoulder:CGPoint(x:0.20+draft*0.7,y:0.16+0.07*sin(phase*2.4+2)),
            width:0.25+0.025*sin(phase*1.8))
    }

    static func draw(_ sprite: PageEffectSprite, into context: inout GraphicsContext) {
        let blue = sprite.asset == "wanderingWisps"
        let time = sprite.phase / (2 * .pi) * (blue ? 0.55 : 1)
        let w = sprite.size.width, h = sprite.size.height
        func shape(_ tongue: Tongue, x: Double, size: Double) -> Path {
            func p(_ x0: Double, _ y0: Double) -> CGPoint {
                CGPoint(x:(x+x0*size)*w,y:(0.44+(y0-0.44)*size)*h)
            }
            var path = Path()
            path.move(to:p(-tongue.width,0.40))
            path.addCurve(to:p(tongue.leftShoulder.x,tongue.leftShoulder.y),
                control1:p(-0.40,0.22),control2:p(-0.28,0.23))
            path.addCurve(to:p(tongue.tip.x,tongue.tip.y),
                control1:p(tongue.leftShoulder.x+0.04,tongue.leftShoulder.y-0.24),
                control2:p(tongue.tip.x-0.06,tongue.tip.y+0.18))
            // A returning curl makes the tips lean and peel away instead of
            // scaling an unchanged teardrop silhouette.
            path.addCurve(to:p(tongue.rightShoulder.x,tongue.rightShoulder.y),
                control1:p(tongue.tip.x+0.08,tongue.tip.y+0.16),
                control2:p(tongue.rightShoulder.x-0.10,tongue.rightShoulder.y-0.18))
            path.addCurve(to:p(tongue.width,0.40),
                control1:p(0.31,0.20),control2:p(0.37,0.35))
            path.addCurve(to:p(-tongue.width,0.40),control1:p(0.17,0.51),control2:p(-0.17,0.51))
            path.closeSubpath()
            return path
        }
        let outer = blue
            ? [Color(red:0.34,green:0.72,blue:0.98),Color(red:0.08,green:0.40,blue:0.86)]
            : [Color(red:1,green:0.70,blue:0.14),Color(red:0.94,green:0.24,blue:0.05)]
        for lane in [0,2,1] {
            let t = tongue(time:time,lane:lane)
            let size = lane == 1 ? 1.24 : 0.83
            let path = shape(t,x:Double(lane-1)*0.18,size:size)
            context.fill(path,with:.linearGradient(Gradient(colors:outer),
                startPoint:CGPoint(x:0,y:-h*0.4),endPoint:CGPoint(x:0,y:h*0.48)))
        }
        let core = shape(tongue(time:time+0.8,lane:3),x:0,size:0.70)
        let colors = blue ? [Color.white,Color(red:0.49,green:0.89,blue:1)]
                          : [Color(red:1,green:0.98,blue:0.77),Color(red:1,green:0.77,blue:0.18)]
        context.fill(core,with:.linearGradient(Gradient(colors:colors),
            startPoint:CGPoint(x:0,y:0),endPoint:CGPoint(x:0,y:h*0.47)))
        // The expression sits in the calm base, independent of the rising tips.
        let ink = blue ? Color(red:0.09,green:0.24,blue:0.42) : Color(red:0.40,green:0.19,blue:0.08)
        for side in [-1.0,1.0] {
            context.fill(Path(ellipseIn:CGRect(x:(side*0.10-0.025)*w,y:h*0.28,width:w*0.05,height:h*0.065)),with:.color(ink))
        }
        var smile = Path(); smile.move(to:CGPoint(x:-w*0.045,y:h*0.365))
        smile.addQuadCurve(to:CGPoint(x:w*0.045,y:h*0.365),control:CGPoint(x:0,y:h*0.405))
        context.stroke(smile,with:.color(ink),style:StrokeStyle(lineWidth:w*0.016,lineCap:.round))
    }
}
