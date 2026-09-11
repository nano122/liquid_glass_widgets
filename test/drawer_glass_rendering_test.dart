import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
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
  testWidgets('抽屉持续增高和底角归零时不再分配整面几何纹理', (tester) async {
    // 中文注释：直接驱动生产几何收集和 paint，绕过宿主是否支持 Impeller 的
    // 平台分流；只省略最终 backdrop 合成，不能用布尔策略断言代替真实资源检查。
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
