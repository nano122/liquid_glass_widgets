// Tests for light-mode shadow guards across glass surfaces.
//
// Verifies that shadows:
//   • Only render in light mode (skipped in dark mode)
//   • Only render when shadowElevation > 0 (skipped when 0)
//   • Use inverse clipping (DecoratedBox present, IgnorePointer wrapping)
//
// Covers:
//   • SearchPill — collapsed and expanded states
//   • TabIndicator (GlassTabBar.bottom) — via the internal _wrapWithBarShadow
//   • GlassMenu trigger — Stack clipBehavior: Clip.none
//   • AdaptiveGlass._wrapWithLightModeShadow — own-layer path
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/src/widgets/surfaces/tab_bar_searchable_internal.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Light-mode test app wrapper (Brightness.light).
Widget _lightApp(Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.light),
      home: CupertinoTheme(
        data: const CupertinoThemeData(brightness: Brightness.light),
        child: Scaffold(
          backgroundColor: Colors.white,
          body: child,
        ),
      ),
    );

/// Dark-mode test app wrapper (Brightness.dark).
Widget _darkApp(Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: CupertinoTheme(
        data: const CupertinoThemeData(brightness: Brightness.dark),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: child,
        ),
      ),
    );

/// Minimal [GlassSearchBarConfig] for SearchPill tests.
GlassSearchBarConfig _searchConfig() => GlassSearchBarConfig(
      onSearchToggle: (_) {},
      hintText: 'Search',
      autoFocusOnExpand: false,
    );

/// Settings with shadow elevation explicitly set.
const _settingsWithShadow = LiquidGlassSettings(
  thickness: 30,
  blur: 3,
  shadowElevation: 1.0,
);

/// Settings with shadow elevation explicitly disabled.
const _settingsNoShadow = LiquidGlassSettings(
  thickness: 30,
  blur: 3,
  shadowElevation: 0.0,
);

/// Finds a [DecoratedBox] whose decoration contains [BoxShadow] entries.
/// This identifies the shadow layer painted by _wrapWithBarShadow /
/// _wrapWithLightModeShadow.
Finder findShadowDecoratedBox() => find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox) return false;
      final decoration = widget.decoration;
      if (decoration is! BoxDecoration) return false;
      return decoration.boxShadow != null && decoration.boxShadow!.isNotEmpty;
    });

// ===========================================================================
// SearchPill shadow guard tests
// ===========================================================================

