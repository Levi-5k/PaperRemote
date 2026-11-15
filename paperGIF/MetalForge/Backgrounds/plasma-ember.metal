#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float pe_hash21(float2 p) {
    p = float2(dot(p, float2(91.31, 47.79)),
               dot(p, float2(31.07, 73.13)));
    return fract(sin(p.x + p.y) * 19357.713);
}

static float pe_vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = pe_hash21(i);
    float b = pe_hash21(i + float2(1.0, 0.0));
    float c = pe_hash21(i + float2(0.0, 1.0));
    float d = pe_hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float pe_fbm3(float2 p) {
    float v = pe_vnoise(p) * 0.5;
    v += pe_vnoise(p * 2.0) * 0.3;
    v += pe_vnoise(p * 4.0) * 0.2;
    return v - 0.5;
}

static float3 pe_pal5(float t, float3 c1, float3 c2, float3 c3, float3 c4, float3 c5) {
    t = clamp(t, 0.0, 1.0);
    if (t < 0.25) return mix(c1, c2, smoothstep(0.0, 0.25, t));
    if (t < 0.5)  return mix(c2, c3, smoothstep(0.25, 0.5, t));
    if (t < 0.75) return mix(c3, c4, smoothstep(0.5, 0.75, t));
    return mix(c4, c5, smoothstep(0.75, 1.0, t));
}

[[ stitchable ]] half4 plasmaEmber(float2 position,
                                   half4  color,
                                   float4 boundingRect,
                                   float  time,
                                   half4  c1,
                                   half4  c2,
                                   half4  c3,
                                   half4  c4,
                                   half4  c5,
                                   float  scale,
                                   float  intensity,
                                   float  distortion) {
    float2 size   = boundingRect.zw;
    float2 uv     = position / size;
    float  aspect = size.x / size.y;
    float2 p      = uv - 0.5;
    p.x *= aspect;
    p   *= scale * 1.3;

    float v = 0.0;
    v += sin(p.x * 2.5 + time * 0.6);
    v += sin(p.y * 3.0 + time * 0.8);
    v += sin(length(p) * 2.0 - time * 0.5);
    v += pe_fbm3(p * 2.0 + time * 0.18) * distortion * 3.0;
    v  = (v + 4.0) * 0.125;
    v  = pow(clamp(v, 0.0, 1.0), 1.6) * intensity;

    float3 col = pe_pal5(v, float3(c1.rgb), float3(c2.rgb), float3(c3.rgb), float3(c4.rgb), float3(c5.rgb));
    col += pow(v, 6.0) * 0.55;
    return half4(half3(col), 1.0h);
}
