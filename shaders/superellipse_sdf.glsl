// 中文说明：几何纹理与单形状解析路径共享同一超椭圆距离场，避免轮廓公式漂移。
// ── Analytic Squircle SDF (Ln-Norm) ─────────────────────────────────────────
// Matches Flutter's native RoundedSuperellipseBorder (ClipRSuperellipse).
// Uses a pure Lamé curve (|x|^n + |y|^n = 1) instead of a piecewise seam.
// This completely eliminates the 45-degree seam blending artifacts.

float fastPow(float x, float n) { 
    return exp2(n * log2(max(x, 1e-4))); 
}

float squircleShape(vec2 p, vec2 b, float zone, float n) {
    vec2 q = abs(p) - b + zone;
    vec2 m = max(q, 0.0);
    float M = max(m.x, m.y);
    float corner = 0.0;
    if (M > 1e-4) {
        vec2 mNorm = m / M;
        corner = M * fastPow(fastPow(mNorm.x, n) + fastPow(mNorm.y, n), 1.0 / n);
    }
    return min(max(q.x, q.y), 0.0) + corner - zone;
}

// sdfSquircle: analytic squircle SDF with graceful degradation.
//
// CRITICAL: n (the Lamé exponent) is derived from the CLAMPED zone, not the
// raw r*1.528 zone. This ensures the SDF's lighting and gradient match
// Flutter's RoundedSuperellipseBorder path exactly:
//
//   Normal squircle  → zone = r*1.528 (unclamped) → n ≈ 3.26
//   Partial clamp    → zone < r*1.528              → n smoothly decreases
//   Full pill clamp  → zone = r (r ≥ half-height)  → n = 2.0 (pure circle)
//
// Without this, the shader draws a squarish SDF (n≈3.26) inside a clip that
// Flutter already forced to a circle (n=2), causing the lighting/glow to
// appear misaligned from the visual edge on pill-shaped squircles.
float sdfSquircle(in vec2 p, in vec2 b, in float r) {
    float boxShort = min(b.x, b.y);
    r    = min(r, boxShort);
    float zone = min(r * 1.528, boxShort);
    float base = 1.0 - 0.29289322 * (r / max(zone, 1e-4));
    float n    = -1.0 / log2(clamp(base, 0.5, 0.9999));
    return squircleShape(p, b, zone, n);
}

float sdfSquircleAsym(in vec2 p, in vec2 b, in float rTop, in float rBottom) {
    float boxShort = min(b.x, b.y);
    rTop    = min(rTop,    boxShort);
    rBottom = min(rBottom, boxShort);

    float zoneT = min(rTop    * 1.528, boxShort);
    float baseT = 1.0 - 0.29289322 * (rTop    / max(zoneT, 1e-4));
    float nT    = -1.0 / log2(clamp(baseT, 0.5, 0.9999));
    float dT    = squircleShape(p, b, zoneT, nT);

    float zoneB = min(rBottom * 1.528, boxShort);
    float baseB = 1.0 - 0.29289322 * (rBottom / max(zoneB, 1e-4));
    float nB    = -1.0 / log2(clamp(baseB, 0.5, 0.9999));
    float dB    = squircleShape(p, b, zoneB, nB);

    float t = smoothstep(-2.0, 2.0, p.y);
    return mix(dT, dB, t);
}

