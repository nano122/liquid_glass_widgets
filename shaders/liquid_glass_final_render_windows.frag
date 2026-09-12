// Copyright 2025, Tim Lehmann for whynotmake.it
// Copyright 2026, Sebastian Degenaar for pixel-innovations.com
//
// SPDX-License-Identifier: MIT
//
// Windows Impeller/OpenGLESSDF 专用 Premium 最终合成 Pass。
//
// 中文说明：保留几何法线折射、RGB 色散、亮度保持 tint、饱和度、增白、
// Fresnel、边缘吸收和显式快照合成。背景读取使用最多三次硬件采样，结构边
// 直接复用中心 geometry 数据，避免通用版本的手工双线性与八点边缘采样在
// ANGLE 首次链接时展开成大型程序。
#version 460 core
precision highp float;

#include <flutter/runtime_effect.glsl>
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
vec4 analyticRoundedRectGeometry(vec2 localPoint, float thickness) {
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

    vec2 screenGradient = vec2(
        gradient.x * uAnalyticInverseX.x
            + gradient.y * uAnalyticInverseY.x,
        gradient.x * uAnalyticInverseX.y
            + gradient.y * uAnalyticInverseY.y
    );
    float logicalDistancePerPixel = max(length(screenGradient), 1e-4);
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

    if (geometryData.a < 0.01) {
        fragColor = vec4(0.0);
        return;
    }

    vec2 localNormal = geometryData.rg * 2.0 - 1.0;
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
    float fresnelBase = 1.0 - normalZ;
    float fresnel = fresnelBase * fresnelBase * uEdgeConfig.y;
    // 中文说明：main 分支的 host uniform 到 uCaptureConfig 为止，Windows
    // 专用 Shader 必须维持完全相同的 49 个 float 槽位。此平台仍为 SDR，
    // 高光上限固定为 1.0，不能把其他分支的 EDR headroom 槽合并进来。
    float highlight = specular * 0.20 + fresnel * 0.12
        + edge * uEdgeConfig.x * 0.10;
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

    float alpha = geometryData.a;
    if (uPlatformViewMode > 0.5) {
        alpha *= max(background.a, clamp(fresnel * 2.0, 0.0, 1.0));
    }
    fragColor = vec4(color * alpha, alpha);
}
