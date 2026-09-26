// Copyright 2025, Tim Lehmann for whynotmake.it
// Copyright 2026, Sebastian Degenaar for pixel-innovations.com
//
// SPDX-License-Identifier: MIT
//
// Windows Impeller/OpenGLESSDF 专用 Premium 最终合成 Pass。
//
// 中文说明：保留几何法线折射、RGB 色散、亮度保持 tint、饱和度、增白、
// Fresnel、边缘吸收和显式快照合成。背景读取使用最多三次硬件采样，并继续
// 避开通用版本的手工双线性背景插值与超椭圆 mode 2，控制 ANGLE 首次链接成本。
//
// 结构边与通用 Shader 完全一致：同样只在轮廓窄带对 SDF/geometry 数据执行
// 8 点 RGSS 超采样，复用 edge_treatment.glsl 的浅灰完整环与左右深色边，并让
// 镜面高光、Fresnel 和 ambient rim 从描边内侧渐入。2026-09-26 之前此文件删除了
// 这套逻辑，Windows 最外轮廓因此被 Fresnel 提亮成白边，而 Android 为黑边。
#version 460 core
precision highp float;

#include <flutter/runtime_effect.glsl>
// 中文说明：Flutter 的增量 Shader 构建不会把自定义 #include 记录为入口依赖。
// 此校验值对应 edge_treatment.glsl 的规范化 UTF-8 内容；修改共享边缘算法后，
// 必须同步更新全部四个入口（含本 Windows 入口），旧编译产物才不会被继续复用。
// POIESIS_EDGE_TREATMENT_ADLER32: eed60717
#include "edge_treatment.glsl"
#include "gles_compat.glsl"

uniform vec2 uSize;
uniform vec2 uGeometryOffset;
uniform vec2 uGeometrySize;
uniform vec4 uGlassColor;
uniform vec4 uOpticalProps;
uniform vec3 uLightConfig;
uniform vec2 uLightDirection;
uniform float uWhiten;
uniform float uWhitenGated;
uniform float uPinchStrength;
uniform vec4 uBackgroundFallback;
uniform vec2 uCaptureOffset;
uniform vec4 uEdgeConfig;
uniform vec4 uAnalyticRect;
uniform vec4 uAnalyticInverseX;
uniform vec4 uAnalyticInverseY;
uniform float uPlatformViewMode;
uniform float uRefractionEnabled;
uniform float uTopRefractionOnly;
uniform vec2 uCaptureConfig;

uniform sampler2D uBackgroundTexture;
uniform sampler2D uGeometryTexture;

layout(location = 0) out vec4 fragColor;

const vec3 kLumaWeights = vec3(0.299, 0.587, 0.114);

vec2 geometryLocalPoint(vec2 fragCoord) {
    return vec2(
        dot(uAnalyticInverseX.xy, fragCoord) + uAnalyticInverseX.z,
        dot(uAnalyticInverseY.xy, fragCoord) + uAnalyticInverseY.z
    );
}

vec2 geometryNormalToScreen(vec2 localNormal) {
    float localLength = length(localNormal);
    if (localLength < 1e-5 || uAnalyticInverseX.w < 0.5) {
        return localNormal;
    }
    vec2 screenGradient = vec2(
        localNormal.x * uAnalyticInverseX.x
            + localNormal.y * uAnalyticInverseY.x,
        localNormal.x * uAnalyticInverseX.y
            + localNormal.y * uAnalyticInverseY.y
    );
    float screenLength = length(screenGradient);
    return screenLength > 1e-5
        ? screenGradient * (localLength / screenLength)
        : localNormal;
}

