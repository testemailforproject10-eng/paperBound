//
//  PageCurl.metal
//  Paperbound
//
//  A leaf curling over a cylinder, as a SwiftUI layer effect. The geometry
//  (fold line and radius) comes from PageCurlGeometry so the Swift side can
//  mask the facing page against exactly the same edge.
//
//  From the reader's side, top to bottom:
//    1. the face-down part of the leaf that has rolled over (x < fold)
//    2. the back of the cylinder (upper half of the roll)
//    3. the front of the cylinder (lower half, still face up)
//    4. the flat, untouched front of the leaf (x < fold)
//    5. past the roll: nothing, except the shadow the roll casts on the page beneath
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float kPi = 3.14159265;

// Paper seen from behind: the stock's own colour with the print showing
// faintly through, reversed.
static half4 leafBack(SwiftUI::Layer layer, float2 source, float shade, float alpha) {
    half4 print = layer.sample(source);
    half ink = 1.0h - dot(print.rgb, half3(0.299h, 0.587h, 0.114h)) * (print.a > 0.0h ? 1.0h : 0.0h);
    half3 paper = half3(0.965h, 0.955h, 0.94h) * half(shade);
    half3 color = paper - ink * 0.07h;
    return half4(color * half(alpha), half(alpha));
}

[[ stitchable ]] half4 pageCurl(float2 position, SwiftUI::Layer layer,
                                float4 page, float2 curl,
                                float seamX, float backAlphaPastSeam) {
    float x = position.x;
    float y = position.y;
    float fold = curl.x;
    float radius = max(curl.y, 0.5);
    float pageMinX = page.x;
    float pageMaxX = page.z;

    if (y < page.y || y > page.w) { return layer.sample(position); }

    float backAlpha = x < seamX ? backAlphaPastSeam : 1.0;

    if (x < fold) {
        // 1. Rolled-over part lying face down. Its source column mirrors
        //    about the far side of the roll.
        float source = 2.0 * fold + kPi * radius - x;
        if (source > fold + kPi * radius && source <= pageMaxX) {
            // Darkest right where it leaves the roll.
            float along = clamp((source - fold - kPi * radius) / max(radius, 1.0), 0.0, 1.0);
            float shade = mix(0.86, 1.0, along);
            return leafBack(layer, float2(source, y), shade, backAlpha);
        }
        // 4. Still flat.
        if (x >= pageMinX) {
            half4 front = layer.sample(position);
            // The page darkens slightly as it rises toward the roll.
            float rise = clamp(1.0 - (fold - x) / (radius * 1.5), 0.0, 1.0);
            return half4(front.rgb * half(1.0 - 0.10 * rise * rise), front.a);
        }
        return layer.sample(position);
    }

    float d = x - fold;
    if (d <= radius) {
        float frontAngle = asin(clamp(d / radius, 0.0, 1.0));
        float backAngle = kPi - frontAngle;

        // 2. Upper half of the roll, seen from behind.
        float backSource = fold + radius * backAngle;
        if (backSource <= pageMaxX) {
            float shade = mix(0.80, 0.98, (backAngle - kPi * 0.5) / (kPi * 0.5));
            return leafBack(layer, float2(backSource, y), shade, 1.0);
        }
        // 3. Lower half, still face up, turning away from the light.
        float frontSource = fold + radius * frontAngle;
        if (frontSource <= pageMaxX) {
            half4 front = layer.sample(float2(frontSource, y));
            float t = frontAngle / (kPi * 0.5);
            return half4(front.rgb * half(1.0 - 0.38 * t * t), front.a);
        }
    }

    // 5. Shadow cast by the roll onto the page beneath.
    float rollEdge = fold + radius;
    float past = x - rollEdge;
    if (past >= 0.0 && x <= pageMaxX + radius) {
        float strength = 0.30 * exp(-past / (radius * 0.9 + 6.0));
        return half4(0.0h, 0.0h, 0.0h, half(strength));
    }
    return half4(0.0h);
}
