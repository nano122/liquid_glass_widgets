import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final helperFile = File('shaders/edge_treatment.glsl');
  final helperSource = helperFile.readAsStringSync(encoding: utf8);

  test('SDR 宽基底与 EDR 指数衰减使用两组独立几何', () {
    // 中文说明：这些值就是 HDR 改造前可见的 SDR 高光宽度。回归测试明确锁定
    // 它们，并同时要求 EDR 使用独立命名常量，防止再次为调整 HDR 而误伤 SDR。
    expect(
      helperSource,
      contains('const float kTopAreaHighlightPlateau = 0.03;'),
    );
    expect(
      helperSource,
      contains('const float kBottomAreaHighlightPlateau = 0.04;'),
    );
    expect(
      helperSource,
      contains(
        'const float kTopAreaHighlightPlateauMaxLogicalHeight = 2.0;',
      ),
    );
    expect(
      helperSource,
      contains(
        'const float kBottomAreaHighlightPlateauMaxLogicalHeight = 3.0;',
      ),
    );
    expect(
      helperSource,
      contains('const float kCrescentTopPlateau = 0.12;'),
    );
    expect(
      helperSource,
      contains('const float kCrescentBottomPlateau = 0.10;'),
    );
    expect(
      helperSource,
      contains('const float kTopEdrDecayLogical = 1.5;'),
    );
    expect(
      helperSource,
      contains('const float kBottomEdrDecayLogical = 1.5;'),
    );
    expect(
      helperSource,
      contains('vec4 getAdaptiveAreaHighlightExposureProfiles('),
    );
    expect(helperSource, contains('highlightExposureProfiles.xy'));
    expect(helperSource, contains('highlightExposureProfiles.zw'));
  });

  test('headroom 为 1.0 时 EDR 层没有任何 SDR 二次提亮', () {
    // 中文说明：EDR 增量必须显式乘 hdrRange。旧公式以 1.0 白点减去当前颜色，
    // 即使 hdrRange 为零也会再提亮窄核心，导致 SDR 输出不再是独立基线。
    expect(
      helperSource,
      contains('vec3(safeColorAlpha * hdrRange * edgeEdrEnergy)'),
    );
    expect(
      helperSource,
      isNot(contains('max(edrWhitePoint - withSdrHighlight')),
    );
    expect(
      helperSource,
      isNot(contains('kBottomHighlightSdrStrength')),
    );
  });

  test('四个 Shader 入口携带最新共享边缘源码校验值', () {
    final normalizedSource =
        helperSource.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final expectedHash = _adler32Hex(utf8.encode(normalizedSource));
    const entryPaths = <String>[
      'shaders/lightweight_glass.frag',
      'shaders/interactive_indicator.frag',
      'shaders/liquid_glass_render.frag',
      'shaders/liquid_glass_final_render_windows.frag',
    ];

    // 中文说明：Windows 有界合成 Shader 为控制 ANGLE 首次链接成本，主动
    // 省略了区域高光 Pass，且平台固定 SDR，因此只校验源码标记，不要求
    // 四通道遮罩；其余三个通用入口仍必须传递独立的 SDR/EDR 遮罩。
    const boundedSdrEntryPaths = <String>{
      'shaders/liquid_glass_final_render_windows.frag',
    };

    for (final path in entryPaths) {
      final source = File(path).readAsStringSync(encoding: utf8);
      expect(
        source,
        contains('POIESIS_EDGE_TREATMENT_ADLER32: $expectedHash'),
        reason: '$path 必须强制失效旧的增量 Shader 编译产物',
      );
      if (boundedSdrEntryPaths.contains(path)) {
        continue;
      }
      expect(
        source,
        contains('getAdaptiveAreaHighlightExposureProfiles('),
        reason: '$path 必须传递独立的 SDR/EDR 四通道遮罩',
      );
    }
  });

  test('SDR surface（headroom ≤ 1.0）跳过 EDR 遮罩与能量分配', () {
    // 中文说明：安卓掉帧排查发现 EDR 分层在 headroom=1.0 时仍逐像素计算
    // 多次 pow/smoothstep，结果却恒乘 0（现为四次 exp）。这里锁定
    // uniform 门控，防止后续改动把不可见的 EDR 开销重新带回 SDR 平台。
    expect(
      helperSource,
      contains('bool edrEnabled = highlightHeadroomMultiplier > 1.0;'),
    );
    expect(helperSource, contains('if (edrEnabled) {'));
    expect(helperSource, contains('if (hdrRange > 0.0) {'));
    // hdrRange 为 0 时的默认结果必须等价于完整公式（edrWhitePoint = alpha，
    // edrLift = 0），否则 SDR 输出会随门控发生偏移。
    expect(
      helperSource,
      contains('vec3 result = min(withSdrHighlight, vec3(safeColorAlpha));'),
    );
    // 能量分配只能出现在门控之后。
    expect(
      helperSource.indexOf('float edgeEnergy = max('),
      greaterThan(helperSource.indexOf('if (hdrRange > 0.0) {')),
    );
    for (final path in const <String>[
      'shaders/liquid_glass_render.frag',
      'shaders/lightweight_glass.frag',
      'shaders/interactive_indicator.frag',
    ]) {
      final source =
          File(path).readAsStringSync(encoding: utf8).replaceAll('\r\n', '\n');
      final call = source.indexOf('getAdaptiveAreaHighlightExposureProfiles(');
      final end = source.indexOf(');', call);
      expect(
        source.substring(call, end),
        contains('uHighlightHeadroom'),
        reason: '$path 必须把 headroom 传入遮罩函数，SDR 下才能跳过 EDR 遮罩',
      );
    }
  });

  test('EDR 边缘能量为单条指数衰减，不再是“肩部 + 窄核心”两级台阶', () {
    // 中文说明：回归 iOS HDR 高光“亮的地方太多”：旧实现把宽肩部与极窄核心
    // 两段 smootherstep 相加，1dp 内从 1.22 骤降到约 1.08 后在 2～4dp 形成
    // 平台。这里锁定按 dp 距离的 exp 衰减，并禁止两段式常量与函数回归。
    expect(
      helperSource,
      contains('exp(-capsuleTopDistance / kTopEdrDecayLogical)'),
    );
    expect(helperSource,
        contains('float capsuleTopDistance = clampedUV.y * safeSize.y;'));
    for (final removed in const <String>[
      'smootherstep01',
      'kTopHighlightShoulderEdrShare',
      'kBottomHighlightShoulderEdrShare',
      'kTopHighlightCoreStart',
      'kBottomHighlightCoreStart',
      'kTopAreaHighlightEdrPlateau',
      'kCrescentTopEdrPlateau',
    ]) {
      expect(
        helperSource,
        isNot(contains(removed)),
        reason: '$removed 属于已废弃的两级台阶 EDR 分配，不应再出现',
      );
    }
  });

  test('EDR 白点下限抬到基底，整块玻璃在 HDR 屏上保持偏亮', () {
    // 中文说明：旧实现边缘能量为 0 处白点被压回 1.0，主体提亮整段被截掉。
    // 总能量必须是“基底 + 剩余份额 × 边缘能量”，白点随之不低于基底。
    expect(
      helperSource,
      contains('const float kGlassBodyEdrShare = 0.15;'),
    );
    expect(
      helperSource,
      contains(
          'float edgeEdrEnergy = (1.0 - kGlassBodyEdrShare) * edgeEnergy;'),
    );
    expect(
      helperSource,
      contains('float edrEnergy = kGlassBodyEdrShare + edgeEdrEnergy;'),
    );
  });

  test('Windows 有界 Shader 声明 slot 49 但把高光白点限制在 SDR', () {
    // 中文说明：宿主在所有平台都会写 slot 49。Windows 必须声明并真实使用它，
    // 防止编译器裁掉未使用 uniform 造成槽位错位；同时封顶 1.0，保证 Windows
    // 永远不会输出扩展亮度。
    final windowsSource = File(
      'shaders/liquid_glass_final_render_windows.frag',
    ).readAsStringSync(encoding: utf8);
    expect(windowsSource, contains('uniform float uHighlightHeadroom;'));
    expect(
      windowsSource,
      contains('min(max(uHighlightHeadroom, 0.0), 1.0)'),
    );
  });
}

/// 计算与 Shader 入口注释一致的 Adler-32，小写十六进制固定补齐八位。
String _adler32Hex(List<int> bytes) {
  const modulus = 65521;
  var a = 1;
  var b = 0;
  for (final byte in bytes) {
    a = (a + byte) % modulus;
    b = (b + a) % modulus;
  }
  final value = (b << 16) | a;
  return value.toRadixString(16).padLeft(8, '0');
}
