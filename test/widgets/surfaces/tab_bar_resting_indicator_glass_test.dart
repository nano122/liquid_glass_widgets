// 中文说明：底部导航选中胶囊“静止玻璃”的平台回归测试。
//
// 背景：合并 iOS HDR 分支后，底部导航选中胶囊静止时常驻 0.18 的玻璃 Pass，
// 安卓真机 A/B（2026-09-28）显示仅这一项造成概要页约 17 帧、AI 页约 10 帧
// 的下降，而安卓不支持 EDR 高光。修复后只在原生 iOS 保留静止玻璃，其余
// 平台静止时回到实色填充。本测试锁定这一平台矩阵，防止再次全平台常驻。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/src/widgets/surfaces/tab_bar_bottom_internal.dart';

/// 构造一个最小的底部导航，便于读取实际传给指示器的静止可见度。
Widget _bottomBar(MaskingQuality maskingQuality) => MaterialApp(
      home: Scaffold(
        body: LiquidGlassWidgets.wrap(
          child: SizedBox(
            height: 140,
            child: GlassTabBar.bottom(
              tabs: const [
                GlassTab(label: 'Home', icon: Icon(Icons.home)),
                GlassTab(label: 'AI', icon: Icon(Icons.bolt)),
                GlassTab(label: 'Me', icon: Icon(Icons.person)),
              ],
              selectedIndex: 0,
              onTabSelected: (_) {},
              maskingQuality: maskingQuality,
            ),
          ),
        ),
      ),
    );

/// 收集底部导航中所有“绘制玻璃”的指示器的静止可见度。
List<double> _glassIndicatorRestingVisibility(WidgetTester tester) => tester
    .widgetList<AnimatedGlassIndicator>(find.byType(AnimatedGlassIndicator))
    .where((indicator) => indicator.paintGlass)
    .map((indicator) => indicator.restingGlassVisibility)
    .toList();

void main() {
  group('restingIndicatorGlassVisibilityFor', () {
    test('仅原生 iOS 保留静止玻璃', () {
      expect(
        restingIndicatorGlassVisibilityFor(
          platform: TargetPlatform.iOS,
          isWeb: false,
        ),
        kIosRestingIndicatorGlassVisibility,
      );
    });

    test('安卓及其他平台静止时不绘制玻璃', () {
      for (final platform in TargetPlatform.values) {
        if (platform == TargetPlatform.iOS) continue;
        expect(
          restingIndicatorGlassVisibilityFor(platform: platform, isWeb: false),
          0.0,
          reason: '$platform 不支持 EDR，静止玻璃只会徒增一层玻璃 Pass',
        );
      }
    });

    test('Web（包括 iOS Safari）静止时不绘制玻璃', () {
      expect(
        restingIndicatorGlassVisibilityFor(
          platform: TargetPlatform.iOS,
          isWeb: true,
        ),
        0.0,
      );
    });
  });

  group('GlassTabBar.bottom 选中胶囊静止玻璃', () {
    for (final quality in const [MaskingQuality.high, MaskingQuality.off]) {
      testWidgets('iOS 下传入 0.18（$quality）', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await tester.pumpWidget(_bottomBar(quality));
          final values = _glassIndicatorRestingVisibility(tester);
          expect(values, isNotEmpty);
          expect(values, everyElement(kIosRestingIndicatorGlassVisibility));
        } finally {
          // 必须在测试体内复位，否则框架的 invariant 检查会报错。
          debugDefaultTargetPlatformOverride = null;
        }
      });

      testWidgets('安卓下传入 0（$quality）', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await tester.pumpWidget(_bottomBar(quality));
          final values = _glassIndicatorRestingVisibility(tester);
          expect(values, isNotEmpty);
          expect(values, everyElement(0.0));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });
}
