// Copyright 2026, Sebastian Degenaar for pixel-innovations.com (liquid_glass_widgets)
//
// SPDX-License-Identifier: MIT
//
// Original work — iOS 26-style liquid glass refraction shader for interactive
// indicators (segmented controls, pills). Fully original implementation.

#include <flutter/runtime_effect.glsl>
// 中文说明：Flutter 的增量 Shader 构建不会把自定义 #include 记录为入口依赖。
// 此校验值对应 edge_treatment.glsl 的规范化 UTF-8 内容；修改共享边缘算法后，
// 必须同步更新三个入口。入口文件内容因此发生变化，旧编译产物才不会被继续复用。
  // POIESIS_EDGE_TREATMENT_ADLER32: c288c981
#include "edge_treatment.glsl"
#include "gles_compat.glsl"

precision highp float;

/*
  iOS 26 LIQUID GLASS INDICATOR SHADER
  =====================================
  
  This shader creates the liquid glass refraction effect for interactive
  indicators (like the pill in a segmented control). It samples a captured
  background texture and applies edge distortion to simulate light bending
  through glass.
  
  COORDINATE SYSTEM:
  - All calculations use LOGICAL pixels (not physical/device pixels)
  - uBackgroundOrigin and uBackgroundSize are in logical pixels
  - This avoids DPR scaling issues across different devices
  
  MAIN EFFECTS:
  1. Edge refraction - bends the background image at the pill edges
  2. Chromatic aberration - separates RGB channels at edges for prism effect
  3. Directional lighting - rim highlights based on light angle
  4. Fresnel glow - subtle glow at grazing angles
  5. Synthetic bevel gradient - top-bright / bottom-dim rim falloff that
     simulates the view-angle gradient of a real 3D Impeller bevel
*/

// -----------------------------------------------------------------------------
// UNIFORMS
// -----------------------------------------------------------------------------
// We pack uniforms into vec4s to avoid Metal's 14 constant buffer limit on the iOS Simulator.
uniform vec4 uData0; // 0..3 (size.x, size.y, origin.x, origin.y)
uniform vec4 uData1; // 4..7 (glassColor)
uniform vec4 uData2; // 8..11 (thickness, lightDir.x, lightDir.y, lightIntensity)
uniform vec4 uData3; // 12..15 (ambientStrength, saturation, refractiveIndex, chromaticAberration)
uniform vec4 uData4; // 16..19 (cornerRadius, scale.x, scale.y, glowIntensity)
uniform vec4 uData5; // 20..23 (densityFactor, interactionIntensity, bgOrigin.x, bgOrigin.y)
uniform vec4 uData6; // 24..27 (bgSize.width, bgSize.height, hasBackground, ambientRim)
uniform vec4 uData7; // 28..31 (baseAlphaMultiplier, edgeAlphaMultiplier, rimThickness, rimSmoothing)
// 32:  uDpr (float)  — device pixel ratio for hardware-filtered sampling
// 33:  uEdgeAbsorption — Beer-Lambert meniscus rim darkening strength [0..1]
// 34:  uPinchStrength — animated concave lens pinch [0..1]
// 35:  uVisibility — glass fade, kept separate from transparent tint colours

uniform sampler2D uTexture;         // Captured background image

// 32: Device pixel ratio — passed from Dart _RenderInteractiveIndicator.
// The background texture is now captured at full DPR resolution, so the
// physical texel size = logical uBackgroundSize * uDpr.
uniform float uDpr;

// 33: Meniscus rim darkening — Beer-Lambert absorption at the pill boundary.
// 广域弯月面吸收先作用于玻璃体；最外终止暗边会在所有镜面光之后再次合成，
// 让外轮廓保持灰黑、白色反射停留在内侧。公式与另外两条路径共用。
// Range: 0.0 (flat, no absorption) → 1.0 (fully dark rim).
// iOS 26 reference calibrated at ~0.15.
uniform float uEdgeAbsorption;

// 34: Concave horizontal-pinch strength driven by AnimatedGlassIndicator.
uniform float uPinchStrength;

// 35: Explicit visibility. The default indicator tint can be fully transparent,
// so tint alpha cannot also carry the glass fade without losing the lens body.
uniform float uVisibility;

out vec4 fragColor;

