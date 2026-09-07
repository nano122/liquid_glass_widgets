import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';

import '../../src/renderer/liquid_glass_renderer.dart';

import '../../theme/glass_theme.dart';
import '../../theme/glass_theme_data.dart';
import '../../types/glass_quality.dart';
import '../../utils/glass_performance_monitor.dart';
import 'glass_isolation_scope.dart';
import 'inherited_liquid_glass.dart';

/// An adaptive liquid glass layer that provides a glass background with proper
/// fallback handling across all platforms.
///
/// This is a custom replacement for `LiquidGlassLayer` that uses `AdaptiveGlass`
/// for rendering, ensuring the background uses the lightweight shader on web/Skia
/// instead of falling back to FakeGlass. On Impeller, Standard and Premium share
/// one native root layer so their descendants sample the same compositor backdrop.
///
/// **Fallback chain for background:**
/// - Standard/Premium + Impeller → Full shader + blending support
/// - Premium + Skia/web → Lightweight shader (not FakeGlass!)
/// - Standard + Skia/web → Lightweight shader
///
/// **Blending:**
/// - `blendAmount` parameter only works on Impeller (requires full renderer)
/// - On Skia, blending is ignored (widgets render separately)
/// - This matches chromatic aberration behavior (Impeller-only features)
///
/// **Usage:**
/// ```dart
/// // With explicit settings:
/// AdaptiveLiquidGlassLayer(
///   settings: LiquidGlassSettings(...),
///   quality: GlassQuality.premium,
///   shape: LiquidRoundedSuperellipse(borderRadius: 32),
///   blendAmount: 10.0, // Impeller-only
///   child: YourContent(),
/// )
///
/// // Or use theme (recommended):
/// AdaptiveLiquidGlassLayer(
///   child: YourContent(), // Uses GlassTheme settings automatically
/// )
/// ```
class AdaptiveLiquidGlassLayer extends StatefulWidget {
  /// Creates a new [AdaptiveLiquidGlassLayer].
  const AdaptiveLiquidGlassLayer({
    required this.child,
    this.shape = const LiquidRoundedSuperellipse(borderRadius: 0),
    this.settings,
    this.quality,
    this.clipBehavior = Clip.antiAlias,
    this.clipExpansion = EdgeInsets.zero,
    this.blendAmount = 10.0,
    this.platformViewBackdrop = false,
    super.key,
  });

  /// The widget to display inside the glass layer.
  final Widget child;

  /// The shape of the glass background.
  final LiquidShape shape;

  /// Glass effect settings for the background.
  ///
  /// If null, uses settings from [GlassTheme] based on current brightness.
  final LiquidGlassSettings? settings;

  /// Rendering quality for the glass effect.
  ///
  /// If null, uses quality from [GlassTheme].
  final GlassQuality? quality;

  /// Clip behavior for the glass shape.
  final Clip clipBehavior;

  /// Expansion margin for the compositor clip rect to allow jelly physics to exceed bounds.
  final EdgeInsets clipExpansion;

  /// Blend amount for smooth glass transitions (Impeller-only).
  ///
  /// Higher values create smoother blending between overlapping glass elements.
  /// Only works on Impeller - ignored on Skia (like chromatic aberration).
  ///
  /// Defaults to 10.0.
  final double blendAmount;

  /// When true (typically for iOS PlatformViews), forces the fallback rendering
  /// path (BackdropFilter) instead of the Impeller-native shader.
  final bool platformViewBackdrop;

  /// Detects if Impeller rendering engine is active.
  static bool get _canUseImpeller => ui.ImageFilter.isShaderFilterSupported;

  /// Whether the adaptive root should create the native full renderer.
  ///
  /// Standard and Premium intentionally share this decision on Impeller. The
  /// distinction between the two qualities is kept in their settings and in
  /// the adaptive policy, while the root layer must remain shared so child
  /// glass surfaces sample one consistent compositor backdrop. Skia/Web,
  /// minimal quality, and PlatformView backdrops keep the lightweight or
  /// BackdropFilter fallback path.
  @visibleForTesting
  static bool shouldUseNativeRenderer({
    required bool isImpeller,
    required bool platformViewBackdrop,
    required GlassQuality quality,
  }) {
    return isImpeller &&
        !platformViewBackdrop &&
        quality != GlassQuality.minimal;
  }

  @override
  State<AdaptiveLiquidGlassLayer> createState() =>
      _AdaptiveLiquidGlassLayerState();
}

