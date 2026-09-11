// Copyright 2025, Tim Lehmann for whynotmake.it
// Copyright 2026, Sebastian Degenaar for pixel-innovations.com (liquid_glass_widgets)
//
// SPDX-License-Identifier: MIT
//
// Originally: Final render pass reading displacement texture; basic refraction
// Modifications (2026):
//   - Migrated to V1 surface normal encoding (displacement_encoding.glsl V1).
//   - Added chromatic aberration pass (RGB channel split on refraction vector).
//   - Added Rec. 709 saturation control (applySaturation).
//   - Added iOS 26-style luminosity-preserving tint (applyGlassColor).
//   - Added meniscus darkening (VQ5) for physical glass depth.
//   - Switched from mediump to highp to eliminate colour banding on mobile.
//   - Expanded from ~62 lines to full multi-pass pipeline (~487 lines).
//   - Uniform layout migrated to explicit layout(location) slots for Impeller.
//
// Final rendering pass for liquid glass with pre-computed geometry.
// Reads surface normal data from the geometry texture (V1 encoding) and applies
// the liquid glass effect: refraction, chromatic aberration, tint, and edge lighting.
//
// Geometry texture layout (displacement_encoding.glsl):
//   R: normal.x  [-1, 1] → [0, 1]
//   G: normal.y  [-1, 1] → [0, 1]
//   B: height    normalized to thickness
//   A: foreground alpha (SDF AA)

#version 460 core
precision highp float; // mediump causes colour banding (10-bit mantissa on mobile)

#define DEBUG_GEOMETRY 0

#include <flutter/runtime_effect.glsl>
#include "displacement_encoding.glsl"
// 中文说明：Flutter 的增量 Shader 构建不会把自定义 #include 记录为入口依赖。
// 此校验值对应 edge_treatment.glsl 的规范化 UTF-8 内容；修改共享边缘算法后，
// 必须同步更新三个入口。入口文件内容因此发生变化，旧编译产物才不会被继续复用。
// POIESIS_EDGE_TREATMENT_ADLER32: eed60717
#include "edge_treatment.glsl"
#include "gles_compat.glsl"
#include "render.glsl"

// Slot 0-1:  uSize           — physical-pixel size of the backdrop capture
// Slots 2-3: uGeometryOffset — top-left of geometry matte in physical pixels
// Slots 4-5: uGeometrySize   — size of geometry matte in physical pixels
// Slots 6-9: uGlassColor
// Slots 10-12: uOpticalProps (refractiveIndex, chromaticAberration, thickness)
// Slots 13-15: uLightConfig  (lightIntensity, ambientStrength, saturation)
// Slots 16-17: uLightDirection
// Slots 10:  uOpticalProps   — refractiveIndex, chromaticAberration, thickness, refractScale
// Slots 11:  uLightConfig    — lightIntensity, ambientStrength, saturation
// Slots 12:  uLightDirection — lightDirection.x, lightDirection.y
// Slots 13:  uWhiten, uWhitenGated, uPinchStrength
// Slots 14-15: uBackgroundFallback
// Slots 16:  uCaptureOffset  — x, y
// Slots 17:  uEdgeConfig     — ambientRim (scaled by DPR/3.0), fresnelStrength, dprScale (DPR/3.0), edgeAbsorption
uniform vec2 uSize;
uniform vec2 uGeometryOffset;
uniform vec2 uGeometrySize;
uniform vec4 uGlassColor;
uniform vec4 uOpticalProps; // x: refractiveIndex, y: chromaticAberration, z: thickness, w: refractScale
uniform vec3 uLightConfig;
uniform vec2 uLightDirection;
uniform float uWhiten;
// Slot 19: uWhitenGated. 1 = the whiten is luminance-gated (protects dark
// pixels — the light-mode behaviour, keeps text/icons beneath the glass dark);
// 0 = ungated, uniform whiten across the whole control (the dark-mode
// behaviour, gives dark glass a small even lift toward white).
uniform float uWhitenGated;

// Slot 20: uPinchStrength. Concave horizontal-pinch strength [0..1].
// When > 0, the pill's refraction is squeezed inward at the left/right edges,
// creating the iOS 26 "pinched through a lens" look. The centre is left flat.
uniform float uPinchStrength;

// Slot 21-24: uBackgroundFallback — Per-mode opaque stand-in for backdrop
// regions the engine can't capture (e.g. a PlatformView past the glass).
// Straight (non-premultiplied) RGBA; a == 0 disables it.
uniform vec4 uBackgroundFallback;

// Slot 25-26: uCaptureOffset — physical-pixel offset from the render surface
// origin to the capture-boundary origin. Only non-zero on the Impeller capture
// path (GlassEffect with backgroundKey on Impeller premium). When zero (the
// default / BackdropFilter path), (fragCoord + uCaptureOffset) == fragCoord, so
// this is a mathematical no-op and has zero performance impact on existing paths.
//
// BackdropFilter mode (default, uCaptureOffset == vec2(0)):
//   FlutterFragCoord() is screen-space physical pixels.
//   uSize == full-screen physical pixel size.
//   screenUV = fragCoord / uSize → samples the backdrop at screen position.
//
// Capture mode (uCaptureOffset != vec2(0)):
//   FlutterFragCoord() is RepaintBoundary-surface-space physical pixels.
//   uSize == captured image physical pixel size.
//   uCaptureOffset shifts fragCoord so that (fragCoord + offset) is the
//   position within the capture image — mapping the indicator's fragment
//   to the correct texel in the pre-captured bar texture.
uniform vec2 uCaptureOffset;

// Slot 28-31: uEdgeConfig — x: ambientRim (scaled by DPR/3.0), y: fresnelStrength, z: dprScale (DPR/3.0), w: edgeAbsorption
uniform vec4 uEdgeConfig;

// Slots 32-43：解析式圆角信息与完整几何逆仿射。
//
// 中文说明：解析式与普通 geometry texture 共享“屏幕物理像素 → 几何本地
// 逻辑像素”的 2x3 逆仿射。这样多形状底栏经过祖先旋转/斜切后，纹理 alpha、
// 法线和最外描边仍使用同一套局部几何，不再退化为屏幕轴对齐包围盒。
//   uAnalyticRect      = (本地宽, 本地高, 本地圆角半径, enabled)
//   uAnalyticInverseX = 屏幕物理像素 → shape 本地逻辑 x 的仿射行
//   uAnalyticInverseY = 屏幕物理像素 → shape 本地逻辑 y 的仿射行
//   uAnalyticInverseX.w == 1 表示逆仿射有效；捕获/透视兼容路径写 0。
uniform vec4 uAnalyticRect;
uniform vec4 uAnalyticInverseX;
uniform vec4 uAnalyticInverseY;