// 解析式仅覆盖圆角矩形。Windows 的超椭圆继续由 Dart 回退到 geometry
// texture，避免重新引入会导致永久白屏的动态幂函数路径。
//
// 中文说明：返回 (本地逻辑像素 SDF, 单位梯度, 1.0)。中心几何与 8 个 RGSS
// 边缘样本共用这一函数，保证 alpha、折射法线和双层描边位于同一条轮廓上；
// 返回格式与通用 Shader 的 analyticRoundedRectSdfAt 保持一致。
vec4 analyticRoundedRectSdfAt(vec2 localPoint) {
    vec2 size = max(uAnalyticRect.xy, vec2(0.001));
    vec2 halfSize = size * 0.5;
    float radius = min(uAnalyticRect.z, min(halfSize.x, halfSize.y));
    vec2 centered = localPoint - halfSize;
    vec2 q = abs(centered) - halfSize + radius;
    vec2 outside = max(q, 0.0);
    float outsideLength = length(outside);
    float signedDistance = min(max(q.x, q.y), 0.0)
        + outsideLength - radius;

    vec2 gradient;
    if (outsideLength > 1e-5) {
        gradient = outside / outsideLength * sign(centered);
    } else if (q.x > q.y) {
        gradient = vec2(sign(centered.x), 0.0);
    } else {
        gradient = vec2(0.0, sign(centered.y));
    }
    return vec4(signedDistance, gradient, 1.0);
}

vec4 analyticRoundedRectGeometry(vec2 localPoint, float thickness) {
    vec4 sdfData = analyticRoundedRectSdfAt(localPoint);
    float signedDistance = sdfData.x;
    vec2 gradient = sdfData.yz;

    vec2 screenGradient = vec2(
        gradient.x * uAnalyticInverseX.x
            + gradient.y * uAnalyticInverseY.x,
        gradient.x * uAnalyticInverseX.y
            + gradient.y * uAnalyticInverseY.y
    );
    // 中文说明：方形屏幕像素沿法线的覆盖宽度取 L1 投影，与通用 Shader 及
    // edge_treatment.glsl 的 getSdfPixelFootprint 一致；旧 L2 会在斜向圆弧
    // 少估约 29% 的 AA 窗口，使中心 alpha 与 RGSS 描边覆盖率不一致。
    float logicalDistancePerPixel = getSdfPixelFootprint(screenGradient);
    float alpha = clamp(
        0.5 - signedDistance / logicalDistancePerPixel,
        0.0,
        1.0
    );
    if (alpha < 0.01 || thickness <= 0.0) {
        return vec4(0.0);
    }

    float dpr = max(1.0, uEdgeConfig.z * 3.0);
    float physicalDistance = min(signedDistance, 0.0) * dpr;
    float normalScale = clamp(
        (thickness + physicalDistance) / max(thickness, 0.001),
        0.0,
        1.0
    );
    vec2 normalXY = gradient * normalScale;
    float x = thickness + physicalDistance;
    float height = physicalDistance < -thickness
        ? thickness
        : sqrt(max(0.0, thickness * thickness - x * x));
    return vec4(
        clamp(normalXY * 0.5 + 0.5, 0.0, 1.0),
        clamp(height / max(thickness, 0.001), 0.0, 1.0),
        alpha
    );
}

// 中文说明：把任意子像素片元坐标换算成 geometry texture UV。启用逆仿射时
// 纹理保存玻璃本地逻辑坐标，否则保存屏幕物理像素包围盒；旧 GLES 仅翻转
// 纹理 Y。结果钳制在 [0, 1]，避免 Repeat 采样器绕到对侧边缘。
vec2 geometryTextureUvFromFragment(vec2 sampleFragCoord) {
    vec2 texturePoint = uAnalyticInverseX.w > 0.5
        ? geometryLocalPoint(sampleFragCoord)
        : sampleFragCoord;
    vec2 sampleUv = (texturePoint - uGeometryOffset)
        / max(uGeometrySize, vec2(0.001));
    #ifdef LGR_GLES_FLIP_SAMPLE_Y
        sampleUv.y = 1.0 - sampleUv.y;
    #endif
    return clamp(sampleUv, 0.0, 1.0);
}

