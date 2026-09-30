// ignore_for_file: public_member_api_docs
// ignore_for_file: deprecated_member_use
// Shared internal sub-widgets for GlassTabBar.bottom and GlassTabBar.searchable.
//
// NOT part of the public API — do not export from liquid_glass_widgets.dart.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../../widgets/shared/glass_focus_region.dart';
import '../../../constants/glass_defaults.dart';
import '../../renderer/liquid_glass_renderer.dart';
import '../../renderer/poiesis_fork_policy.dart';
import '../../../theme/glass_theme.dart';
import '../../../types/glass_quality.dart';
import '../../../utils/draggable_indicator_physics.dart';
import 'tab_bar_drag_gesture_mixin.dart';
import '../../../utils/glass_spring.dart';
import '../../../widgets/interactive/glass_button.dart';
import '../../../widgets/overlays/glass_menu.dart' show GlassMenu;
import '../../../widgets/shared/adaptive_glass.dart';
import '../../../widgets/shared/animated_glass_indicator.dart';
import '../../../widgets/shared/inherited_liquid_glass.dart';
import '../../../widgets/surfaces/shared/tab_bar_extra_button.dart'
    show GlassTabBarExtraButton;
import '../../../widgets/surfaces/shared/tab_bar_types.dart'
    show MaskingQuality, JellyClipper;
import '../../../widgets/surfaces/glass_tab_bar.dart' show GlassTab;

// =============================================================================
// kBottomBarGlassDefaults — shared glass preset
// =============================================================================

/// Default [LiquidGlassSettings] for both [GlassTabBar.bottom] and
/// [GlassTabBar.searchable].
///
/// Centralised here so that both bars are guaranteed to produce visually
/// identical glass when placed on the same screen — there is no risk of
/// the two copies drifting apart during maintenance.
///
/// Values are tuned to the iOS 26 Apple News / Safari tab bar aesthetic:
/// - `thickness: 30` — deep refraction without over-distorting icons.
/// - `blur: 3` — subtle frosted back-blur.
/// - `refractiveIndex: 1.59` — polycarbonate-grade refraction.
/// - `lightAngle: 0.75π` (135°) — Apple standard upper-left key light.
const kBottomBarGlassDefaults = LiquidGlassSettings(
  thickness: 30,
  blur: 3,
  chromaticAberration: 0.3,
  lightIntensity: 0.6,
  refractiveIndex: 1.59,
  saturation: 0.7,
  ambientStrength: 1,
  lightAngle: 0.75 * math.pi,
  glassColor: Color(0x3DFFFFFF),
);

// =============================================================================
// resolveBarLabelColor — shared icon/label color resolution
// =============================================================================

/// Resolves the dynamic icon/label color for both bars.
///
/// In the classic path ([darkAmount] null) this is the Cupertino label color
/// resolved against the ambient brightness — identical to the historical
/// behavior. When the content-aware brightness machinery is active,
/// [darkAmount] is the animated light→dark cross-fade position, and the
/// color interpolates between the label's light and dark variants so glyphs
/// fade with the rest of the appearance instead of snapping. Non-dynamic
/// custom label colors have no variants to fade between and are returned
/// as-is.
Color resolveBarLabelColor(BuildContext context, double? darkAmount) {
  final labelColor = CupertinoTheme.of(context).textTheme.textStyle.color ??
      CupertinoColors.label;
  if (darkAmount != null && labelColor is CupertinoDynamicColor) {
    // Content-aware path: animated cross-fade between light/dark variants.
    return Color.lerp(labelColor.color, labelColor.darkColor, darkAmount)!;
  }
  // Static path: resolve any CupertinoDynamicColor eagerly using the glass
  // brightness cascade. CupertinoDynamicColor returned unresolved works for
  // BottomBarTabItem (IconTheme resolves it during painting), but breaks for
  // SearchPill icons where .value is always the light-mode black. Using
  // GlassTheme.brightnessOf() — the package's single brightness authority —
  // ensures dark glass always produces white glyphs regardless of system brightness.
  if (labelColor is CupertinoDynamicColor) {
    final brightness = GlassTheme.brightnessOf(context);
    return brightness == Brightness.dark
        ? labelColor.darkColor
        : labelColor.color;
  }
  return labelColor;
}

// =============================================================================
// buildIconShadows — pure utility function (visibleForTesting for unit tests)
// =============================================================================

/// Builds multi-directional icon shadows that simulate a stroke/outline effect.
///
/// Returns `null` (no shadow) when:
/// - [thickness] is null (feature not requested), or
/// - [selected] is true AND [activeIcon] is non-null (distinct active icon
///   is used so outline shadow is not needed in that state).
///
/// Otherwise, generates 8 evenly-spaced [Shadow] offsets around the icon at
/// the given [thickness] radius using 45° increments.
///
/// Extracted from [BottomBarTabItem] to enable isolated unit testing.
@visibleForTesting
List<Shadow>? buildIconShadows({
  required Color iconColor,
  required double? thickness,
  required bool selected,
  required Widget? activeIcon,
}) {
  if (thickness == null || (selected && activeIcon != null)) return null;
  final shadows = <Shadow>[];
  const step = math.pi / 4;
  for (double a = 0; a < math.pi * 2; a += step) {
    shadows.add(Shadow(
      color: iconColor,
      offset: Offset.fromDirection(a, thickness),
    ));
  }
  return shadows;
}

