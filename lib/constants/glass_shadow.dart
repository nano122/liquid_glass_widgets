import 'package:flutter/widgets.dart';

import '../src/renderer/poiesis_fork_policy.dart';

/// Default light-mode glass shadow values, matching iOS 26 elevation.
///
/// Used by [AdaptiveGlass] and the internal tab indicator and search pill
/// components. Centralised here to prevent drift between the
/// independent shadow wrappers.
///
/// These shadows are inverse-clipped so they only appear *outside* the
/// glass boundary, preventing the glass from blurring its own shadow.
///
/// ## Usage
///
/// ```dart
/// // Use the defaults
/// GlassShadow.defaults
///
/// // Scale the defaults
/// GlassShadow.scaled(1.5) // 50% stronger
///
/// // Disable shadows
/// GlassShadow.scaled(0.0) // empty list
/// ```
abstract final class GlassShadow {
  /// 中文说明：Poiesis 在 Impeller 上关闭所有向外投射的玻璃阴影，
  /// 只保留 Shader 内部的折射、边缘层和交互光晕。保留这项集中策略，
  /// 让 LiquidGlassSettings、底栏阴影覆盖层和 Premium SDF 路径共享同一开关，
  /// 避免某个入口继续单独创建离屏阴影。
  ///
  /// Skia/Web 由 [PoiesisForkPolicy] 切回上游 1.7.2 行为：外投影恢复启用，
  /// 与原版 `GlassShadow.scaled` / `effectiveShadow` 完全一致。
  static bool get dropShadowsEnabled => !PoiesisForkPolicy.patchesEnabled;

  /// The default elevation shadow (≈6% black, 8px blur, 2px y-offset).
  static const BoxShadow elevation = BoxShadow(
    color: Color(0x0F000000),
    blurRadius: 8,
    spreadRadius: 0,
    offset: Offset(0, 2),
  );

  /// The default contact shadow (≈2% black, 2px blur, 1px y-offset).
  static const BoxShadow contact = BoxShadow(
    color: Color(0x05000000),
    blurRadius: 2,
    spreadRadius: 0,
    offset: Offset(0, 1),
  );

  /// The unscaled default shadow list: [elevation] + [contact].
  static const List<BoxShadow> defaults = [elevation, contact];

  /// Returns the default shadows scaled by [elevation].
  ///
  /// - `0.0` → empty list (no shadow)
  /// - `1.0` → [defaults] (unchanged)
  /// - `2.0` → double opacity and blur
  ///
  /// Opacity is clamped to `0.0–1.0`; blur and offset scale linearly.
  static List<BoxShadow> scaled(double elevation) {
    // 中文说明：Impeller（Poiesis 策略）关闭外投影时直接返回空常量列表，
    // 不创建阴影对象或额外绘制层；Skia/Web 下 dropShadowsEnabled 为 true，
    // 这一行退化为上游原版的 `elevation <= 0` 判断。
    if (!dropShadowsEnabled || elevation <= 0) return const [];
    if (elevation == 1.0) return defaults;
    return [
      BoxShadow(
        color: Color.fromRGBO(0, 0, 0, (0.06 * elevation).clamp(0.0, 1.0)),
        blurRadius: 8 * elevation,
        spreadRadius: 0,
        offset: Offset(0, 2 * elevation),
      ),
      BoxShadow(
        color: Color.fromRGBO(0, 0, 0, (0.02 * elevation).clamp(0.0, 1.0)),
        blurRadius: 2 * elevation,
        spreadRadius: 0,
        offset: Offset(0, 1 * elevation),
      ),
    ];
  }
}
