// Copyright 2024-2025 Tim Lehmann for whynotmake.it
//
// SPDX-License-Identifier: MIT
//
// Originally from liquid_glass_renderer (whynotmake.it).
// Maintained and evolved in-tree for liquid_glass_widgets.
// See lib/src/engine/ATTRIBUTION.md for provenance and modification history.

// ignore_for_file: public_member_api_docs

import 'dart:collection';
import 'dart:math';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../renderer/fragment_shader_extensions.dart';
// 中文说明：上游 1.7 把 renderer/rendering 迁到 engine/rendering；Poiesis 独有
// 的 EDR 高光白点仍留在 renderer/internal，避免与上游目录再次冲突。
import '../../renderer/internal/glass_highlight_headroom.dart';
import '../../renderer/liquid_glass_renderer.dart'
    show debugPaintLiquidGlassGeometry;
import '../liquid_glass_settings.dart';
import '../liquid_shape.dart';
import '../render_liquid_glass_geometry.dart';
import '../shaders.dart';
import '../snap_rect_to_pixels.dart';

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

/// 计算实时 backdrop 路径的 uTouchPosition（slots 51–52）。
///
/// 中文说明：[localTouchPosition] 是玻璃 layer 的本地逻辑坐标，
/// [layerToScreen] 为 layer → 屏幕逻辑坐标的变换（即 matteTransform），
/// 结果与 FlutterFragCoord 同为以 [passOrigin] 为原点的物理像素。
@visibleForTesting
Offset liveTouchPositionUniform({
  required Matrix4 layerToScreen,
  required Offset localTouchPosition,
  required double devicePixelRatio,
  required Offset passOrigin,
}) {
  final screenLogical =
      MatrixUtils.transformPoint(layerToScreen, localTouchPosition);
  return screenLogical * devicePixelRatio - passOrigin;
}

/// 把“屏幕物理像素 → 本地逻辑像素”的 12 个几何 uniform 改写为以
/// [passOrigin] 为原点的版本。
///
/// 中文说明：上游 #333 起，嵌套在其它 BackdropFilter 内的玻璃，其
/// FlutterFragCoord() 相对于外层 compositor pass 而非整屏。Poiesis 的
/// 解析式 / 纹理逆仿射都以屏幕物理像素为输入，因此需要把 pass 原点折算进
/// 平移项：local = A·(frag + origin) + b = A·frag + (A·origin + b)。
/// 只改 X/Y 两行的平移分量（下标 6、10），线性项和启用标记保持不变；
/// 线性项为零的禁用路径改写后仍为零，不需要额外分支。
List<double> shiftGeometryUniformsToPass(
  List<double> values,
  Offset passOrigin,
) {
  if (passOrigin == Offset.zero) return values;
  assert(values.length == 12, 'geometry uniforms must be 12 floats');
  return List<double>.of(values)
    ..[6] = values[6] + values[4] * passOrigin.dx + values[5] * passOrigin.dy
    ..[10] = values[10] + values[8] * passOrigin.dx + values[9] * passOrigin.dy;
}

/// A render object that can assemble [RenderLiquidGlassGeometry] shapes and
/// render them to the screen with the liquid glass effect.
abstract class LiquidGlassRenderObject extends RenderProxyBox {
  LiquidGlassRenderObject({
    required GeometryRenderLink link,
    this.renderShader,
    required LiquidGlassSettings settings,
    required double devicePixelRatio,
    BackdropKey? backdropKey,
    ui.Image? captureImage,
    Offset captureOriginInScreenSpace = Offset.zero,
    bool preferAnalyticRoundedRectangle = false,
    double captureOverlayOpacity = 0,
  })  : _settings = settings,
        _devicePixelRatio = devicePixelRatio,
        _backdropKey = backdropKey,
        _captureImage = captureImage,
        _captureOverlayOpacity = captureOverlayOpacity,
        _captureOriginInScreenSpace = captureOriginInScreenSpace,
        _preferAnalyticRoundedRectangle = preferAnalyticRoundedRectangle,
        _link = link,
        _cachedLightDir = Offset(
          cos(settings.lightAngle),
          -sin(settings.lightAngle),
        );

