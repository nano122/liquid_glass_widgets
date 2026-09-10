/// Common constants used throughout the liquid_glass_widgets package.
///
/// These constants define default values for glass effects, dimensions,
/// and other commonly used values to ensure consistency across widgets.
library;

import 'package:flutter/widgets.dart';

/// Default values for glass visual properties.
class GlassDefaults {
  // Prevent instantiation
  GlassDefaults._();

  // ============================================================================
  // Glass Effect Properties
  // ============================================================================

  /// Default glass thickness for most widgets (30.0)
  static const double thickness = 30.0;

  /// Default blur amount for glass effects (3.0)
  static const double blur = 3.0;

  /// Default light intensity for specular highlights (2.0)
  static const double lightIntensity = 2.0;

  /// Default chromatic aberration amount (0.5)
  static const double chromaticAberration = 0.5;

  /// Default refractive index for glass (1.15)
  static const double refractiveIndex = 1.15;

  /// Default light angle in radians (135° = 0.75 * π — Apple iOS 26 standard, upper-left light)
  static const double lightAngle = 0.75 * 3.14159265358979; // 0.75 * pi

  // ============================================================================
  // Press Interaction
  // ============================================================================

  /// Even surface brightening of a pressed button in light mode — measured at
  /// about +15 luma against a native iOS 26 press (0.3)
  static const double ambientBaseLight = 0.3;

  /// Dark-mode counterpart: the darker resting surface needs half the overlay
  /// for the same read. Estimated pending a native dark-mode capture (0.14)
  static const double ambientBaseLightDark = 0.14;

  /// The pressed lift ramps over the press inflation (150 ms)
  static const Duration ambientLiftDuration = Duration(milliseconds: 150);

  /// ...and collapses on release (60 ms)
  static const Duration ambientLiftReverseDuration = Duration(milliseconds: 60);

  // ============================================================================
  // Border Radius
  // ============================================================================

  /// Standard border radius for most glass widgets (16.0)
  static const double borderRadius = 16.0;

  /// Small border radius for compact elements (8.0)
  static const double borderRadiusSmall = 8.0;

  /// Large border radius for prominent elements (20.0)
  static const double borderRadiusLarge = 20.0;

  /// Sentinel radius that produces a perfect capsule (stadium) shape at any
  /// widget height.
  ///
  /// Internally, interactive widgets such as [GlassSegmentedControl]
  /// and [GlassTabBar] detect this value via a
  /// `>= capsuleRadius` guard and pass it straight through to the glass shader
  /// without subtracting the indicator padding inset. This guarantees a
  /// true circular pill even during jelly-bloom expansion, where the physics
  /// canvas grows well beyond the widget’s at-rest height.
  ///
  /// Use this constant instead of a raw `9999` literal:
  /// ```dart
  /// GlassTabBar.bottom(
  ///   barBorderRadius: GlassDefaults.capsuleRadius, // true capsule
  /// )
  /// ```
  ///
  /// Why 9999 and not [double.infinity]? The shader SDF receives the radius
  /// as a uniform float and guards against infinity, so a large-but-finite
  /// sentinel is the safe cross-platform choice.
  static const double capsuleRadius = 9999.0;

  // ============================================================================
  // Padding
  // ============================================================================

  /// Standard padding for card-like widgets
  static const EdgeInsets paddingCard = EdgeInsets.all(16.0);

  /// Standard padding for panel-like widgets
  static const EdgeInsets paddingPanel = EdgeInsets.all(24.0);

  /// Standard padding for input fields
  static const EdgeInsets paddingInput =
      EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0);

  /// Compact padding for small elements
  static const EdgeInsets paddingCompact = EdgeInsets.all(8.0);

  /// Minimal padding for tight layouts
  static const EdgeInsets paddingMinimal = EdgeInsets.all(4.0);

  // ============================================================================
  // Dimensions
  // ============================================================================

  /// Standard height for interactive controls (32.0)
  static const double heightControl = 32.0;

  /// Standard height for buttons (48.0)
  static const double heightButton = 48.0;

  /// Standard height for input fields (48.0)
  static const double heightInput = 48.0;

  // ============================================================================
  // Animation Durations
  // ============================================================================

  /// Standard animation duration for glass effects (200ms)
  static const Duration animationDuration = Duration(milliseconds: 200);

  /// Fast animation duration for quick transitions (100ms)
  static const Duration animationDurationFast = Duration(milliseconds: 100);

  /// Slow animation duration for deliberate effects (300ms)
  static const Duration animationDurationSlow = Duration(milliseconds: 300);

  /// Entrance duration of the materialize glass transition (250ms).
  ///
  /// Measured from iOS 26's `glassEffectTransition(.materialize)` in a 120fps
  /// capture of the native navigation bar: the glass fades up from nothing to
  /// settled in roughly a quarter second.
  static const Duration materializeDuration = Duration(milliseconds: 250);

  /// Exit duration of the materialize glass transition (350ms).
  ///
  /// The native dematerialize runs noticeably longer than the entrance — the
  /// content blurs away first and the glass dissolves after it.
  static const Duration dematerializeDuration = Duration(milliseconds: 350);

  // ============================================================================
  // Overlay / Compositor
  // ============================================================================

  /// Barrier colour for modal overlays (sheets, action sheets).
  /// iOS 26 uses 54% black to dim content behind modals.
  static const Color barrierColor = Color(0x8A000000); // ~54% black

  /// Specular tint applied to drag handles and pill surfaces (light mode).
  static const double specularLightAlpha = 0.15;

  /// Specular tint applied to drag handles and pill surfaces (dark mode).
  static const double specularDarkAlpha = 0.10;

  // ============================================================================
  // Outer Drop Shadow (GlassButton & interactive controls)
  // ============================================================================

  /// 外部阴影模糊半径（12.0，柔和大范围扩散）
  static const double outerShadowBlurRadius = 12.0;

  /// 外部阴影纵向偏移（2.0）
  static const Offset outerShadowOffset = Offset(0.0, 2.0);

  /// 外部阴影亮色模式颜色。
  /// 中文说明：针对页面暖奶灰大底色（0xFFFAF9F6，原生 B 通道比 R 低 4 个点）
  /// 进行反向穿透冷色补偿，采用带深冷微蓝的高级冷灰阴影 Color(0x0E0E1C44)（约 5.5% 不透明度）。
  /// 在羽化扩散区与暖底叠加后，精确消除纯黑阴影产生的泛黄偏色，
  /// 使实测像素稳定呈现 R=224, G=224, B=229（B 通道高出约 5 个点）的通透微冷质感。
  static const Color outerShadowColorLight = Color(0x0E0E1C44);

  /// 外部阴影暗色模式颜色（10% 纯黑，温和不厚重）
  static const Color outerShadowColorDark = Color(0x1A000000);

  /// 根据当前亮度模式获取默认外部投影 [BoxShadow]
  static BoxShadow defaultOuterShadow(Brightness brightness) {
    return BoxShadow(
      color: brightness == Brightness.dark
          ? outerShadowColorDark
          : outerShadowColorLight,
      blurRadius: outerShadowBlurRadius,
      offset: outerShadowOffset,
    );
  }
}
