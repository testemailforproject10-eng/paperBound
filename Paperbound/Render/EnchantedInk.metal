#include <metal_stdlib>
using namespace metal;
struct InkUniforms { uint seed; uint transport; uint width; uint height; };
uint inkHash(uint2 p, uint seed) {
    uint h = seed ^ (p.x * 0x9e3779b9u) ^ (p.y * 0x85ebca6bu);
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15;
    h *= 0x846ca68bu; return h ^ (h >> 16);
}
float noise(uint2 p, uint seed) { return float(inkHash(p, seed) & 0x00ffffffu) / 16777215.0; }
constexpr sampler nearestSample(coord::normalized, address::clamp_to_edge, filter::nearest);
constexpr sampler linearSample(coord::normalized, address::clamp_to_edge, filter::linear);

// Positive channels hold optical density; negative channels hold additive light
// pigment. Targets are material data, never an animated visibility mask.
float3 pigmentTarget(float3 paper, float3 finished) {
    return select(log(max(paper, 0.00001526) / max(finished, 0.00001526)),
                  paper - finished, finished > paper);
}
bool printed(float4 p, float4 f) { return any(abs(p.rgb - f.rgb) > 0.0001); }
kernel void inkInitialize(texture2d<float, access::read> paper [[texture(0)]],
                          texture2d<float, access::read> finished [[texture(1)]],
                          texture2d<half, access::write> target [[texture(2)]],
                          uint2 p [[thread_position_in_grid]]) {
    if (p.x >= target.get_width() || p.y >= target.get_height()) return;
    float4 ground = paper.read(p), color = finished.read(p);
    target.write(half4(half3(pigmentTarget(ground.rgb, color.rgb)), printed(ground, color) ? 1 : 0), p);
}
kernel void inkClear(texture2d<half, access::write> state [[texture(0)]],
                     uint2 p [[thread_position_in_grid]]) {
    if (p.x < state.get_width() && p.y < state.get_height()) state.write(half4(0), p);
}
kernel void inkMoisture(texture2d<half, access::read> previous [[texture(0)]],
                        texture2d<half, access::write> next [[texture(1)]],
                        constant InkUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    uint2 size(previous.get_width(), previous.get_height());
    if (any(p >= size)) return;
    float wet = previous.read(p).r;
    float neighbors = 0;
    const int2 offsets[4] = {int2(-1,0), int2(1,0), int2(0,-1), int2(0,1)};
    for (uint i=0; i<4; ++i) {
        uint2 q = uint2(clamp(int2(p) + offsets[i], int2(0), int2(size)-1));
        neighbors += float(previous.read(q).r) - wet;
    }
    float fibre = noise(p / 3, u.seed);
    bool source = noise(p / 7, u.seed ^ 0xace1u) > 0.78;
    float influx = source ? 0.22 : 0.014 + 0.018 * fibre;
    wet = clamp(wet + (u.transport ? 0.18 * neighbors : 0.0) + influx * (1.0 - wet), 0.0, 1.0);
    next.write(half4(half(wet)), p);
}
kernel void inkDeposit(texture2d<half, access::read> targets [[texture(0)]],
                       texture2d<half, access::read> mobile [[texture(2)]],
                       texture2d<half, access::read> deposit [[texture(3)]],
                       texture2d<half, access::sample> moisture [[texture(4)]],
                       texture2d<half, access::write> nextMobile [[texture(5)]],
                       texture2d<half, access::write> nextDeposit [[texture(6)]],
                       constant InkUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    uint2 size(u.width, u.height);
    if (any(p >= size)) return;
    half4 material = targets.read(p);
    if (material.a == 0) {
        nextMobile.write(half4(0), p); nextDeposit.write(half4(0), p); return;
    }
    float3 target = float3(material.rgb);
    float concentration = mobile.read(p).r, exchange = 0;
    const int2 offsets[4] = {int2(-1,0), int2(1,0), int2(0,-1), int2(0,1)};
    for (uint i=0; i<4; ++i) {
        int2 q = int2(p) + offsets[i];
        if (any(q < 0) || any(q >= int2(size))) continue;
        // No pigment transport through counters, whitespace or missing paper.
        if (targets.read(uint2(q)).a > 0)
            exchange += float(mobile.read(uint2(q)).r) - concentration;
    }
    float2 uv = (float2(p) + 0.5) / float2(size);
    float wet = moisture.sample(nearestSample, uv).r;
    float permeability = 0.65 + 0.35 * noise(p / 2, u.seed ^ 0x713u);
    float wetting = wet * wet * wet;
    float reservoir = wetting * (0.02 + 0.16 * noise(p / 9, u.seed));
    concentration = clamp(concentration + (u.transport ? 0.19 * exchange : 0.0)
                          + reservoir * (1.0 - concentration), 0.0, 1.0);
    float3 old = float3(deposit.read(p).rgb);
    float3 amount = old + (target - old) * (concentration * wetting * permeability * 0.50);
    // A local material convergence threshold avoids half-float residue without
    // depending on elapsed time or revealing a finished image.
    amount = select(amount, target, abs(target - amount) < max(abs(target) * 0.002, 0.0002));
    amount = sign(target) * min(abs(target), max(abs(old), abs(amount)));
    nextMobile.write(half4(half(concentration)), p);
    nextDeposit.write(half4(half3(amount), 0), p);
}
struct InkVertex { float4 position [[position]]; float2 uv; };
vertex InkVertex inkVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * float2(2,-2) + float2(-1,1), 0, 1), p};
}
fragment float4 inkFragment(InkVertex v [[stage_in]], texture2d<float> paper [[texture(0)]],
                            texture2d<half> deposit [[texture(1)]]) {
    float4 ground = paper.sample(linearSample, v.uv);
    float3 ink = float3(deposit.sample(nearestSample, v.uv).rgb);
    float3 color = ground.rgb * exp(-max(ink, 0.0)) + max(-ink, 0.0);
    return float4(clamp(color, 0.0, 1.0), ground.a);
}