// =============================================================================
// BottomBarTabItem — shared tab item widget
// =============================================================================

/// Renders a single tab item for [GlassTabBar.bottom] and [GlassTabBar.searchable].
///
/// Previously duplicated as `_BottomBarTab` and `_TabItem`. Single source of truth.
class BottomBarTabItem extends StatelessWidget {
  const BottomBarTabItem({
    required this.tab,
    required this.selected,
    this.semanticsSelected,
    required this.selectedIconColor,
    required this.unselectedIconColor,
    this.selectedLabelColor,
    this.unselectedLabelColor,
    this.selectedLabelStyle,
    this.unselectedLabelStyle,
    required this.iconSize,
    required this.textStyle,
    required this.labelFontSize,
    required this.iconLabelSpacing,
    required this.glowDuration,
    required this.glowBlurRadius,
    required this.glowSpreadRadius,
    required this.glowOpacity,
    required this.onTap,
    this.semanticOnTap,
    super.key,
  });

  final GlassTab tab;
  final bool selected;
  final bool? semanticsSelected;
  final Color selectedIconColor;
  final Color unselectedIconColor;
  final Color? selectedLabelColor;
  final Color? unselectedLabelColor;

  /// Per-state label text style. Merged over the base label style, so it can
  /// override font family / weight / letter-spacing while keeping the resolved
  /// [selectedLabelColor] / [unselectedLabelColor] (unless the style sets its
  /// own color). Null leaves the existing behavior unchanged.
  final TextStyle? selectedLabelStyle;
  final TextStyle? unselectedLabelStyle;

  final double iconSize;
  final TextStyle? textStyle;

  /// Font size for tab labels when [textStyle] is null.
  ///
  /// Mirrors [iconSize] as an explicit sizing knob. Defaults to 11.
  /// Reduce to 10 for bars with 4+ tabs or long label text.
  final double labelFontSize;
  final double iconLabelSpacing;
  final Duration glowDuration;
  final double glowBlurRadius;
  final double glowSpreadRadius;
  final double glowOpacity;
  // Nullable: when null the GestureDetector does not handle taps.
  // Pass null in contexts where the outer TabIndicator owns selection via
  // onTapDown, and accessibility is handled by the indicator's own Semantics.
  final VoidCallback? onTap;

  /// Activation for assistive technology and the keyboard, independent of the
  /// pointer path.
  ///
  /// The bottom and searchable bars own selection on the indicator's own
  /// `onTapDown`, so every tab is built with a null [onTap] and the
  /// [GestureDetector] here is excluded from semantics. Without this the tab's
  /// node is a button with a selected state and no [SemanticsAction.tap]:
  /// TalkBack and VoiceOver read every destination and can activate none, and
  /// a focused tab does not answer Enter or Space either.
  ///
  /// The layout passes `() => onTabSelected(i)`. It never takes pointer input,
  /// so the bar's own drag gesture is untouched.
  final VoidCallback? semanticOnTap;

