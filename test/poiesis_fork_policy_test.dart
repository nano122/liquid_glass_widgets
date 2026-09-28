import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/src/renderer/poiesis_fork_policy.dart';
import 'package:liquid_glass_widgets/widgets/shared/glass_effect.dart';

import 'shared/test_helpers.dart';

/// 中文说明：Poiesis fork 渲染器分流的回归测试。
///
/// 生产环境里 [PoiesisForkPolicy.patchesEnabled] 等价于
/// `ImageFilter.isShaderFilterSupported`：Impeller 为 true（启用 Poiesis 补丁），
/// Skia/Web 为 false（严格回到上游 1.7.2）。`flutter test` 默认被
/// flutter_test_config.dart 固定为补丁模式，这里的“上游模式”分组显式改为
/// false，并在 tearDown 恢复，避免影响同一 isolate 内的其他用例。
void main() {
  /// 收集子树中所有 DecoratedBox 的 BoxShadow，用于判断是否绘制了外投影。
  List<BoxShadow> collectBoxShadows(WidgetTester tester, Finder scope) {
    final shadows = <BoxShadow>[];
    final boxes = tester.widgetList<DecoratedBox>(
      find.descendant(of: scope, matching: find.byType(DecoratedBox)),
    );
    for (final box in boxes) {
      final decoration = box.decoration;
      if (decoration is BoxDecoration && decoration.boxShadow != null) {
        shadows.addAll(decoration.boxShadow!);
      }
    }
    return shadows;
  }

  final bool? originalOverride = PoiesisForkPolicy.debugPatchesEnabledOverride;

  tearDown(() {
    // 中文说明：恢复全局覆盖值并清空 Shader 静态缓存，保证用例之间互不污染。
    PoiesisForkPolicy.debugPatchesEnabledOverride = originalOverride;
    LightweightLiquidGlass.resetForTesting();
    GlassEffect.resetForTesting();
  });

  group('PoiesisForkPolicy 基础路由', () {
    test('覆盖值为 null 时回到真实渲染器判断（flutter test 下为 Skia 语义）', () {
      PoiesisForkPolicy.debugPatchesEnabledOverride = null;
      // flutter test 没有 Impeller，isShaderFilterSupported 恒为 false。
      expect(PoiesisForkPolicy.patchesEnabled, isFalse);
    });

    test('轻量 Shader 路径按模式切换目录', () {
      PoiesisForkPolicy.debugPatchesEnabledOverride = true;
      expect(
        PoiesisForkPolicy.lightweightShaderPath('lightweight_glass.frag'),
        'shaders/lightweight_glass.frag',
      );
      PoiesisForkPolicy.debugPatchesEnabledOverride = false;
      expect(
        PoiesisForkPolicy.lightweightShaderPath('lightweight_glass.frag'),
        'shaders/upstream/lightweight_glass.frag',
      );
      expect(
        PoiesisForkPolicy.lightweightShaderPath('interactive_indicator.frag'),
        'shaders/upstream/interactive_indicator.frag',
      );
    });
  });

  group('上游原版 Shader 逐字节一致', () {
    // 中文说明：shaders/upstream/ 必须与官方 1.7.2（4d3f4dfe）完全一致；
    // 工作区可能因 core.autocrlf 变成 CRLF，比较前统一归一化为 LF。
    const upstreamCommit = '4d3f4dfe';
    const files = <String>[
      'lightweight_glass.frag',
      'interactive_indicator.frag',
      'gles_compat.glsl',
    ];

    String normalize(String s) => s.replaceAll('\r\n', '\n');

    for (final name in files) {
      test('shaders/upstream/$name == $upstreamCommit:shaders/$name', () {
        final result = Process.runSync(
          'git',
          ['show', '$upstreamCommit:shaders/$name'],
          // 中文说明：Shader 含 UTF-8 字符（如破折号），Windows 默认代码页
          // 会解码成乱码，必须显式按 UTF-8 读取。
          stdoutEncoding: utf8,
        );
        if (result.exitCode != 0) {
          // 中文说明：浅克隆或无 git 环境拿不到官方提交时只能跳过，
          // 并把原因打印出来，避免误以为已经校验通过。
          markTestSkipped('无法读取 $upstreamCommit：${result.stderr}');
          return;
        }
        final local = File('shaders/upstream/$name').readAsStringSync();
        expect(normalize(local), normalize(result.stdout as String));
      });
    }
  });

  group('上游模式（Skia/Web）', () {
    setUp(() => PoiesisForkPolicy.debugPatchesEnabledOverride = false);

    test('默认 shadowElevation 恢复上游 1.0，外投影开启', () {
      const settings = LiquidGlassSettings();
      expect(settings.shadowElevation, 1.0);
      expect(GlassShadow.dropShadowsEnabled, isTrue);
      expect(settings.effectiveShadow, isNotEmpty);
    });

    test('显式 shadow 覆盖原样生效', () {
      const custom = [BoxShadow(color: Color(0x33000000), blurRadius: 4)];
      const settings = LiquidGlassSettings(shadow: custom);
      expect(settings.effectiveShadow, custom);
    });

    test('GlassThemeSettings.applyTo 保留上游完整构造器语义', () {
      // 中文说明：上游 1.7.2 用完整构造器重建，bodyMode 等未列出的字段
      // 会回到默认值；这是官方原版行为，Skia 下有意保留。
      const base = LiquidGlassSettings(
        thickness: 10,
        bodyMode: GlassBodyMode.clear,
      );
      final merged = const GlassThemeSettings(blur: 7).applyTo(base);
      expect(merged.blur, 7);
      expect(merged.thickness, 10);
      expect(merged.bodyMode, GlassBodyMode.adaptive);
    });

    test('preWarm 加载 shaders/upstream 下的上游 Shader', () async {
      final logs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        LightweightLiquidGlass.resetForTesting();
        await LightweightLiquidGlass.preWarm();
        GlassEffect.resetForTesting();
        await GlassEffect.preWarm();
      } finally {
        debugPrint = originalDebugPrint;
      }
      expect(
        logs,
        contains(
          '[LightweightGlass] Loaded shaders/upstream/lightweight_glass.frag',
        ),
      );
      expect(
        logs,
        contains(
          '[GlassEffect] Loaded shaders/upstream/interactive_indicator.frag',
        ),
      );
    });

    testWidgets('GlassBadge 与状态点恢复上游彩色外投影', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          child: Column(
            children: [
              GlassBadge(
                key: const Key('count'),
                count: 3,
                child: const Icon(Icons.notifications),
              ),
              GlassBadge.dot(
                key: const Key('dot'),
                child: const Icon(Icons.mail),
              ),
            ],
          ),
        ),
      );
      expect(
        collectBoxShadows(tester, find.byKey(const Key('count'))),
        isNotEmpty,
      );
      expect(
        collectBoxShadows(tester, find.byKey(const Key('dot'))),
        isNotEmpty,
      );
    });

    testWidgets('GlassToast 恢复上游彩色外投影', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          child: GlassToast(message: 'hello', onDismissed: () {}),
        ),
      );
      final shadows = collectBoxShadows(tester, find.byType(GlassToast));
      expect(
        shadows.any((s) => s.blurRadius == 20 && s.spreadRadius == 2),
        isTrue,
      );
    });

    testWidgets('GlassButton 不绘制 Poiesis 反向镂空外投影', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: Colors.transparent,
          ),
          child: AdaptiveLiquidGlassLayer(
            settings: defaultTestGlassSettings,
            child: GlassButton(
              icon: const Icon(CupertinoIcons.heart),
              onTap: () {},
            ),
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is GlassButtonOuterShadowPainter,
        ),
        findsNothing,
      );
    });

    testWidgets('底栏使用上游圆角矩形并用 RepaintBoundary 缓存底板', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          child: GlassTabBar.bottom(
            tabs: const [
              GlassTab(label: 'A', icon: Icon(CupertinoIcons.home)),
              GlassTab(label: 'B', icon: Icon(CupertinoIcons.search)),
            ],
            selectedIndex: 0,
            onTabSelected: (_) {},
          ),
        ),
      );
      final bar = find.byType(AdaptiveGlass).first;
      expect(
        tester.widget<AdaptiveGlass>(bar).shape,
        isA<LiquidRoundedRectangle>(),
      );
      expect(
        find.ancestor(of: bar, matching: find.byType(RepaintBoundary)),
        findsWidgets,
      );
    });

    testWidgets('Standard 质量的 AdaptiveLiquidGlassLayer 包裹 LiquidGlassLayer',
        (tester) async {
      await tester.pumpWidget(
        createTestApp(
          child: const AdaptiveLiquidGlassLayer(
            settings: defaultTestGlassSettings,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );
      // 中文说明：上游只有 minimal / platformViewBackdrop 才直通；
      // Poiesis 在非 Impeller 下全部直通，这里锁定上游语义。
      expect(find.byType(LiquidGlassLayer), findsOneWidget);
    });
  });

  group('补丁模式（Impeller）', () {
    setUp(() => PoiesisForkPolicy.debugPatchesEnabledOverride = true);

    test('外投影被统一关闭', () {
      const settings = LiquidGlassSettings(
        shadow: [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
      );
      expect(GlassShadow.dropShadowsEnabled, isFalse);
      expect(const LiquidGlassSettings().effectiveShadow, isEmpty);
      expect(settings.effectiveShadow, isEmpty);
    });

    test('GlassThemeSettings.applyTo 基于 copyWith 保留 bodyMode', () {
      const base = LiquidGlassSettings(bodyMode: GlassBodyMode.clear);
      final merged = const GlassThemeSettings(blur: 7).applyTo(base);
      expect(merged.blur, 7);
      expect(merged.bodyMode, GlassBodyMode.clear);
    });

    testWidgets('GlassBadge 不绘制外投影', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          child: GlassBadge(
            key: const Key('count'),
            count: 3,
            child: const Icon(Icons.notifications),
          ),
        ),
      );
      expect(
        collectBoxShadows(tester, find.byKey(const Key('count'))),
        isEmpty,
      );
    });

    testWidgets('底栏使用 Poiesis 超椭圆', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          child: GlassTabBar.bottom(
            tabs: const [
              GlassTab(label: 'A', icon: Icon(CupertinoIcons.home)),
              GlassTab(label: 'B', icon: Icon(CupertinoIcons.search)),
            ],
            selectedIndex: 0,
            onTabSelected: (_) {},
          ),
        ),
      );
      final bar = find.byType(AdaptiveGlass).first;
      expect(
        tester.widget<AdaptiveGlass>(bar).shape,
        isA<LiquidRoundedSuperellipse>(),
      );
    });
  });
}