// Slot 44：上游 v1.3.0 的 PlatformView 模式移动到 Poiesis 几何参数之后，
// 0 = fallbackColor（默认），1 = passthrough。
uniform float uPlatformViewMode;

// Slot 45：背景折射总开关。关闭时背景仍以原坐标参与 tint、饱和度和亮度
// 自适应，但不再发生法线位移、RGB 色散或 indicator pinch；材质其余阶段不变。
uniform float uRefractionEnabled;

// Slot 46：顶部折射区域限制。开启后仅玻璃本地顶部约 20% 获得折射，
// 其余区域保留材质合成但改走原坐标单样本路径，降低大面积玻璃的采样成本。
uniform float uTopRefractionOnly;

// uThickness directly and is already DPR-independent).
// uniform float uRefractScale; // Removed in favor of scaling uThickness

uniform sampler2D uBackgroundTexture;
uniform sampler2D uGeometryTexture;

layout(location = 0) out vec4 fragColor;

// ── Manual Bilinear Filtering ─────────────────────────────────────────────
// Impeller's implicit BackdropFilterLayer sampler is bound to the
// FragmentShader as Nearest-Neighbor with no Dart API to override it.
// Tracked as:
//   Flutter Issue #139887 — original bug report (NN aliasing on backdrop)
//   Flutter Issue #188365 — feature request to expose FilterQuality on
//                           BackdropFilterLayer (filed during 0.18.2 work)
// Once #188365 is resolved, this entire function can be replaced with a
// single texture() call and the physTexSize/invTexSize derivation removed.
//
// On-screen bilinear is lost without this workaround, which means continuous
// sub-pixel UV shifts (pinch lens, refraction) snap to integer texels and
// produce stair-step aliasing on high-contrast background edges.
//
// This function replaces all uBackgroundTexture lookups with 4 Nearest-Neighbor
// fetches and a standard bilinear mix, restoring perfectly smooth sub-pixel
// sampling at the cost of 3 additional cache-hot reads per invocation.
//
// NOTE: uGeometryTexture is intentionally excluded — it is a pre-rasterized
// SDF picture whose texels are pixel-aligned by construction. Bilinear
// filtering it would soften the SDF alpha channel and degrade anti-aliasing.
//
// Windows/SkSL: texture() with literal-computed UVs is legal in glslang
// SPIR-V path; floor(), fract(), and vec2 arithmetic are all universally
// supported. This function introduces no new platform compatibility issues.
vec4 textureBilinear(vec2 uv, vec2 size, vec2 invSize) {
    vec2 px = uv * size - 0.5;
    vec2 f = fract(px);
    vec2 p0 = floor(px);
    vec2 p1 = p0 + vec2(1.0, 0.0);
    vec2 p2 = p0 + vec2(0.0, 1.0);
    vec2 p3 = p0 + vec2(1.0, 1.0);

    vec4 c0 = texture(uBackgroundTexture, (p0 + 0.5) * invSize);
    vec4 c1 = texture(uBackgroundTexture, (p1 + 0.5) * invSize);
    vec4 c2 = texture(uBackgroundTexture, (p2 + 0.5) * invSize);
    vec4 c3 = texture(uBackgroundTexture, (p3 + 0.5) * invSize);

    vec4 cTop = mix(c0, c1, f.x);
    vec4 cBot = mix(c2, c3, f.x);
    vec4 bg = mix(cTop, cBot, f.y);

    // Composite the (premultiplied) backdrop sample OVER the fallback colour.
    // Where the engine couldn't capture a backdrop (a PlatformView past the bar
    // → transparent black, bg.a ≈ 0) this yields the fallback; where the
    // backdrop is real (bg.a ≈ 1) it is left untouched. uBackgroundFallback is
    // straight RGBA, so premultiply it by its own alpha before the over.
    //
    // Phase 3B (perf): The alpha check is a uniform — coherent across the entire
    // draw call — so the GPU branch predictor takes it for free. In the common
    // case (no PlatformView / platformViewFallbackColor not set) this skips 4
    // MADs and a 2× MAD per sample point.
    if (uBackgroundFallback.a > 0.0) {
        bg.rgb += uBackgroundFallback.rgb * uBackgroundFallback.a * (1.0 - bg.a);
        bg.a += uBackgroundFallback.a * (1.0 - bg.a);
    }
    return bg;
}

vec3 analyticRoundedRectSdfAt(vec2 localPoint) {
    vec2 size = max(uAnalyticRect.xy, vec2(0.001));
    vec2 halfSize = size * 0.5;
    float radius = min(uAnalyticRect.z, min(halfSize.x, halfSize.y));
    vec2 centered = localPoint - halfSize;
    vec2 q = abs(centered) - halfSize + radius;
    vec2 outside = max(q, 0.0);
    float outsideLength = length(outside);
    float sdLogical = min(max(q.x, q.y), 0.0) + outsideLength - radius;

    // 圆角矩形 SDF 的解析梯度。角区使用归一化圆弧方向，直边区直接选择
    // 最近轴；深层中心的梯度不会参与折射（nCos 已经归零）。
    vec2 gradient;
    if (outsideLength > 1e-5) {
        gradient = (outside / outsideLength) * sign(centered);
    } else if (q.x > q.y) {
        gradient = vec2(sign(centered.x), 0.0);
    } else {
        gradient = vec2(0.0, sign(centered.y));
    }

    return vec3(sdLogical, gradient);
}

vec4 analyticRoundedRectGeometry(vec2 localPoint, float thickness) {
    vec3 sdfData = analyticRoundedRectSdfAt(localPoint);
    float sdLogical = sdfData.x;
    vec2 gradient = sdfData.yz;

    // 中文说明：先用逆仿射把本地 SDF 梯度投到屏幕空间。方形屏幕像素在
    // 当前法线上的覆盖支撑宽度必须取 L1 投影；旧版 L2 在斜向圆弧处少估
    // AA，导致直边正常而曲线毛刺。后续双层描边复用同一 L1 足迹。
    vec2 screenGradient = vec2(
        gradient.x * uAnalyticInverseX.x + gradient.y * uAnalyticInverseY.x,
        gradient.x * uAnalyticInverseX.y + gradient.y * uAnalyticInverseY.y
    );
    float localDistancePerScreenPixel = getSdfPixelFootprint(screenGradient);
    float signedDistanceInScreenPixels =
        sdLogical / localDistancePerScreenPixel;
    float foregroundAlpha = clamp(
        0.5 - signedDistanceInScreenPixels,
        0.0,
        1.0
    );
    if (foregroundAlpha < 0.01 || thickness <= 0.0) {
        return vec4(0.0);
    }

    // 中文说明：外侧半像素只承担轮廓覆盖率，不能把玻璃曲面继续外推；
    // 光学高度和法线仍钳制在真实 SDF 边界，避免 AA 区产生额外折射亮边。
    float dpr = max(1.0, uEdgeConfig.z * 3.0);
    float sdPhysical = min(sdLogical, 0.0) * dpr;
    float nCos = clamp((thickness + sdPhysical) / thickness, 0.0, 1.0);
    vec2 normalXY = gradient * nCos;
    float x = thickness + sdPhysical;
    float sqrtTerm = sqrt(max(0.0, thickness * thickness - x * x));
    float height = mix(sqrtTerm, thickness, float(sdPhysical < -thickness));
    return encodeGeometryData(normalXY, height, thickness, foregroundAlpha);
}