  @override
  Widget build(BuildContext context) {
    final iconColor = selected ? selectedIconColor : unselectedIconColor;
    final iconWidget = selected ? (tab.activeIcon ?? tab.icon) : tab.icon;
    final bool hasIcon = iconWidget != null;

    // Label style resolution — most-specific-wins:
    //   1. Base typography: caller [textStyle], else the built-in default keyed
    //      to the per-state icon color.
    //   2. An explicit per-state label color
    //      ([selectedLabelColor]/[unselectedLabelColor]) overrides the base
    //      color — including a color baked into [textStyle] — since it's the more
    //      specific intent. When null, textStyle's own color (or the icon-color
    //      default) stands.
    //   3. The per-state [selectedLabelStyle]/[unselectedLabelStyle] merges last,
    //      so a caller can set a heavier/different selected font on top.
    var baseLabelStyle = textStyle ??
        TextStyle(
          color: iconColor,
          fontSize: labelFontSize,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        );
    final perStateLabelColor =
        selected ? selectedLabelColor : unselectedLabelColor;
    if (perStateLabelColor != null) {
      baseLabelStyle = baseLabelStyle.copyWith(color: perStateLabelColor);
    }
    final stateLabelStyle =
        selected ? selectedLabelStyle : unselectedLabelStyle;
    final resolvedLabelStyle = stateLabelStyle != null
        ? baseLabelStyle.merge(stateLabelStyle)
        : baseLabelStyle;

    return GlassFocusRegion(
      enabled: true,
      isButton: true,
      tracksSelection: true,
      isSelected: semanticsSelected ?? selected,
      semanticLabel: tab.semanticLabel ?? tab.label ?? 'Tab',
      onKeyboardActivate: onTap ?? semanticOnTap,
      // The GestureDetector below is excluded from semantics, so the tap
      // action has to be declared here or the node carries none at all.
      semanticOnTap: onTap ?? semanticOnTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: GestureDetector(
        // onTap may be null when selection is owned by the outer TabIndicator
        // (visual path). When non-null it provides accessibility support for
        // VoiceOver / TalkBack which route through onTap, not onTapDown.
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              spacing: hasIcon ? iconLabelSpacing : 0,
              children: [
                if (hasIcon)
                  ExcludeSemantics(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (tab.glowColor != null)
                          Positioned(
                            top: -24,
                            right: -24,
                            left: -24,
                            bottom: -24,
                            child: RepaintBoundary(
                              child: AnimatedContainer(
                                duration: glowDuration,
                                transformAlignment: Alignment.center,
                                curve: Curves.easeOutCirc,
                                transform: selected
                                    ? Matrix4.identity()
                                    : (Matrix4.identity()
                                      ..scale(0.4)
                                      ..rotateZ(-math.pi)),
                                child: AnimatedOpacity(
                                  duration: glowDuration,
                                  opacity: selected ? 1 : 0,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: tab.glowColor!.withOpacity(
                                            selected ? glowOpacity : 0,
                                          ),
                                          blurRadius: glowBlurRadius,
                                          spreadRadius: glowSpreadRadius,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        IconTheme(
                          data: IconThemeData(
                            color: iconColor,
                            size: iconSize,
                            // Use the extracted top-level function for testability
                            shadows: buildIconShadows(
                              iconColor: iconColor,
                              thickness: tab.thickness,
                              selected: selected,
                              activeIcon: tab.activeIcon,
                            ),
                          ),
                          child: DefaultTextStyle(
                            style: DefaultTextStyle.of(context)
                                .style
                                .copyWith(color: iconColor),
                            child: iconWidget,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (tab.label != null)
                  // The enclosing Semantics already announces the tab, so the
                  // label text would otherwise be merged in a second time —
                  // announcing 'Home' as 'Home\nHome', and demoting
                  // semanticLabel from an override to a prefix.
                  ExcludeSemantics(
                    child: Text(
                      tab.label!,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: resolvedLabelStyle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// BottomBarExtraBtn — shared extra button widget
// =============================================================================

/// Renders the extra action button using [GlassButton].
///
/// Previously duplicated as `_ExtraButton` and `_ExtraBtn`. Single source of truth.
class BottomBarExtraBtn extends StatelessWidget {
  const BottomBarExtraBtn({
    required this.config,
    required this.quality,
    required this.iconColor,
    this.enableBlend = false,
    this.borderRadius,
    this.platformViewBackdrop = false,
    super.key,
  });

  final GlassTabBarExtraButton config;
  final GlassQuality quality;
  final Color iconColor;
  final bool enableBlend;
  final double? borderRadius;

  /// When true, routes rendering through the frosted fallback (live
  /// [BackdropFilter]) instead of the Impeller-native shader. Required when
  /// the button floats over an iOS PlatformView (e.g. a map) — the shader
  /// paths read a captured backdrop that excludes the platform view, so they
  /// render inert there. Matches [GlassButton.platformViewBackdrop].
  final bool platformViewBackdrop;

  @override
  Widget build(BuildContext context) {
    // Shape selection for the frosted fallback (BackdropFilter) path:
    //
    // When platformViewBackdrop is true, LiquidOval is swapped for
    // LiquidRoundedRectangle (radius = size / 2). Both produce a circle,
    // but AdaptiveGlass forwards LiquidRoundedRectangle's ClipRRect to the
    // PlatformView mutator stack. This constrains the UIKitView
    // compositing sample area to the circle boundary, preventing a rectangular
    // "light square" bleed from the BackdropFilter's rectangular capture region.
    // LiquidOval relies on a shader-side SDF clip which the mutator stack cannot
    // propagate to the native view layer, so it must not be used here.
    final effectiveShape = borderRadius != null
        ? LiquidRoundedRectangle(borderRadius: borderRadius!)
        : (platformViewBackdrop
            ? LiquidRoundedRectangle(borderRadius: config.size / 2)
            : const LiquidOval());

    Widget buildButton(VoidCallback onTap) {
      return GlassButton(
        icon: config.icon,
        onTap: onTap,
        label: config.label,
        width: config.size,
        height: config.size,
        quality: quality,
        iconColor: iconColor,
        useOwnLayer: !enableBlend, // When blending, share the parent's layer
        shape: effectiveShape,
        platformViewBackdrop: platformViewBackdrop,
        stretch: platformViewBackdrop ? 0.0 : 0.5,
        // The extra button is anchored inside the compound bar and does not
        // animate its layout bounds at rest. Marking it stationary lets
        // AdaptiveGlass retain the BackdropFilter blur in GlassQuality.minimal,
        // so it matches the frosted appearance of the main tab bar surface.
        // See: https://github.com/sdegenaar/liquid_glass_widgets/issues/203
        isStationary: true,
        enabled: config.enabled,
      );
    }

    if (config.isMenu) {
      return GlassMenu(
        menuAlignment: config.menuAlignment,
        menuWidth: config.menuWidth,
        autoAdjustToScreen: true,
        items: config.menuItems!,
        triggerBuilder: (context, toggleMenu) => buildButton(toggleMenu),
      );
    }

    return buildButton(config.onTap);
  }
}

// =============================================================================
// TabIndicator — draggable pill indicator with spring physics
// =============================================================================

/// Internal widget that manages the draggable indicator with physics.
///
/// Extracted from [GlassTabBar.bottom] to keep the public widget focused on layout
/// and configuration, while this widget owns all gesture, animation, and
/// rendering logic for the tab indicator pill.
///
/// Responsibilities:
/// - Horizontal drag gesture handling ([GestureDetector] + [Listener])
/// - Spring-based alignment animation ([VelocitySpringBuilder])
/// - Jelly deformation during drag ([SpringBuilder] + thickness)
/// - Dual rendering modes: [MaskingQuality.off] and [MaskingQuality.high]
/// iOS 底部导航选中胶囊静止时保留的玻璃可见度。
///
/// 中文说明：数值保持克制，避免选中态抢过整块底栏的主体高光。
const double kIosRestingIndicatorGlassVisibility = 0.18;

/// 底部导航选中胶囊在静止时的玻璃可见度（0 表示静止为实色填充）。
///
/// 中文说明：静止玻璃会让选中胶囊每帧常驻一层带背景采样的玻璃 Pass。
/// 安卓真机 A/B（2026-09-28）显示仅关闭这一项，概要页 96→113、AI 页
/// 72→82 帧，是 HDR 合并后掉帧的主因；而安卓不支持 EDR 高光，静止玻璃
/// 的视觉收益有限。因此只在原生 iOS 保留，其余平台（含 Web）恢复上游
/// “静止实色、交互时才绘制玻璃”：AnimatedGlassIndicator 在 fade ≤ 0.01
/// 时直接输出空占位，静止状态不再产生任何玻璃 Pass。
@visibleForTesting
double restingIndicatorGlassVisibilityFor({
  required TargetPlatform platform,
  required bool isWeb,
}) {
  if (isWeb || platform != TargetPlatform.iOS) {
    return 0.0;
  }
  return kIosRestingIndicatorGlassVisibility;
}

class TabIndicator extends StatefulWidget {
  const TabIndicator({
    required this.childUnselected,
    required this.selectedTabBuilder,
    required this.tabIndex,
    required this.tabCount,
    required this.onTabChanged,
    required this.visible,
    required this.indicatorColor,
    required this.quality,
    this.backgroundQuality,
    required this.barHeight,
    required this.barBorderRadius,
    this.indicatorBorderRadius,
    required this.tabPadding,
    required this.magnification,
    required this.innerBlur,
    required this.maskingQuality,
    this.indicatorSettings,
    this.backgroundKey,
    this.indicatorExpansion = const EdgeInsets.all(8.0),
    this.indicatorPinchStrength = 1.0,
    this.interactionGlowColor,
    this.interactionGlowRadius = 1.5,
    this.interactionGlowBlurRadius = 0,
    this.interactionGlowSpreadRadius = 0,
    this.interactionGlowOpacity = 1,
    this.interactionScale = 1.0,
    this.platformViewBackdrop = false,
    this.springDescription,
    super.key,
  });

  final int tabIndex;
  final int tabCount;
  final bool visible;
  final Widget childUnselected;
  final Widget Function(BuildContext, double, Alignment) selectedTabBuilder;
  final Color? indicatorColor;
  final LiquidGlassSettings? indicatorSettings;
  final ValueChanged<int> onTabChanged;
  final GlassQuality quality;
  final GlassQuality? backgroundQuality;
  final double barHeight;
  final double barBorderRadius;
  final double? indicatorBorderRadius;
  final EdgeInsetsGeometry tabPadding;
  final double magnification;
  final double innerBlur;
  final MaskingQuality maskingQuality;
  final SpringDescription? springDescription;
  final GlobalKey? backgroundKey;

  /// How far the jelly indicator's leading and trailing edges expand
  /// past the tab boundary as the indicator translates. Higher values
  /// give a more dramatic "puff" stretch; lower values produce a
  /// tighter, more iOS-native feel. Defaults to `14` to match the
  /// pre-existing visual.
  final EdgeInsetsGeometry indicatorExpansion;

  /// Maximum concave lens pinch strength for the animated pill.
  /// Forwarded directly to [AnimatedGlassIndicator.pinchStrength].
  final double indicatorPinchStrength;

  final Color? interactionGlowColor;
  final double interactionGlowRadius;
  final double interactionGlowBlurRadius;
  final double interactionGlowSpreadRadius;
  final double interactionGlowOpacity;

  /// The scale factor applied by [LiquidStretch] on press.
  ///
  /// Pass `1.0` to disable scaling. Resolved by the parent widget from
  /// [GlassInteractionBehavior] before being forwarded here.
  final double interactionScale;

  /// When true, forces BackdropFilter rendering and refracts the icon layer
  /// instead of the backdrop — needed over iOS PlatformViews.
  final bool platformViewBackdrop;

  @override
  State<TabIndicator> createState() => TabIndicatorState();
}

/// State for [TabIndicator]. Public for testing via `@visibleForTesting`.
@visibleForTesting
class TabIndicatorState extends State<TabIndicator>
    with TabDragGestureMixin<TabIndicator> {
  // ── Mixin interface ────────────────────────────────────────────────────────
  @override
  int get tabCount => widget.tabCount;
  @override
  int get tabIndex => widget.tabIndex;
  @override
  bool get isPlatformViewBackdrop => widget.platformViewBackdrop;
  @override
  void notifyTabChanged(int index) => widget.onTabChanged(index);

  // 中文说明：上游 1.7.2（#344）改为按 GlassTheme.brightnessOf 解析默认指示器颜色，
  // 旧的固定白色回退常量已无引用，因此只保留 Poiesis 的静止玻璃可见度。
  // 底部导航选中胶囊静止时是否保留玻璃材质按平台决定（仅原生 iOS 保留），
  // 详见 [restingIndicatorGlassVisibilityFor] 的安卓掉帧 A/B 说明。
  static double get _restingIndicatorGlassVisibility =>
      restingIndicatorGlassVisibilityFor(
        platform: defaultTargetPlatform,
        isWeb: kIsWeb,
      );

  /// 选中/未选中图标层的果冻裁剪方式。
  ///
  /// 中文说明：上游使用 [Clip.antiAliasWithSaveLayer]，底栏每帧因此多出两个
  /// 与底栏等大的离屏 saveLayer（未选中层 + 选中层各一个），在 Impeller GLES
  /// 上各对应一次独立 render pass 的开启、结束与回贴，底栏出现在所有主页面，
  /// 这部分开销每帧都要付（见 docs/performance/20260930-gpu/REPORT.md）。
  ///
  /// Impeller 的裁剪基于模板缓冲，边缘抗锯齿由 MSAA 统一提供，离屏层内外的
  /// 裁剪边缘质量相同；被裁剪的只是互不重叠的图标与文字，没有需要先合成
  /// 再整体裁剪的半透明叠加，所以改为 [Clip.antiAlias] 视觉上等价。
  /// Skia/Web 仍回到上游 1.7.2 的 saveLayer 裁剪，保持官方视觉基线。
  @visibleForTesting
  static Clip get jellyClipBehavior => PoiesisForkPolicy.patchesEnabled
      ? Clip.antiAlias
      : Clip.antiAliasWithSaveLayer;

  final GlobalKey _iconLayerKey = GlobalKey();

  // Cached shape to avoid recreation on every animation frame
  late LiquidShape _barShape = _buildBarShape(widget.barBorderRadius);

  /// 按渲染器选择底栏外壳形状。
  ///
  /// 中文说明：超椭圆底栏是 Poiesis 针对 Impeller 原生玻璃层的视觉补丁；
  /// Skia/Web 回到上游 1.7.2 的 [LiquidRoundedRectangle]，与轻量 Shader
  /// 的圆角矩形 SDF 保持一致。
  static LiquidShape _buildBarShape(double borderRadius) =>
      PoiesisForkPolicy.patchesEnabled
          ? LiquidRoundedSuperellipse(borderRadius: borderRadius)
          : LiquidRoundedRectangle(borderRadius: borderRadius);

  /// 构建底栏玻璃底板。
  ///
  /// 中文说明：Impeller（Poiesis）下底板直接作为共享玻璃层的几何节点参与
  /// 合成——当前配方 blur 为 0，额外 RepaintBoundary 不提供模糊缓存收益，
  /// 直接注册可减少一层无必要的合成隔离。Skia/Web 回到上游 1.7.2：用
  /// RepaintBoundary 缓存底板，避免拖动胶囊时重复栅格化模糊。
  /// 两种模式都采用上游 1.6 新增的 backgroundQuality，允许底板与指示器
  /// 分别指定质量。
  Widget _buildBarBackground() {
    final background = AdaptiveGlass.grouped(
      quality: widget.backgroundQuality ?? widget.quality,
      platformViewBackdrop: widget.platformViewBackdrop,
      shape: _barShape,
      child: const SizedBox.expand(),
    );
    if (PoiesisForkPolicy.patchesEnabled) return background;
    return RepaintBoundary(child: background);
  }

  @override
  void didUpdateWidget(covariant TabIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateTabAlignIfNeeded(oldWidget.tabIndex, oldWidget.tabCount);

    // Update cached shape if border radius changes
    if (oldWidget.barBorderRadius != widget.barBorderRadius) {
      _barShape = _buildBarShape(widget.barBorderRadius);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = GlassTheme.brightnessOf(context);
    final indicatorColor = widget.indicatorColor ??
        (brightness == Brightness.dark
            ? CupertinoColors.white.withValues(alpha: .1)
            : CupertinoColors.black.withValues(alpha: .1));
    final targetAlignment = computeTabAlignment(widget.tabIndex);

    // Nested-arc default: if the outer bar is a capsule sentinel (≥ 9999),
    // the indicator is also passed 9999 directly, so the glass shader clamps to
    // a true capsule even during jelly-bloom expansion (where the pill canvas
    // grows beyond its rest size and a finite radius would appear boxy).
    // For custom radii (e.g. GlassTabBar.bottom default 32), the indicator subtracts
    // the padding inset (4 px) to produce concentric nested arcs (32 − 4 = 28).
    // An explicit indicatorBorderRadius always takes priority.
    const indicatorPadding = 4.0;
    final indicatorRadius = widget.indicatorBorderRadius ??
        (widget.barBorderRadius >= GlassDefaults.capsuleRadius
            ? GlassDefaults.capsuleRadius
            : (widget.barBorderRadius - indicatorPadding).clamp(
                0.0,
                GlassDefaults.capsuleRadius,
              ));

    // Lateral sway: the bar body subtly follows the interactive pill during
    // horizontal drags, mimicking iOS 26 bottom bar physics. The SpringBuilder
    // animates the offset back to 0.0 when the drag ends.
    return SpringBuilder(
      spring: GlassSpring.smooth(
        duration: const Duration(milliseconds: 250),
      ),
      value: barSwayOffset,
      builder: (context, swayValue, _) {
        return Transform.translate(
          offset: Offset(swayValue, 0),
          child: LiquidStretch(
            interactionScale: widget.interactionScale,
            stretch:
                0.0, // stretch disabled on platformViewBackdrop to prevent BackdropFilter pixel-snap jitter
            resistance: 0.08,
            anchorStretch: false, // Tab bars use jelly-follow, not anchored
            child: Listener(
              // Raw pointer events fire BEFORE gesture recognizers and never compete
              // in the gesture arena, so tabIsDown is always set on the very first event.
              onPointerDown: (e) => onBarPointerDown(e.position),
              onPointerUp: (e) => onBarPointerUp(e.position),
              onPointerCancel: (e) => onBarPointerCancel(e.position),
              child: GestureDetector(
                key: ValueKey(gestureEpoch),
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onHorizontalDragDown: onBarDragDown,
                onHorizontalDragStart: onBarDragStart,
                onHorizontalDragUpdate: onBarDragUpdate,
                onHorizontalDragEnd: onBarDragEnd,
                // On cancel (e.g. parent scroll steals the gesture or pointer goes
                // off-screen), tabIsDown is cleared by the Listener when pointer lifts.
                onHorizontalDragCancel: onBarDragCancel,
                onTapDown:
                    onBarTapDown, // DX1: makes jelly visible on desktop taps
                onTapUp: onBarTapUp,
                onTapCancel: onBarTapCancel,
                child: VelocitySpringBuilder(
                  value: tabXAlign,
                  springWhenActive: GlassSpring.interactive(),
                  springWhenReleased: widget.springDescription ??
                      GlassSpring.snappy(
                        duration: const Duration(milliseconds: 350),
                      ),
                  active: tabIsDragging,
                  builder: (context, value, velocity, child) {
                    // tabXAlign is a PHYSICAL coordinate (−1 = physical left,
                    // +1 = physical right) — always. Use Alignment (not
                    // AlignmentDirectional) so that Flutter does not re-apply
                    // the RTL flip and land the pill on the mirror-image tab.
                    final alignment = Alignment(value, 0);

                    return SpringBuilder(
                      spring: GlassSpring.snappy(
                        duration: const Duration(milliseconds: 300),
                      ),
                      // Keep thickness active while:
                      //  - tabIsDown (tap pressed, 420 ms window for spring travel), OR
                      //  - tabIsDragging (finger is physically moving — keep glass alive
                      //    even when passing back over the selected tab), OR
                      //  - the spring still has meaningful separation from target.
                      // Threshold 0.05 (was 0.10) catches the full deceleration tail.
                      value: widget.visible &&
                              (tabIsDown ||
                                  tabIsDragging ||
                                  (value - targetAlignment).abs() > 0.05)
                          ? 1.0
                          : 0.0,
                      builder: (context, thickness, child) {
                        // Lazy evaluation optimization: skip expensive calculations when hidden
                        if (thickness < 0.01 &&
                            !widget.visible &&
                            widget.maskingQuality == MaskingQuality.high) {
                          // Fast path: indicator is hidden, render simple layout
                          return Container(
                            height: widget.barHeight,
                            decoration: ShapeDecoration(
                              shape: _barShape,
                            ),
                            child: AdaptiveGlass.grouped(
                              quality:
                                  widget.backgroundQuality ?? widget.quality,
                              platformViewBackdrop: widget.platformViewBackdrop,
                              shape: _barShape,
                              child: Container(
                                padding: widget.tabPadding,
                                child: widget.childUnselected,
                              ),
                            ),
                          );
                        }

                        // Calculate jelly transform for the clipper (only when needed)
                        final jellyTransform =
                            DraggableIndicatorPhysics.buildJellyTransform(
                          velocity: Offset(velocity, 0),
                          maxDistortion: 0.8,
                          velocityScale: 10,
                        );

                        // Switch rendering mode based on masking quality
                        switch (widget.maskingQuality) {
                          case MaskingQuality.off:
                            return _buildSimpleMode(
                              alignment: alignment,
                              // Same physical-coordinate reasoning as above:
                              // targetAlignment is a physical x-value.
                              targetAlignment: Alignment(targetAlignment, 0),
                              thickness: thickness,
                              velocity: velocity,
                              indicatorRadius: indicatorRadius,
                              indicatorColor: indicatorColor,
                            );

                          case MaskingQuality.high:
                            return _buildHighQualityMode(
                              alignment: alignment,
                              thickness: thickness,
                              velocity: velocity,
                              jellyTransform: jellyTransform,
                              indicatorRadius: indicatorRadius,
                              indicatorColor: indicatorColor,
                            );
                        }
                      },
                    ); // SpringBuilder (thickness)
                  }, // VelocitySpringBuilder builder
                ), // VelocitySpringBuilder
              ), // GestureDetector
            ), // Listener
          ), // LiquidStretch
        ); // Transform.translate
      }, // SpringBuilder builder (sway)
    ); // SpringBuilder (sway)
  }

  /// Wraps the bar pill with a light-mode drop shadow using inverse clipping.
  ///
  /// Builds a standalone shadow widget for the tab pill.
  ///
  /// Rendered as a SIBLING in the parent Stack, BELOW the glass pill,
  /// so it doesn't interfere with the blend group compositing.
  /// Returns null in dark mode or when no shadow is configured.
  Widget? buildShadowOverlay(BuildContext context) {
    final isDark = GlassTheme.brightnessOf(context) == Brightness.dark;
    if (isDark) return null;

    final effectiveSettings = InheritedLiquidGlass.ofOrDefault(context);
    final shadows = effectiveSettings.effectiveShadow;
    if (shadows.isEmpty) return null;

    return IgnorePointer(
      child: ClipPath(
        clipBehavior: Clip.antiAlias,
        clipper: _InverseBarClipper(_barShape),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius:
                GlassDefaults.safeBorderRadius(widget.barBorderRadius),
            boxShadow: shadows,
          ),
        ),
      ),
    );
  }

  /// Wraps [child] in a [GlassGlow] sensor if the resolved glow color is
  /// non-transparent. When [GlassInteractionBehavior.none] or [scaleOnly] is
  /// active, the parent passes [Colors.transparent] — we skip the wrapper
  /// entirely to avoid three extra widget/render-object allocations per frame.
  Widget _wrapWithGlow({required Widget child}) {
    final effectiveColor =
        widget.interactionGlowColor ?? const Color(0x1FFFFFFF);
    if (effectiveColor.a == 0) return child;
    return GlassGlow(
      clipper: ShapeBorderClipper(shape: _barShape),
      glowColor: effectiveColor,
      glowRadius: widget.interactionGlowRadius,
      glowBlurRadius: widget.interactionGlowBlurRadius,
      glowSpreadRadius: widget.interactionGlowSpreadRadius,
      glowOpacity: widget.interactionGlowOpacity,
      child: child,
    );
  }

  /// Builds simple rendering mode without masking (MaskingQuality.off).
  ///
  /// Only renders tabs once without dual-layer masking. Maximum performance.
  Widget _buildSimpleMode({
    required AlignmentGeometry alignment,
    required AlignmentGeometry targetAlignment,
    required double thickness,
    required double velocity,
    required double indicatorRadius,
    required Color indicatorColor,
  }) {
    return SizedBox(
      height: widget.barHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: _wrapWithGlow(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Glass background（Poiesis/上游分流见 _buildBarBackground）
                  Positioned.fill(child: _buildBarBackground()),

                  // Unselected icons — always visible, all tabs in unselected style.
                  // The glass indicator refracts this layer as the pill moves over it.
                  Positioned.fill(
                    child: Container(
                      padding: widget.tabPadding,
                      child: widget.childUnselected,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Glass indicator — on top so it refracts the icon layer AND the glow beneath.
          // 中文说明：Poiesis 为支持 iOS 静止玻璃，在 thickness≈0 时也保留
          // 指示器；Skia/Web 回到上游 1.7.2，静止（thickness ≤ 0.05）时不构建。
          if (widget.visible &&
              (PoiesisForkPolicy.patchesEnabled || thickness > 0.05))
            AnimatedGlassIndicator(
              velocity: velocity,
              itemCount: widget.tabCount,
              alignment: alignment,
              thickness: thickness,
              quality: widget.quality,
              indicatorColor: indicatorColor,
              isBackgroundIndicator: false,
              innerBlur: widget.innerBlur,
              padding: const EdgeInsets.all(4),
              expansion: widget.indicatorExpansion,
              settings: widget.indicatorSettings,
              borderRadius: indicatorRadius,
              pinchStrength: widget.indicatorPinchStrength,
              restingGlassVisibility: _restingIndicatorGlassVisibility,
              backgroundKey: widget.platformViewBackdrop
                  ? _iconLayerKey
                  : widget.backgroundKey,
            ),

          // Persistent selected-icon overlay — always rendered at the TARGET
          // (settled) tab position regardless of spring thickness. This ensures
          // the selected icon stays vibrant (selected style) at rest, not washed
          // out by the unselected-style icons in the layer below.
          if (widget.visible)
            Positioned.fill(
              child: Align(
                alignment: targetAlignment,
                child: FractionallySizedBox(
                  widthFactor: 1 / widget.tabCount,
                  child: Container(
                    padding: widget.tabPadding,
                    height: widget.barHeight,
                    child: widget.selectedTabBuilder(context, 1.0,
                        targetAlignment.resolve(Directionality.of(context))),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Builds high quality rendering mode with jelly masking (MaskingQuality.high).
  ///
  /// Dual-layer rendering with ClipPath for "magic lens" effect.
  Widget _buildHighQualityMode({
    required AlignmentGeometry alignment,
    required double thickness,
    required double velocity,
    required Matrix4 jellyTransform,
    required double indicatorRadius,
    required Color indicatorColor,
  }) {
    return SizedBox(
      height: widget.barHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: _wrapWithGlow(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 1. Glass Background（Poiesis/上游分流见 _buildBarBackground）
                  Positioned.fill(child: _buildBarBackground()),

                  // 1.5. Solid Indicator Background (drawn below icons so selected icons are vibrant)
                  AnimatedGlassIndicator(
                    velocity: velocity,
                    itemCount: widget.tabCount,
                    alignment: alignment,
                    thickness: thickness,
                    quality: widget.quality,
                    indicatorColor: indicatorColor,
                    isBackgroundIndicator: false,
                    paintBackground: true,
                    paintGlass: false,
                    innerBlur: widget.innerBlur,
                    padding: const EdgeInsets.all(4),
                    expansion: widget.indicatorExpansion,
                    settings: widget.indicatorSettings,
                    borderRadius: indicatorRadius,
                    backgroundKey: widget.platformViewBackdrop
                        ? _iconLayerKey
                        : widget.backgroundKey,
                  ),

                  // 2. Icon Content Layer (Unselected + Selected combined for refraction)
                  //
                  // The RepaintBoundary is only needed when platformViewBackdrop:true so that
                  // toImageSync() can capture bar content for Impeller's captureImage path
                  // (eliminates the opaque-white indicator bug #99 on Platform Views).
                  // For the common case the boundary would create a GPU compositing layer
                  // every frame with no benefit, so we skip it.
                  Positioned.fill(
                    child: widget.platformViewBackdrop
                        ? RepaintBoundary(
                            key: _iconLayerKey,
                            child: Stack(
                              children: [
                                // Unselected (inverse clipped — visible OUTSIDE pill)
                                ClipPath(
                                  clipBehavior: jellyClipBehavior,
                                  clipper: JellyClipper(
                                    itemCount: widget.tabCount,
                                    alignment: alignment
                                        .resolve(Directionality.of(context)),
                                    thickness: thickness,
                                    expansion: widget.indicatorExpansion
                                        .resolve(Directionality.of(context)),
                                    transform: jellyTransform,
                                    borderRadius: indicatorRadius * 2,
                                    inverse: true,
                                  ),
                                  child: Container(
                                    padding: widget.tabPadding,
                                    height: widget.barHeight,
                                    child: widget.childUnselected,
                                  ),
                                ),
                                // Selected (forward clipped — visible INSIDE pill)
                                ClipPath(
                                  clipBehavior: jellyClipBehavior,
                                  clipper: JellyClipper(
                                    itemCount: widget.tabCount,
                                    alignment: alignment
                                        .resolve(Directionality.of(context)),
                                    thickness: thickness,
                                    expansion: widget.indicatorExpansion
                                        .resolve(Directionality.of(context)),
                                    transform: jellyTransform,
                                    borderRadius: indicatorRadius * 2,
                                  ),
                                  child: Container(
                                    padding: widget.tabPadding,
                                    height: widget.barHeight,
                                    child: widget.selectedTabBuilder(
                                        context,
                                        thickness,
                                        alignment.resolve(
                                            Directionality.of(context))),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Stack(
                            children: [
                              // Unselected (inverse clipped — visible OUTSIDE pill)
                              ClipPath(
                                clipBehavior: jellyClipBehavior,
                                clipper: JellyClipper(
                                  itemCount: widget.tabCount,
                                  alignment: alignment
                                      .resolve(Directionality.of(context)),
                                  thickness: thickness,
                                  expansion: widget.indicatorExpansion
                                      .resolve(Directionality.of(context)),
                                  transform: jellyTransform,
                                  borderRadius: indicatorRadius * 2,
                                  inverse: true,
                                ),
                                child: Container(
                                  padding: widget.tabPadding,
                                  height: widget.barHeight,
                                  child: widget.childUnselected,
                                ),
                              ),
                              // Selected (forward clipped — visible INSIDE pill)
                              ClipPath(
                                clipBehavior: jellyClipBehavior,
                                clipper: JellyClipper(
                                  itemCount: widget.tabCount,
                                  alignment: alignment
                                      .resolve(Directionality.of(context)),
                                  thickness: thickness,
                                  expansion: widget.indicatorExpansion
                                      .resolve(Directionality.of(context)),
                                  transform: jellyTransform,
                                  borderRadius: indicatorRadius * 2,
                                ),
                                child: Container(
                                  padding: widget.tabPadding,
                                  height: widget.barHeight,
                                  child: widget.selectedTabBuilder(
                                      context,
                                      thickness,
                                      alignment
                                          .resolve(Directionality.of(context))),
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),

          // 3. Moving Glass Indicator Layer — on top so it refracts
          // the merged icon RepaintBoundary AND the glow beneath it.
          AnimatedGlassIndicator(
            velocity: velocity,
            itemCount: widget.tabCount,
            alignment: alignment,
            thickness: thickness,
            quality: widget.quality,
            indicatorColor: indicatorColor,
            isBackgroundIndicator: false,
            paintBackground: false,
            paintGlass: true,
            padding: const EdgeInsets.all(4),
            expansion:
                widget.indicatorExpansion.resolve(Directionality.of(context)),
            settings: widget.indicatorSettings,
            borderRadius: indicatorRadius,
            pinchStrength: widget.indicatorPinchStrength,
            restingGlassVisibility: _restingIndicatorGlassVisibility,
            backgroundKey: widget.platformViewBackdrop
                ? _iconLayerKey
                : widget.backgroundKey,
          ),
        ],
      ),
    );
  }
}

/// Clips out the interior of a bar shape, leaving only the exterior.
/// Used to prevent bar drop shadows from bleeding under translucent glass.
class _InverseBarClipper extends CustomClipper<Path> {
  const _InverseBarClipper(this.shape);

  final LiquidShape shape;

  @override
  Path getClip(Size size) {
    final rect = Offset.zero & size;
    final shapePath = shape.getOuterPath(rect);
    final outerRect = rect.inflate(50.0);
    final outerPath = Path()..addRect(outerRect);
    return Path.combine(PathOperation.difference, outerPath, shapePath);
  }

  @override
  bool shouldReclip(_InverseBarClipper oldClipper) => oldClipper.shape != shape;
}
