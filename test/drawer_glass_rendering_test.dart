import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/src/engine/multi_shader_builder.dart';
import 'package:liquid_glass_widgets/src/engine/render_liquid_glass_geometry.dart';
import 'package:liquid_glass_widgets/src/engine/liquid_glass.dart';
import 'package:liquid_glass_widgets/src/engine/liquid_glass_blend_group.dart';
import 'package:liquid_glass_widgets/src/engine/rendering/liquid_glass_render_object.dart';
import 'package:liquid_glass_widgets/src/engine/shaders.dart';

const _settings = LiquidGlassSettings(blur: 0, thickness: 45);

void main() {
  test('Premium 两个 Pass 均按原生 Windows 与其他平台分流', () {
    // 中文注释：Windows Web 不使用出错的原生 OpenGLESSDF 后端，因此仍加载
    // 通用版本；原生 Windows 的 geometry 与最终合成都必须在加载前选择较小
    // 的编译单元，避免仅隔离最终 Shader 后仍被 968KB geometry 阻塞首帧。
    expect(
      ShaderKeys.blendedGeometryForPlatform(
        TargetPlatform.windows,
        isWeb: false,
      ),
      endsWith('shaders/liquid_glass_geometry_blended_windows.frag'),
    );
    expect(
      ShaderKeys.blendedGeometryForPlatform(
        TargetPlatform.android,
        isWeb: false,
      ),
      endsWith('shaders/liquid_glass_geometry_blended.frag'),
    );
    expect(
      ShaderKeys.blendedGeometryForPlatform(
        TargetPlatform.windows,
        isWeb: true,
      ),
      endsWith('shaders/liquid_glass_geometry_blended.frag'),
    );
    expect(
      ShaderKeys.liquidGlassRenderForPlatform(
        TargetPlatform.windows,
        isWeb: false,
      ),
      endsWith('shaders/liquid_glass_final_render_windows.frag'),
    );
    expect(
      ShaderKeys.liquidGlassRenderForPlatform(
        TargetPlatform.android,
        isWeb: false,
      ),
      endsWith('shaders/liquid_glass_render.frag'),
    );
    expect(
      ShaderKeys.liquidGlassRenderForPlatform(
        TargetPlatform.windows,
        isWeb: true,
      ),
      endsWith('shaders/liquid_glass_render.frag'),
    );
  });

  test('Windows 有界 Shader 保持 host 契约与 Premium 核心效果', () {
    final fullSource =
        File('shaders/liquid_glass_render.frag').readAsStringSync();
    final windowsSource = File(
      'shaders/liquid_glass_final_render_windows.frag',
    ).readAsStringSync();
    final fullGeometrySource = File(
      'shaders/liquid_glass_geometry_blended.frag',
    ).readAsStringSync();
    final windowsGeometrySource = File(
      'shaders/liquid_glass_geometry_blended_windows.frag',
    ).readAsStringSync();
    // 中文注释：必须从行首匹配真实声明，不能把历史保留的
    // `// uniform float uRefractScale` 注释误算进 host 契约。
    final uniformPattern = RegExp(
      r'^[ \t]*uniform\s+\w+\s+\w+[ \t]*;',
      multiLine: true,
    );
    final geometryUniformPattern = RegExp(
      r'^[ \t]*(?:layout\([^\n]+\)[ \t]*)?uniform\s+[^;]+;',
      multiLine: true,
    );

    // 中文注释：两个 Shader 由同一个 Dart 宿主写入固定 slot；声明的数量、
    // 类型和顺序必须完全一致，否则只修复编译问题也会引入 uniform 错位。
    expect(
      uniformPattern
          .allMatches(windowsSource)
          .map((match) => match.group(0))
          .toList(),
      orderedEquals(
        uniformPattern
            .allMatches(fullSource)
            .map((match) => match.group(0))
            .toList(),
      ),
    );
    expect(fullSource, contains('sdfSquircleAsym'));
    expect(windowsSource, isNot(contains('sdfSquircleAsym')));
    expect(windowsSource, isNot(contains('superellipse_sdf.glsl')));

    // 中文注释：geometry host 同样按固定槽位写 size、optical、shape settings
    // 与 112 个 shape float。Windows 文件可以更换计算策略，但声明顺序不能
    // 改，否则性能修复会在首次 setFloat 时变成 uniform 越界或错位。
    expect(
      geometryUniformPattern
          .allMatches(windowsGeometrySource)
          .map((match) => match.group(0)!.replaceAll(RegExp(r'\s+'), ' '))
          .toList(),
      orderedEquals(
        geometryUniformPattern
            .allMatches(fullGeometrySource)
            .map((match) => match.group(0)!.replaceAll(RegExp(r'\s+'), ' '))
            .toList(),
      ),
    );

    // 中文注释：这些断言描述 Windows 驱动的编译预算，而不是具体颜色常量。
    // geometry 只能执行一次前向场融合，最终合成最多保留三通道硬件采样；
    // 同时仍需保留折射、色散、颜色与显式快照语义，防止修成 minimal 外观。
    expect(windowsGeometrySource, isNot(contains('sdf.glsl')));
    expect(windowsGeometrySource, isNot(contains('superellipse_sdf.glsl')));
    expect(windowsGeometrySource,
        isNot(matches(RegExp(r'\b(?:pow|exp2|log2)\s*\('))));
    expect(
      RegExp(r'sceneField\(').allMatches(windowsGeometrySource).length,
      2,
      reason: '应只有函数声明和 main 中的一次场计算',
    );
    // 中文注释：2026-09-26 起 Windows 合成 Shader 重新包含共享边缘算法，
    // 否则最外轮廓缺少浅灰环与左右深边，被 Fresnel 提亮成白边。编译预算
    // 仍通过“背景不使用手工双线性”和“8 点采样只在轮廓窄带执行”控制；
    // edge_treatment.glsl 中未调用的面积高光函数会被 impellerc 剔除。
    expect(windowsSource, contains('#include "edge_treatment.glsl"'));
    expect(windowsSource, contains('applyDualLayerRim('));
    expect(windowsSource, contains('getInnerHighlightGate('));
    expect(
      RegExp(r'sampleAnalyticEdgeAtOffset\(kEdgeRgss\d')
          .allMatches(windowsSource)
          .length,
      8,
      reason: '解析路径应与通用 Shader 一样执行 8 点 RGSS',
    );
    expect(
      RegExp(r'sampleTextureEdgeAtOffset\(kEdgeRgss\d')
          .allMatches(windowsSource)
          .length,
      8,
      reason: '纹理路径应与通用 Shader 一样执行 8 点 RGSS',
    );
    expect(
      windowsSource,
      contains('centerRimDistance > conservativeEdgeReach'),
      reason: '内部片元必须跳过 8 点采样，避免整面玻璃付出边缘成本',
    );
    expect(windowsSource, isNot(contains('textureBilinear')));
    expect(windowsSource, contains('refract('));
    expect(windowsSource, contains('redSample'));
    expect(windowsSource, contains('applyGlassTint'));
    expect(windowsSource, contains('uCaptureConfig'));
  });

  testWidgets('非 Windows 抽屉持续增高和底角归零时不分配整面几何纹理', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // 中文注释：直接驱动生产几何收集和 paint，绕过宿主是否支持 Impeller 的
    // Widget 分流；显式模拟非 Windows，确认原有 mode 2 优化没有被全局关闭。
    await tester.runAsync(
        () => MultiShaderBuilder.precacheShader(ShaderKeys.blendedGeometry));
    final program =
        await ui.FragmentProgram.fromAsset(ShaderKeys.liquidGlassRender);
    final shader = program.fragmentShader();
    final geometryProgram =
        await ui.FragmentProgram.fromAsset(ShaderKeys.blendedGeometry);
    final geometryShader = geometryProgram.fragmentShader();
    final link = GeometryRenderLink();
    final groupLink = GlassGroupLink();
    for (final height in [280.0, 380.0, 480.0, 560.0, 300.0]) {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: Center(
              child: _Host(
            shader: shader,
            link: link,
            child: _Group(
              shader: geometryShader,
              link: link,
              groupLink: groupLink,
              child: _Shape(
                groupLink: groupLink,
                shape: LiquidVerticalRoundedSuperellipse(
                  topRadius: 45,
                  bottomRadius: height >= 480 ? 0 : 45,
                ),
                child: SizedBox(width: 320, height: height),
              ),
            ),
          )),
        ),
      ));
      await tester.pump();
      final renderer = tester.renderObject<_ProbeRenderer>(find.byType(_Host));
      expect(renderer.hasFullGeometryTexture, isFalse,
          reason: '高度 $height 的单形状抽屉应直接计算原超椭圆，不生成整面纹理');
      expect(renderer.debugUsesAnalyticRoundedRectangle, isTrue);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    // 中文注释：Flutter 3.47.1 会在 addTearDown 之前检查 foundation 全局变量，
    // 因此必须在 widget 测试体返回前恢复平台 override。
    debugDefaultTargetPlatformOverride = null;
    shader.dispose();
    geometryShader.dispose();
    link.dispose();
  });

  testWidgets('Windows 超椭圆回退几何纹理且安全 Shader 可以编译', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    // 中文注释：加载生产选择器返回的资产，确保 pubspec 打包、Shader 编译和
    // RenderObject 回退同时成立；这比只匹配文件名更接近首屏失败的真实路径。
    final program =
        await ui.FragmentProgram.fromAsset(ShaderKeys.liquidGlassRender);
    final shader = program.fragmentShader();
    final geometryProgram =
        await ui.FragmentProgram.fromAsset(ShaderKeys.blendedGeometry);
    final geometryShader = geometryProgram.fragmentShader();
    final link = GeometryRenderLink();
    final groupLink = GlassGroupLink();

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 1),
        child: Center(
          child: _Host(
            shader: shader,
            link: link,
            child: _Group(
              shader: geometryShader,
              link: link,
              groupLink: groupLink,
              child: _Shape(
                groupLink: groupLink,
                shape: const LiquidVerticalRoundedSuperellipse(
                  topRadius: 45,
                  bottomRadius: 0,
                ),
                child: const SizedBox(width: 320, height: 560),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    final renderer = tester.renderObject<_ProbeRenderer>(find.byType(_Host));
    expect(renderer.debugUsesAnalyticRoundedRectangle, isFalse);
    expect(renderer.hasFullGeometryTexture, isTrue,
        reason: 'Windows 安全 Shader 不包含 mode 2，超椭圆必须使用既有纹理几何');

    await tester.pumpWidget(const SizedBox.shrink());
    // 中文注释：同上，提前清空测试平台，避免状态泄漏到 Flutter binding。
    debugDefaultTargetPlatformOverride = null;
    shader.dispose();
    geometryShader.dispose();
    link.dispose();
  });
}

// 中文注释：测试只绕过平台 Widget 分流，形状注册、几何收集和纹理生成均用生产类。
class _Group extends SingleChildRenderObjectWidget {
  const _Group(
      {required this.shader,
      required this.link,
      required this.groupLink,
      required super.child});
  final ui.FragmentShader shader;
  final GeometryRenderLink link;
  final GlassGroupLink groupLink;
  @override
  RenderLiquidGlassBlendGroup createRenderObject(BuildContext context) =>
      RenderLiquidGlassBlendGroup(
          renderLink: link,
          geometryShader: shader,
          settings: _settings,
          devicePixelRatio: 1,
          link: groupLink,
          blend: 0);
}

class _Shape extends SingleChildRenderObjectWidget {
  const _Shape(
      {required this.shape, required this.groupLink, required super.child});
  final LiquidShape shape;
  final GlassGroupLink groupLink;
  @override
  RenderLiquidGlass createRenderObject(BuildContext context) =>
      RenderLiquidGlass(
          shape: shape, glassContainsChild: false, blendGroupLink: groupLink);
  @override
  void updateRenderObject(
      BuildContext context, RenderLiquidGlass renderObject) {
    renderObject.shape = shape;
  }
}

/// 中文注释：用真实 RenderObject 观察几何资源；不创建不受测试 Skia 支持的
/// ImageFilter.shader，因此同一回归能在 Windows 的普通 flutter test 中执行。
class _Host extends SingleChildRenderObjectWidget {
  const _Host({required this.shader, required this.link, required super.child});
  final ui.FragmentShader shader;
  final GeometryRenderLink link;

  @override
  _ProbeRenderer createRenderObject(BuildContext context) =>
      _ProbeRenderer(shader, link);
}

class _ProbeRenderer extends LiquidGlassRenderObject {
  _ProbeRenderer(ui.FragmentShader shader, GeometryRenderLink link)
      : super(
            renderShader: shader,
            link: link,
            settings: _settings,
            devicePixelRatio: 1,
            preferAnalyticRoundedRectangle: true);

  bool get hasFullGeometryTexture => geometryImage != null;
  @override
  Size get desiredMatteSize => size;
  @override
  Matrix4 get matteTransform => getTransformTo(null);
  @override
  void paintLiquidGlass(
      PaintingContext context,
      Offset offset,
      List<(RenderLiquidGlassGeometry, GeometryCache, Matrix4)> shapes,
      Rect boundingBox) {}
}
