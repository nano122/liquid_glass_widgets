// ignore_for_file: public_member_api_docs

import 'dart:collection';
import 'dart:math';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../internal/fragment_shader_extensions.dart';
import '../liquid_glass_renderer.dart';
import '../internal/render_liquid_glass_geometry.dart';
import '../internal/snap_rect_to_pixels.dart';

// 中文说明：最终渲染 Shader 的几何坐标 uniform 固定占 12 个 float。捕获
// 路径无法复用屏幕坐标逆矩阵，因此每帧显式写零，避免同一个 FragmentShader
// 实例残留上一帧的解析式或纹理逆仿射状态。
const List<double> _disabledAnalyticUniforms = <double>[
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
];

/// 为 geometry texture 构造“屏幕物理像素 → 渲染层本地逻辑像素”的逆仿射。
///
/// 中文说明：纹理本身是在 [_geometryLocalBounds] 的局部坐标中生成的。过去把
/// [matteTransform] 后的轴对齐包围盒只写成 offset/size，会永久丢掉旋转和斜切
/// 系数；底栏转动时纹理中的 alpha 与深色终止边因此无法贴合主体。现在保留完整
/// 2x3 逆矩阵，让 Shader 对每个片元先回到纹理的局部坐标再计算 UV。
///
/// 返回 null 表示当前矩阵包含透视、退化或非有限值。调用方必须保留旧的屏幕
/// 包围盒映射作为兼容回退，不能把不完整的仿射近似送进 Shader。
List<double>? _textureGeometryUniformValues({
  required Matrix4 layerToScreen,
  required Rect geometryLocalBounds,
  required double devicePixelRatio,
}) {
  if (geometryLocalBounds.isEmpty ||
      !devicePixelRatio.isFinite ||
      devicePixelRatio <= 0) {
    return null;
  }

  final storage = layerToScreen.storage;
  const epsilon = 1e-9;
  final isTwoDimensionalAffine = storage[3].abs() < epsilon &&
      storage[7].abs() < epsilon &&
      storage[11].abs() < epsilon &&
      (storage[15] - 1.0).abs() < epsilon;
  if (!isTwoDimensionalAffine) return null;

  final screenToLayer = Matrix4.copy(layerToScreen);
  final determinant = screenToLayer.invert();
  if (!determinant.isFinite || determinant.abs() < epsilon) return null;

  final inverse = screenToLayer.storage;
  final requiredValues = <double>[
    inverse[0],
    inverse[1],
    inverse[4],
    inverse[5],
    inverse[12],
    inverse[13],
  ];
  if (requiredValues.any((value) => !value.isFinite)) return null;

  return <double>[
    0.0,
    0.0,
    0.0,
    0.0, // uAnalyticRect.w == 0：继续使用 geometry texture。
    inverse[0] / devicePixelRatio,
    inverse[4] / devicePixelRatio,
    inverse[12],
    1.0, // uAnalyticInverseX.w：启用纹理局部坐标逆仿射。
    inverse[1] / devicePixelRatio,
    inverse[5] / devicePixelRatio,
    inverse[13],
    0.0,
  ];
}

/// A render object that can assemble [RenderLiquidGlassGeometry] shapes and
/// render them to the screen with the liquid glass effect.
abstract class LiquidGlassRenderObject extends RenderProxyBox {
  LiquidGlassRenderObject({
    required GeometryRenderLink link,
    required this.renderShader,
    required LiquidGlassSettings settings,
    required double devicePixelRatio,
    BackdropKey? backdropKey,
    ui.Image? captureImage,
    Offset captureOriginInScreenSpace = Offset.zero,
    bool preferAnalyticRoundedRectangle = false,
  })  : _settings = settings,
        _devicePixelRatio = devicePixelRatio,
        _backdropKey = backdropKey,
        _captureImage = captureImage,
        _captureOriginInScreenSpace = captureOriginInScreenSpace,
        _preferAnalyticRoundedRectangle = preferAnalyticRoundedRectangle,
        _link = link,
        _cachedLightDir = Offset(
          cos(settings.lightAngle),
          -sin(settings.lightAngle),
        );

  final FragmentShader renderShader;

  /// Cached light direction vector — updated only when [settings.lightAngle]
  /// changes. Avoids recomputing cos/sin on every setting change.
  Offset _cachedLightDir;

  /// The size that the geometry texture should have.
  Size get desiredMatteSize;

  Matrix4 get matteTransform;

  late GeometryRenderLink _link;
  GeometryRenderLink get link => _link;
  set link(GeometryRenderLink value) {
    if (_link == value) return;
    markNeedsPaint();
    _link = value;
  }