// 中文说明：把 Flutter 根表面的物理片元坐标还原到几何纹理生成时的局部
// 逻辑坐标。这一函数同时服务解析式单形状和 Premium 多形状纹理分支。
vec2 geometryLocalPointFromFragment(vec2 fragCoord) {
    return vec2(
        dot(uAnalyticInverseX.xy, fragCoord) + uAnalyticInverseX.z,
        dot(uAnalyticInverseY.xy, fragCoord) + uAnalyticInverseY.z
    );
}

// 中文说明：geometry texture 保存的是局部 SDF 法线。位置使用逆仿射后，
// 折射与镜面光仍需把法线方向变回屏幕坐标；J^T * n 正是局部距离场在屏幕
// 上的梯度方向。保留原长度可继续表达玻璃曲面的倾斜程度。
vec2 geometryNormalToScreen(vec2 localNormal) {
    float localLength = length(localNormal);
    if (localLength < 1e-5 || uAnalyticInverseX.w < 0.5) {
        return localNormal;
    }
    vec2 screenGradient = vec2(
        localNormal.x * uAnalyticInverseX.x + localNormal.y * uAnalyticInverseY.x,
        localNormal.x * uAnalyticInverseX.y + localNormal.y * uAnalyticInverseY.y
    );
    float screenLength = length(screenGradient);
    if (screenLength < 1e-5) {
        return localNormal;
    }
    return screenGradient * (localLength / screenLength);
}

vec2 geometryTextureUvFromFragment(vec2 sampleFragCoord) {
    vec2 sampleUv;
    if (uAnalyticInverseX.w > 0.5) {
        vec2 textureLocalPoint = geometryLocalPointFromFragment(sampleFragCoord);
        sampleUv = (textureLocalPoint - uGeometryOffset) / uGeometrySize;
    } else {
        sampleUv = (sampleFragCoord - uGeometryOffset) / uGeometrySize;
    }
    #ifdef LGR_GLES_FLIP_SAMPLE_Y
        sampleUv.y = 1.0 - sampleUv.y;
    #endif
    return clamp(sampleUv, 0.0, 1.0);
}

float rimDistanceFromGeometry(vec4 geometryData, float thickness) {
    float normalizedHeight = geometryData.b;
    float cosTerm = sqrt(max(
        0.0,
        1.0 - normalizedHeight * normalizedHeight
    ));
    return thickness * (1.0 - cosTerm);
}

vec3 sampleAnalyticEdgeAtOffset(
    vec2 pixelOffset,
    vec2 fragCoord,
    vec2 lightRimProfile,
    vec2 darkRimProfile
) {
    // 中文说明：解析式 Premium 分支直接在八个物理子像素位置重新求 SDF，
    // 不读取几何占位纹理。每个样本也独立通过逆仿射计算屏幕距离比例，因此
    // 旋转、斜切与非均匀 jelly 缩放下仍保持真实一物理像素的连续终止边。
    vec2 sampleLocal = geometryLocalPointFromFragment(
        fragCoord + pixelOffset
    );
    vec3 sampleSdf = analyticRoundedRectSdfAt(sampleLocal);
    vec2 sampleNormal = sampleSdf.yz;
    vec2 sampleScreenGradient = vec2(
        sampleNormal.x * uAnalyticInverseX.x
            + sampleNormal.y * uAnalyticInverseY.x,
        sampleNormal.x * uAnalyticInverseX.y
            + sampleNormal.y * uAnalyticInverseY.y
    );
    float sampleDistanceScale = getSdfDistanceScale(sampleScreenGradient);
    return getSupersampledSdfEdgeContribution(
        sampleSdf.x,
        lightRimProfile.x * sampleDistanceScale,
        darkRimProfile.x * sampleDistanceScale,
        sampleNormal.x,
        lightRimProfile.y,
        darkRimProfile.y
    );
}

vec3 sampleTextureEdgeAtOffset(
    vec2 pixelOffset,
    vec2 fragCoord,
    float thickness,
    float dpr,
    vec2 lightRimProfile,
    vec2 darkRimProfile
) {
    // 中文说明：多形状融合只能从 geometry texture 恢复 SDF 结果。对八个
    // 物理子像素分别读取 alpha/法线/高度，并在各自位置还原描边面积，可消除
    // 单次双线性法线产生的 chord 明暗振荡；背景纹理仍只按原流程采样一次。
    vec4 sampleGeometry = texture(
        uGeometryTexture,
        geometryTextureUvFromFragment(fragCoord + pixelOffset)
    );
    vec2 sampleLocalNormal = decodeNormalXY(sampleGeometry);
    float sampleNormalLength = max(length(sampleLocalNormal), 1e-4);
    vec2 sampleLocalRimNormal = sampleLocalNormal / sampleNormalLength;
    vec2 sampleScreenGradient = vec2(
        sampleLocalRimNormal.x * uAnalyticInverseX.x
            + sampleLocalRimNormal.y * uAnalyticInverseY.x,
        sampleLocalRimNormal.x * uAnalyticInverseX.y
            + sampleLocalRimNormal.y * uAnalyticInverseY.y
    );
    float inverseEnabled = step(0.5, uAnalyticInverseX.w);
    float sampleDistanceScale = mix(
        1.0,
        getSdfDistanceScale(sampleScreenGradient) * dpr,
        inverseEnabled
    );
    float samplePixelFootprint = mix(
        1.0,
        getSdfPixelFootprint(sampleScreenGradient) * dpr,
        inverseEnabled
    );
    return getFilteredSdfEdgeContribution(
        rimDistanceFromGeometry(sampleGeometry, thickness),
        lightRimProfile.x * sampleDistanceScale,
        darkRimProfile.x * sampleDistanceScale,
        samplePixelFootprint,
        sampleGeometry.a,
        sampleLocalRimNormal.x,
        lightRimProfile.y,
        darkRimProfile.y
    );
}