void main() {
  group('SearchPill — light-mode shadow guard', () {
    testWidgets('Poiesis 的 collapsed pill 在亮色模式也不绘制外投影', (tester) async {
      await tester.pumpWidget(
        _lightApp(
          Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: InheritedLiquidGlass(
                settings: _settingsWithShadow,
                quality: GlassQuality.minimal,
                child: SearchPill(
                  config: _searchConfig(),
                  isActive: false,
                  barBorderRadius: 20,
                  quality: GlassQuality.minimal,
                  enableBackgroundAnimation: false,
                  backgroundPressScale: 1.0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(findShadowDecoratedBox(), findsNothing);
    });

    testWidgets('collapsed pill skips shadow in dark mode', (tester) async {
      await tester.pumpWidget(
        _darkApp(
          Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: InheritedLiquidGlass(
                settings: _settingsWithShadow,
                quality: GlassQuality.minimal,
                child: SearchPill(
                  config: _searchConfig(),
                  isActive: false,
                  barBorderRadius: 20,
                  quality: GlassQuality.minimal,
                  enableBackgroundAnimation: false,
                  backgroundPressScale: 1.0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // No shadow DecoratedBox in dark mode.
      debugDumpApp();
      expect(findShadowDecoratedBox(), findsNothing);
    });

    testWidgets('collapsed pill skips shadow when shadowElevation is 0',
        (tester) async {
      await tester.pumpWidget(
        _lightApp(
          Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: InheritedLiquidGlass(
                settings: _settingsNoShadow,
                quality: GlassQuality.minimal,
                child: SearchPill(
                  config: _searchConfig(),
                  isActive: false,
                  barBorderRadius: 20,
                  quality: GlassQuality.minimal,
                  enableBackgroundAnimation: false,
                  backgroundPressScale: 1.0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // No shadow when elevation is 0.
      debugDumpApp();
      expect(findShadowDecoratedBox(), findsNothing);
    });

    testWidgets('Poiesis 的 expanded pill 在亮色模式也不绘制外投影', (tester) async {
      await tester.pumpWidget(
        _lightApp(
          Center(
            child: SizedBox(
              width: 300,
              height: 64,
              child: InheritedLiquidGlass(
                settings: _settingsWithShadow,
                quality: GlassQuality.minimal,
                child: SearchPill(
                  config: _searchConfig(),
                  isActive: true,
                  barBorderRadius: 20,
                  quality: GlassQuality.minimal,
                  enableBackgroundAnimation: false,
                  backgroundPressScale: 1.0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(findShadowDecoratedBox(), findsNothing);
    });

    testWidgets('expanded pill skips shadow in dark mode', (tester) async {
      await tester.pumpWidget(
        _darkApp(
          Center(
            child: SizedBox(
              width: 300,
              height: 64,
              child: InheritedLiquidGlass(
                settings: _settingsWithShadow,
                quality: GlassQuality.minimal,
                child: SearchPill(
                  config: _searchConfig(),
                  isActive: true,
                  barBorderRadius: 20,
                  quality: GlassQuality.minimal,
                  enableBackgroundAnimation: false,
                  backgroundPressScale: 1.0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      debugDumpApp();
      expect(findShadowDecoratedBox(), findsNothing);
    });

    testWidgets('Poiesis 不为交互胶囊创建空的 shadow layer', (tester) async {
      await tester.pumpWidget(
        _lightApp(
          Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: InheritedLiquidGlass(
                settings: _settingsWithShadow,
                quality: GlassQuality.minimal,
                child: SearchPill(
                  config: _searchConfig(),
                  isActive: false,
                  barBorderRadius: 20,
                  quality: GlassQuality.minimal,
                  enableBackgroundAnimation: false,
                  backgroundPressScale: 1.0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 中文说明：策略关闭后应连空的阴影包装节点也省掉，而不是只把 alpha
      // 设为零；这样不会留下多余合成层或命中测试包装。
      expect(findShadowDecoratedBox(), findsNothing);
    });
  });

  // ===========================================================================
  // GlassMenu trigger Stack clip test
  // ===========================================================================

  group('GlassMenu — trigger Stack clipBehavior', () {
    testWidgets('trigger Stack uses Clip.none for shadow overflow',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GlassMenu(
                trigger: const SizedBox(
                  width: 56,
                  height: 56,
                  child: Text('Menu'),
                ),
                items: [
                  GlassMenuItem(title: 'Item', onTap: () {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The GlassMenu wraps trigger + OverlayPortal in a Stack.
      // Find Stack widgets that are descendants of GlassMenu.
      final menuStacks = find.descendant(
        of: find.byType(GlassMenu),
        matching: find.byType(Stack),
      );

      // At least one Stack should exist with Clip.none.
      bool foundClipNone = false;
      for (final element in menuStacks.evaluate()) {
        final stack = element.widget as Stack;
        if (stack.clipBehavior == Clip.none) {
          foundClipNone = true;
          break;
        }
      }
      expect(foundClipNone, isTrue,
          reason:
              'GlassMenu trigger Stack must use Clip.none so button shadows '
              'are not clipped at the Stack boundary');
    });
  });

  // ===========================================================================
  // GlassMenu — morph shadow only in light mode with elevation
  // ===========================================================================

  group('GlassMenu — morph overlay shadow guard', () {
    testWidgets('menu opens without crash in dark mode (no shadow)',
        (tester) async {
      await tester.pumpWidget(
        _darkApp(
          Center(
            child: GlassMenu(
              trigger: const SizedBox(
                width: 56,
                height: 56,
                child: Text('DarkMenu'),
              ),
              items: [
                GlassMenuItem(title: 'DarkItem', onTap: () {}),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('DarkMenu'));
      await tester.pump();
      await tester.pumpAndSettle();

      // Menu opens successfully — no shadow crash in dark mode.
      expect(find.text('DarkItem'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('menu opens without crash in light mode with elevation',
        (tester) async {
      await tester.pumpWidget(
        _lightApp(
          Center(
            child: GlassMenu(
              settings: _settingsWithShadow,
              trigger: const SizedBox(
                width: 56,
                height: 56,
                child: Text('LightMenu'),
              ),
              items: [
                GlassMenuItem(title: 'LightItem', onTap: () {}),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('LightMenu'));
      await tester.pump();
      await tester.pumpAndSettle();

      // Menu opens successfully — shadow renders without crash.
      expect(find.text('LightItem'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('menu opens without crash in light mode with shadowElevation=0',
        (tester) async {
      await tester.pumpWidget(
        _lightApp(
          Center(
            child: GlassMenu(
              settings: _settingsNoShadow,
              trigger: const SizedBox(
                width: 56,
                height: 56,
                child: Text('NoShadowMenu'),
              ),
              items: [
                GlassMenuItem(title: 'NoShadowItem', onTap: () {}),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('NoShadowMenu'));
      await tester.pump();
      await tester.pumpAndSettle();

      // Menu opens successfully — no shadow when elevation is 0.
      expect(find.text('NoShadowItem'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ===========================================================================
  // AdaptiveGlass — light-mode shadow integration
  // ===========================================================================

  group('AdaptiveGlass — light-mode shadow guard', () {
    testWidgets('Poiesis 的 own-layer 在亮色模式也不绘制外投影', (tester) async {
      await tester.pumpWidget(
        _lightApp(
          Center(
            child: SizedBox(
              width: 200,
              height: 100,
              child: AdaptiveGlass(
                shape: const LiquidRoundedSuperellipse(borderRadius: 20),
                settings: _settingsWithShadow,
                quality: GlassQuality.minimal,
                useOwnLayer: true,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(findShadowDecoratedBox(), findsNothing);
    });

    testWidgets('own-layer skips shadow in dark mode', (tester) async {
      await tester.pumpWidget(
        _darkApp(
          Center(
            child: SizedBox(
              width: 200,
              height: 100,
              child: AdaptiveGlass(
                shape: const LiquidRoundedSuperellipse(borderRadius: 20),
                settings: _settingsWithShadow,
                quality: GlassQuality.minimal,
                useOwnLayer: true,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      debugDumpApp();
      expect(findShadowDecoratedBox(), findsNothing);
    });

    testWidgets('own-layer skips shadow when shadowElevation=0',
        (tester) async {
      await tester.pumpWidget(
        _lightApp(
          Center(
            child: SizedBox(
              width: 200,
              height: 100,
              child: AdaptiveGlass(
                shape: const LiquidRoundedSuperellipse(borderRadius: 20),
                settings: _settingsNoShadow,
                quality: GlassQuality.minimal,
                useOwnLayer: true,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      debugDumpApp();
      expect(findShadowDecoratedBox(), findsNothing);
    });

    testWidgets('Poiesis 在 minimal grouped 回退路径也关闭玻璃外投影', (tester) async {
      // 中文说明：Poiesis 的无外投影策略覆盖所有质量档位和显式 shadow，
      // minimal 回退不能重新引入 DecoratedBox 阴影层。
      await tester.pumpWidget(
        _lightApp(
          Center(
            child: SizedBox(
              width: 200,
              height: 100,
              child: AdaptiveLiquidGlassLayer(
                settings: _settingsWithShadow,
                child: AdaptiveGlass.grouped(
                  shape: const LiquidRoundedSuperellipse(borderRadius: 20),
                  quality: GlassQuality.minimal,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(findShadowDecoratedBox(), findsNothing);
    });

    // NOTE: Premium grouped path (LiquidGlass.grouped) skips
    // _wrapWithLightModeShadow to avoid breaking metaball blending,
    // but this can only be verified on Impeller-enabled devices.
    // In flutter test (no Impeller), premium falls back to standard
    // which does include the shadow wrapper.
  });

  // ===========================================================================
  // GlassShadow.scaled — unit tests
  // ===========================================================================

  group('GlassShadow.scaled', () {
    test('elevation 0 returns empty list', () {
      expect(GlassShadow.scaled(0.0), isEmpty);
    });

    test('negative elevation returns empty list', () {
      expect(GlassShadow.scaled(-1.0), isEmpty);
    });

    test('Poiesis 在 elevation 1.0 时仍返回空列表', () {
      expect(GlassShadow.scaled(1.0), isEmpty);
    });

    test('Poiesis 在更高 elevation 时也不创建外投影', () {
      expect(GlassShadow.scaled(2.0), isEmpty);
    });

    test('Poiesis 会拦截显式传入的 shadow', () {
      const settings = LiquidGlassSettings(
        shadow: [BoxShadow(color: Color(0xFF000000), blurRadius: 10)],
      );
      expect(settings.effectiveShadow, isEmpty);
    });

    test('Poiesis 不会从 shadowElevation 回退创建外投影', () {
      const settings = LiquidGlassSettings(shadowElevation: 1.0);
      expect(settings.effectiveShadow, isEmpty);
    });

    test('effectiveShadow returns empty when elevation is 0 and shadow is null',
        () {
      const settings = LiquidGlassSettings(shadowElevation: 0.0);
      expect(settings.effectiveShadow, isEmpty);
    });
  });
}