  LiquidGlassSettings? _settings;
  LiquidGlassSettings get settings => _settings!;
  set settings(LiquidGlassSettings value) {
    if (_settings == value) return;
    // Only recompute the trig if lightAngle actually changed.
    if (value.lightAngle != _settings?.lightAngle) {
      _cachedLightDir = Offset(cos(value.lightAngle), -sin(value.lightAngle));
    }
    // alwaysNeedsCompositing == (_geometryImage != null). The geometry image is
    // set synchronously inside paint() so we cannot call
    // markNeedsCompositingBitsUpdate() from there. However, when settings
    // change such that the paint path changes (e.g. thickness/blur both drop to
    // zero → _clearGeometryImage is called → predicate flips false), we need
    // to dirty the compositing bit. Capture the pre-update state and request
    // a re-evaluation after the value changes.
    final wasCompositing = alwaysNeedsCompositing;
    _settings = value;
    if (wasCompositing != alwaysNeedsCompositing) {
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
  }

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    // 中文说明：几何 matte 按物理像素分辨率生成；窗口跨屏或 DPR 改变时，
    // 旧纹理尺寸已经失效，必须重建一次，而普通位置变化不需要重建。
    needsGeometryUpdate = true;
    markNeedsPaint();
  }

  /// The [BackdropKey] for blur-sharing via the layer's own [BackdropGroup].
  /// Set to [BackdropGroup.of(context)?.backdropKey] from the layer's local
  /// [BackdropGroup]; null when no group exists (no-op).
  BackdropKey? _backdropKey;
  BackdropKey? get backdropKey => _backdropKey;
  set backdropKey(BackdropKey? value) {
    if (_backdropKey == value) return;
    _backdropKey = value;
    markNeedsPaint();
  }

  // ── Capture-path fields ───────────────────────────────────────────────────
  //
  // When [captureImage] is non-null, [paintLiquidGlass] implementations MUST
  // use [paintLiquidGlassWithCapture] instead of the BackdropFilterLayer path.
  // The captured image is the background texture fed directly to the shader,
  // bypassing the live compositor read entirely.
  //
  // [captureOriginInScreenSpace] is the global (screen-space) logical-pixel
  // position of the RepaintBoundary that produced [captureImage]. It is used
  // to derive [uCaptureOffset]: the physical-pixel shift from the render
  // surface's canvas origin to the capture boundary's origin, which corrects
  // [FlutterFragCoord()] (canvas-local) into capture-image space.

  ui.Image? _captureImage;
  ui.Image? get captureImage => _captureImage;
  set captureImage(ui.Image? value) {
    if (identical(_captureImage, value)) return;
    _captureImage = value;
    markNeedsPaint();
  }

  Offset _captureOriginInScreenSpace = Offset.zero;
  Offset get captureOriginInScreenSpace => _captureOriginInScreenSpace;
  set captureOriginInScreenSpace(Offset value) {
    if (_captureOriginInScreenSpace == value) return;
    _captureOriginInScreenSpace = value;
    markNeedsPaint();
  }