class _AdaptiveLiquidGlassLayerState extends State<AdaptiveLiquidGlassLayer> {
  // Stable identity for the child subtree across the structural wrapper toggle
  // in build(). `useFullRenderer` (which flips with [platformViewBackdrop])
  // decides whether the child is wrapped in a [LiquidGlassBlendGroup]. Without a
  // stable key, toggling the flag changes the child's depth in the element tree,
  // so Flutter REMOUNTS the whole subtree — re-running initState on any
  // animation controllers inside it. For a bottom bar that re-seeds the
  // selected-indicator springs at their settled value, so the indicator SNAPS
  // to the new tab instead of morphing. A GlobalKey lets Flutter reparent the
  // subtree across the wrapper change (preserving the live controllers) instead.
  final GlobalKey _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    // Resolve settings: start with base defaults, apply theme partial override
    // (only non-null fields), then let explicit widget settings win entirely.
    final themeData = GlassThemeData.of(context);
    const baseSettings = LiquidGlassSettings();
    final themeOverride = themeData.settingsFor(context);
    final withTheme = themeOverride?.applyTo(baseSettings) ?? baseSettings;
    final effectiveSettings = widget.settings ?? withTheme;
    final effectiveQuality =
        widget.quality ??
        themeData.qualityFor(context) ??
        GlassQuality.standard;

    // ---- TRANSPARENT PASS-THROUGH FAST-PATHS --------------------------------
    // The fallback cases share the same pass-through structure (no
    // LiquidGlassLayer wrapper, no blend group — just InheritedLiquidGlass so
    // descendants can read settings and quality):
    //
    // 1. GlassQuality.standard / minimal:
    //    Standard 与 Minimal 的效果都由子级自己绘制，不会向 Premium
    //    GeometryRenderLink 注册任何形状。父级 LiquidGlassLayer 因而没有
    //    可见输出，只会额外创建 BackdropGroup、RepaintBoundary 与 shader
    //    构建器；直接透传可完整保留视觉，并缩短每帧合成链。
    //
    //    Minimal 还需要避免父层覆盖完整布局边界：
    //    Skips LiquidGlassLayer entirely. The layer has no shape — it wraps
    //    the full bounds including any padding around pill/circle children.
    //    Painting a BackdropFilter + tinted Container here bleeds into that
    //    padding area, creating the dark rectangle visible above/around the
    //    individual glass shapes. Glass tinting and blur come entirely from
    //    child AdaptiveGlass widgets, each rendered as _FrostedFallback with
    //    correct shape-aware clipping.
    //
    // 2. Standard on Skia/Web:
    //    Standard descendants render through LightweightLiquidGlass because
    //    ShaderFilter is unavailable. 中文说明：此处仍保持根层透传，避免在
    //    不支持原生 Shader 的渲染器上创建无效的原生合成层。
    //
    //    Standard on Impeller deliberately does not take this branch. It gets
    //    the same shared native root as Premium, otherwise each child would
    //    sample a different backdrop and the surface could become matte.
    //
    // 3. platformViewBackdrop == true (e.g. glass over an iOS map/video):
    //    LiquidGlassLayer pushes an Impeller fragment-shader ImageFilter layer.
    //    Attempting to run a shader filter over a UIKitView crashes on iOS.
    //    We bypass it entirely; child AdaptiveGlass widgets already route to
    //    _FrostedFallback (live BackdropFilter) when platformViewBackdrop is
    //    set, which correctly samples through the PlatformView compositor.
    // -------------------------------------------------------------------------
    // 中文说明：Poiesis 的 Standard 与 Premium 在 Impeller 上共用完整原生
    // 根层；质量差异留在 settings 内，避免 Standard 子玻璃各自采样不同背景。
    final bool useFullRenderer =
        AdaptiveLiquidGlassLayer.shouldUseNativeRenderer(
          isImpeller: AdaptiveLiquidGlassLayer._canUseImpeller,
          platformViewBackdrop: widget.platformViewBackdrop,
          quality: effectiveQuality,
        );

    if (!useFullRenderer) {
      return GlassIsolationScope(
        isolated: false,
        child: InheritedLiquidGlass(
          settings: effectiveSettings,
          quality: effectiveQuality,
          isBlurProvidedByAncestor: false,
          child: KeyedSubtree(key: _contentKey, child: widget.child),
        ),
      );
    }

    // Resolve shadow for SDF rendering. Shadows only apply in light mode.
    final bool isDark = GlassTheme.brightnessOf(context) == Brightness.dark;
    final List<BoxShadow> resolvedShadows = isDark
        ? const <BoxShadow>[]
        : effectiveSettings.effectiveShadow;

    // Keep the child subtree's element identity stable across the wrapper toggle
    // below (see [_contentKey]) so its animation controllers survive.
    final Widget keyedContent = KeyedSubtree(
      key: _contentKey,
      child: widget.child,
    );

    return PremiumGlassTracker(
      child: LiquidGlassLayer(
        settings: effectiveSettings,
        shadows: resolvedShadows,
        clipExpansion: widget.clipExpansion,
        child: GlassIsolationScope(
          isolated: false,
          child: InheritedLiquidGlass(
            settings: effectiveSettings,
            quality: effectiveQuality,
            isBlurProvidedByAncestor:
                false, // Root never provides the blur; containers do.
            // Standard 与 Premium 在 Impeller 下共用同一个 blend group，保证
            // 子玻璃从同一原生 backdrop 采样；Skia/Web 已在上面的回退分支
            // 中直接使用 LightweightLiquidGlass。
            child: LiquidGlassBlendGroup(
              blend: widget.blendAmount,
              child: keyedContent,
            ),
          ),
        ),
      ),
    );
  }
}
