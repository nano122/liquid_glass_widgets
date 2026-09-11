import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 中文说明：这里用 CPU 侧等价公式锁定 Shader 的区域边界。测试不参与生产
// 渲染，仅用于防止后续重构把“顶部 16% 全量、16%～20% 平滑退出、其余关闭”
// 意外改成硬切或颠倒纵向坐标。
double _topRefractionGate(double verticalPosition) {
  final normalized = verticalPosition.clamp(0.0, 1.0);
  final progress = ((normalized - 0.16) / 0.04).clamp(0.0, 1.0);
  final smoothProgress = progress * progress * (3.0 - 2.0 * progress);
  return 1.0 - smoothProgress;
}

void main() {
  test('顶部折射门控在 16%～20% 平滑退出并处理越界坐标', () {
    expect(_topRefractionGate(-1), 1.0);
    expect(_topRefractionGate(0.16), 1.0);
    expect(_topRefractionGate(0.18), closeTo(0.5, 1e-12));
    expect(_topRefractionGate(0.20), 0.0);
    expect(_topRefractionGate(2), 0.0);
  });

  test('三条 Shader 路径都声明并只关闭背景折射采样偏移', () {
    final premium = File(
      'shaders/liquid_glass_final_render.frag',
    ).readAsStringSync();
    final lightweight = File(
      'shaders/lightweight_glass.frag',
    ).readAsStringSync();
    final indicator = File(
      'shaders/interactive_indicator.frag',
    ).readAsStringSync();
    final sharedEdgeTreatment = File(
      'shaders/edge_treatment.glsl',
    ).readAsStringSync();

    // 中文注释：开关必须是独立 uniform，不能通过把 thickness、折射率或色散
    // 参数归零来模拟；这些参数还参与边缘光、Fresnel 和材质深度，复用它们会
    // 连带改变用户要求保留的玻璃观感。
    for (final source in <String>[premium, lightweight, indicator]) {
      expect(source, contains('uniform float uRefractionEnabled;'));
      expect(source, contains('uniform float uTopRefractionOnly;'));
    }

    // 中文注释：区域边界必须集中在共享函数中，三条路径只传各自的组件本地
    // 纵向坐标。16%～20% 的过渡既避免硬接缝，也保证 20% 以下门控精确为零。
    expect(
      sharedEdgeTreatment,
      contains('const float kTopRefractionFullEnd = 0.16;'),
    );
    expect(
      sharedEdgeTreatment,
      contains('const float kTopRefractionFadeEnd = 0.20;'),
    );
    expect(
      sharedEdgeTreatment,
      contains('if (refractionEnabled < 0.5) return 0.0;'),
    );
    expect(
      sharedEdgeTreatment,
      contains('if (topRefractionOnly < 0.5) return 1.0;'),
    );

    expect(premium, contains('glassVerticalPosition,'));
    expect(premium, contains('uTopRefractionOnly'));
    expect(premium, contains('uChromaticAberration * refractionAreaGate'));
    expect(lightweight, contains('edgeOffset *= refractionAreaGate;'));
    expect(
      lightweight,
      contains('uChromaticAberration * refractionAreaGate'),
    );
    expect(
      indicator,
      contains('edgeOffsetLogical *= refractionAreaGate;'),
    );
    expect(
      indicator,
      contains('uChromaticAberration * refractionAreaGate'),
    );
  });

  test('Dart host 为所有 Shader 显式写入折射开关 uniform', () {
    final renderObject = File(
      'lib/src/renderer/rendering/liquid_glass_render_object.dart',
    ).readAsStringSync();
    final lightweight = File(
      'lib/widgets/shared/lightweight_liquid_glass.dart',
    ).readAsStringSync();
    final indicator = File(
      'lib/widgets/shared/glass_effect.dart',
    ).readAsStringSync();

    // 中文注释：Premium 的普通 backdrop 与显式 capture 会复用同一个 Shader
    // 实例，两条写入路径都必须覆盖 slot 45，避免继承上一帧其他组件的状态。
    expect(
      RegExp(r'setFloatUniforms\(initialIndex: 45').allMatches(renderObject),
      hasLength(2),
    );
    // 中文注释：Premium 的区域开关紧随总开关使用 slot 46；普通 backdrop
    // 与显式 capture 都必须写入，避免共享 Shader 沿用上一组件的值。
    expect(
      RegExp(r'setFloatUniforms\(initialIndex: 46').allMatches(renderObject),
      hasLength(2),
    );
    expect(
      lightweight,
      contains('_settings.refractionEnabled ? 1.0 : 0.0'),
    );
    expect(
      indicator,
      contains('_settings.refractionEnabled ? 1.0 : 0.0'),
    );
    expect(
      lightweight,
      contains('_settings.topRefractionOnly ? 1.0 : 0.0'),
    );
    expect(
      indicator,
      contains('_settings.topRefractionOnly ? 1.0 : 0.0'),
    );
  });
}