  final FragmentShader? renderShader;

  /// Cached light direction vector — updated only when [settings.lightAngle]
  /// changes. Avoids recomputing cos/sin on every setting change.
  Offset _cachedLightDir;

  /// The size that the geometry texture should have.
  Size get desiredMatteSize;

  Matrix4 get matteTransform;

  /// Local-space rect of the backdrop-reading compositor pass this render
  /// object opened on its last paint (the clip around its
  /// [BackdropFilterLayer]), or null when it painted via the capture path
  /// (no live backdrop pass opened). Descendant glass uses this via
  /// [enclosingBackdropPassRect] to find the pass its own fragment
  /// coordinates are relative to.
  Rect? backdropPassClipRectLocal;

  /// Screen-space (logical) rect of the nearest enclosing Impeller compositor
  /// pass that a [BackdropFilterLayer] in this subtree samples from, or null
  /// when that pass is the root surface.
  ///
  /// On Impeller, every [BackdropFilterLayer] renders its subtree into an
  /// offscreen pass sized to its clip. [FlutterFragCoord()] inside any shader
  /// nested in that subtree is relative to the pass, not the screen, and the
  /// backdrop texture the nested shader samples IS that pass — not the full
  /// screen. The live-path uniforms (uSize, uGeometryOffset, uTouchPosition)
  /// must therefore be expressed against this rect rather than the screen.
  ///
  /// Recognises two pass sources:
  ///   1. Flutter's own [RenderBackdropFilter] (any BackdropFilter widget).
  ///   2. A [LiquidGlassRenderObject] whose [backdropPassClipRectLocal] is
  ///      non-null (any own-layer glass surface on the live/backdrop path).
  ///
  /// Returns null (→ uniforms reduce to current behaviour) when no such
  /// ancestor is found, i.e. the glass composes directly into the root pass.
  Rect? enclosingBackdropPassRect() {
    RenderObject? node = parent;
    while (node != null) {
      Rect? local;
      if (node is RenderBackdropFilter) {
        // Flutter's BackdropFilter opens a pass scoped to its own logical size.
        local = Offset.zero & node.size;
      } else if (node is LiquidGlassRenderObject) {
        local = node.backdropPassClipRectLocal;
      }
      if (local != null) {
        final global = MatrixUtils.transformRect(
          node.getTransformTo(null),
          local,
        );
        // Coverage never exceeds the root surface.
        return global.intersect(Offset.zero & desiredMatteSize);
      }
      node = node.parent;
    }
    return null;
  }

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

