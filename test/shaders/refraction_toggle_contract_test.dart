import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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

    // 中文注释：开关必须是独立 uniform，不能通过把 thickness、折射率或色散
    // 参数归零来模拟；这些参数还参与边缘光、Fresnel 和材质深度，复用它们会
    // 连带改变用户要求保留的玻璃观感。
    for (final source in <String>[premium, lightweight, indicator]) {
      expect(source, contains('uniform float uRefractionEnabled;'));
    }

    expect(premium, contains('displacement *= uRefractionEnabled;'));
    expect(
      premium,
      contains(
        'uRefractionEnabled > 0.5 && uPinchStrength > 0.001',
      ),
    );
    expect(lightweight, contains('edgeOffset *= uRefractionEnabled;'));
    expect(indicator, contains('edgeOffsetLogical *= uRefractionEnabled;'));
    expect(
      indicator,
      contains(
        'uRefractionEnabled > 0.5 && uPinchStrength > 0.001',
      ),
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
    expect(
      lightweight,
      contains('_settings.refractionEnabled ? 1.0 : 0.0'),
    );
    expect(
      indicator,
      contains('_settings.refractionEnabled ? 1.0 : 0.0'),
    );
  });
}
