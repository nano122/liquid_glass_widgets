import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/types/glass_quality.dart';
import 'package:liquid_glass_widgets/widgets/shared/adaptive_glass.dart';

void main() {
  group('AdaptiveGlass Impeller 路由', () {
    test('Impeller 下 Standard 与 Premium 共用完整 Shader', () {
      // 中文说明：Standard 需要获得与 Premium 相同的终止黑边和实时
      // backdrop；这里锁定两档都进入官方 LiquidGlass 合成路径。
      expect(
        AdaptiveGlass.shouldUsePremiumShader(
          isImpeller: true,
          isWeb: false,
          platformViewBackdrop: false,
          quality: GlassQuality.standard,
        ),
        isTrue,
      );
      expect(
        AdaptiveGlass.shouldUsePremiumShader(
          isImpeller: true,
          isWeb: false,
          platformViewBackdrop: false,
          quality: GlassQuality.premium,
        ),
        isTrue,
      );
    });

    test('Skia/Web、minimal 与 PlatformView 继续使用安全回退', () {
      // 中文说明：Skia/Web 无法运行官方几何 Shader；minimal 不应产生任何
      // 自定义 Shader；PlatformView 不能被 toImageSync 背景捕获，三者都必须
      // 保留既有 Lightweight 或 BackdropFilter 回退。
      expect(
        AdaptiveGlass.shouldUsePremiumShader(
          isImpeller: false,
          isWeb: false,
          platformViewBackdrop: false,
          quality: GlassQuality.standard,
        ),
        isFalse,
      );
      expect(
        AdaptiveGlass.shouldUsePremiumShader(
          isImpeller: true,
          isWeb: true,
          platformViewBackdrop: false,
          quality: GlassQuality.standard,
        ),
        isFalse,
      );
      expect(
        AdaptiveGlass.shouldUsePremiumShader(
          isImpeller: true,
          isWeb: false,
          platformViewBackdrop: false,
          quality: GlassQuality.minimal,
        ),
        isFalse,
      );
      expect(
        AdaptiveGlass.shouldUsePremiumShader(
          isImpeller: true,
          isWeb: false,
          platformViewBackdrop: true,
          quality: GlassQuality.standard,
        ),
        isFalse,
      );
    });

    test('Standard 独立使用时自动创建 own layer，已有共享层时保持 grouped', () {
      // 中文说明：Standard 复用 Premium 原生 Shader 后，不能在没有父层时
      // 继续调用 LiquidGlass.grouped，否则 LiquidGlassBlendGroup 无法取得
      // InheritedGeometryRenderLink 并会在 Debug 模式触发断言。
      expect(
        AdaptiveGlass.shouldUseOwnLayerForNativePath(
          requestedOwnLayer: false,
          hasNativeLayer: false,
          isIsolated: false,
        ),
        isTrue,
      );
      expect(
        AdaptiveGlass.shouldUseOwnLayerForNativePath(
          requestedOwnLayer: false,
          hasNativeLayer: true,
          isIsolated: false,
        ),
        isFalse,
      );
      expect(
        AdaptiveGlass.shouldUseOwnLayerForNativePath(
          requestedOwnLayer: false,
          hasNativeLayer: true,
          isIsolated: true,
        ),
        isTrue,
      );
      expect(
        AdaptiveGlass.shouldUseOwnLayerForNativePath(
          requestedOwnLayer: true,
          hasNativeLayer: true,
          isIsolated: false,
        ),
        isTrue,
      );
    });
  });
}