// ── Hardware Bilinear Filtering ───────────────────────────────────────────
// 中文说明：这个 Shader 的纹理由 Dart 通过 setImageSampler(...,
// FilterQuality.medium) 显式绑定，Flutter 3.41+ 已能使用硬件线性采样。旧实现
// 仍手写四次 texture() 再 mix，导致普通折射 4 次、色散边缘 12 次纹理读取。
// 保留半 texel clamp 后交给采样器完成线性插值，像素边界语义不变，而采样数
// 分别降为 1 次和 3 次。Premium 的实时 backdrop 已回到官方最终 Shader。
vec4 sampleBackground(vec2 uv, vec2 physSize) {
    vec2 halfTexel = 0.5 / max(physSize, vec2(1.0));
    return texture(uTexture, clamp(uv, halfTexel, vec2(1.0) - halfTexel));
}

vec3 evaluateIndicatorRoundedRectSdfAt(
    vec2 localPoint,
    vec2 size,
    float cornerRadius
) {
    vec2 halfSize = size * 0.5;
    vec2 centered = localPoint - halfSize;
    vec2 innerHalfSize = halfSize - cornerRadius;
    vec2 closestOnSkeleton = clamp(
        centered,
        -innerHalfSize,
        innerHalfSize
    );
    vec2 toEdge = centered - closestOnSkeleton;
    float edgeLength = length(toEdge);
    vec2 q = abs(centered) - halfSize + cornerRadius;
    float signedDistance =
        length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cornerRadius;
    vec2 normal = edgeLength > 0.001
        ? toEdge / edgeLength
        : vec2(0.0);
    return vec3(signedDistance, normal);
}

vec3 sampleIndicatorEdgeAtOffset(
    vec2 pixelOffset,
    vec2 fragPx,
    vec2 origin,
    vec2 scale,
    vec2 size,
    float cornerRadius,
    vec2 lightRimProfile,
    vec2 darkRimProfile
) {
    // 中文说明：每个子样本从物理片元坐标重新映射到指示器本地坐标，并独立
    // 求圆角矩形 SDF 与法线。这样按压/切换动画中的非均匀缩放不会把八点采样
    // 错误压到同一法线直线上，左右圆弧的覆盖率也不会再随相位突然跳变。
    vec2 sampleLocal = (fragPx + pixelOffset - origin) / scale;
    vec3 sampleSdf = evaluateIndicatorRoundedRectSdfAt(
        sampleLocal,
        size,
        cornerRadius
    );
    vec2 sampleNormal = sampleSdf.yz;
    vec2 safeScale = max(abs(scale), vec2(0.0001));
    float sampleDistanceScale = getSdfDistanceScale(
        sampleNormal / safeScale
    );
    return getSupersampledSdfEdgeContribution(
        sampleSdf.x,
        lightRimProfile.x * sampleDistanceScale,
        darkRimProfile.x * sampleDistanceScale,
        sampleNormal.x,
        lightRimProfile.y,
        darkRimProfile.y
    );
}

