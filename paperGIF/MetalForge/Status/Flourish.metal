#include <metal_stdlib>
using namespace metal;

static float mfSdRR(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float mfH21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float mfNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mfH21(i), mfH21(i + float2(1.0, 0.0)), f.x), mix(mfH21(i + float2(0.0, 1.0)), mfH21(i + float2(1.0, 1.0)), f.x), f.y);
}

static float mfFbm(float2 p) {
    float s = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        s += a * mfNoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        a *= 0.5;
    }
    return s;
}

[[ stitchable ]] half4 mfHolo(float2 p, half4 color, float2 size, float t, float mode, float3 c1, float3 c2, float3 c3, float3 c4, float strength, float sz) {
    float w = size.x;
    float h = size.y;
    if (mode < 0.5) {
        float g = (p.x + (h - p.y) * 0.75) / (w + h * 0.75);
        float c = mix(-0.35, 1.35, 1.0 - pow(1.0 - clamp(t / 0.95, 0.0, 1.0), 2.2));
        float bq = (g - c) / (0.13 * sz);
        float band = exp(-bq * bq);
        float x = g * 1.7 - t * 0.6;
        float3 sp = (c1 * (1.0 + 2.0 * cos(6.2831853 * x)) + c2 * (1.0 + 2.0 * cos(6.2831853 * (x - 0.3333333))) + c3 * (1.0 + 2.0 * cos(6.2831853 * (x - 0.6666667)))) / 3.0;
        float sparkle = step(0.9, mfH21(floor(p / 2.5) + floor(t * 14.0))) * band;
        float wq = (t - 0.45) / 0.25;
        float wash = 0.12 * exp(-wq * wq);
        float a = clamp((band * 0.5 + sparkle * 0.6 + wash) * strength, 0.0, 0.95);
        return half4(half3(clamp(mix(sp, c4, sparkle), 0.0, 1.0) * a), half(a));
    }
    float env = 1.0 - smoothstep(0.05, 0.5, t);
    float row = floor(p.y / (3.0 * sz));
    float tick = floor(t * 28.0);
    float on = step(0.62, mfH21(float2(row, tick))) * env;
    float off = (mfH21(float2(row + 7.0, tick)) - 0.5) * w * 0.25 * sz;
    float bar = on * step(fract((p.x + off) / (w * 0.5)), 0.6);
    float scan = step(0.5, fract(p.y / 2.0)) * 0.08 * env;
    float grain = abs(mfH21(p + tick) - 0.5) * 0.12 * env;
    float3 col = mix(c1, c2, mfH21(float2(row, tick + 3.0)));
    float a = clamp((bar * 0.42 + scan + grain) * strength, 0.0, 0.9);
    return half4(half3(col * a), half(a));
}

[[ stitchable ]] half4 mfAura(float2 p, half4 color, float4 tray, float radius, float t, float mode, float3 c1, float3 c2, float3 c3, float strength, float sz) {
    float2 c = tray.xy + tray.zw * 0.5;
    float2 b = tray.zw * 0.5;
    float2 q = p - c;
    float d = mfSdRR(q, b, radius);
    float2 dir = normalize(q + 1e-4);
    float n = mfFbm(dir * 2.4 + float2(d * 0.03 / sz - t * 1.6, t * 0.9));
    float n2 = mfFbm(q * 0.02 / sz + float2(t * 0.5, -t * 0.7));
    float env;
    float fall;
    if (mode < 0.5) {
        env = smoothstep(0.0, 0.22, t) * (1.0 - smoothstep(0.45, 1.5, t));
        fall = 26.0;
    } else {
        float e1 = (t - 0.16) / 0.09;
        float e2 = (t - 0.5) / 0.11;
        env = (exp(-e1 * e1) + 0.65 * exp(-e2 * e2)) * (0.82 + 0.18 * mfNoise(float2(t * 45.0, 1.0)));
        fall = 16.0;
    }
    float dd = max(d + (n2 - 0.5) * 10.0 * sz, 0.0);
    float f = exp(-dd / (fall * sz)) * (0.45 + 0.75 * n) * (1.0 - smoothstep(50.0 * sz, 130.0 * sz, dd));
    float3 col = mix(mix(c1, c2, smoothstep(0.3, 0.7, n)), c3, smoothstep(0.55, 0.9, n2));
    float a = clamp(f * env * 0.62 * strength, 0.0, 0.9);
    return half4(half3(col * a), half(a));
}
