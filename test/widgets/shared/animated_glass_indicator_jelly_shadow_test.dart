// AnimatedGlassIndicator：移动玻璃 jelly 的外投影回归测试。
//
// Poiesis 的视觉规范明确禁止玻璃组件产生外投影。即使上游允许调用方显式
// 传入 shadowElevation 或 shadow，这里也必须在所有亮度与动画状态下拦截，
// 避免升级上游版本时重新引入与应用设计不一致的悬浮阴影。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../shared/test_helpers.dart';

/// The outer-shadow layer is a CustomPaint with the (private)
/// _OuterShadowPainter — identified by runtime type name.
Finder _outerShadowPaint() => find.byWidgetPredicate((w) =>
    w is CustomPaint &&
    w.painter.runtimeType.toString() == '_OuterShadowPainter');

Widget _wrap(Widget indicator, {required Brightness brightness}) =>
    createTestApp(
      theme: ThemeData(brightness: brightness),
      child: SizedBox(
        width: 400,
        height: 80,
        child: Stack(children: [indicator]),
      ),
    );

AnimatedGlassIndicator _make({
  LiquidGlassSettings? settings,
  double thickness = 0.5, // > 0.01 → glass pass mounts (mid-morph)
}) =>
    AnimatedGlassIndicator(
      velocity: 0.0,
      itemCount: 3,
      alignment: Alignment.center,
      thickness: thickness,
      quality: GlassQuality.standard,
      indicatorColor: Colors.blue,
      isBackgroundIndicator: false,
      borderRadius: 20.0,
      settings: settings,
      pinchStrength: 0.4,
      expansion: const EdgeInsets.all(8.0),
      paintBackground: true,
      paintGlass: true,
      innerBlur: 0.0,
    );

void main() {
  group('AnimatedGlassIndicator — jelly outer shadow', () {
    testWidgets('Poiesis 在亮色模式拦截显式 shadowElevation', (tester) async {
      await tester.pumpWidget(_wrap(
        _make(settings: const LiquidGlassSettings(shadowElevation: 3.0)),
        brightness: Brightness.light,
      ));
      await tester.pump();
      expect(_outerShadowPaint(), findsNothing);
    });

    testWidgets('Poiesis 在亮色模式拦截显式 shadow 列表', (tester) async {
      await tester.pumpWidget(_wrap(
        _make(
          settings: const LiquidGlassSettings(shadow: [
            BoxShadow(
                color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
          ]),
        ),
        brightness: Brightness.light,
      ));
      await tester.pump();
      expect(_outerShadowPaint(), findsNothing);
    });

    testWidgets('default settings paint NO shadow (back-compat)',
        (tester) async {
      await tester.pumpWidget(_wrap(
        _make(settings: const LiquidGlassSettings()),
        brightness: Brightness.light,
      ));
      await tester.pump();
      expect(_outerShadowPaint(), findsNothing);
    });

    testWidgets('null settings paint NO shadow (back-compat)', (tester) async {
      await tester.pumpWidget(_wrap(
        _make(),
        brightness: Brightness.light,
      ));
      await tester.pump();
      expect(_outerShadowPaint(), findsNothing);
    });

    testWidgets('dark mode paints NO shadow even with explicit elevation',
        (tester) async {
      await tester.pumpWidget(_wrap(
        _make(settings: const LiquidGlassSettings(shadowElevation: 3.0)),
        brightness: Brightness.dark,
      ));
      await tester.pump();
      expect(_outerShadowPaint(), findsNothing);
    });

    testWidgets('no shadow at rest (glass pass unmounted)', (tester) async {
      await tester.pumpWidget(_wrap(
        _make(
          settings: const LiquidGlassSettings(shadowElevation: 3.0),
          thickness: 0.0, // resting — interactive indicator not built
        ),
        brightness: Brightness.light,
      ));
      await tester.pump();
      expect(_outerShadowPaint(), findsNothing);
    });
  });
}
