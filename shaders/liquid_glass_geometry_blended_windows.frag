// Copyright 2025, Tim Lehmann for whynotmake.it
// Copyright 2026, Sebastian Degenaar for pixel-innovations.com
//
// SPDX-License-Identifier: MIT
//
// Windows Impeller/OpenGLESSDF 专用几何 Pass。
//
// 中文说明：通用版本为 16 个形状展开双向 smooth-union，并为中心差分重复
// 计算五次场景 SDF；ANGLE 首次链接该程序时会长时间占满一个 CPU 核心。
// 此版本维持 Windows GLES 原有的 8 形状上限和同一 uniform 布局，把距离与
// 梯度合并到一条前向 O(n) 链中。Windows 上超椭圆采用相同半径的圆角矩形
// 近似；圆形/胶囊端点保持一致，普通圆角矩形和椭圆仍走各自解析公式。
#version 460 core
precision highp float;

#include <flutter/runtime_effect.glsl>

#define MAX_SHAPES 16
layout(location = 0) uniform vec2 uSize;
layout(location = 1) uniform vec4 uOpticalProps;
layout(location = 2) uniform vec2 uShapeSettings;
layout(location = 3) uniform float uShapeData[MAX_SHAPES * 7];
layout(location = 0) out vec4 fragColor;

vec3 roundedRectField(vec2 p, vec2 halfSize, float radius) {
    radius = min(radius, min(halfSize.x, halfSize.y));
    vec2 q = abs(p) - halfSize + radius;
    vec2 outside = max(q, 0.0);
    float outsideLength = length(outside);
    float distance = min(max(q.x, q.y), 0.0) + outsideLength - radius;
    vec2 gradient;
    if (outsideLength > 1e-5) {
        gradient = outside / outsideLength * sign(p);
    } else if (q.x > q.y) {
        gradient = vec2(sign(p.x), 0.0);
    } else {
        gradient = vec2(0.0, sign(p.y));
    }
    return vec3(distance, gradient);
}

vec3 roundedRectAsymmetricField(
    vec2 p,
    vec2 halfSize,
    float topRadius,
    float bottomRadius
) {
    vec3 top = roundedRectField(p, halfSize, topRadius);
    vec3 bottom = roundedRectField(p, halfSize, bottomRadius);
    return mix(top, bottom, smoothstep(-2.0, 2.0, p.y));
}

vec3 ellipseField(vec2 p, vec2 radius) {
    radius = max(radius, vec2(1e-4));
    vec2 pOverRadius = p / radius;
    float k1 = length(pOverRadius);
    float k2 = length(p / (radius * radius));
    float distance = k1 * (k1 - 1.0) / max(k2, 1e-4);
    vec2 gradient = normalize(p / (radius * radius) + vec2(1e-6));
    return vec3(distance, gradient);
}

vec3 shapeField(
    float type,
    vec2 p,
    vec2 center,
    vec2 size,
    float topRadius,
    float bottomRadius
) {
    vec2 localPoint = p - center;
    vec2 halfSize = size * 0.5;
    if (type == 1.0) {
        return roundedRectAsymmetricField(
            localPoint,
            halfSize,
            topRadius,
            bottomRadius
        );
    }
    if (type == 2.0) return ellipseField(localPoint, halfSize);
    if (type == 3.0) {
        return roundedRectAsymmetricField(
            localPoint,
            halfSize,
            topRadius,
            bottomRadius
        );
    }
    return vec3(1e9, 0.0, 0.0);
}

#define SHAPE_FIELD(BASE) shapeField( \
    uShapeData[BASE], p, \
    vec2(uShapeData[BASE + 1], uShapeData[BASE + 2]), \
    vec2(uShapeData[BASE + 3], uShapeData[BASE + 4]), \
    uShapeData[BASE + 5], uShapeData[BASE + 6])

vec3 field0(vec2 p) { return SHAPE_FIELD(0); }
vec3 field1(vec2 p) { return SHAPE_FIELD(7); }
vec3 field2(vec2 p) { return SHAPE_FIELD(14); }
vec3 field3(vec2 p) { return SHAPE_FIELD(21); }
vec3 field4(vec2 p) { return SHAPE_FIELD(28); }
vec3 field5(vec2 p) { return SHAPE_FIELD(35); }
vec3 field6(vec2 p) { return SHAPE_FIELD(42); }
vec3 field7(vec2 p) { return SHAPE_FIELD(49); }

vec3 smoothUnionField(vec3 first, vec3 second, float blend) {
    if (blend <= 1e-5) return first.x < second.x ? first : second;
    float weight = clamp(
        0.5 + 0.5 * (second.x - first.x) / blend,
        0.0,
        1.0
    );
    float distance = mix(second.x, first.x, weight)
        - blend * weight * (1.0 - weight);
    vec2 gradient = normalize(
        mix(second.yz, first.yz, weight) + vec2(1e-6)
    );
    return vec3(distance, gradient);
}

vec3 sceneField(vec2 p, int count, float blend) {
    if (count <= 0) return vec3(1e9, 0.0, 0.0);
    vec3 result = field0(p);
    if (count == 1) return result;
    result = smoothUnionField(result, field1(p), blend);
    if (count == 2) return result;
    result = smoothUnionField(result, field2(p), blend);
    if (count == 3) return result;
    result = smoothUnionField(result, field3(p), blend);
    if (count == 4) return result;
    result = smoothUnionField(result, field4(p), blend);
    if (count == 5) return result;
    result = smoothUnionField(result, field5(p), blend);
    if (count == 6) return result;
    result = smoothUnionField(result, field6(p), blend);
    if (count == 7) return result;
    return smoothUnionField(result, field7(p), blend);
}

void main() {
    float thickness = uOpticalProps.z;
    int shapeCount = int(min(uShapeSettings.x, 8.0));
    vec3 field = sceneField(
        FlutterFragCoord().xy,
        shapeCount,
        uOpticalProps.w
    );
    float gradientLength = length(field.yz);
    float normalizedDistance = gradientLength > 0.1
        ? field.x / gradientLength
        : field.x;
    float alpha = clamp(0.5 - normalizedDistance, 0.0, 1.0);
    if (alpha < 0.01 || thickness <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    float opticalDistance = min(normalizedDistance, 0.0);
    float normalCosine = clamp(
        (thickness + opticalDistance) / thickness,
        0.0,
        1.0
    );
    vec2 normalXY = normalize(vec3(
        field.yz * normalCosine,
        sqrt(max(0.0, 1.0 - normalCosine * normalCosine))
    )).xy;
    float x = thickness + opticalDistance;
    float height = opticalDistance < -thickness
        ? thickness
        : sqrt(max(0.0, thickness * thickness - x * x));

    // 保留 uSize 与 DPR 槽位，避免 host 的既有写入顺序被驱动优化破坏。
    alpha = max(
        alpha,
        (dot(uSize, vec2(1.0)) + uShapeSettings.y) * 1e-20
    );
    fragColor = vec4(
        clamp(normalXY * 0.5 + 0.5, 0.0, 1.0),
        clamp(height / thickness, 0.0, 1.0),
        alpha
    );
}