// 中文说明：几何 Pass 把高度编码为 sqrt(T² - (T + d)²) / T，这里精确反解出
// 从外轮廓向内的物理像素距离 d，供描边宽度与白光避让使用。
float rimDistanceFromGeometry(vec4 geometryData, float thickness) {
    float normalizedHeight = geometryData.b;
    float cosTerm = sqrt(max(
        0.0,
        1.0 - normalizedHeight * normalizedHeight
    ));
    return thickness * (1.0 - cosTerm);
}

// 中文说明：解析圆角矩形在一个 RGSS 子像素位置重新求 SDF。每个样本独立
// 经逆仿射计算屏幕距离比例，旋转或 jelly 缩放时终止边仍保持恒定物理宽度。
// 与通用 Shader 同名函数逐行等价，只是 SDF 不包含 Windows 不支持的 mode 2。
vec3 sampleAnalyticEdgeAtOffset(
    vec2 pixelOffset,
    vec2 fragCoord,
    vec2 lightRimProfile,
    vec2 darkRimProfile
) {
    vec2 sampleLocal = geometryLocalPoint(fragCoord + pixelOffset);
    vec4 sampleSdf = analyticRoundedRectSdfAt(sampleLocal);
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

// 中文说明：多形状与 Windows 超椭圆回退只能从 geometry texture 恢复 SDF。
// 在一个 RGSS 子像素读取 alpha/法线/高度并还原描边面积；这些读取只发生在
// 轮廓窄带，且与中心样本相邻（cache-hot），背景纹理读取数量保持不变。
// 与通用 Shader 同名函数逐行等价。
vec3 sampleTextureEdgeAtOffset(
    vec2 pixelOffset,
    vec2 fragCoord,
    float thickness,
    float dpr,
    vec2 lightRimProfile,
    vec2 darkRimProfile
) {
    vec4 sampleGeometry = texture(
        uGeometryTexture,
        geometryTextureUvFromFragment(fragCoord + pixelOffset)
    );
    vec2 sampleLocalNormal = sampleGeometry.rg * 2.0 - 1.0;
    float sampleNormalLength = max(length(sampleLocalNormal), 1e-4);
    vec2 sampleLocalRimNormal = sampleLocalNormal / sampleNormalLength;
    vec2 sampleScreenGradient = vec2(
        sampleLocalRimNormal.x * uAnalyticInverseX.x
            + sampleLocalRimNormal.y * uAnalyticInverseY.x,
        sampleLocalRimNormal.x * uAnalyticInverseX.y
            + sampleLocalRimNormal.y * uAnalyticInverseY.y
    );
    // 中文说明：逆仿射路径的纹理距离是物理像素，需要乘回 DPR；屏幕包围盒
    // 兼容路径本身就在物理像素空间，比例固定为 1。
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

// Windows 路径使用一次硬件采样。当前 Flutter 绑定可能采用 nearest，画质
// 影响只落在折射边缘；换来的收益是避免把 3 个色散通道展开成 12 次读取。
vec4 sampleBackground(vec2 uv) {
    vec4 background = texture(
        uBackgroundTexture,
        clamp(uv, vec2(0.001), vec2(0.999))
    );
    if (uCaptureConfig.x > 0.5) {
        background.rgb *= 1.0 - uCaptureConfig.y;
        background.a += (1.0 - background.a) * uCaptureConfig.y;
    }
    if (uBackgroundFallback.a > 0.0) {
        background.rgb += uBackgroundFallback.rgb
            * uBackgroundFallback.a * (1.0 - background.a);
        background.a += uBackgroundFallback.a * (1.0 - background.a);
    }
    return background;
}

vec3 applySaturation(vec3 color, float saturation) {
    float luminance = dot(color, kLumaWeights);
    return clamp(mix(vec3(luminance), color, saturation), 0.0, 1.0);
}

vec3 applyGlassTint(vec3 background, vec4 glassColor) {
    float backgroundLuma = dot(background, kLumaWeights);
    float glassLuma = dot(glassColor.rgb, kLumaWeights);
    vec3 luminosityTint = clamp(
        glassColor.rgb + backgroundLuma - glassLuma,
        0.0,
        1.0
    );
    float chroma = max(max(glassColor.r, glassColor.g), glassColor.b)
        - min(min(glassColor.r, glassColor.g), glassColor.b);
    vec3 directTint = mix(background, glassColor.rgb, glassColor.a);
    vec3 chromaticTint = mix(background, luminosityTint, glassColor.a);
    return mix(directTint, chromaticTint, clamp(chroma * 8.0, 0.0, 1.0));
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 inverseTextureSize = 1.0 / max(uSize, vec2(1.0));
    vec2 backgroundUv = (fragCoord + uCaptureOffset) * inverseTextureSize;
    // 中文说明：Flutter 3.46 之前的 GLES 离屏纹理使用相反的 Y 原点。
    // 兼容宏只调整纹理坐标，不改变玻璃本地坐标，避免顶部折射区域倒置。
    #ifdef LGR_GLES_FLIP_SAMPLE_Y
        backgroundUv.y = 1.0 - backgroundUv.y;
    #endif

    vec2 geometryUv;
    vec4 geometryData;
    if (uAnalyticRect.w > 0.5) {
        vec2 localPoint = geometryLocalPoint(fragCoord);
        geometryUv = clamp(
            localPoint / max(uAnalyticRect.xy, vec2(0.001)),
            0.0,
            1.0
        );
        geometryData = analyticRoundedRectGeometry(
            localPoint,
            uOpticalProps.z
        );
    } else {
        vec2 texturePoint = uAnalyticInverseX.w > 0.5
            ? geometryLocalPoint(fragCoord)
            : fragCoord;
        geometryUv = clamp(
            (texturePoint - uGeometryOffset) / max(uGeometrySize, vec2(0.001)),
            0.0,
            1.0
        );
        vec2 geometrySampleUv = geometryUv;
        #ifdef LGR_GLES_FLIP_SAMPLE_Y
            geometrySampleUv.y = 1.0 - geometrySampleUv.y;
        #endif
        geometryData = texture(uGeometryTexture, geometrySampleUv);
    }

    // 中文说明：0.36 / 0.18 logical px 先换成名义物理宽度；不足一物理像素
    // 时 profile.x 扩为 1px、profile.y 同比降低能量。参数与通用 Shader 一致，
    // 保证 Windows 与 Android 的描边累计视觉重量相同。
    float dpr = max(1.0, uEdgeConfig.z * 3.0);
    const float lightRimLogicalWidth = 0.36;
    const float darkRimLogicalWidth = 0.18;
    vec2 lightRimProfile = getEnergyPreservingRimProfile(
        lightRimLogicalWidth * dpr
    );
    vec2 darkRimProfile = getEnergyPreservingRimProfile(
        darkRimLogicalWidth * dpr
    );
    float centerRimDistance = rimDistanceFromGeometry(
        geometryData,
        uOpticalProps.z
    );
    float conservativeEdgeReach =
        max(lightRimProfile.x, darkRimProfile.x) * 4.0 + 1.0;
    vec3 supersampledEdge;
    if (geometryData.a >= 0.999 && centerRimDistance > conservativeEdgeReach) {
        // 中文说明：中心完全覆盖且远离终止边时，任何子样本都不会落入一像素
        // 描边，直接返回满 alpha / 零描边。绝大多数内部片元走此分支，8 次
        // SDF 或几何纹理读取只发生在形状外沿的窄带。
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
                  sampleTextureEdgeAtOffset(kEdgeRgss0, fragCoord, uOpticalProps.z, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss1, fragCoord, uOpticalProps.z, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss2, fragCoord, uOpticalProps.z, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss3, fragCoord, uOpticalProps.z, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss4, fragCoord, uOpticalProps.z, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss5, fragCoord, uOpticalProps.z, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss6, fragCoord, uOpticalProps.z, dpr, lightRimProfile, darkRimProfile)
                + sampleTextureEdgeAtOffset(kEdgeRgss7, fragCoord, uOpticalProps.z, dpr, lightRimProfile, darkRimProfile);
        }
        supersampledEdge = resolveEdgeSupersample(edgeSampleSum);
    }
    // 中文说明：外形覆盖率改用 8 点结果，中心样本只继续提供法线与高度。
    geometryData.a = supersampledEdge.x;
    float continuousLightRimMask = supersampledEdge.y;
    float lateralDarkRimMask = supersampledEdge.z;

    if (geometryData.a < 0.01) {
        fragColor = vec4(0.0);
        return;
    }

    // 中文说明：外侧 RGSS 样本可能检测到少量覆盖，而中心几何样本仍完全透明
    // （纹理为透明黑、解析路径返回 vec4(0)）。此时 RG 解码出的 (-1, -1) 不是
    // 有效法线，必须归零，否则会在玻璃外侧凭空产生折射与镜面亮点。
    vec2 localNormal = geometryData.b > 0.0
        ? geometryData.rg * 2.0 - 1.0
        : vec2(0.0);
    vec2 normalXY = geometryNormalToScreen(localNormal);
    float normalLengthSquared = dot(normalXY, normalXY);
    float normalZ = sqrt(max(0.0, 1.0 - normalLengthSquared));

    float refractionGate = step(0.5, uRefractionEnabled);
    if (uTopRefractionOnly > 0.5) {
        refractionGate *= 1.0 - smoothstep(0.18, 0.24, geometryUv.y);
    }

    vec2 displacement = vec2(0.0);
    if (refractionGate > 0.0 && normalLengthSquared > 1e-4) {
        vec3 refracted = refract(
            vec3(0.0, 0.0, -1.0),
            vec3(normalXY, normalZ),
            1.0 / max(uOpticalProps.x, 0.001)
        );
        float height = geometryData.b * uOpticalProps.z;
        float rayLength = (height + uOpticalProps.z * 8.0)
            / max(abs(refracted.z), 0.001);
        displacement = refracted.xy * rayLength
            * uOpticalProps.w * refractionGate;
        // 中文说明：旧 GLES 仅需要反转实际的纹理位移，法线仍保持 Flutter
        // 屏幕坐标语义，防止折射方向与高光方向一起被错误翻转。
        #ifdef LGR_GLES_FLIP_SAMPLE_Y
            displacement.y = -displacement.y;
        #endif
    }

    if (refractionGate > 0.0 && uPinchStrength > 0.001) {
        vec2 centered = geometryUv - 0.5;
        float horizontalEdge = smoothstep(0.15, 0.5, abs(centered.x));
        backgroundUv += centered * horizontalEdge
            * uPinchStrength * 0.025 * geometryData.a * refractionGate;
    }

    vec2 refractedUv = backgroundUv + displacement * inverseTextureSize;
    float dispersion = uOpticalProps.y * 0.5 * refractionGate;
    vec4 background;
    if (dispersion < 0.01) {
        background = sampleBackground(refractedUv);
    } else {
        vec4 redSample = sampleBackground(
            backgroundUv + displacement * (1.0 + dispersion)
                * inverseTextureSize
        );
        vec4 greenSample = sampleBackground(refractedUv);
        vec4 blueSample = sampleBackground(
            backgroundUv + displacement * (1.0 - dispersion)
                * inverseTextureSize
        );
        background = vec4(
            redSample.r,
            greenSample.g,
            blueSample.b,
            greenSample.a
        );
    }
    if (background.a > 0.001) {
        background.rgb /= background.a;
    }

    vec3 color = applyGlassTint(background.rgb, uGlassColor);
    color = applySaturation(color, uLightConfig.z);

    vec2 lightDirection = normalize(uLightDirection + vec2(1e-5));
    float directional = max(dot(normalXY, -lightDirection), 0.0);
    float directionalSquared = directional * directional;
    float specular = directionalSquared * directionalSquared
        * max(uLightConfig.x, 0.0);
    float edge = 1.0 - smoothstep(0.08, 0.32, geometryData.b);

    // 中文说明：白光避让与通用 Shader 相同——用中心样本的向内距离与屏幕
    // 恒宽的浅边宽度计算 innerHighlightGate。本地法线左乘逆仿射雅可比得到
    // 屏幕梯度，L2 长度把 1 物理像素换回 rimDist 单位；未启用逆仿射的屏幕
    // 包围盒兼容路径本身就是物理像素，比例固定为 1。
    vec2 localRimNormal = localNormal / max(length(localNormal), 1e-4);
    vec2 rimScreenGradient = vec2(
        localRimNormal.x * uAnalyticInverseX.x
            + localRimNormal.y * uAnalyticInverseY.x,
        localRimNormal.x * uAnalyticInverseX.y
            + localRimNormal.y * uAnalyticInverseY.y
    );
    float rimDistanceScale = mix(
        1.0,
        getSdfDistanceScale(rimScreenGradient) * dpr,
        step(0.5, uAnalyticInverseX.w)
    );
    float innerHighlightGate = getInnerHighlightGate(
        centerRimDistance,
        lightRimProfile.x * rimDistanceScale,
        uEdgeConfig.w
    );

    float fresnelBase = 1.0 - normalZ;
    // 中文说明：Fresnel 在最外轮廓处最强，正是旧版 Windows 白边的来源；
    // 乘入 innerHighlightGate 后只允许出现在描边内侧。PlatformView 透传的
    // alpha 也复用这一已避让值，与通用 Shader 的 passthrough 语义一致。
    float fresnel = fresnelBase * fresnelBase * uEdgeConfig.y
        * innerHighlightGate;
    // 中文说明：main 分支的 host uniform 到 uCaptureConfig 为止，Windows
    // 专用 Shader 必须维持完全相同的 49 个 float 槽位。此平台仍为 SDR，
    // 高光上限固定为 1.0，不能把其他分支的 EDR headroom 槽合并进来。
    // 镜面与 ambient rim 同样属于白色反射，统一在描边内侧渐入。
    float highlight = (specular * 0.20 + edge * uEdgeConfig.x * 0.10)
        * innerHighlightGate + fresnel * 0.12;
    color = clamp(color + vec3(highlight), 0.0, 1.0);

    float luminance = dot(color, kLumaWeights);
    float whitenGate = mix(
        1.0,
        1.0 - smoothstep(0.15, 0.75, luminance),
        clamp(uWhitenGated, 0.0, 1.0)
    );
    color = mix(
        color,
        vec3(1.0),
        clamp(uWhiten, 0.0, 1.0) * whitenGate
    );
    color *= 1.0 - clamp(uEdgeConfig.w, 0.0, 1.0) * edge * 0.35;

    // 中文说明：结构边必须是最后一个颜色运算：先铺完整浅灰环，再叠加只由
    // 局部 normal.x 控制的左右深色边。它晚于镜面、Fresnel、增白与吸收，
    // 因此任何白色反射都不能再覆盖最外轮廓；颜色与透明度来自共享的
    // applyDualLayerRim，与 Android/iOS 通用 Shader 完全相同。
    color = applyDualLayerRim(
        color,
        continuousLightRimMask,
        lateralDarkRimMask,
        uEdgeConfig.w
    );

    float alpha = geometryData.a;
    if (uPlatformViewMode > 0.5) {
        alpha *= max(background.a, clamp(fresnel * 2.0, 0.0, 1.0));
    }
    fragColor = vec4(color * alpha, alpha);
}
