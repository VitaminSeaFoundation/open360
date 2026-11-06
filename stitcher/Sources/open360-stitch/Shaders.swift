// Metal source is compiled at runtime (no Xcode / metal toolchain required).
let stitchShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

// Parameter block layout (floats), see Stitcher.packParams():
//  [0..11]  view->body rotation rows (r0.xyz,_, r1.xyz,_, r2.xyz,_)
//  [12] outW  [13] outH  [14] feather (rad)  [15] 1/stitch distance (1/m, 0 = infinity)
//  [16] output projection: 0 = equirect 360
//  [17] lens1 luma gain  [18] lens texture width  [19] lens texture height (luma px)
//  lens i at 32 + 48*i (all image quantities normalised to the lens image, v from top):
//     [0] xi [1] fx [2] fy [3] cx [4] cy  [5..8] k1..k4  [9..10] p1 p2  [11..14] s1..s4
//     [15..17] translation  [18] image-circle radius  [19] u offset  [20] u scale
//     [21..23] radial profile r0, a1, a2:  scale = r0 (1 + a1 u^2 + a2 u^4), u = theta/90deg
//     [24..35] lens rotation rows (3 x float4)
//  accessory at 128: [0..4] bare h(theta) poly, [5..9] accessory poly, [10] enabled

struct LensSample { float2 uv; float valid; };

static float3 viewDir(float2 p, constant float* P) {
    float W = P[12], H = P[13];
    float lon = (p.x / W) * 2.0f * M_PI_F - M_PI_F;
    float lat = M_PI_2_F - (p.y / H) * M_PI_F;
    float3 d = float3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon));
    float3 r0 = float3(P[0], P[1], P[2]), r1 = float3(P[4], P[5], P[6]), r2 = float3(P[8], P[9], P[10]);
    return float3(dot(r0, d), dot(r1, d), dot(r2, d));
}

static float poly5(constant float* c, float t) { return c[0] + t * (c[1] + t * (c[2] + t * (c[3] + t * c[4]))); }

static LensSample project(float3 cam, constant float* L, float invDist, constant float* A) {
    float3 r0 = float3(L[24], L[25], L[26]), r1 = float3(L[28], L[29], L[30]), r2 = float3(L[32], L[33], L[34]);
    float3 c = float3(dot(r0, cam), dot(r1, cam), dot(r2, cam));
    c = normalize(c - float3(L[15], L[16], L[17]) * invDist);
    LensSample s;
    float den = c.z + L[0];
    if (den <= 1e-4f) { s.uv = float2(-1); s.valid = 0; return s; }
    float x = c.x / den, y = c.y / den;
    float q = x * x + y * y;
    float rad = 1.0f + q * (L[5] + q * (L[6] + q * (L[7] + q * L[8])));
    float xd = x * rad + 2.0f * L[9] * x * y + L[10] * (q + 2.0f * x * x) + L[11] * q + L[12] * q * q;
    float yd = y * rad + L[9] * (q + 2.0f * y * y) + 2.0f * L[10] * x * y + L[13] * q + L[14] * q * q;
    float thd = max(1.0f, acos(clamp(c.z, -1.0f, 1.0f)) * 57.2957795f);
    float uu = thd / 90.0f; uu *= uu;
    float sc = L[21] * (1.0f + uu * (L[22] + uu * L[23]));
    if (A[10] > 0.5f) sc *= poly5(A + 5, thd) / poly5(A, thd);
    float u = L[1] * xd * sc + L[3];
    float v = L[2] * yd * sc + L[4];
    float du = u - L[3], dv = v - L[4];
    s.valid = (du * du + dv * dv < L[18] * L[18] && u > 0.0f && u < 1.0f && v > 0.0f && v < 1.0f) ? 1.0f : 0.0f;
    s.uv = float2(L[19] + u * L[20], v);
    return s;
}

