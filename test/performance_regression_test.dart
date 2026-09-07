import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/src/renderer/internal/multi_shader_builder.dart';
import 'package:liquid_glass_widgets/src/renderer/internal/render_liquid_glass_geometry.dart';
import 'package:liquid_glass_widgets/src/renderer/rendering/liquid_glass_render_object.dart';
import 'package:liquid_glass_widgets/src/renderer/shaders.dart';

void main() {
  test('Standard/Premium 仅在 Impeller 使用原生共享根层', () {
    // 中文注释：Standard 在 Impeller 下必须和 Premium 共用原生根层，才能
    // 让子玻璃从一致的 compositor backdrop 采样；Skia/Web、minimal 和
    // PlatformView 则必须继续走无原生根层的安全回退。
    expect(
      AdaptiveLiquidGlassLayer.shouldUseNativeRenderer(
        isImpeller: true,
        platformViewBackdrop: false,
        quality: GlassQuality.standard,
      ),
      isTrue,
    );
    expect(
      AdaptiveLiquidGlassLayer.shouldUseNativeRenderer(
        isImpeller: true,
        platformViewBackdrop: false,
        quality: GlassQuality.premium,
      ),
      isTrue,
    );
    expect(
      AdaptiveLiquidGlassLayer.shouldUseNativeRenderer(
        isImpeller: false,
        platformViewBackdrop: false,
        quality: GlassQuality.standard,
      ),
      isFalse,
    );
    expect(
      AdaptiveLiquidGlassLayer.shouldUseNativeRenderer(
        isImpeller: true,
        platformViewBackdrop: false,
        quality: GlassQuality.minimal,
      ),
      isFalse,
    );
    expect(
      AdaptiveLiquidGlassLayer.shouldUseNativeRenderer(
        isImpeller: true,
        platformViewBackdrop: true,
        quality: GlassQuality.standard,
      ),
      isFalse,
    );
  });

  testWidgets('Skia/Web Standard 根层不创建原生层', (tester) async {
    // 中文注释：Flutter widget test 使用 Skia；此处锁定非 Impeller 回退，
    // 防止后续为了修复 Impeller 误把原生层扩展到不支持 ShaderFilter 的平台。
    await tester.pumpWidget(
      const CupertinoApp(
        home: AdaptiveLiquidGlassLayer(
          quality: GlassQuality.standard,
          child: SizedBox(width: 120, height: 48),
        ),
      ),
    );

    expect(find.byType(LiquidGlassLayer), findsNothing);
  });

  testWidgets('相同 Shader key 的新 List 不应重建 FragmentShader', (tester) async {
    await MultiShaderBuilder.precacheShader(ShaderKeys.liquidGlassRender);
    ui.FragmentShader? currentShader;

    Widget buildHarness() {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: MultiShaderBuilder(
          (context, shaders, child) {
            currentShader = shaders.single;
            return const SizedBox(width: 1, height: 1);
          },
          // 中文注释：每次 build 都故意创建新的 List，复现 ShaderBuilder
          // 使用 `[assetKey]` 时触发 List 身份比较误判的真实路径。
          assetKeys: <String>[ShaderKeys.liquidGlassRender],
        ),
      );
    }

    await tester.pumpWidget(buildHarness());
    final firstShader = currentShader;
    expect(firstShader, isNotNull);

    await tester.pumpWidget(buildHarness());

    expect(identical(currentShader, firstShader), isTrue);
  });

  testWidgets('Shader key 变化和组件销毁时必须释放旧实例', (tester) async {
    await MultiShaderBuilder.precacheShaders(<String>[
      ShaderKeys.liquidGlassRender,
      ShaderKeys.blendedGeometry,
    ]);
    ui.FragmentShader? currentShader;

    Widget buildHarness(String key) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: MultiShaderBuilder(
          (context, shaders, child) {
            currentShader = shaders.single;
            return const SizedBox(width: 1, height: 1);
          },
          assetKeys: <String>[key],
        ),
      );
    }

    await tester.pumpWidget(buildHarness(ShaderKeys.liquidGlassRender));
    final firstShader = currentShader!;

    await tester.pumpWidget(buildHarness(ShaderKeys.blendedGeometry));
    final secondShader = currentShader!;

    // 中文注释：切换 key 后旧 Shader 不再被任何渲染对象使用，应立即释放
    // GPU 资源；只缓存 FragmentProgram，不缓存带可变 uniform 的 Shader 实例。
    expect(firstShader.debugDisposed, isTrue);
    expect(secondShader.debugDisposed, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(secondShader.debugDisposed, isTrue);
  });

  testWidgets('Standard 重绘时应复用 BackdropFilterLayer', (tester) async {
    await LightweightLiquidGlass.preWarm();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 120,
            height: 48,
            child: LightweightLiquidGlass(
              shape: LiquidRoundedRectangle(borderRadius: 24),
              settings: LiquidGlassSettings(blur: 4),
              child: SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final firstLayer = tester.layers.whereType<BackdropFilterLayer>().single;
    tester.renderObject(find.byType(LightweightLiquidGlass)).markNeedsPaint();
    await tester.pump();
    final secondLayer = tester.layers.whereType<BackdropFilterLayer>().single;

    // 中文注释：Standard 在滚动或动画中会频繁重绘；保留同一个合成层可让
    // Flutter/Impeller 复用 layer tree，避免每帧创建并重新连接原生层对象。
    expect(identical(secondLayer, firstLayer), isTrue);
  });

  test('相同尺寸的重复 layout 不应把 Premium 几何标记为失效', () async {
    final program = await ui.FragmentProgram.fromAsset(
      ShaderKeys.liquidGlassRender,
    );
    final shader = program.fragmentShader();
    final renderObject = _TestLiquidGlassRenderObject(shader);
    const constraints = BoxConstraints.tightFor(width: 120, height: 48);

    // 中文注释：真实页面中父级动画、滚动或约束传播都可能让 layout 再次
    // 进入，但只要本地尺寸不变，就没有理由重新 Picture.toImageSync。
    renderObject.layout(constraints);
    renderObject.markGeometryCleanForTesting();
    renderObject.layout(constraints);

    expect(renderObject.geometryNeedsUpdateForTesting, isFalse);
    renderObject.dispose();
    shader.dispose();
  });
}

/// 仅暴露抽象渲染对象的几何失效状态，用于验证重复 layout 的回归路径。
class _TestLiquidGlassRenderObject extends LiquidGlassRenderObject {
  _TestLiquidGlassRenderObject(ui.FragmentShader shader)
      : super(
          link: GeometryRenderLink(),
          renderShader: shader,
          settings: const LiquidGlassSettings(),
          devicePixelRatio: 1,
        );

  @override
  Size get desiredMatteSize => hasSize ? size : Size.zero;

  @override
  Matrix4 get matteTransform => Matrix4.identity();

  @override
  void paintLiquidGlass(
    PaintingContext context,
    Offset offset,
    List<(RenderLiquidGlassGeometry, GeometryCache, Matrix4)> shapes,
    Rect boundingBox,
  ) {}

  void markGeometryCleanForTesting() => needsGeometryUpdate = false;

  bool get geometryNeedsUpdateForTesting => needsGeometryUpdate;
}