void main() {
    // Unpacked here rather than at global scope: global non-constant initialisers
    // (e.g. float x = uniform.y) are valid in desktop GLSL 4.6 but rejected by
    // SkSL / glslang on Windows (SPIR-V path). Same fix as 0.7.10 geometry shader.
    float uRefractiveIndex     = uOpticalProps.x;
    float uChromaticAberration = uOpticalProps.y;
    float uThickness           = uOpticalProps.z;
    float uLightIntensity      = uLightConfig.x;
    float uAmbientStrength     = uLightConfig.y;
    float uSaturation          = uLightConfig.z;

    vec2 fragCoord = FlutterFragCoord().xy;

    vec2 physTexSize = uSize;
    vec2 invTexSize = 1.0 / physTexSize;
    // uCaptureOffset shifts the fragment into capture-image space.
    // In BackdropFilter mode uCaptureOffset == vec2(0) so this is a no-op.
    vec2 screenUV = (fragCoord + uCaptureOffset) * invTexSize;

    // Pre-3.46 GLES stored render-to-texture content bottom-up; see
    // gles_compat.glsl. On 3.46+ the backend absorbs the difference and this
    // flip must NOT be applied, or the glass samples the backdrop mirrored
    // about the screen's horizontal centre line.
    #ifdef LGR_GLES_FLIP_SAMPLE_Y
        screenUV.y = 1.0 - screenUV.y;
    #endif

    vec2 geometryUV;
    vec4 geometryData;
    float glassVerticalPosition;
    // 中文说明：Premium 的尺寸来源可能是本地逻辑像素，也可能是捕获兼容
    // 路径的物理像素。提前还原 DPR，确保后续 10 / 20 的上限始终表示 dp。
    float dpr = max(1.0, uEdgeConfig.z * 3.0);
    vec2 glassLogicalSize;
    float glassLogicalHeight;
    if (uAnalyticRect.w > 0.5) {
        // 中文说明：FlutterFragCoord 属于官方根 backdrop 表面；Dart 已把
        // shape→screen 的完整 jelly 仿射变换求逆，因此这里能精确恢复本地坐标，
        // 不把横向拉伸后的椭圆角错误近似成屏幕轴对齐的圆角。
        vec2 localPoint = geometryLocalPointFromFragment(fragCoord);
        geometryUV = clamp(localPoint / max(uAnalyticRect.xy, vec2(0.001)), 0.0, 1.0);
        glassLogicalSize = uAnalyticRect.xy;
        glassVerticalPosition = geometryUV.y;
        glassLogicalHeight = uAnalyticRect.y;
        geometryData = analyticRoundedRectGeometry(localPoint, uThickness);
    } else {
        if (uAnalyticInverseX.w > 0.5) {
            // 中文说明：普通纹理也先回到玻璃层本地坐标；uGeometryOffset/Size
            // 此时就是纹理录制时的本地逻辑边界，旋转系数不会再被 AABB 丢失。
            vec2 textureLocalPoint = geometryLocalPointFromFragment(
                fragCoord
            );
            geometryUV = (textureLocalPoint - uGeometryOffset) / uGeometrySize;
            // 中文说明：有效逆仿射路径写入的是纹理本地逻辑边界，可直接作为
            // dp 高度使用，旋转和非等比缩放不会改变设计空间中的高光上限。
            glassLogicalSize = uGeometrySize;
            glassLogicalHeight = uGeometrySize.y;
        } else {
            // 捕获纹理或透视矩阵无法用 2x3 仿射精确表达，保留原屏幕包围盒
            // 采样作为兼容路径；不会用错误逆矩阵污染正常旋转动画。
            vec2 textureScreenPoint = fragCoord;
            geometryUV = (textureScreenPoint - uGeometryOffset) / uGeometrySize;
            // 中文说明：捕获或透视兼容路径的边界是物理像素，必须除以 DPR
            // 才能与另外两条 Premium 分支共享 10dp / 20dp 的逻辑上限。
            glassLogicalSize = uGeometrySize / dpr;
            glassLogicalHeight = uGeometrySize.y / dpr;
        }
        // 中文说明：先保存几何本地的纵向比例，再处理旧 GLES 的纹理 Y 翻转。
        // 区域高光属于玻璃自身的顶部/底部，不应随纹理存储原点变化而上下颠倒。
        glassVerticalPosition = clamp(geometryUV.y, 0.0, 1.0);
        #ifdef LGR_GLES_FLIP_SAMPLE_Y
            geometryUV.y = 1.0 - geometryUV.y;
        #endif

        // Clamp geometryUV to [0, 1] for two reasons:
        // 1. Impeller's texture samplers may default to Repeat mode. Without this
        //    clamp, a fragment slightly outside uGeometrySize (e.g. during
        //    LiquidStretch scaling overshoot) wraps around and samples the opposite
        //    edge of the geometry SDF, producing inverted normals and extreme
        //    chromatic aliasing (jagged rainbows).
        // 2. Fragments genuinely outside the pill (the _clipExpansion zone) get
        //    clamped to the SDF edge, which has near-zero alpha. The
        //    `geometryData.a < 0.01` early-out below discards them efficiently.
        geometryUV = clamp(geometryUV, 0.0, 1.0);
        geometryData = texture(uGeometryTexture, geometryUV);
    }

    // 中文说明：自适应高光根据长宽比自动在胶囊平直高光与圆形月牙高光之间平滑融合；
    // 颜色会在最终合成时复用折射背景样本，不增加纹理读取、uniform 或渲染 Pass。
    float verticalAreaHighlightExposureLift = getAdaptiveAreaHighlightExposureLift(
        geometryUV,
        glassLogicalSize
    );

    // 中文说明：0.36 / 0.18 logical px 先换成名义物理宽度；不足一物理像素
    // 时 profile.x 扩为 1px，profile.y 同比降低能量。随后只对 SDF/geometry
    // 边缘数据做八点采样，背景折射、色散与光照纹理读取维持原数量。
    const float lightRimLogicalWidth = 0.36;
    const float darkRimLogicalWidth = 0.18;
    vec2 lightRimProfile = getEnergyPreservingRimProfile(
        lightRimLogicalWidth * dpr
    );
    vec2 darkRimProfile = getEnergyPreservingRimProfile(
        darkRimLogicalWidth * dpr
    );
    vec3 supersampledEdge;
    float centerRimDistance = rimDistanceFromGeometry(
        geometryData,
        uThickness
    );
    float conservativeEdgeReach =
        max(lightRimProfile.x, darkRimProfile.x) * 4.0 + 1.0;
    if (geometryData.a >= 0.999 && centerRimDistance > conservativeEdgeReach) {
        // 中文说明：中心已经完全覆盖且离终止边足够远时，任何 RGSS 子样本都
        // 不可能进入一像素描边。内部区域直接返回满 alpha/零描边，八次几何
        // 读取或 SDF 计算因此只发生在形状外沿的窄带。
        supersampledEdge = vec3(1.0, 0.0, 0.0);
    } else {
        vec3 edgeSampleSum;
        if (uAnalyticRect.w > 0.5) {
            edgeSampleSum =
                  sampleAnalyticEdgeAtOffset(kEdgeRgss0, fragCoord, lightRimProfile, darkRimProfile)
                + sampleAnalyticEdgeAtOffset(kEdgeRgss1, fragCoord, lightRimProfile, darkRimProfile)
                + sampleAnalyticEdgeAtOffset(kEdgeRgss2, fragCoord, lightRimProfile, darkRimProfile)
                + sampleAnalyticEdgeAtOffset(kEdgeRgss3, fragCoord, lightRimProfile, darkRimProfile)
                + sampleAnalyticEdgeAtOffset(kEdgeRgss4, fragCoord, lightRimProfile, darkRimProfile)
                + sampleAnalyticEdgeAtOffset(kEdgeRgss5, fragCoord, lightRimProfile, darkRimProfile)
                + sampleAnalyticEdgeAtOffset(kEdgeRgss6, fragCoord, lightRimProfile, darkRimProfile)
                + sampleAnalyticEdgeAtOffset(kEdgeRgss7, fragCoord, lightRimProfile, darkRimProfile);
        } else {
            edgeSampleSum =
                  sampleTextureEdgeAtOffset(kEdgeRgss0, fragCoord, uThickness, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss1, fragCoord, uThickness, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss2, fragCoord, uThickness, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss3, fragCoord, uThickness, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss4, fragCoord, uThickness, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss5, fragCoord, uThickness, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss6, fragCoord, uThickness, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss7, fragCoord, uThickness, dpr, lightRimProfile, darkRimProfile);
        }
        supersampledEdge = resolveEdgeSupersample(edgeSampleSum);
    }
    geometryData.a = supersampledEdge.x;
    float continuousLightRimMask = supersampledEdge.y;
    float lateralDarkRimMask = supersampledEdge.z;

    #if DEBUG_GEOMETRY
        fragColor = geometryData;
        return;
    #endif

    if (geometryData.a < 0.01) {
        fragColor = vec4(0);
        return;
    }

    // --- V1: Decode true surface normal from geometry texture ---
    //
    // The geometry pass stores the SDF-gradient-derived normal in RG.
    // Before V1 this stored displacement XY, and the render pass called
    // normalize(displacement) as a proxy for the normal — which diverges
    // from the true normal in blend-group neck zones (smooth-union joins).
    // The true normal is now decoded and used for both refraction and lighting.
    // 中文说明：外侧 RGSS 可能检测到少量覆盖，而中心几何样本仍完全透明；
    // 这时中心 RG 的透明黑不是有效法线。显式归零可保证只输出覆盖率，不会
    // 在玻璃外侧凭空产生折射、色散或镜面亮点。
    vec2 localNormalXY = geometryData.a > 0.0 && geometryData.b > 0.0
        ? decodeNormalXY(geometryData)
        : vec2(0.0);
    vec2 normalXY = geometryNormalToScreen(localNormalXY);
    float normalZSq = max(0.0, 1.0 - dot(normalXY, normalXY));
    float normalZ   = sqrt(normalZSq);
    vec3  normal    = vec3(normalXY, normalZ);   // unit-length surface normal

    // 中文说明：区域门控使用保存于 GLES 翻转前的玻璃本地纵向坐标，因此
    // 旋转、jelly 缩放、捕获模式或纹理原点差异都不会把顶部 20% 颠倒。
    float refractionAreaGate = getRefractionAreaGate(
        glassVerticalPosition,
        uRefractionEnabled,
        uTopRefractionOnly
    );
    float normalMagnitudeSquared = dot(normalXY, normalXY);
    vec2 displacement = vec2(0.0);

    // 中文说明：20% 以下以及全局关闭时直接跳过 refract、decodeHeight 和
    // 相关除法；平坦内部同样无需计算位移。normal、thickness 仍供后续光照、
    // Fresnel、弯月面吸收和结构边使用，材质外观不会随优化路径发生突变。
    if (refractionAreaGate > 0.0 && normalMagnitudeSquared >= 1e-4) {
        // Recompute refraction displacement from the true normal.
        // This is the same refract() call used in the geometry pass — exact,
        // not approximated. Height is still read from the B channel.
        float height = decodeHeight(geometryData, uThickness);
        float baseHeight = uThickness * 8.0;
        vec3 incident = vec3(0.0, 0.0, -1.0);
        float invN = 1.0 / max(uRefractiveIndex, 0.001);
        vec3 baseRefract = refract(incident, normal, invN);
        float refractLen =
            (height + baseHeight) / max(0.001, abs(baseRefract.z));
        displacement = baseRefract.xy * refractLen;
        // Scale displacement by uRefractScale (uOpticalProps.w) to ensure
        // logical-pixel identical refraction magnitude across all DPRs.
        displacement *= uOpticalProps.w * refractionAreaGate;

        // On pre-3.46 GLES the sampling UV is Y-up, while the decoded normal
        // remains in Flutter's Y-down space. Correct only the active offset.
        #ifdef LGR_GLES_FLIP_SAMPLE_Y
            displacement.y = -displacement.y;
        #endif
    }

    // ── Concave horizontal pinch ──────────────────────────────────────────────
    // iOS 26 indicator pills make the bar content behind the left/right edges
    // appear slightly compressed inward — as if the pill is a convex lens
    // squeezing the bar through its edges. The effect is HORIZONTAL ONLY:
    // the bar content at the pill edges is sampled from a position slightly
    // closer to the pill centre, making those edge regions appear to pinch in.
    //
    // The centre of the pill (over the icon/label) is left completely flat.
    //
    // Scale: shifts are in UV space relative to the FULL backdrop (uSize).
    // 0.015 UV on a 390pt screen ≈ 6pt logical pixels — subtle but visible.
    //
    // ── iOS 26 Concave Lens Pinch ─────────────────────────────────────────────
    if (refractionAreaGate > 0.0 && uPinchStrength > 0.001) {
        // We cannot use normalXY because it is 0.0 in the flat interior of the pill,
        // which prevents the background from being pinched at all.
        // We also cannot use a circular distance field, because a circle mapped to a
        // wide pill creates an elliptical lens that curves the flat top/bottom edges.
        //
        // Solution: Use an L6 norm (superellipse/squircle) distance field.
        // This mathematically mimics the physical shape of a rounded rectangle:
        // perfectly flat on the top/bottom/sides, and perfectly rounded in the corners.
        vec2 centered = geometryUV - vec2(0.5);
        vec2 absCentered = abs(centered) * 2.0; // 0.0 to 1.0

        // Compute x^4 and y^4 using multiply chains instead of pow().
        float x2 = absCentered.x * absCentered.x;
        float ax4 = x2 * x2;
        float y2 = absCentered.y * absCentered.y;
        float ay4 = y2 * y2;

        // L4 norm: (x^4 + y^4)^(1/4). 
        // Flatter than a circle (L2), but much softer in the corners than L6/L8.
        // ⁴√s = √(√(s)) — two sqrt() calls, mathematically exact.
        float s = ax4 + ay4;
        float squircleDist = sqrt(sqrt(s));

        // Map the squircle distance to a 0..1 smooth curve.
        float pinchRamp = smoothstep(0.0, 1.0, squircleDist);

        // Vector pointing outwards from the pill centre, scaled by the ramp.
        // uPinchStrength interpolates the effect during spring animations.
        // 0.025 is the baseline UV shift magnitude (subtle but visible).
        vec2 pinchShift = centered * pinchRamp * uPinchStrength * 0.025;

        // Feather the pinch shift to zero at the pill's SDF boundary.
        // Without this, there is a hard UV discontinuity at the pill edge:
        // the background content inside the pill is sampled from a shifted UV
        // while the content immediately outside is at the natural UV — this
        // mismatch produces the "stepped/aliased" edge visible through the lens,
        // especially where the bar's own clip edge is refracted inward.
        // Multiplying by geometryData.a (which is 0 at the boundary and 1 by 2 px
        // inside) ramps the shift smoothly from 0 → full pinch over the same AA
        // zone as the pill alpha, eliminating the hard UV seam.
        // 中文说明：分界带同时衰减 pinch，避免位移在 20% 边界突然截断。
        pinchShift *= geometryData.a * refractionAreaGate;

        screenUV += pinchShift;
        
        // Guarantee we never sample outside the valid backdrop capture bounds,
        // preventing black/void artifacts if the pill is pressed tightly against the edge.
        screenUV = clamp(screenUV, vec2(0.001), vec2(0.999));
    }

    // PP1 optimisation: when the surface normal is flat (pointing straight up,
    // i.e. normalXY ≈ 0), refract() always produces displacement = vec2(0) and
    // the refracted UV is identical to screenUV.  Skip refract() entirely and
    // take a single background sample.  This covers the majority of pixels on
    // large surfaces (GlassAppBar, GlassPanel), where the edge zone is a small
    // fraction of the total area.
    //
    // Threshold chosen conservatively: 1e-4 in squared magnitude corresponds to
    // a normal tilted < 0.6° from vertical — visually indistinguishable from a
    // zero-displacement sample at any display resolution.
    vec4 refractColor;
    // 中文说明：色散是折射采样的一部分。此处使用局部有效值，不覆盖 uniform
    // 中的艺术配置，开关恢复后原有色散强度会完整返回。
    float effectiveChromaticAberration =
        uChromaticAberration * refractionAreaGate;
    if (refractionAreaGate <= 0.0 || normalMagnitudeSquared < 1e-4) {
        // 中文说明：受限区域外和平坦内部都只做一次原坐标双线性采样；前者
        // 是顶部限制的主要性能收益，仍为全表面材质合成提供真实背景颜色。
        refractColor = textureBilinear(screenUV, physTexSize, invTexSize);
    } else if (effectiveChromaticAberration < 0.01) {
        vec2 refractedUV = screenUV + displacement * invTexSize;
        refractColor = textureBilinear(refractedUV, physTexSize, invTexSize);
    } else {
        float dispersionStrength = effectiveChromaticAberration * 0.5;
        vec2 redOffset  = displacement * (1.0 + dispersionStrength);
        vec2 blueOffset = displacement * (1.0 - dispersionStrength);

        vec2 redUV   = screenUV + redOffset   * invTexSize;
        vec2 greenUV = screenUV + displacement * invTexSize;
        vec2 blueUV  = screenUV + blueOffset  * invTexSize;

        float red         = textureBilinear(redUV, physTexSize, invTexSize).r;
        vec4  greenSample = textureBilinear(greenUV, physTexSize, invTexSize);
        float blue        = textureBilinear(blueUV, physTexSize, invTexSize).b;

        refractColor = vec4(red, greenSample.g, blue, greenSample.a);
    }

    // Un-premultiply the background sample before refraction math.
    // BackdropFilter delivers premultiplied RGBA; toImageSync captures also
    // deliver premultiplied RGBA. Without un-premultiply, the chromatic
    // aberration dispersion channels (red/blue split) operate on premultiplied
    // values, which biases saturated colours toward grey at the edges.
    // On fully-opaque backdrops (refractColor.a == 1.0) this is a no-op.
    if (refractColor.a > 0.001) {
        refractColor.rgb /= refractColor.a;
    }

    vec4 finalColor = applyGlassColor(refractColor, uGlassColor);

    // VQ4: Content-adaptive glass strength.
    //
    // iOS 26 glass dynamically adjusts its material intensity based on the
    // luminance of the content beneath it.  Dark backdrops produce richer,
    // more vivid glass; bright or uniform backdrops produce a subtler material
    // to avoid overwhelming the UI.
    //
    // Implementation: dot-product backdrop luminance from refractColor —
    // the already-sampled background at the refracted UV.  Zero extra texture
    // reads; the sample is already in the register file.
    //
    // LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114) (BT.601, defined in render.glsl)
    //
    // adaptiveStrength range [0.8, 1.2]:
    //   • backdropLuma = 0.0 (black)  → strength 1.2 (richer glass)
    //   • backdropLuma = 1.0 (white)  → strength 0.8 (subtler glass)
    //
    // Cost: 1 dot product + 1 mix() + 1 extra mix() for tint = 3 MADs.
    // Effectively free on modern GPUs.
    float backdropLuma     = dot(refractColor.rgb, LUMA_WEIGHTS);
    float adaptiveStrength = mix(1.2, 0.8, backdropLuma);

    // Apply saturation with adaptive scaling.
    // adaptiveStrength > 1.0 → more vivid (dark backdrop).
    // adaptiveStrength < 1.0 → more muted (bright/uniform backdrop).
    // uSaturation is the artist-set base; we only modulate it, never replace it.
    finalColor.rgb = applySaturation(finalColor.rgb, uSaturation * adaptiveStrength);

    // Modulate glass tint blend weight by adaptiveStrength.
    // On dark backgrounds the tint reads heavier (+20%); on bright backgrounds
    // it reads lighter (-20%).  The delta is small (max ±20% of the 12% base
    // weight = ±2.4%) — within a single JND step, noticeable as a property
    // not a glitch.  Uses mix() to re-blend toward uGlassColor.rgb over the
    // already-tinted finalColor, scaled by the adaptive delta only.
    finalColor.rgb = mix(finalColor.rgb,
                         uGlassColor.rgb,
                         uGlassColor.a * 0.12 * (adaptiveStrength - 1.0));

    // Whitening veil — applied here, right after the body tint and BEFORE the
    // rim/fresnel passes. Applying it before the edge lighting means the rim
    // and fresnel highlights are drawn on top of the whitened body, so the
    // bright edges stay crisp even when the body is heavily whitened —
    // matching iOS 26's light-mode bar, where the white ring / edge
    // reflections stay sharp over a whitened interior.
    //
    // Luminance-gated mode: scale the whiten by how bright this pixel already
    // is, so near-white content beneath the glass lifts to pure white while
    // darks (text, icons) are left untouched — instead of a uniform veil that
    // grays the darks too. This is a point operation (per-pixel, depending
    // only on this pixel's own luminance — no neighbourhood sampling), so
    // unlike a spatial content detector it cannot produce a halo or seam; at
    // a dark-on-light edge it just steepens the existing gradient (crisper
    // edge, no gray ring).
    //
    // WHITEN_LO / WHITEN_HI are content-classification thresholds (what
    // luminance counts as "a dark to protect" vs "a white to push"), not
    // aesthetic per-recipe values — so they are hardcoded rather than passed
    // as uniforms. The single tunable lever is uWhiten (the strength).
    //   below WHITEN_LO → gate 0 (fully protected, stays dark)
    //   above WHITEN_HI → gate 1 (fully whitened, lifts to white)
    const float WHITEN_LO = 0.40;
    const float WHITEN_HI = 0.80;
    float whitenLuma = dot(finalColor.rgb, LUMA_WEIGHTS);
    // uWhitenGated 1 → gate by luminance (light mode, protects darks);
    // uWhitenGated 0 → gate = 1, uniform whiten (dark mode, even lift).
    float whitenGate =
        mix(1.0, smoothstep(WHITEN_LO, WHITEN_HI, whitenLuma), uWhitenGated);
    finalColor.rgb =
        mix(finalColor.rgb, vec3(1.0), clamp(uWhiten, 0.0, 1.0) * whitenGate);
    // Edge lighting — uses the true normal.xy (V1; was normalize(displacement))
    float normalizedHeight = geometryData.b;
    // The 40.0 constant was calibrated on a 3x Retina display.
    // We scale it by uEdgeConfig.z (which contains devicePixelRatio / 3.0) 
    // so the edge clamp ratio behaves identically on all pixel densities.
    float baseScale        = 40.0 * max(0.1, uEdgeConfig.z);
    float thicknessScale   = clamp(baseScale / max(uThickness, 1.0), 1.0, 4.0);
    float edgeThreshold    = mix(0.8, 0.5, 1.0 / thicknessScale);
    float edgeFactor       = uThickness < 0.01 ? 0.0 : 1.0 - smoothstep(0.0, edgeThreshold, normalizedHeight);

    // 中文说明：rimDist 是从 SDF 外轮廓向玻璃内部量取的物理像素距离。
    // 双层描边已经在 geometryData 读取后由八个 RGSS 样本完成；这里仅重建
    // 中心样本的有效浅边宽度，供白色高光避让继续使用同一终止边内侧位置。
    float cosTerm = sqrt(max(0.0, 1.0 - normalizedHeight * normalizedHeight));
    float rimDist = uThickness * (1.0 - cosTerm);
    float normalLength2D = max(length(normalXY), 1e-4);
    vec2 rimN = normalXY / normalLength2D;
    float localNormalLength2D = max(length(localNormalXY), 1e-4);
    vec2 localRimN = localNormalXY / localNormalLength2D;
    // 中文说明：uAnalyticInverseX/Y 的 xy 分量是屏幕物理像素到本地逻辑
    // 坐标的雅可比行。将本地 SDF 法线左乘该雅可比后，L1 投影负责方形
    // 像素的 AA 足迹，L2 长度负责把目标屏幕线宽换成 rimDist 单位；两者
    // 都乘回 DPR，是因为 rimDist 使用物理像素尺度。横纵拉伸或圆弧转向时，
    // 抗锯齿与几何线宽会分别保持正确，不再互相放大误差。
    vec2 rimScreenGradient = vec2(
        localRimN.x * uAnalyticInverseX.x + localRimN.y * uAnalyticInverseY.x,
        localRimN.x * uAnalyticInverseX.y + localRimN.y * uAnalyticInverseY.y
    );
    float analyticRimDistanceScale =
        getSdfDistanceScale(rimScreenGradient) * dpr;
    float analyticRimPixelFootprint =
        getSdfPixelFootprint(rimScreenGradient) * dpr;
    float rimDistanceScale = mix(
        1.0,
        analyticRimDistanceScale,
        step(0.5, uAnalyticInverseX.w)
    );
    float rimPixelFootprint = mix(
        1.0,
        analyticRimPixelFootprint,
        step(0.5, uAnalyticInverseX.w)
    );
    float lightRimWidth = lightRimProfile.x * rimDistanceScale;
    float darkRimWidth = darkRimProfile.x * rimDistanceScale;
    // 中文说明：continuousLightRimMask / lateralDarkRimMask 已包含八点覆盖率
    // 与名义能量补偿，不能再调用单样本 outer-minus-inner，否则会重复滤波。
    float innerHighlightGate = getInnerHighlightGate(
        rimDist,
        lightRimWidth,
        uEdgeConfig.w
    );

    // VQ5: Meniscus darkening — three physics improvements.
    //
    // [1] HEMISPHERE LENS PROFILE
    //     A glass pill cross-section follows a circular arc. The physically correct
    //     thickness profile is hemisphere-shaped: thickest at the rim boundary,
    //     thinning toward the interior following sqrt(1 - r²) where r = normalizedHeight.
    //     This gives a sharp onset at the rim and a gentler fade inward, matching
    //     real curved glass rather than the previous polynomial approximation.
    //
    // [2] LIGHT-MODULATED ABSORPTION STRENGTH
    //     On the lit side, the specular highlight compensates for absorption —
    //     the rim appears bright regardless. On the shadow side, no compensation
    //     occurs and the dark meniscus band is fully exposed. We reduce absorption
    //     strength on the lit side (0.6×) and increase it on the shadow side (1.4×)
    //     so the contrast between lit and shadow rim matches iOS 26's reference.
    //       normalXY is the 2D surface normal at this pixel (rim = non-zero, interior = 0).
    //       dot(n, L) = +1 → full lit → scale 0.6 (absorption hidden by specular)
    //       dot(n, L) = -1 → shadow  → scale 1.4 (absorption fully exposed)
    //
    // [3] CHROMATIC ABERRATION AT THE RIM
    //     Already correct here: displacement magnitude is proportional to normalXY
    //     which is zero at the interior and maximum at the rim — so the RGB split
    //     in the refraction sampling above (lines ~338-350) is already edge-weighted.
    //     No change needed.

    // [1] Hemisphere profile: use normalizedHeight as the radial parameter.
    //     normalizedHeight ≈ 0 at the interior flat face, ≈ 1 at the rim boundary.
    //     Invert: r_rim = 1 - normalizedHeight → 1 at rim, 0 interior.
    float r_rim = clamp(1.0 - normalizedHeight, 0.0, 1.0);
    float lensThickness = uThickness < 0.01 ? 0.0 : sqrt(max(0.0, 1.0 - r_rim * r_rim));
    // lensThickness: 1.0 at interior (r_rim=0), 0.0 at rim (r_rim=1) — correct:
    // interior glass is thinnest, rim is thickest → invert for absorption weight.
    float rimThickness = 1.0 - lensThickness; // 0 interior → 1 rim

    // [2] Light-modulated strength
    float litness   = dot(rimN, uLightDirection); // [-1, +1]
    float dirScale  = mix(1.4, 0.6, litness * 0.5 + 0.5);

    float absorption = 1.0 - sqrt(rimThickness) * uEdgeConfig.w * dirScale;
    finalColor.rgb *= max(0.0, absorption);

    if (edgeFactor > 0.01) {
        // Re-normalize the bilinearly interpolated normal.
        // Interpolating normals across pixels shrinks their magnitude (the 'chord' effect).
        // If we don't re-normalize, this magnitude oscillation causes severe flickering
        // when amplified by non-linear specular curves.
        float len = max(length(normalXY), 1e-4);
        vec2 anisoN = normalXY / len;

        float mainLight     = max(0.0, dot(anisoN, uLightDirection));
        float oppositeLight = max(0.0, dot(anisoN, -uLightDirection));
        float totalInfluence = mainLight + oppositeLight * 0.8;

        // Restore the thin, sharp iOS 26 highlight lobe!
        // pow(x, 1.5) = x * sqrt(x). This thins out the highlight without causing
        // flickering because we properly re-normalized anisoN above.
        float directional = totalInfluence * sqrt(totalInfluence) * uLightIntensity * 3.0;
        float ambient     = uAmbientStrength * 0.5;

        // Soft-clamp brightness with x/(1+x) to prevent mix() extrapolating
        // beyond highlightColor.
        float brightnessRaw = (directional + ambient) * edgeFactor * thicknessScale * 0.8;
        float brightness    = brightnessRaw / (1.0 + brightnessRaw);

        // 中文说明：镜面白光避开最外终止边，并在内侧约 2px 内平滑恢复，
        // 防止后绘制的高光重新把灰黑边覆盖成白色描边。
        brightness *= innerHighlightGate;

        vec3 highlightColor = getHighlightColor(refractColor.rgb, 1.0);
        finalColor.rgb = mix(finalColor.rgb, highlightColor, brightness);
    }

    // VQ2: Fresnel edge luminosity ramp.
    //
    // iOS 26 glass is subtly brighter at grazing angles (the rim) even when
    // no directional specular highlight lands there.  This is the Fresnel term:
    // at near-normal incidence (flat interior) reflected light is minimal;
    // at grazing incidence (edges) it increases.
    //
    // normalZ → 0 at the rim (surface nearly perpendicular to view ray),
    // normalZ → 1 at flat interior (surface facing the camera directly).
    // So (1.0 - normalZ) gives a smooth 0→1 ramp from interior to rim.
    //
    // Gated by edgeFactor so the effect is naturally confined to the rim zone
    // and doesn't accumulate on interior pixels where edgeFactor ≈ 0.
    //
    // Strength 0.10 produces a gentle brightening calibrated against Apple
    // reference screenshots. Fully branchless — no extra GPU divergence.
    // Fresnel strength 0.12 (was 0.10 in the calibration build).
    // The extra 0.02 restores the subtle rim luminosity that the geometry AA band
    // experiment temporarily reduced — keeping the glass edge visually present
    // against dark bar backgrounds without making it glowing or harsh.
    float rimBase = (1.0 - normalZ) * edgeFactor;
    // uEdgeConfig.x (uAmbientRim) > 0 draws an ADDITIONAL rim band of that width (in the
    // normalized space of rimDist). This gives indicator pills a crisp, physical
    // illuminated edge that is thicker than a standard Fresnel gradient.
    // 
    // At uEdgeConfig.x = 0 rendering is exactly stock.
    // At uEdgeConfig.x = 2 the rim is noticeably thicker.
    // At uEdgeConfig.x = 3 the rim is very prominent.
    // Scale the anti-aliasing window by the same DPR scale applied to the thickness,
    // so the edge remains perfectly sharp (and exactly the same logical width) across all screens.
    float ringWindow = 0.75 * max(0.1, uEdgeConfig.z);
    
    float ring    = (1.0 - smoothstep(uEdgeConfig.x - ringWindow, uEdgeConfig.x + ringWindow, rimDist))
                  * step(0.001, uEdgeConfig.x);
    // 中文说明：Fresnel 和额外 ring 都属于白色反射，同样只允许出现在
    // 终止暗边的内侧，避免最外轮廓在最终合成阶段重新发亮。
    float fresnel = (rimBase * 0.12 * uEdgeConfig.y + ring * 0.45)
                  * innerHighlightGate;
    finalColor.rgb = clamp(finalColor.rgb + vec3(fresnel), 0.0, 1.0);

    // 中文说明：复用已经去预乘的折射背景，让顶部/底部肩部按背景逐通道
    // 最多消耗剩余亮度空间的 35% / 20%；峰值核心才会把增益提升到 1.0，并用
    // 宽 smoothstep 保留接近旧版 2dp 的可见范围，
    // 因而白底端点更白而不形成死白平台，背景纹理与色相仍会保留。区域高光
    // 先补亮内部，随后灰黑双层边再覆盖最外轮廓。
    finalColor.rgb = applyVerticalAreaHighlight(
        finalColor.rgb,
        refractColor.rgb,
        verticalAreaHighlightExposureLift,
        1.0
    );

    // 中文说明：最后先铺完整浅灰环，再叠加只由 abs(localRimN.x) 控制的
    // 几何局部左右深灰边；因此整个底栏旋转后，深边会和主体一起转动，而不是
    // 固定在屏幕左右。顺序晚于镜面高光与 Fresnel，不会再被白色反射覆盖。
    finalColor.rgb = applyDualLayerRim(
        finalColor.rgb,
        continuousLightRimMask,
        lateralDarkRimMask,
        uEdgeConfig.w
    );

    float alpha  = geometryData.a;

    // 中文说明：保留上游 v1.3.0 的 PlatformView 透传修复，并在 Poiesis
    // 结构边完成后调整覆盖率；这样既不会恢复黑色胶囊，也不会丢失定制边缘。
    bool passthrough = uPlatformViewMode > 0.5;
    if (passthrough) {
        float rim = clamp(fresnel * 3.0, 0.0, 1.0);
        alpha *= max(refractColor.a, rim);
        finalColor.rgb = mix(
            finalColor.rgb,
            vec3(1.0),
            rim * (1.0 - refractColor.a) * 0.85
        );
    }
    fragColor    = vec4(finalColor.rgb * alpha, alpha);
}