// Returns weight for lens 0 and both sample positions.
static float blendWeights(float2 p, constant float* P, thread LensSample& a, thread LensSample& b) {
    float3 d = viewDir(p, P);
    // parallax (stitch distance) correction only matters at the seam: fade it out over 20 deg
    float el0 = asin(clamp(d.z, -1.0f, 1.0f));
    float invDist = P[15] * clamp(1.0f - fabs(el0) / 0.349f, 0.0f, 1.0f);
    a = project(float3(d.x, -d.y, d.z), P + 32, invDist, P + 128);
    b = project(float3(-d.x, -d.y, -d.z), P + 80, invDist, P + 128);
    float elev = asin(clamp(d.z, -1.0f, 1.0f));
    float w = clamp(elev / P[14] * 0.5f + 0.5f, 0.0f, 1.0f);
    w = w * w * (3.0f - 2.0f * w);
    if (a.valid < 0.5f) w = 0.0f;
    if (b.valid < 0.5f) w = (a.valid > 0.5f) ? 1.0f : w;
    return w;
}

kernel void stitchLuma(texture2d<float, access::sample> yA [[texture(0)]],
                       texture2d<float, access::sample> yB [[texture(1)]],
                       texture2d<float, access::write> outY [[texture(2)]],
                       constant float* P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outY.get_width() || gid.y >= outY.get_height()) return;
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    LensSample a, b;
    float w = blendWeights(float2(gid) + 0.5f, P, a, b);
    float va = yA.sample(smp, a.uv).r;
    float vb = yB.sample(smp, b.uv).r;
    // lens-1 exposure match applied around video-range black (64/1023)
    const float blk = 64.0f / 1023.0f;
    vb = blk + (vb - blk) * P[17];
    outY.write(float4(mix(vb, va, w)), gid);
}

kernel void stitchChroma(texture2d<float, access::sample> cA [[texture(0)]],
                         texture2d<float, access::sample> cB [[texture(1)]],
                         texture2d<float, access::write> outC [[texture(2)]],
                         constant float* P [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outC.get_width() || gid.y >= outC.get_height()) return;
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    // chroma plane may be subsampled; work in luma pixel coordinates
    float sx = P[12] / float(outC.get_width());
    float sy = P[13] / float(outC.get_height());
    float2 p = (float2(gid) + 0.5f) * float2(sx, sy);
    // lens textures are luma-sized for UV math; chroma texture uses the same normalized coords
    LensSample a, b;
    float w = blendWeights(p, P, a, b);
    float2 va = cA.sample(smp, a.uv).rg;
    float2 vb = cB.sample(smp, b.uv).rg;
    outC.write(float4(mix(vb, va, w), 0, 0), gid);
}

// Low resolution grayscale preview used for automatic stitch-distance / exposure estimation.
kernel void seamProbe(texture2d<float, access::sample> yA [[texture(0)]],
                      texture2d<float, access::sample> yB [[texture(1)]],
                      device float* out [[buffer(1)]],
                      constant float* P [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    // grid: x = sample along seam (W), y = elevation offset index (H)
    // Writes (lensA, lensB) luma for each seam-band sample.
    uint W = uint(P[12]), H = uint(P[13]);
    if (gid.x >= W || gid.y >= H) return;
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float az = (float(gid.x) + 0.5f) / float(W) * 2.0f * M_PI_F;
    float el = ((float(gid.y) + 0.5f) / float(H) - 0.5f) * P[14] * 2.0f;  // within +-band
    // body frame direction: z = sin(el) (lens axis), xy around the seam ring
    float3 d = float3(cos(el) * cos(az), cos(el) * sin(az), sin(el));
    float invDist = P[15];
    LensSample a = project(float3(d.x, -d.y, d.z), P + 32, invDist, P + 128);
    LensSample b = project(float3(-d.x, -d.y, -d.z), P + 80, invDist, P + 128);
    uint i = (gid.y * W + gid.x) * 3;
    out[i] = yA.sample(smp, a.uv).r;
    out[i + 1] = yB.sample(smp, b.uv).r;
    out[i + 2] = (a.valid > 0.5f && b.valid > 0.5f && abs(d.y) < 0.9f) ? 1.0f : 0.0f;
}
"""#