  /// 中文说明：快照不包含 ModalBarrier；在采样后叠加同一黑色遮罩，
  /// 无需为路由动画的每一帧再生成一张变暗快照。
  double _captureOverlayOpacity;
  double get captureOverlayOpacity => _captureOverlayOpacity;
  set captureOverlayOpacity(double value) {
    if (_captureOverlayOpacity == value) return;
    _captureOverlayOpacity = value;
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

  // ── Touch Specular fields ─────────────────────────────────────────────────
  //
  // Driven by GlassGlowLayerState via a ValueNotifier. The logical-pixel touch
  // position and spring-animated intensity are forwarded to the shader as
  // uTouchPosition (physical px) and uTouchIntensity.
  //
  // setTouchSpecular() is the only public mutation point: it guards against
  // redundant markNeedsPaint() calls (equality check on both fields) and
  // performs the DPR scale so callers work in logical pixels.

  /// Touch point in logical pixels (layer-local).
  Offset _touchPosition = Offset.zero;

  /// Spring-animated touch presence scalar [0.0 at rest, 1.0 while pressed].
  double _touchIntensity = 0.0;

  @visibleForTesting
  Offset get touchPosition => _touchPosition;

  @visibleForTesting
  double get touchIntensity => _touchIntensity;

  /// Updates the touch specular uniforms and schedules a repaint if changed.
  ///
  /// [position] must be in layer-local **logical pixels**.
  /// [intensity] must be in [0.0, 1.0].
  ///
  /// Called from [GlassGlowLayerState] on every spring animation tick via a
  /// [ValueNotifier] listener — never from a widget build or setState.
  void setTouchSpecular(Offset position, double intensity) {
    final clamped = intensity.clamp(0.0, 1.0);
    if (_touchPosition == position && _touchIntensity == clamped) return;
    _touchPosition = position;
    _touchIntensity = clamped;
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

  /// Physical-pixel budget for [_geometryImage] while its shape is animating.
  /// See [_matteDevicePixelRatio].
  static const double _kAnimatingMattePixelBudget = 1024 * 1024;

  /// The pixel ratio [_geometryImage] was rasterized at. Equal to
  /// [devicePixelRatio] unless the matte was capped.
  double _geometryImageDevicePixelRatio = 1;

  /// Whether the previous paint rebuilt [_geometryImage]. A rebuild on the
  /// paint right after a rebuild means the shape is animating.
  bool _rebuiltGeometryLastPaint = false;

  /// Whether [_geometryImage] was rasterized below [devicePixelRatio] and
  /// still owes a full-resolution rebuild once the shape comes to rest.
  bool _geometryImageCapped = false;

  /// Whether the paint that settles a capped matte is already requested.
  bool _settleGeometryScheduled = false;

  @override
  @mustCallSuper
  void attach(PipelineOwner owner) {
    super.attach(owner);
  }

  @override
  @mustCallSuper
  void detach() {
    // Reset transient paint-state flags so a re-attached surface always starts
    // its first paint at full resolution, without inheriting stale animation
    // state (e.g. a surface that was animating when removed would otherwise
    // cap its first post-reattach matte).
    _rebuiltGeometryLastPaint = false;
    _settleGeometryScheduled = false;
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
    // 根据调用方声明盲目启用。复杂轮廓、多形状或不可逆变换都会返回
    // null，并继续执行原来的 geometry texture 路径。
    _activeAnalyticGeometry = _resolveAnalyticRoundedRectangle();

    // 中文说明：上游 1.7 用 rebuildGeometry 记录“本帧是否重建过 matte”，
    // 以便连续动画时降采样、静止后回到全分辨率。解析式路径不生成纹理，
    // 因此必须记为 false，否则下一次回到纹理路径时会被误判为动画中而降采样。
    final rebuildGeometry = _activeAnalyticGeometry == null &&
        (needsGeometryUpdate || _geometryImage == null || link._dirty);
    if (_activeAnalyticGeometry != null) {
      _clearGeometryImage();
      needsGeometryUpdate = false;
      link._dirty = false;
    } else if (rebuildGeometry) {
      link.updateAllGeometries();
      link._dirty = false;
      needsGeometryUpdate = false;

      // Synchronous rasterization (toImageSync) eliminates 1-frame jitter
      // during size animations (like modal sheet expansion).
      //
      // The first rebuild after a quiet paint is at full resolution; every
      // consecutive one is capped, since a shape that rebuilds on every paint
      // is animating and the matte is only on screen for one frame.
      _updateGeometrySync(
        _shapesWithGeometry,
        boundingBox,
        capped: _rebuiltGeometryLastPaint,
      );

      // The image is now current — no latency. On the very first frame there
      // is no previous image — fall through to the early-return below via the
      // null check on _geometryImage.
    } else if (_geometryImageCapped) {
      // The shape came to rest on a capped matte: settle at full resolution.
      _updateGeometrySync(_shapesWithGeometry, boundingBox, capped: false);
    }
    _rebuiltGeometryLastPaint = rebuildGeometry;

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

        final dpr = devicePixelRatio;

        // On Impeller, any ancestor BackdropFilter (Flutter's or our own
        // own-layer glass) renders its subtree into an offscreen pass scoped to
        // that ancestor's clip. FlutterFragCoord() inside our shader is then
        // relative to that pass, not the screen, and the backdrop texture IS
        // that pass. Express uSize and uGeometryOffset against that pass rect.
        // When there is no such ancestor, passLogical is null and passPhysical
        // equals the full screen — uniforms reduce exactly to their previous
        // values (zero regression for top-level surfaces).
        // 中文说明：pass 矩形换算抽到 [_enclosingPassPhysicalRect]，合成阶段的
        // 逆仿射同步也复用同一公式，保证 paint 与 addToScene 的原点一致。
        final passPhysical = _enclosingPassPhysicalRect(dpr);

        renderShader!
          // Slot 0-1: uSize — physical-pixel size of the enclosing compositor
          // pass (root surface when no backdrop ancestor exists).
          ..setFloatUniforms(initialIndex: 0, (value) {
            value.setSize(passPhysical.size);
          })
          // Slots 2-5: uGeometryOffset + uGeometrySize, pass-relative.
          // Subtracting passPhysical.topLeft converts screen-space activeBounds
          // into coordinates relative to the pass texture's origin (0,0).
          ..setFloatUniforms(initialIndex: 2, (value) {
            if (textureGeometryUniforms != null) {
              // 中文说明：启用逆仿射后 offset/size 改为纹理生成时的局部逻辑
              // 坐标。Shader 会先把片元逆映射回来，因此旋转、斜切和非等比
              // 缩放都不会再被轴对齐包围盒抹掉。pass 原点已折算进逆仿射
              // 平移项（见 slot 32），这里不能再减 passPhysical。
              value
                ..setOffset(_geometryLocalBounds.topLeft)
                ..setSize(_geometryLocalBounds.size);
            } else {
              // 解析式分支不读取这四个值；透视纹理兼容路径继续使用屏幕物理
              // 像素包围盒，并按上游 #333 换算到外层 compositor pass 原点。
              value
                ..setOffset(activeBounds.topLeft * dpr - passPhysical.topLeft)
                ..setSize(activeBounds.size * dpr);
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
          // 中文说明：上游 #333 后 FlutterFragCoord 相对外层 pass，逆仿射的
          // 平移项必须同步折算 passPhysical 原点，否则嵌套玻璃会整体错位。
          ..setFloatUniforms(initialIndex: 32, (value) {
            value.setFloats(
              shiftGeometryUniformsToPass(
                analyticGeometry?.uniformValues(devicePixelRatio) ??
                    textureGeometryUniforms ??
                    _disabledAnalyticUniforms,
                passPhysical.topLeft,
              ),
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
          // Slot 50: uBodyMode — 0 = adaptive, 1 = clear.
          // 中文说明：上游 1.6.2 写在 slot 33；Poiesis 的 32–49 已被占用，
          // 因此与 liquid_glass_render.frag 的声明一起顺延到 50。
          ..setFloatUniforms(initialIndex: 50, (value) {
            value.setFloat(
              settings.bodyMode == GlassBodyMode.clear ? 1.0 : 0.0,
            );
          })
          // Slots 51-52: uTouchPosition (physical px); Slot 53: uTouchIntensity.
          // Multiply by DPR here so the shader receives physical-pixel coords
          // matching FlutterFragCoord() — GlassGlowLayerState delivers logical px.
          // Subtract passPhysical.topLeft for the same reason as uGeometryOffset:
          // touch position must be relative to the enclosing pass, not the screen.
          // 中文说明：上游原本写在 34–36，与 Poiesis 解析几何冲突，顺延到 51–53。
          // 触点来自 globalToLocal，是本 layer 的本地逻辑坐标；实时路径的
          // FlutterFragCoord 却是屏幕（或外层 pass）物理像素。上游直接乘 DPR
          // 只在 layer 恰好位于屏幕原点时正确，这里先经 matteTransform 映射到
          // 屏幕再换算 pass 原点，旋转/缩放后的高光也能落在手指处。
          ..setFloatUniforms(initialIndex: 51, (value) {
            value
              ..setOffset(
                liveTouchPositionUniform(
                  layerToScreen: matteTransform,
                  localTouchPosition: _touchPosition,
                  devicePixelRatio: dpr,
                  passOrigin: passPhysical.topLeft,
                ),
              )
              ..setFloat(_touchIntensity.clamp(0.0, 1.0));
          })
          // Slot 45：背景折射总开关。普通 backdrop 路径也必须逐次写入，
          // 防止共享 FragmentShader 沿用上一组件的开关状态。
          ..setFloatUniforms(initialIndex: 45, (value) {
            value.setFloat(settings.refractionEnabled ? 1.0 : 0.0);
          })
          // Slot 46：共享 Shader 会跨组件复用，因此普通 backdrop 路径必须
          // 每次覆盖顶部折射限制，避免上一组件的性能策略泄漏到当前组件。
          ..setFloatUniforms(initialIndex: 46, (value) {
            value.setFloat(settings.topRefractionOnly ? 1.0 : 0.0);
          })
          // 中文说明：实时 backdrop 仍是 nearest sampler，不能启用捕获专用插值。
          ..setFloatUniforms(initialIndex: 47, (value) {
            value.setFloats([0.0, 0.0]);
          })
          // Slot 49：只扩展 iOS EDR surface 的高光白点；普通玻璃体、
          // 透明度与灰黑结构边仍保持原有 SDR 数值和合成顺序。
          ..setFloatUniforms(initialIndex: 49, (value) {
            value.setFloat(glassHighlightHeadroom);
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
        debugPaintLiquidGlassGeometry ||
        _shapesWithGeometry.length != 1) {
      return null;
    }

    final geometryCache = _shapesWithGeometry.single.$2;
    if (geometryCache.shapes.length != 1) return null;

    final shapeGeometry = geometryCache.shapes.single;
    final shape = shapeGeometry.shape;
    // 中文说明：非 Windows 平台继续为单个超椭圆启用 mode 2；Windows 的
    // 安全 Shader 从编译产物中完全移除了该分支，因此这里必须回退 geometry
    // texture，不能只把未被安全 Shader 支持的 mode 继续写入 uniform。
    final supportsAnalyticSuperellipse =
        ShaderKeys.supportsAnalyticSuperellipse;
    final (radius, bottomRadius, mode) = switch (shape) {
      LiquidRoundedRectangle(:final borderRadius) => (
          borderRadius,
          borderRadius,
          1.0
        ),
      LiquidRoundedSuperellipse(:final borderRadius)
          when supportsAnalyticSuperellipse =>
        (borderRadius, borderRadius, 2.0),
      LiquidVerticalRoundedSuperellipse(:final topRadius, :final bottomRadius)
          when supportsAnalyticSuperellipse =>
        (topRadius, bottomRadius, 2.0),
      _ => (0.0, 0.0, 0.0),
    };
    if (mode == 0) return null;

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
      cornerRadius: radius,
      bottomRadius: bottomRadius,
      mode: mode,
      screenToShape: screenToShape,
    );
  }

  /// Physical-pixel rect of the compositor pass that [FlutterFragCoord()] is
  /// relative to on the live path (see [enclosingBackdropPassRect]).
  ///
  /// 中文说明：Impeller 以整物理像素分配离屏 pass 纹理，因此向外取整；
  /// 没有外层 backdrop pass 时退化为整屏，uniform 与 #333 之前完全一致。
  Rect _enclosingPassPhysicalRect(double dpr) {
    final passLogical = enclosingBackdropPassRect();
    if (passLogical == null) return Offset.zero & (desiredMatteSize * dpr);
    return Rect.fromLTRB(
      (passLogical.left * dpr).floorToDouble(),
      (passLogical.top * dpr).floorToDouble(),
      (passLogical.right * dpr).ceilToDouble(),
      (passLogical.bottom * dpr).ceilToDouble(),
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
    // 中文说明：上游 1.7 起 renderShader 可空；Shader 未就绪时不写 uniform。
    final shader = renderShader;
    if (!attached || captureImage != null || shader == null) return false;

    if (_activeAnalyticGeometry != null) {
      final analyticGeometry = _resolveAnalyticRoundedRectangle();
      if (analyticGeometry == null) return false;
      _activeAnalyticGeometry = analyticGeometry;
      // 中文说明：与 paint 相同，逆仿射平移项折算外层 pass 原点（#333）。
      final passOrigin = _enclosingPassPhysicalRect(devicePixelRatio).topLeft;
      shader.setFloatUniforms(initialIndex: 32, (value) {
        value.setFloats(shiftGeometryUniformsToPass(
          analyticGeometry.uniformValues(devicePixelRatio),
          passOrigin,
        ));
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

    shader
      ..setFloatUniforms(initialIndex: 2, (value) {
        value
          ..setOffset(_geometryLocalBounds.topLeft)
          ..setSize(_geometryLocalBounds.size);
      })
      ..setFloatUniforms(initialIndex: 32, (value) {
        value.setFloats(shiftGeometryUniformsToPass(
          textureGeometryUniforms,
          _enclosingPassPhysicalRect(devicePixelRatio).topLeft,
        ));
      });
    return true;
  }

  void _clearGeometryImage() {
    _geometryImage?.dispose();
    _geometryImage = null;
    _geometryImageCapped = false;
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
  ///     uCaptureOffset = (thisRenderOriginGlobal - captureOriginGlobal) * dpr
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
        (thisOriginLogical - captureOriginInScreenSpace) * dpr;

    // uSize: physical pixel dimensions of the captured image.
    final captureSize = ui.Size(
      capture.width.toDouble(),
      capture.height.toDouble(),
    );

    final scale = dpr / 3.0;

    renderShader!
      // Slot 0-1: uSize — physical size of the capture image.
      ..setFloatUniforms(initialIndex: 0, (value) {
        value.setSize(captureSize);
      })
      // Slots 2-5: uGeometryOffset + uGeometrySize, relative to capture origin.
      ..setFloatUniforms(initialIndex: 2, (value) {
        // 中文说明：捕获 Canvas 已统一到 layer 本地物理像素，几何纹理
        // 使用本地逻辑边界和逆 DPR 映射，不再混入截图的全局原点。
        value
          ..setOffset(_geometryLocalBounds.topLeft)
          ..setSize(_geometryLocalBounds.size);
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
      // 中文说明：捕获路径也支持解析几何，逆矩阵从当前 Canvas 本地开始。
      // 多形状继续读取原几何纹理；每次覆盖模式和矩阵，避免 Shader 残留状态。
      ..setFloatUniforms(initialIndex: 32, (value) {
        value.setFloats(_activeAnalyticGeometry?.uniformValues(dpr,
                localToScreen: matteTransform) ??
            _textureGeometryUniformValues(
                layerToScreen: Matrix4.identity(),
                geometryLocalBounds: _geometryLocalBounds,
                devicePixelRatio: dpr)!);
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
      // Slot 50: uBodyMode。中文说明：捕获路径同样逐次覆盖，避免共享
      // FragmentShader 沿用上一组件的 clear/adaptive 模式。
      ..setFloatUniforms(initialIndex: 50, (value) {
        value.setFloat(
          settings.bodyMode == GlassBodyMode.clear ? 1.0 : 0.0,
        );
      })
      // Slots 51-52: uTouchPosition (physical px); Slot 53: uTouchIntensity.
      // 中文说明：捕获路径的 FlutterFragCoord 是 layer 本地物理像素（Canvas
      // 已 scale(1/dpr)），触点同样是 layer 本地逻辑像素，乘 DPR 即可对齐。
      ..setFloatUniforms(initialIndex: 51, (value) {
        value
          ..setOffset(_touchPosition * dpr)
          ..setFloat(_touchIntensity.clamp(0.0, 1.0));
      })
      // Slot 45：捕获路径同样显式覆盖开关；关闭时仍使用原坐标背景完成
      // tint、饱和度与光照合成，只跳过折射、pinch 和色散偏移。
      ..setFloatUniforms(initialIndex: 45, (value) {
        value.setFloat(settings.refractionEnabled ? 1.0 : 0.0);
      })
      // Slot 46：显式捕获与普通 backdrop 共用最终 Shader；逐次同步区域
      // 开关，确保平台视图兼容路径也只在本地顶部约 20% 折射。
      ..setFloatUniforms(initialIndex: 46, (value) {
        value.setFloat(settings.topRefractionOnly ? 1.0 : 0.0);
      })
      // Slot 0: captured background image (replaces the BackdropFilter read).
      // 中文说明：显式 sampler 可用硬件双线性，一次读取替代四次手工读取。
      // 遮罩使用与当前 ModalBarrier 相同的动画值，快照本身保持不变。
      ..setFloatUniforms(initialIndex: 47, (value) {
        value.setFloats([1.0, captureOverlayOpacity]);
      })
      // Slot 49：显式捕获与实时 backdrop 复用同一个 FragmentShader，
      // 所以捕获路径也必须逐帧覆盖，避免复用实例残留上一 surface 的白点。
      ..setFloatUniforms(initialIndex: 49, (value) {
        value.setFloat(glassHighlightHeadroom);
      })
      ..setImageSampler(0, capture, filterQuality: FilterQuality.low)
      ..setImageSampler(
          1,
          _activeAnalyticGeometry != null
              ? _analyticSamplerImage
              : geometryImage!,
          filterQuality: FilterQuality.medium);

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
      // 中文说明：FragmentShader 的 Canvas 坐标是逻辑像素，backdrop 是物理
      // 像素。显式缩放让两种入口共享原有光学厚度与抗锯齿，不随 DPR 变形。
      ..translate(offset.dx, offset.dy)
      ..scale(1 / dpr)
      ..clipRect(Rect.fromLTRB(clipRect.left * dpr, clipRect.top * dpr,
          clipRect.right * dpr, clipRect.bottom * dpr))
      ..drawRect(
          Rect.fromLTRB(clipRect.left * dpr, clipRect.top * dpr,
              clipRect.right * dpr, clipRect.bottom * dpr),
          Paint()..shader = renderShader)
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
        ..scale(1 / _geometryImageDevicePixelRatio)
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
  ///
  /// With [capped], the matte is rasterized at [_matteDevicePixelRatio] and one
  /// more paint is requested so it settles at full resolution once the shape
  /// stops changing.
  void _updateGeometrySync(
    List<(RenderLiquidGlassGeometry, GeometryCache, Matrix4)> geometries,
    Rect bounds, {
    required bool capped,
  }) {
    final matteDevicePixelRatio =
        _matteDevicePixelRatio(bounds.size, capped: capped);

    // Record canvas commands synchronously — pure CPU work.
    final (picture, localBounds, imageSize) =
        _recordGeometryPicture(geometries, bounds, matteDevicePixelRatio);

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
      _geometryImageDevicePixelRatio = matteDevicePixelRatio;
      _geometryImageCapped = matteDevicePixelRatio < devicePixelRatio;
      // No markNeedsPaint() needed — we are already inside paint().
      if (_geometryImageCapped) _scheduleGeometrySettle();
    } finally {
      picture.dispose();
    }
  }

  /// The pixel ratio to rasterize the geometry matte at.
  ///
  /// A resting surface builds its matte once and holds it, so full resolution
  /// costs nothing per frame there and it is always rasterized at
  /// [devicePixelRatio]. An animating surface rebuilds it on every frame, and
  /// the raster thread frees each texture some frames after the UI thread
  /// allocated the next: a sheet-sized matte is ~8 MB at 3×, which at 120 Hz
  /// grows the working set by hundreds of megabytes for the length of the
  /// animation. While [capped], the matte is scaled down to at most
  /// [_kAnimatingMattePixelBudget] physical pixels. The render shader samples
  /// it through a normalized UV with bilinear filtering, so a moving edge at
  /// ~1.5× is not visibly different from 3×; a capsule or tab bar is under
  /// the budget at any pixel ratio and is untouched.
  double _matteDevicePixelRatio(Size logicalSize, {required bool capped}) {
    final dpr = devicePixelRatio;
    if (!capped) return dpr;
    final pixels = logicalSize.width * logicalSize.height * dpr * dpr;
    if (pixels <= _kAnimatingMattePixelBudget) return dpr;
    return dpr * sqrt(_kAnimatingMattePixelBudget / pixels);
  }

  /// Requests one more paint after a capped rebuild. Nothing repaints a
  /// surface once its animation stops, so without this it would rest on the
  /// last capped matte.
  void _scheduleGeometrySettle() {
    if (_settleGeometryScheduled) return;
    _settleGeometryScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _settleGeometryScheduled = false;
      if (attached && _geometryImageCapped) markNeedsPaint();
    });
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
  /// pixel size needed for rasterization at [matteDevicePixelRatio]. The
  /// caller is responsible for disposing the picture after rasterization.
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
    double matteDevicePixelRatio,
  ) {
    // Work in local coordinate space — no matteTransform applied.
    // Inflate by 2 logical pixels (= 2×DPR physical pixels after snapToPixels
    // aligns to the pixel grid) to ensure the anti-aliased SDF edge is fully
    // captured. Without this, the picture boundaries tightly crop the fractional
    // edge pixels, abruptly cutting off the rim lighting at the pill boundary.
    final localBounds = bounds.snapToPixels(devicePixelRatio).inflate(2.0);
    final size = localBounds.size * matteDevicePixelRatio;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    for (final (_, geometry, transform) in geometries) {
      canvas
        ..save()
        ..scale(matteDevicePixelRatio)
        // Shift so localBounds.topLeft is the texture origin.
        ..translate(-localBounds.left, -localBounds.top)
        // Apply geometry-local → glass-local transform only (no matteTransform).
        ..transform(transform.storage)
        // Each shape's matte is in physical pixels at the real pixel ratio.
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
    required this.bottomRadius,
    required this.mode,
  });

  final Size size;
  final double cornerRadius;
  final double bottomRadius;
  final double mode;
  final Matrix4 screenToShape;

  List<double> uniformValues(double devicePixelRatio,
      {Matrix4? localToScreen}) {
    // 中文说明：backdrop 片元在根视图；直接 Canvas 绘制的片元在玻璃层本地。
    // 两种入口共用 shape 逆矩阵，但捕获入口必须先乘回 layer→screen。
    final matrix = Matrix4.copy(screenToShape);
    if (localToScreen != null) matrix.multiply(localToScreen);
    final inverse = matrix.storage;
    return <double>[
      size.width,
      size.height,
      cornerRadius,
      mode,
      inverse[0] / devicePixelRatio,
      inverse[4] / devicePixelRatio,
      inverse[12],
      1.0, // 同时启用 Shader 中的法线屏幕方向变换。
      inverse[1] / devicePixelRatio,
      inverse[5] / devicePixelRatio,
      inverse[13],
      bottomRadius,
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
