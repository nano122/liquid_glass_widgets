import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/src/renderer/internal/multi_shader_builder.dart';
import 'package:liquid_glass_widgets/src/renderer/internal/render_liquid_glass_geometry.dart';
import 'package:liquid_glass_widgets/src/renderer/liquid_glass.dart';
import 'package:liquid_glass_widgets/src/renderer/liquid_glass_blend_group.dart';
import 'package:liquid_glass_widgets/src/renderer/rendering/liquid_glass_render_object.dart';
import 'package:liquid_glass_widgets/src/renderer/shaders.dart';

const _settings = LiquidGlassSettings(blur: 0, thickness: 45);

void main() {
  test('最终合成 Shader 按原生 Windows 与其他平台分流', () {
    // 中文注释：Windows Web 不使用出错的原生 OpenGLESSDF 后端，因此仍加载
    // 通用版本；只有原生 Windows 必须选择不含 mode 2 的安全编译单元。
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
      endsWith('shaders/liquid_glass_final_render.frag'),
    );
    expect(
      ShaderKeys.liquidGlassRenderForPlatform(
        TargetPlatform.windows,
        isWeb: true,
      ),
      endsWith('shaders/liquid_glass_final_render.frag'),
    );
  });

  test('Windows 安全 Shader 保持 uniform 契约且不包含 mode 2', () {
    final fullSource =
        File('shaders/liquid_glass_final_render.frag').readAsStringSync();
    final windowsSource = File(
      'shaders/liquid_glass_final_render_windows.frag',
    ).readAsStringSync();
    final uniformPattern = RegExp(r'uniform\s+\w+\s+\w+\s*;');

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