void main() {
  vec2 uSize = uData0.xy;
  vec2 uOrigin = uData0.zw;
  vec4 uGlassColor = uData1;
  float uThickness = uData2.x;
  vec2 uLightDirection = uData2.yz;
  float uLightIntensity = uData2.w;
  float uAmbientStrength = uData3.x;
  float uSaturation = uData3.y;
  float uRefractiveIndex = uData3.z;
  float uChromaticAberration = uData3.w;
  float uCornerRadius = uData4.x;
  vec2 uScale = uData4.yz;
  float uGlowIntensity = uData4.w;
  float uDensityFactor = uData5.x;
  float uInteractionIntensity = uData5.y;
  vec2 uBackgroundOrigin = uData5.zw;
  vec2 uBackgroundSize = uData6.xy;
  float uHasBackground = uData6.z;
  float uAmbientRim = uData6.w;
  float uBaseAlphaMultiplier = uData7.x;
  float uEdgeAlphaMultiplier = uData7.y;
  float uRimThickness = uData7.z;
  float uRimSmoothing = uData7.w;

  // ==========================================================================
  // COORDINATE SETUP
  // ==========================================================================
  // FlutterFragCoord gives pixel position within the current drawing layer.
  // Since we're inside a RepaintBoundary layer, this starts at (0,0).
  
  vec2 fragPx = FlutterFragCoord().xy;
  
  // Convert to local logical position (0 to uSize)
  // Note: uOrigin is (0,0) and uScale is (1,1) due to layer boundaries
  vec2 localLogical = (fragPx - uOrigin) / uScale;
  // 中文说明：交互指示器与普通玻璃共用局部逻辑高度。小尺寸使用顶部
  // 15% / 底部 30%，大尺寸封顶 10dp / 20dp；按压缩放时仍跟随胶囊本体。
  float glassVerticalPosition = clamp(
    localLogical.y / max(uSize.y, 0.0001),
    0.0,
    1.0
  );
  float verticalAreaHighlightExposureLift = getVerticalAreaHighlightExposureLift(
    glassVerticalPosition,
    uSize.y
  );
  vec2 center = uSize * 0.5;
  vec2 normalizedP = (localLogical - center) / center;
  float radialDist = length(normalizedP);  // 0 at center, 1 at edge
  
  // ==========================================================================
  // SDF PILL SHAPE
  // ==========================================================================
  // Using a standard high-fidelity Rounded Rectangle SDF for lighting stability.
  
  vec3 centerSdf = evaluateIndicatorRoundedRectSdfAt(
    localLogical,
    uSize,
    uCornerRadius
  );
  float dist = centerSdf.x;

  // ==========================================================================
  // SURFACE NORMAL
  // ==========================================================================
  // 中文说明：光学效果继续使用中心法线；只有外形 alpha 与双层结构边执行
  // 八点重建，避免把背景折射和色散纹理读取也放大八倍。
  vec2 surfaceNormal = centerSdf.yz;

  // 中文说明：外形 alpha 和双层描边共享当前 SDF 屏幕梯度。方形像素的
  // AA 足迹使用 L1 投影，线宽换算单独使用 L2 长度；这样既补足斜向圆弧
  // 的覆盖窗口，也不会让 45° 处因抗锯齿变宽而产生新的粗边。
  vec2 safeRimScale = max(abs(uScale), vec2(0.0001));
  vec2 rimScreenGradient = surfaceNormal / safeRimScale;
  float rimDistanceScale = getSdfDistanceScale(rimScreenGradient);
  float rimPixelFootprint = getSdfPixelFootprint(rimScreenGradient);
  float smoothing = 1.0 / uScale.x;

  const float lightRimLogicalWidth = 0.36;
  const float darkRimLogicalWidth = 0.18;
  float safeDpr = max(uDpr, 1.0);
  vec2 lightRimProfile = getEnergyPreservingRimProfile(
    lightRimLogicalWidth * safeDpr
  );
  vec2 darkRimProfile = getEnergyPreservingRimProfile(
    darkRimLogicalWidth * safeDpr
  );
  float lightRimWidth = lightRimProfile.x * rimDistanceScale;
  float darkRimWidth = darkRimProfile.x * rimDistanceScale;

  float centerCoverage = clamp(
    0.5 - dist / rimPixelFootprint,
    0.0,
    1.0
  );
  if (centerCoverage <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }

  vec3 supersampledEdge;
  float centerInwardDistance = max(-dist, 0.0);
  float edgeSamplingReach = max(lightRimWidth, darkRimWidth)
      + rimPixelFootprint * 0.5;
  if (centerCoverage >= 1.0 && centerInwardDistance > edgeSamplingReach) {
    // 中文说明：八点 SDF 只在终止边窄带执行；完整内部直接使用满覆盖率，
    // 后续折射与背景采样数量不变，避免高画质边缘影响整块指示器的成本。
    supersampledEdge = vec3(1.0, 0.0, 0.0);
  } else {
    vec3 edgeSampleSum =
        sampleIndicatorEdgeAtOffset(kEdgeRgss0, fragPx, uOrigin, uScale, uSize, uCornerRadius, lightRimProfile, darkRimProfile)
      + sampleIndicatorEdgeAtOffset(kEdgeRgss1, fragPx, uOrigin, uScale, uSize, uCornerRadius, lightRimProfile, darkRimProfile)
      + sampleIndicatorEdgeAtOffset(kEdgeRgss2, fragPx, uOrigin, uScale, uSize, uCornerRadius, lightRimProfile, darkRimProfile)
      + sampleIndicatorEdgeAtOffset(kEdgeRgss3, fragPx, uOrigin, uScale, uSize, uCornerRadius, lightRimProfile, darkRimProfile)
      + sampleIndicatorEdgeAtOffset(kEdgeRgss4, fragPx, uOrigin, uScale, uSize, uCornerRadius, lightRimProfile, darkRimProfile)
      + sampleIndicatorEdgeAtOffset(kEdgeRgss5, fragPx, uOrigin, uScale, uSize, uCornerRadius, lightRimProfile, darkRimProfile)
      + sampleIndicatorEdgeAtOffset(kEdgeRgss6, fragPx, uOrigin, uScale, uSize, uCornerRadius, lightRimProfile, darkRimProfile)
      + sampleIndicatorEdgeAtOffset(kEdgeRgss7, fragPx, uOrigin, uScale, uSize, uCornerRadius, lightRimProfile, darkRimProfile);
    supersampledEdge = resolveEdgeSupersample(edgeSampleSum);
  }
  float mask = supersampledEdge.x;
  float continuousLightRimMask = supersampledEdge.y;
  float lateralDarkRimMask = supersampledEdge.z;

  // ==========================================================================
  // BACKGROUND REFRACTION (THE MAIN EFFECT)
  // ==========================================================================
  // Sample the background texture with UV coordinates.
  // All values are in LOGICAL pixels for consistency.
  
  vec2 posInBg = uBackgroundOrigin + localLogical;
  vec2 physBgSize = max(uBackgroundSize * uDpr, vec2(1.0));
  
  // --------------------------------------------------------------------------
  // EDGE DISTORTION
  // --------------------------------------------------------------------------
  // Creates the "liquid lens" effect at the pill edges by bending the
  // sampled background position inward along the surface normal.
  
  float distFromEdge = abs(dist);
  float rimDistance = max(-dist, 0.0);

  // 中文说明：双层边的真实覆盖面积已经由上方八点重建完成。中心距离只保留
  // 给折射、Fresnel 与白色高光避让，避免改变用户已经确认的玻璃光学观感。
  float innerHighlightGate = getInnerHighlightGate(
    distFromEdge,
    lightRimWidth,
    uEdgeAbsorption
  );
  
  // TWEAK: edgeZone - How far from the edge the distortion extends (logical px)
  //   Smaller = sharper transition, concentrated at very edge
  //   Larger = softer, more gradual effect spreading inward
  float edgeZone = 14.0;
  
  // Calculate influence: 1.0 at edge, 0.0 at edgeZone pixels inward
  float edgeInfluence = smoothstep(edgeZone, 0.0, distFromEdge);
  
  // TWEAK: Quadratic falloff makes the bend gentler (less abrupt)
  //   Use edgeInfluence directly for sharper edge effect
  //   Use edgeInfluence * edgeInfluence for gentler, more natural curve
  //   Use pow(edgeInfluence, 3.0) for even gentler effect
  edgeInfluence = edgeInfluence * edgeInfluence;
  
  // TWEAK: bendStrength - Overall refraction intensity
  //   Base (0.9): stronger edge lens distortion, closer to Impeller volumetric warp
  //   Range: 0.45 (rest) → 1.17 (fully pressed)
  float bendStrength = 0.9 * (0.5 + uInteractionIntensity * 0.7);
  
  // TWEAK: The final multiplier (uSize.y * 0.35) scales by widget height
  //   0.35 means max offset is 35% of widget height
  //   Increase for more dramatic effect, decrease for subtler
  vec2 edgeOffsetLogical = surfaceNormal * edgeInfluence * bendStrength * uSize.y * 0.35;
  // Standard 只使用 Dart 显式绑定的纹理；Premium 的实时采样与坐标变换由
  // liquid_glass_final_render.frag 和官方 LiquidGlassLayer 统一负责。
  #ifdef LGR_GLES_FLIP_SAMPLE_Y
    vec2 localRefracted = posInBg + vec2(edgeOffsetLogical.x, -edgeOffsetLogical.y);
  #else
    vec2 localRefracted = posInBg - edgeOffsetLogical;
  #endif
  vec2 refractedUv = localRefracted / uBackgroundSize;

  // 中文说明：直接在解析式 SDF 上计算凹透镜 pinch，不再依赖几何 matte。
  // L4 superellipse 让宽胶囊的上下边保持平直，mask 把偏移在 AA 边缘羽化为
  // 零，避免玻璃内外背景坐标突然跳变。该公式与完整 Premium Shader 同源。
  if (uPinchStrength > 0.001) {
    vec2 geometryUv = localLogical / uSize;
    vec2 centered = geometryUv - vec2(0.5);
    vec2 absCentered = abs(centered) * 2.0;
    float x2 = absCentered.x * absCentered.x;
    float y2 = absCentered.y * absCentered.y;
    float squircleDist = sqrt(sqrt(x2 * x2 + y2 * y2));
    float pinchRamp = smoothstep(0.0, 1.0, squircleDist);
    vec2 pinchShift = centered * pinchRamp * uPinchStrength * 0.025 * mask;
    refractedUv += pinchShift;
  }
  
  // --------------------------------------------------------------------------
  // CHROMATIC ABERRATION
  // --------------------------------------------------------------------------
  // Separates RGB channels slightly at edges, creating a subtle prism effect.
  // Red shifts one way, blue shifts the opposite, green stays centered.
  
  // TWEAK: (0.12) - subtle chromatic shift for "Apple style" refraction
  vec2 distort = surfaceNormal * edgeInfluence * uChromaticAberration;
  vec2 chromaticShift = distort * 0.12; 
  
  vec3 bg;
  if (uHasBackground > 0.5) {
    if (uChromaticAberration < 0.001) {
      // No chromatic aberration — one hardware-filtered texture fetch.
      bg = sampleBackground(refractedUv, physBgSize).rgb;
    } else {
      // Chromatic aberration: three hardware-filtered fetches, one per channel.
      vec2 chromaticShiftUv = chromaticShift / uBackgroundSize;
      vec3 colR = sampleBackground(refractedUv + chromaticShiftUv, physBgSize).rgb;
      vec3 colG = sampleBackground(refractedUv, physBgSize).rgb;
      vec3 colB = sampleBackground(refractedUv - chromaticShiftUv, physBgSize).rgb;
      bg = vec3(colR.r, colG.g, colB.b);
    }
  } else {
    // SYNTHETIC LIQUID: Use the passed indicator color
    // This allows the standard mode to respect the color passed to the widget
    bg = uGlassColor.rgb;
  }
  
  // uLightDirection is passed from Dart as [cos(angle), -sin(angle)]
  float edgeLightCatch = dot(surfaceNormal, uLightDirection);
  
  // Key light: bright highlight on edges facing the light
  // PP2: pow(x, 8.0) replaced with multiply chain — zero transcendentals.
  // x^8 = ((x^2)^2)^2 — 3 multiplies vs exp(8·log(x)).
  // Same optimisation already applied in lightweight_glass.frag.
  float lc  = max(edgeLightCatch,  0.0);
  float lc2 = lc  * lc;
  float lc4 = lc2 * lc2;
  float keyHighlight = lc4 * lc4 * uLightIntensity * 0.5;  // lc^8
  
  // Kick light: subtle highlight on opposite edge (back-reflection)
  // PP2: pow(x, 12.0) = x^8 * x^4 — 4 multiplies vs transcendental.
  float kc  = max(-edgeLightCatch, 0.0);
  float kc2 = kc  * kc;
  float kc4 = kc2 * kc2;
  float kc8 = kc4 * kc4;
  float kickHighlight = kc8 * kc4 * uLightIntensity * 0.5; // kc^12
  
  // TWEAK: ambientRim - minimum rim brightness regardless of light direction
  float rimBrightness = uAmbientRim + keyHighlight + kickHighlight;
  
  // ==========================================================================
  // FRESNEL GLOW
  // ==========================================================================
  // Subtle glow at grazing angles (edges appear slightly brighter)
  
  // PP2: pow(radialDist, 2.0) → radialDist * radialDist (1 multiply, no transcendental).
  float fresnel = (radialDist * radialDist) * 0.25 * innerHighlightGate;
  
  // ==========================================================================
  // HAIRLINE RIM
  // ==========================================================================
  // Thin bright line at the very edge of the pill
  
  // Configurable hairline rim
  float borderMask = 1.0 - smoothstep(0.0, smoothing * uRimSmoothing, distFromEdge - uRimThickness);

  // 中文说明：高光环只在暗色终止边内侧可见；关闭 edgeAbsorption 时共享
  // gate 恒为 1，不改变第三方包原始的 hairline rim 行为。
  borderMask *= innerHighlightGate;

  // --------------------------------------------------------------------------
  // SYNTHETIC BEVEL GRADIENT
  // --------------------------------------------------------------------------
  // The Impeller 3D bevel naturally brightens at the top because the top-face
  // normals angle toward the viewer, catching more ambient light. On a flat 2D
  // ring every point gets the same brightness, which reads as "fake".
  //
  // We simulate this by blending rim brightness with a vertical gradient derived
  // from the Y component of the surface normal:
  //   surfaceNormal.y < 0  → top of pill  → brighter (add bevelBoost)
  //   surfaceNormal.y > 0  → bottom       → dimmer   (subtract bevelDip)
  //
  // This is pure ALU — no texture samples, no uniforms required.
  // kBevelStrength: calibrated so the gradient reads clearly on large pills
  // (tab bar ~50px) without being aggressive on small elements (switch thumb ~22px).
  const float kBevelStrength = 0.18;
  // normalY range: -1 (top edge) to +1 (bottom edge) in Flutter's Y-down space
  float bevelGradient = -surfaceNormal.y * kBevelStrength;
  // Blend the gradient in only where the border mask is visible to avoid
  // affecting the body of the pill.
  // Clamp to 0.0: gradient dims the bottom rim to neutral, never to negative
  // (negative values subtract from finalColor and cause dark jagged artefacts).
  float modifiedRimBrightness = max(0.0, rimBrightness + bevelGradient * borderMask);

  // Scale rim brightness with ambientRim parameter
  vec3 rimColor = vec3(1.0) * modifiedRimBrightness * (uAmbientRim * 10.0);
  
  // ==========================================================================
  // COMPOSITE FINAL COLOR
  // ==========================================================================
  
  // Start with background — glass transmits and adds luminosity, not darkness.
  float bgBoost = uSaturation;
  vec3 finalColor = (uHasBackground > 0.5) ? (bg * bgBoost) : bg;
  
  // Rim highlight: primary + secondary bevel definition collapsed to one operation.
  // Was: finalColor += rimColor * borderMask; finalColor += rimColor * borderMask * 0.5;
  // 1.5× is mathematically identical with one fewer MAD per border fragment.
  finalColor += rimColor * borderMask * 1.5;

  // Add fresnel glow — uGlowIntensity controls how visible the glass-edge luminosity is.
  finalColor += vec3(1.0) * fresnel * uGlowIntensity;
  
  // Interior light lift — matches Premium Impeller's internal SDF specular glow.
  finalColor += vec3(uAmbientStrength);
  
  // Apply glass tint color
  finalColor = mix(finalColor, finalColor + uGlassColor.rgb * 0.2, uGlassColor.a);

  // ==========================================================================
  // MENISCUS RIM DARKENING (Beer-Lambert absorption) — applied LAST
  // ==========================================================================
  // Three physics improvements over a naive isotropic absorption:
  //
  // [1] HEMISPHERE LENS PROFILE
  //     A glass pill cross-section is a circular arc — thickest at the rim,
  //     thinning toward the interior following a hemisphere curve:
  //         thickness(r) = sqrt(1 - r²)  where r = distFromEdge / edgeZone
  //     This gives a physically correct onset: slow in the middle of the zone,
  //     sharper right at the boundary — matching a real curved glass edge.
  //     Previously: sqrt(edgeInfluence) which is a polynomial convenience, not
  //     a lens shape.
  //
  // [2] LIGHT-MODULATED ABSORPTION STRENGTH
  //     The meniscus absorbs the same amount on all sides (Beer-Lambert), but
  //     the PERCEIVED darkness differs by quadrant:
  //       • Lit side:    specular highlight partially compensates → rim appears
  //                      bright, absorption is perceptually hidden.
  //       • Shadow side: no specular compensation → dark band fully exposed.
  //     iOS 26 reference: the shadow-side meniscus is clearly darker than the
  //     lit-side meniscus, not because more absorption occurs, but because the
  //     specular energy on the lit side "fills in" the absorbed darkness.
  //     We replicate this by weakening absorption on the lit side, where it is
  //     masked anyway, and strengthening it on the shadow side, where it is the
  //     dominant visual term.
  //       dot(surfaceNormal, uLightDirection) = +1  → full facing light → litness=1
  //       dot(surfaceNormal, uLightDirection) = -1  → shadow side      → litness=0
  //     absorption scale: [0.6 × strength (lit)] … [1.4 × strength (shadow)]
  //
  // [3] CHROMATIC ABERRATION AT THE RIM
  //     Already implemented in the background sampling section above (line ~246):
  //       vec2 distort = surfaceNormal * edgeInfluence * uChromaticAberration;
  //     edgeInfluence concentrates the RGB split at the SDF boundary. No change
  //     needed here — this shader already has edge-weighted dispersion.

  // [1] Hemisphere lens thickness profile
  float r_norm = clamp(distFromEdge / edgeZone, 0.0, 1.0);
  float lensThickness = sqrt(max(0.0, 1.0 - r_norm * r_norm)); // hemisphere arc

  // [2] Light-modulated strength: weaker on lit side (0.6×), stronger on shadow (1.4×)
  float litness = dot(surfaceNormal, uLightDirection); // [-1, +1]
  float dirScale = mix(1.4, 0.6, litness * 0.5 + 0.5); // shadow → lit
  float modulatedAbsorption = uEdgeAbsorption * dirScale;

  // Combined: hemisphere profile × light-modulated strength
  float absorption = 1.0 - lensThickness * modulatedAbsorption;
  finalColor *= max(0.0, absorption);

  // 中文说明：复用当前折射背景 bg，肩部按背景逐通道最多消耗剩余亮度空间的
  // 35% / 20%；共享函数只在峰值核心把增益提升到 1.0，并用宽 smoothstep 保留
  // 接近旧版 2dp 的可见范围。无纹理模式自然使用
  // 既有底色，白底端点更白但不会让整段高光失去过渡。
  finalColor = applyVerticalAreaHighlight(
    finalColor,
    bg,
    verticalAreaHighlightExposureLift,
    1.0
  );

  // 中文说明：最后先铺完整浅灰环，再叠加由 abs(surfaceNormal.x) 控制的
  // 左右深边，防止 hairline 与 fresnel 再次点亮结构轮廓。
  finalColor = applyDualLayerRim(
    finalColor,
    continuousLightRimMask,
    lateralDarkRimMask,
    uEdgeAbsorption
  );

  // Clamp to prevent over-bright pixels
  finalColor = min(finalColor, vec3(1.2));
  
  // ==========================================================================
  // ALPHA / TRANSPARENCY
  // ==========================================================================
  
  // TWEAK: baseAlpha - center transparency (lower = more see-through)
  // Standard mode: Provide a solid glassy body even at rest (Intensity 0), 
  // boosting it slightly when pressed.
  float standardBaseAlpha = uBaseAlphaMultiplier * mix(0.6, 1.0, uInteractionIntensity);
  // Restore original 0.70 when background is enabled — clear glass is translucent, not frosted.
  float baseAlpha = (uHasBackground > 0.5) ? 0.70 : standardBaseAlpha;
  
  // TWEAK: edgeAlpha - edge opacity (higher = more solid edges)
  // Standard mode: Keep a strong structural rim at rest to match 3D bevel.
  float standardEdgeAlpha = uEdgeAlphaMultiplier * mix(0.6, 1.0, uInteractionIntensity);
  float edgeAlpha = (uHasBackground > 0.5) ? 0.95 : standardEdgeAlpha;
  
  // Blend from center to edge
  float glassAlpha = mix(baseAlpha, edgeAlpha, edgeInfluence);
  float ringOpacity = borderMask * 0.9 * clamp(uAmbientRim * 10.0, 0.0, 1.0);
  glassAlpha = max(glassAlpha, ringOpacity);



  
  float alpha = glassAlpha * mask * clamp(uVisibility, 0.0, 1.0);
  
  // Premultiplied alpha output
  fragColor = vec4(finalColor * alpha, alpha);
}
