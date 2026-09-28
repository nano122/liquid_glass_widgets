// 中文说明：升级官方 1.7.2 时，上游新增的 uBodyMode / uTouchPosition /
// uTouchIntensity 原本写在 slot 33–36，与 Poiesis 的解析几何 32–43 冲突。
// 本文件锁定“顺延到 50–53 / 轻量 38”的契约，以及 #333 pass 原点折算，
// 防止后续再合并上游时 uniform 静默错位（错位不会报错，只会画错）。
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/src/engine/rendering/liquid_glass_render_object.dart';

/// 提取 GLSL 中所有非 sampler uniform 的变量名（按声明顺序），忽略注释行。
///
/// 中文说明：sampler 不占 float 槽位，排除后列表顺序即 float 槽位分配顺序。
List<String> _uniformNames(String source) {
  final pattern = RegExp(
    r'^[ \t]*uniform\s+(?!sampler)\w+\s+(\w+)[ \t]*;',
    multiLine: true,
  );
  return pattern.allMatches(source).map((m) => m.group(1)!).toList();
}

void main() {
  group('Premium 最终合成 uniform 顺延', () {
    final premium = File('shaders/liquid_glass_render.frag').readAsStringSync();
    final windows = File('shaders/liquid_glass_final_render_windows.frag')
        .readAsStringSync();
    final renderObject = File(
      'lib/src/engine/rendering/liquid_glass_render_object.dart',
    ).readAsStringSync();

    test('上游新增 uniform 紧跟 uHighlightHeadroom 声明', () {
      final names = _uniformNames(premium);
      final headroom = names.indexOf('uHighlightHeadroom');
      expect(headroom, isNonNegative);
      // 中文说明：float 槽位按声明顺序连续分配，49 之后必须依次是 50/51-52/53。
      expect(
        names.sublist(headroom, headroom + 4),
        orderedEquals(<String>[
          'uHighlightHeadroom',
          'uBodyMode',
          'uTouchPosition',
          'uTouchIntensity',
        ]),
      );
    });

    test('Windows 安全 Shader 声明并使用 slots 50–53', () {
      expect(_uniformNames(windows), orderedEquals(_uniformNames(premium)));
      // 中文说明：未被引用的 uniform 可能被编译器裁掉，导致宿主写入越界。
      expect(windows,
          contains('applyGlassTint(background.rgb, uGlassColor, uBodyMode)'));
      expect(windows, contains('fragCoord - uTouchPosition'));
      expect(windows, contains('uTouchIntensity > 0.001'));
    });

    test('宿主在实时与捕获两条路径都写 slot 50 与 51，且不再写 33/34', () {
      expect(
        RegExp(r'setFloatUniforms\(initialIndex: 50').allMatches(renderObject),
        hasLength(2),
      );
      expect(
        RegExp(r'setFloatUniforms\(initialIndex: 51').allMatches(renderObject),
        hasLength(2),
      );
      // 中文说明：33/34 属于 Poiesis 的 uAnalyticRect，上游写法若被再次合并
      // 进来会覆盖解析圆角尺寸。
      expect(renderObject, isNot(contains('initialIndex: 33')));
      expect(renderObject, isNot(contains('initialIndex: 34')));
    });

    test('#337 边缘折射上限仍位于 Poiesis 折射门控之内', () {
      final gate = premium.indexOf(
        'if (refractionAreaGate > 0.0 && normalMagnitudeSquared >= 1e-4)',
      );
      final clamp = premium.indexOf('float maxReach');
      expect(gate, isNonNegative);
      expect(clamp, greaterThan(gate));
      // 中文说明：必须使用统一换算后的 dp 尺寸，而不是在逆仿射路径里语义为
      // 本地逻辑像素的 uGeometrySize。
      expect(premium, isNot(contains('min(uGeometrySize.x, uGeometrySize.y)')));
      expect(windows, contains('float maxReach'));
    });
  });

  group('轻量 Shader uBodyMode', () {
    test('uBodyMode 位于 Poiesis 的 uHighlightHeadroom(37) 之后即 slot 38', () {
      final names = _uniformNames(
        File('shaders/lightweight_glass.frag').readAsStringSync(),
      );
      expect(names.last, 'uBodyMode');
      expect(names[names.length - 2], 'uHighlightHeadroom');
    });
  });

  group('shiftGeometryUniformsToPass (#333)', () {
    // 中文说明：X 行 = (a, b, c, enabled)，Y 行 = (d, e, f, 0)。
    const values = <double>[
      100, 50, 12, 1, // uAnalyticRect
      0.5, 0.25, -10, 1, // uAnalyticInverseX
      -0.25, 0.5, -20, 0, // uAnalyticInverseY
    ];

    test('pass 原点为零时原样返回', () {
      expect(
        identical(shiftGeometryUniformsToPass(values, Offset.zero), values),
        isTrue,
      );
    });

    test('只改写两行的平移项，使 pass 相对坐标映射到同一本地点', () {
      const origin = Offset(40, 80);
      final shifted = shiftGeometryUniformsToPass(values, origin);
      // 中文说明：pass 内片元 p 对应屏幕 p + origin；两种写法应得同一本地点。
      const passFragment = Offset(7, 9);
      final screenFragment = passFragment + origin;
      double row(List<double> v, int base, Offset p) =>
          v[base] * p.dx + v[base + 1] * p.dy + v[base + 2];
      expect(row(shifted, 4, passFragment),
          closeTo(row(values, 4, screenFragment), 1e-9));
      expect(row(shifted, 8, passFragment),
          closeTo(row(values, 8, screenFragment), 1e-9));
      // 线性项、尺寸与启用标记保持不变，且不修改入参。
      for (final i in <int>[0, 1, 2, 3, 4, 5, 7, 8, 9, 11]) {
        expect(shifted[i], values[i]);
      }
      expect(values[6], -10);
    });

    test('禁用的全零 uniform 折算后仍为全零', () {
      final zeros = List<double>.filled(12, 0);
      expect(
        shiftGeometryUniformsToPass(zeros, const Offset(30, 60)),
        everyElement(0),
      );
    });
  });

  group('liveTouchPositionUniform', () {
    test('layer 不在屏幕原点时先映射到屏幕再换算 pass 原点', () {
      // 中文说明：修复上游把 layer 本地触点直接乘 DPR 的问题——layer 平移
      // (100, 200) 时，本地 (10, 20) 应落在屏幕逻辑 (110, 220)。
      final layerToScreen = Matrix4.translationValues(100, 200, 0);
      final result = liveTouchPositionUniform(
        layerToScreen: layerToScreen,
        localTouchPosition: const Offset(10, 20),
        devicePixelRatio: 3,
        passOrigin: const Offset(30, 60),
      );
      expect(result, const Offset(110 * 3 - 30, 220 * 3 - 60));
    });

    test('单位矩阵、无外层 pass 时退化为上游写法', () {
      final result = liveTouchPositionUniform(
        layerToScreen: Matrix4.identity(),
        localTouchPosition: const Offset(10, 20),
        devicePixelRatio: 2,
        passOrigin: Offset.zero,
      );
      expect(result, const Offset(20, 40));
    });
  });
}