  bool _preferAnalyticRoundedRectangle;
  bool get preferAnalyticRoundedRectangle => _preferAnalyticRoundedRectangle;
  set preferAnalyticRoundedRectangle(bool value) {
    if (_preferAnalyticRoundedRectangle == value) return;
    final wasCompositing = alwaysNeedsCompositing;
    _preferAnalyticRoundedRectangle = value;
    // 中文说明：切换解析式策略时立即释放不再需要的中间纹理；若之后发现形状
    // 不受支持，下一次 paint 会按原管线重新生成，避免同时常驻两份 GPU 几何。
    if (value) {
      _clearGeometryImage();
    } else {
      needsGeometryUpdate = true;
    }
    if (wasCompositing != alwaysNeedsCompositing) {
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing =>
      _preferAnalyticRoundedRectangle || _geometryImage != null;

  /// Pre-rendered geometry texture in the render object's LOCAL coordinate space.
  /// Because the geometry is recorded without `matteTransform`, its screen-space
  /// position is always derived synchronously at paint time — zero async lag.
  ui.Image? _geometryImage;
  @protected
  ui.Image? get geometryImage => _geometryImage;

  /// Bounding box of [_geometryImage] in the render object's LOCAL logical-pixel
  /// coordinate space (snapped to physical pixels).
  /// Apply `matteTransform` at paint time to get the current screen-space bounds.
  Rect _geometryLocalBounds = Rect.zero;
  @protected
  Rect get geometryLocalBounds => _geometryLocalBounds;

  @override
  @mustCallSuper
  void attach(PipelineOwner owner) {
    super.attach(owner);
  }

  @override
  @mustCallSuper
  void detach() {
    super.detach();
  }

  @override
  void layout(Constraints constraints, {bool parentUsesSize = false}) {
    final previousSize = hasSize ? size : null;
    super.layout(constraints, parentUsesSize: parentUsesSize);
    // 中文说明：父级动画、滚动和约束传播可能重复进入 layout，但几何纹理
    // 记录在本地坐标系中；本地尺寸未变时，重新 Picture.toImageSync 既不会
    // 改变画面，也会制造同步 GPU 栅格开销。形状内容变化仍由 link._dirty
    // 精确触发，因此这里只针对真正的尺寸变化失效。
    if (previousSize != size) {
      needsGeometryUpdate = true;
    }
  }

  ui.Rect _paintBounds = ui.Rect.zero;

  @override
  ui.Rect get paintBounds => _paintBounds;

  // Reusable list to avoid per-frame allocations during paint traversal.
  final _shapesWithGeometry =
      <(RenderLiquidGlassGeometry, GeometryCache, Matrix4)>[];

  _AnalyticRoundedRectangleGeometry? _activeAnalyticGeometry;

  /// 解析式分支仍需满足 FragmentShader 声明的 sampler 1 绑定数量。
  ///
  /// 中文说明：1×1 透明图只用于占位，Shader 在解析式 uniform 开启时不会读取
  /// 它；每个 RenderObject 只创建一次，并在 dispose 中显式释放 GPU 资源。
  ui.Image? _analyticSamplerPlaceholder;

  ui.Image get _analyticSamplerImage {
    if (_analyticSamplerPlaceholder case final image?) return image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(const Color(0x00000000), BlendMode.src);
    final picture = recorder.endRecording();
    try {
      return _analyticSamplerPlaceholder = picture.toImageSync(1, 1);
    } finally {
      picture.dispose();
    }
  }

  @visibleForTesting
  bool get debugUsesAnalyticRoundedRectangle => _activeAnalyticGeometry != null;

  // MARK: Painting

  @override
  @nonVirtual
  void paint(PaintingContext context, Offset offset) {
    // Guard: if this render object has been detached mid-frame (e.g. rapid
    // widget removal during isolate shutdown), skip all GPU operations to
    // prevent use-after-free on Mali GPU Vulkan resources.
    if (!attached) return;

    _shapesWithGeometry.clear();

    Rect? boundingBox;

    for (final geometryRo in link.shapes) {
      final geometry = geometryRo.maybeRebuildGeometry();

      if (geometry == null) continue;

      final transform = geometryRo.getTransformTo(this);
      _shapesWithGeometry.add((geometryRo, geometry, transform));

      final geoBounds = MatrixUtils.transformRect(transform, geometry.bounds);
      boundingBox = boundingBox == null
          ? geoBounds
          : boundingBox.expandToInclude(geoBounds);
    }

    if (boundingBox == null || boundingBox.isEmpty || !boundingBox.isFinite) {
      _activeAnalyticGeometry = null;
      _clearGeometryImage();

      super.paint(context, offset);
      return;
    }

    _paintBounds = boundingBox;

    // Fast-path: if there is no geometric thickness AND no blur, there is
    // nothing to render — skip the expensive async geometry build entirely.
    // If blur > 0 but thickness == 0, we must still run paintLiquidGlass so
    // the BackdropFilterLayer blur pass fires in liquid_glass_layer.dart.
    if (settings.effectiveThickness <= 0 && settings.effectiveBlur <= 0) {
      _clearGeometryImage();
      paintShapeContents(
        context,
        offset,
        _shapesWithGeometry,
        insideGlass: true,
      );
      paintShapeContents(
        context,
        offset,
        _shapesWithGeometry,
        insideGlass: false,
      );
      super.paint(context, offset);
      return;
    }

    // 中文说明：解析式资格在官方层已经收集完 shape 与 transform 后判断，绝不
    // 根据调用方声明盲目启用。捕获纹理、复杂轮廓、多形状或不可逆变换都会返回
    // null，并继续执行原来的 geometry texture 路径。
    _activeAnalyticGeometry = _resolveAnalyticRoundedRectangle();

    if (_activeAnalyticGeometry != null) {
      _clearGeometryImage();
      needsGeometryUpdate = false;
      link._dirty = false;
    } else if (needsGeometryUpdate || _geometryImage == null || link._dirty) {
      link.updateAllGeometries();
      link._dirty = false;
      needsGeometryUpdate = false;

      // Synchronous rasterization (toImageSync) eliminates 1-frame jitter
      // during size animations (like modal sheet expansion).
      _updateGeometrySync(_shapesWithGeometry, boundingBox);

      // The image is now current — no latency. On the very first frame there
      // is no previous image — fall through to the early-return below via the
      // null check on _geometryImage.
    }

    if (debugPaintLiquidGlassGeometry) {
      _debugPaintGeometry(context, offset);
      paintShapeContents(
        context,
        offset,
        _shapesWithGeometry,
        insideGlass: true,
      );
      paintShapeContents(
        context,
        offset,
        _shapesWithGeometry,
        insideGlass: false,
      );
    } else {
      final analyticGeometry = _activeAnalyticGeometry;
      final geometrySampler =
          analyticGeometry != null ? _analyticSamplerImage : _geometryImage;
      if (geometrySampler case final geometryImage?) {
        // Map the texture to exactly the bounds it was originally built for
        // (_geometryLocalBounds) rather than the newly expanding current frame
        // bounds (_paintBounds).
        //
        // Using _paintBounds causes severe multi-button jitter during animations:
        // as one button scales, _paintBounds expands/shifts to contain it. Since
        // the asynchronous texture lags 1 frame behind, rendering the old texture
        // using the new origin visually shifted entire group of buttons on the
        // screen until the next texture arrived.
        //
        // Locking the shader mapping to the precise bounds the texture was built
        // with ensures stable pixel positioning for the life of the texture.
        final activeBounds = MatrixUtils.transformRect(
          matteTransform,
          analyticGeometry == null ? _geometryLocalBounds : boundingBox,
        ).snapToPixels(devicePixelRatio);
        final textureGeometryUniforms = analyticGeometry == null
            ? _textureGeometryUniformValues(
                layerToScreen: matteTransform,
                geometryLocalBounds: _geometryLocalBounds,
                devicePixelRatio: devicePixelRatio,
              )
            : null;

        // Scale physical thickness to maintain identical logical rim width across DPRs.
        // The baseline visual thickness was tuned on a 3x Retina display.
        final scale = devicePixelRatio / 3.0;

        renderShader
          // Slot 0-1: uSize — physical-pixel size of the backdrop layer.
          // Must be set before painting so the shader can derive correct screen UVs.
          ..setFloatUniforms(initialIndex: 0, (value) {
            value.setSize(desiredMatteSize * devicePixelRatio);
          })
          ..setFloatUniforms(initialIndex: 2, (value) {
            if (textureGeometryUniforms != null) {
              // 中文说明：启用逆仿射后 offset/size 改为纹理生成时的局部逻辑
              // 坐标。Shader 会先把片元逆映射回来，因此旋转、斜切和非等比
              // 缩放都不会再被轴对齐包围盒抹掉。
              value
                ..setOffset(_geometryLocalBounds.topLeft)
                ..setSize(_geometryLocalBounds.size);
            } else {
              // 解析式分支不读取这四个值；透视纹理与捕获纹理则继续沿用
              // 屏幕物理像素包围盒，保证不支持的矩阵仍有稳定兼容路径。
              value
                ..setOffset(activeBounds.topLeft * devicePixelRatio)
                ..setSize(activeBounds.size * devicePixelRatio);
            }
          })
          ..setFloatUniforms(initialIndex: 6, (value) {
            value
              ..setColor(settings.effectiveGlassColor)
              ..setFloats([
                settings.effectiveRefractiveIndex,
                settings.effectiveChromaticAberration,
                settings.effectiveThickness * scale,
                1.0, // uRefractScale (slot 13) - normalization handled by physical geometry curve scaling
                settings.effectiveLightIntensity,
                settings.effectiveAmbientStrength,
                settings.effectiveSaturation,
              ])
              ..setOffset(_cachedLightDir); // slots 17-18
          })
          // Slot 19: uWhiten (whitening amount); slot 20: uWhitenGated
          // Slot 21: uPinchStrength
          ..setFloatUniforms(initialIndex: 19, (value) {
            value
              ..setFloat(settings.effectiveWhitenStrength)
              ..setFloat(settings.whitenGated ? 1.0 : 0.0)
              ..setFloat(settings.pinchStrength);
          })
          // Slots 22-25: uBackgroundFallback (straight RGBA).
          ..setFloatUniforms(initialIndex: 22, (value) {
            final b = settings.platformViewFallbackColor ??
                settings.effectiveBackerColor ??
                const Color(0x00000000);
            value.setFloats(<double>[b.r, b.g, b.b, b.a]);
          })
          // Slots 26-27: uCaptureOffset
          ..setFloatUniforms(initialIndex: 26, (value) {
            value.setOffset(Offset.zero);
          })
          // Slots 28-31: uEdgeConfig (ambientRim, fresnelStrength, dprScale, edgeAbsorption)
          ..setFloatUniforms(initialIndex: 28, (value) {
            value.setFloats([
              settings.effectiveAmbientRim * scale,
              settings.effectiveFresnelStrength,
              scale,
              settings.effectiveEdgeAbsorption,
            ]);
          })
          // Slots 32-43：解析式圆角信息，或 geometry texture 的“屏幕物理
          // 像素 → 渲染层本地逻辑像素”逆仿射。只有不支持的透视兼容路径写零。
          ..setFloatUniforms(initialIndex: 32, (value) {
            value.setFloats(
              analyticGeometry?.uniformValues(devicePixelRatio) ??
                  textureGeometryUniforms ??
                  _disabledAnalyticUniforms,
            );
          })
          // Slot 44：上游 v1.3.0 的 PlatformView 透传模式排在 Poiesis
          // 12 个几何 uniform 之后，两组数据互不覆盖。
          ..setFloatUniforms(initialIndex: 44, (value) {
            value.setFloat(
              settings.platformViewMode == PlatformViewGlassMode.passthrough
                  ? 1.0
                  : 0.0,
            );
          })
          // Slot 45：背景折射总开关。普通 backdrop 路径也必须逐次写入，
          // 防止共享 FragmentShader 沿用上一组件的开关状态。
          ..setFloatUniforms(initialIndex: 45, (value) {
            value.setFloat(settings.refractionEnabled ? 1.0 : 0.0);
          })
          ..setImageSampler(
            1,
            geometryImage,
            filterQuality: FilterQuality.medium,
          );
        paintLiquidGlass(context, offset, _shapesWithGeometry, _paintBounds);
      }
    }

    super.paint(context, offset);
  }

  _AnalyticRoundedRectangleGeometry? _resolveAnalyticRoundedRectangle() {
    if (!preferAnalyticRoundedRectangle ||
        captureImage != null ||
        debugPaintLiquidGlassGeometry ||
        _shapesWithGeometry.length != 1) {
      return null;
    }

    final geometryCache = _shapesWithGeometry.single.$2;
    if (geometryCache.shapes.length != 1) return null;

    final shapeGeometry = geometryCache.shapes.single;
    final shape = shapeGeometry.shape;
    if (shape is! LiquidRoundedRectangle) return null;
    final roundedRect = shape;

    final shapeRenderObject = shapeGeometry.renderObject;
    if (!shapeRenderObject.attached ||
        !shapeRenderObject.hasSize ||
        shapeRenderObject.size.isEmpty) {
      return null;
    }

    // 中文说明：shapeToScreen 把圆角矩形本地逻辑坐标映射到根视图逻辑坐标；
    // Shader 收到的是物理像素，因此 uniformValues 再把线性项除以 DPR。
    final shapeToLayer = shapeRenderObject.getTransformTo(this);
    final shapeToScreen = Matrix4.copy(matteTransform)..multiply(shapeToLayer);
    final storage = shapeToScreen.storage;

    // 当前快速路径只接受可精确逆映射的二维仿射变换。遇到透视或退化矩阵时
    // 直接回退 geometry texture，避免用错误坐标换取性能。
    const epsilon = 1e-9;
    final isTwoDimensionalAffine = storage[3].abs() < epsilon &&
        storage[7].abs() < epsilon &&
        storage[11].abs() < epsilon &&
        (storage[15] - 1.0).abs() < epsilon;
    if (!isTwoDimensionalAffine) return null;

    final screenToShape = Matrix4.copy(shapeToScreen);
    final determinant = screenToShape.invert();
    if (!determinant.isFinite || determinant.abs() < epsilon) return null;

    final inverseStorage = screenToShape.storage;
    final requiredValues = <double>[
      inverseStorage[0],
      inverseStorage[1],
      inverseStorage[4],
      inverseStorage[5],
      inverseStorage[12],
      inverseStorage[13],
    ];
    if (requiredValues.any((value) => !value.isFinite)) return null;

    return _AnalyticRoundedRectangleGeometry(
      size: shapeRenderObject.size,
      cornerRadius: roundedRect.borderRadius,
      screenToShape: screenToShape,
    );
  }

  /// 在合成阶段同步只依赖祖先 Transform 的几何坐标 uniform。
  ///
  /// 中文说明：祖先 [Transform] 可以只重组图层而不让玻璃 repaint boundary
  /// 重绘。此时若等到下一帧 paint 才刷新逆矩阵，陀螺仪连续动画中的描边会始终
  /// 落后一帧。变换追踪层会在当前 scene 遍历到玻璃 Shader 之前调用本方法；这里
  /// 不重建 SDF 纹理，只更新 2x3 逆仿射，所以开销固定且不会引入异步竞态。
  @protected
  bool synchronizeGeometryTransformUniformsForScene() {
    if (!attached || captureImage != null) return false;

    if (_activeAnalyticGeometry != null) {
      final analyticGeometry = _resolveAnalyticRoundedRectangle();
      if (analyticGeometry == null) return false;
      _activeAnalyticGeometry = analyticGeometry;
      renderShader.setFloatUniforms(initialIndex: 32, (value) {
        value.setFloats(analyticGeometry.uniformValues(devicePixelRatio));
      });
      return true;
    }

    if (_geometryImage == null || _geometryLocalBounds.isEmpty) return false;
    final textureGeometryUniforms = _textureGeometryUniformValues(
      layerToScreen: matteTransform,
      geometryLocalBounds: _geometryLocalBounds,
      devicePixelRatio: devicePixelRatio,
    );
    if (textureGeometryUniforms == null) return false;

    renderShader
      ..setFloatUniforms(initialIndex: 2, (value) {
        value
          ..setOffset(_geometryLocalBounds.topLeft)
          ..setSize(_geometryLocalBounds.size);
      })
      ..setFloatUniforms(initialIndex: 32, (value) {
        value.setFloats(textureGeometryUniforms);
      });
    return true;
  }

  void _clearGeometryImage() {
    _geometryImage?.dispose();
    _geometryImage = null;
  }

  /// Subclasses implement the actual glass rendering
  /// (e.g., with backdrop filters)
  void paintLiquidGlass(
    PaintingContext context,
    Offset offset,
    List<(RenderLiquidGlassGeometry, GeometryCache, Matrix4)> shapes,
    Rect boundingBox,
  );

  /// Direct-draw paint path used when [captureImage] is non-null.
  ///
  /// Instead of emitting a [BackdropFilterLayer] (which reads from the live
  /// compositor), this draws the shader as a plain rect onto the current canvas,
  /// binding the pre-captured background image to sampler slot 0.
  ///
  /// Coordinate math:
  ///   [FlutterFragCoord()] in a plain canvas.drawRect gives the fragment
  ///   position within the current compositing layer (the RepaintBoundary that
  ///   [LiquidGlassLayer] creates). [captureOriginInScreenSpace] is the global
  ///   logical-pixel origin of the capture boundary (from localToGlobal).
  ///   The physical-pixel offset between the two coordinate origins is:
  ///
  ///     uCaptureOffset = (captureOriginGlobal - thisRenderOriginGlobal) * dpr
  ///
  ///   Adding this to [FlutterFragCoord()] maps each fragment into capture-image
  ///   space, so [screenUV] correctly addresses the pre-captured bar texture.
  @protected
  void paintLiquidGlassWithCapture(
    PaintingContext context,
    Offset offset,
    List<(RenderLiquidGlassGeometry, GeometryCache, Matrix4)> shapes,
    Rect boundingBox,
    ui.Image capture,
  ) {
    if (!attached) return;

    final dpr = devicePixelRatio;

    // Our render object's global logical-pixel origin.
    final thisOriginGlobal = matteTransform.getTranslation();
    final thisOriginLogical = Offset(thisOriginGlobal.x, thisOriginGlobal.y);

    // Physical-pixel offset from our canvas origin → capture-boundary origin.
    // This is the uCaptureOffset uniform: it shifts FlutterFragCoord() (which
    // is relative to the compositing layer, i.e. our RepaintBoundary surface)
    // into the capture image's coordinate space.
    final captureOffset =
        (captureOriginInScreenSpace - thisOriginLogical) * dpr;

    // uSize: physical pixel dimensions of the captured image.
    final captureSize = ui.Size(
      capture.width.toDouble(),
      capture.height.toDouble(),
    );

    // Geometry bounds in screen space, snapped to pixels.
    final activeBounds = MatrixUtils.transformRect(
      matteTransform,
      _geometryLocalBounds,
    ).snapToPixels(dpr);

    // uGeometryOffset/uGeometrySize are relative to the capture origin
    // (not screen origin) so that geometryUV = (fragCoord + uCaptureOffset -
    // uGeometryOffset) / uGeometrySize resolves correctly.
    final geometryOffsetInCapture =
        (activeBounds.topLeft - captureOriginInScreenSpace) * dpr;
    final geometrySizePhysical = activeBounds.size * dpr;
    final scale = dpr / 3.0;

    renderShader
      // Slot 0-1: uSize — physical size of the capture image.
      ..setFloatUniforms(initialIndex: 0, (value) {
        value.setSize(captureSize);
      })
      // Slots 2-5: uGeometryOffset + uGeometrySize, relative to capture origin.
      ..setFloatUniforms(initialIndex: 2, (value) {
        value
          ..setOffset(geometryOffsetInCapture)
          ..setSize(geometrySizePhysical);
      })
      ..setFloatUniforms(initialIndex: 6, (value) {
        value
          ..setColor(settings.effectiveGlassColor)
          ..setFloats([
            settings.effectiveRefractiveIndex,
            settings.effectiveChromaticAberration,
            settings.effectiveThickness * scale,
            1.0, // uRefractScale (slot 13) - normalization handled by physical geometry curve scaling
            settings.effectiveLightIntensity,
            settings.effectiveAmbientStrength,
            settings.effectiveSaturation,
          ])
          ..setOffset(_cachedLightDir); // slots 17-18
      })
      ..setFloatUniforms(initialIndex: 19, (value) {
        value
          ..setFloat(settings.effectiveWhitenStrength)
          ..setFloat(settings.whitenGated ? 1.0 : 0.0)
          ..setFloat(settings.pinchStrength);
      })
      ..setFloatUniforms(initialIndex: 22, (value) {
        final b = settings.platformViewFallbackColor ??
            settings.effectiveBackerColor ??
            const Color(0x00000000);
        value.setFloats(<double>[b.r, b.g, b.b, b.a]);
      })
      // Slot 26-27: uCaptureOffset
      ..setFloatUniforms(initialIndex: 26, (value) {
        value.setOffset(captureOffset);
      })
      // Slots 28-31: uEdgeConfig (ambientRim, fresnelStrength, dprScale, edgeAbsorption)
      ..setFloatUniforms(initialIndex: 28, (value) {
        value.setFloats([
          settings.effectiveAmbientRim * scale,
          settings.effectiveFresnelStrength,
          scale,
          settings.effectiveEdgeAbsorption,
        ]);
      })
      // Slots 32-43：捕获模式始终使用 geometry texture。即使同一个 Shader
      // 上一帧刚渲染过解析式圆角，也必须清零 enabled 和逆变换，避免残留状态
      // 让捕获纹理被错误地当作解析几何处理。
      ..setFloatUniforms(initialIndex: 32, (value) {
        value.setFloats(_disabledAnalyticUniforms);
      })
      // Slot 44：捕获路径同样必须显式同步 PlatformView 模式，避免复用的
      // FragmentShader 残留上一条绘制命令的透传状态。
      ..setFloatUniforms(initialIndex: 44, (value) {
        value.setFloat(
          settings.platformViewMode == PlatformViewGlassMode.passthrough
              ? 1.0
              : 0.0,
        );
      })
      // Slot 45：捕获路径同样显式覆盖开关；关闭时仍使用原坐标背景完成
      // tint、饱和度与光照合成，只跳过折射、pinch 和色散偏移。
      ..setFloatUniforms(initialIndex: 45, (value) {
        value.setFloat(settings.refractionEnabled ? 1.0 : 0.0);
      })
      // Slot 0: captured background image (replaces the BackdropFilter read).
      ..setImageSampler(0, capture)
      ..setImageSampler(1, geometryImage!, filterQuality: FilterQuality.medium);

    // Draw the capture path: no BackdropFilterLayer needed — draw directly
    // onto the canvas over the expanded clip rect.
    final clipRect = boundingBox.expandToInclude(
      Rect.fromLTRB(
        boundingBox.left - 20,
        boundingBox.top - 15,
        boundingBox.right + 20,
        boundingBox.bottom + 15,
      ),
    );

    // Pass 1 (blur): retained even in capture mode — the blur layer reads from
    // the BackdropGroup which is the internal bar blur, not the external capture.
    // This is correct: the inner blur pass blurs icon content inside the glass,
    // the capture provides the bar background behind the glass.
    paintShapeContents(context, offset, shapes, insideGlass: true);

    // Pass 2: glass refraction shader as a plain canvas.drawRect.
    // No BackdropFilter wrapper; the captured image is already bound to slot 0.
    context.canvas
      ..save()
      ..clipRect(clipRect.shift(offset))
      ..drawRect(clipRect.shift(offset), Paint()..shader = renderShader)
      ..restore();

    // Pass 3: shape contents painted on top (non-glass child layer).
    paintShapeContents(context, offset, shapes, insideGlass: false);
  }

  @protected
  void paintShapeContents(
    PaintingContext context,
    Offset offset,
    List<(RenderLiquidGlassGeometry, GeometryCache, Matrix4)> shapes, {
    required bool insideGlass,
  }) {
    for (final (geometryRenderObject, _, _) in shapes) {
      geometryRenderObject.paintShapeContents(
        this,
        context,
        offset,
        insideGlass: insideGlass,
      );
    }
  }

  void _debugPaintGeometry(PaintingContext context, Offset offset) {
    if (_geometryImage case final geometryImage?) {
      // The geometry image is in local space. Draw it at the local bounds
      // position so it overlays the glass content at the correct on-screen
      // location (the rendering canvas already applies the correct transform).
      context.canvas
        ..save()
        ..translate(_geometryLocalBounds.left, _geometryLocalBounds.top)
        ..scale(1 / devicePixelRatio)
        ..drawImage(
          geometryImage,
          Offset.zero,
          Paint()..blendMode = BlendMode.src,
        )
        ..restore();
    }
  }

  /// Synchronously rasterizes the geometry picture using [ui.Picture.toImageSync].
  /// This eliminates the 1-frame async lag that caused visible ghosting during
  /// modal sheet and button-group animations. For the small pill-shape geometry
  /// used here, synchronous GPU upload is sub-millisecond and safe.
  void _updateGeometrySync(
    List<(RenderLiquidGlassGeometry, GeometryCache, Matrix4)> geometries,
    Rect bounds,
  ) {
    // Record canvas commands synchronously — pure CPU work.
    final (picture, localBounds, imageSize) = _recordGeometryPicture(
      geometries,
      bounds,
    );

    try {
      // Synchronous GPU rasterization — no async lag.
      // Clamp to ≥1: jelly squash can push geometry to near-zero size and
      // toImageSync(0, n) throws "Invalid image dimensions".
      final image = picture.toImageSync(
        max(1, imageSize.width.ceil()),
        max(1, imageSize.height.ceil()),
      );

      _clearGeometryImage();
      _geometryImage = image;
      _geometryLocalBounds = localBounds;
      // No markNeedsPaint() needed — we are already inside paint().
    } finally {
      picture.dispose();
    }
  }

  @override
  @mustCallSuper
  void dispose() {
    _activeAnalyticGeometry = null;
    _analyticSamplerPlaceholder?.dispose();
    _analyticSamplerPlaceholder = null;
    _clearGeometryImage();
    // Break reference chains to prevent stale GPU resource retention during
    // isolate shutdown. The render shader holds a DlRuntimeEffectColorSource
    // that retains Vulkan textures — nulling _settings ensures no closure
    // retains a path back to the shader's GPU resources past the Vulkan
    // context lifetime (Crash 2 in Mali GPU crash analysis).
    _settings = null;
    super.dispose();
  }

  // MARK: Geometry

  @protected
  bool needsGeometryUpdate = true;

  /// Records all geometry drawing commands into a [ui.Picture] synchronously.
  /// Returns the picture, the LOCAL-SPACE bounding rect, and the physical
  /// pixel size needed for rasterization. The caller is responsible for
  /// disposing the picture after rasterization.
  ///
  /// ## Local-space rasterization (A3)
  ///
  /// The geometry is recorded WITHOUT applying [matteTransform] (position,
  /// jelly scale, global screen offset). This means:
  ///
  /// - The image represents the pill SDF purely in the render object's own
  ///   coordinate space, at its current LOCAL size.
  /// - [matteTransform] is applied SYNCHRONOUSLY at paint time to derive the
  ///   screen-space [uGeometryOffset] / [uGeometrySize] uniforms — no 1-2
  ///   frame async lag, no correction needed.
  /// - Geometry rebuilds are only needed when the LOCAL shape changes
  ///   (layout/style), not for every position or jelly-scale animation frame.
  (ui.Picture, Rect, Size) _recordGeometryPicture(
    List<(RenderLiquidGlassGeometry, GeometryCache, Matrix4)> geometries,
    Rect bounds,
  ) {
    // Work in local coordinate space — no matteTransform applied.
    // Inflate by 2 logical pixels (= 2×DPR physical pixels after snapToPixels
    // aligns to the pixel grid) to ensure the anti-aliased SDF edge is fully
    // captured. Without this, the picture boundaries tightly crop the fractional
    // edge pixels, abruptly cutting off the rim lighting at the pill boundary.
    final localBounds = bounds.snapToPixels(devicePixelRatio).inflate(2.0);
    final size = localBounds.size * devicePixelRatio;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    for (final (_, geometry, transform) in geometries) {
      canvas
        ..save()
        ..scale(devicePixelRatio)
        // Shift so localBounds.topLeft is the texture origin.
        ..translate(-localBounds.left, -localBounds.top)
        // Apply geometry-local → glass-local transform only (no matteTransform).
        ..transform(transform.storage)
        ..scale(1 / devicePixelRatio)
        ..translate(
          geometry.matteBounds.topLeft.dx,
          geometry.matteBounds.topLeft.dy,
        );

      switch (geometry) {
        case UnrenderedGeometryCache(matte: final picture):
          canvas.drawPicture(picture);
        case RenderedGeometryCache(matte: final image):
          canvas.drawImage(image, Offset.zero, Paint());
      }

      canvas.restore();
    }

    return (recorder.endRecording(), localBounds, size);
  }
}

/// 单个圆角矩形解析式路径的不可变绘制快照。
///
/// 中文说明：这里保存逆变换而不是每帧把 SDF 展平成屏幕轴对齐矩形，因此底栏
/// jelly 的横向拉伸、纵向压缩和平移都与官方 geometry texture 的视觉一致。
@immutable
class _AnalyticRoundedRectangleGeometry {
  const _AnalyticRoundedRectangleGeometry({
    required this.size,
    required this.cornerRadius,
    required this.screenToShape,
  });

  final Size size;
  final double cornerRadius;
  final Matrix4 screenToShape;

  List<double> uniformValues(double devicePixelRatio) {
    final inverse = screenToShape.storage;
    return <double>[
      size.width,
      size.height,
      cornerRadius,
      1.0,
      inverse[0] / devicePixelRatio,
      inverse[4] / devicePixelRatio,
      inverse[12],
      1.0, // 同时启用 Shader 中的法线屏幕方向变换。
      inverse[1] / devicePixelRatio,
      inverse[5] / devicePixelRatio,
      inverse[13],
      0.0,
    ];
  }
}

class GeometryRenderLink {
  final List<RenderLiquidGlassGeometry> _shapeGeometries = [];

  UnmodifiableListView<RenderLiquidGlassGeometry> get shapes =>
      UnmodifiableListView(_shapeGeometries);

  bool _dirty = false;

  void updateAllGeometries() {
    for (final renderObject in _shapeGeometries) {
      renderObject.maybeRebuildGeometry();
    }
  }

  void registerGeometry(RenderLiquidGlassGeometry renderObject) {
    _dirty = true;
    _shapeGeometries.add(renderObject);
  }

  /// Signals that a geometry object has completed a rebuild and the render
  /// layer should integrate the updated result on the next paint.
  void notifyGeometryChanged(RenderLiquidGlassGeometry renderObject) {
    _dirty = true;
  }

  void unregisterGeometry(RenderLiquidGlassGeometry renderObject) {
    _shapeGeometries.remove(renderObject);
  }

  void dispose() {
    _shapeGeometries.clear();
  }
}

class InheritedGeometryRenderLink extends InheritedWidget {
  const InheritedGeometryRenderLink({
    required this.link,
    required super.child,
    super.key,
  });

  final GeometryRenderLink link;

  static GeometryRenderLink? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<InheritedGeometryRenderLink>()
        ?.link;
  }

  @override
  bool updateShouldNotify(covariant InheritedGeometryRenderLink oldWidget) {
    return oldWidget.link != link;
  }
}
