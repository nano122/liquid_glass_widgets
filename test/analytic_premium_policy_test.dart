import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/src/renderer/liquid_shape.dart';
import 'package:liquid_glass_widgets/types/glass_quality.dart';
import 'package:liquid_glass_widgets/widgets/shared/glass_effect.dart';

void main() {
  test('解析式 Premium 只接管当前能够精确表达的圆角矩形', () {
    // 中文注释：交互指示器 Shader 使用 rounded-rectangle SDF；虽然
    // superellipse 和椭圆也有单一半径，但它们的边界曲率并不完全相同，
    // 第一阶段宁可回退旧几何纹理管线，也不以轮廓偏差换取性能。
    expect(
      GlassEffect.supportsAnalyticPremium(
        const LiquidRoundedRectangle(borderRadius: 24),
      ),
      isTrue,
    );
    expect(
      GlassEffect.supportsAnalyticPremium(
        const LiquidRoundedSuperellipse(borderRadius: 24),
      ),
      isFalse,
    );
    expect(
      GlassEffect.supportsAnalyticPremium(const LiquidOval()),
      isFalse,
    );
    expect(
      GlassEffect.supportsAnalyticPremium(
        const LiquidVerticalRoundedRectangle(
          topRadius: 20,
          bottomRadius: 8,
        ),
      ),
      isFalse,
    );
  });

  test('Impeller Standard/Premium 始终进入官方层，解析优化只接管受支持形状', () {
    const shape = LiquidRoundedRectangle(borderRadius: 24);

    // 中文注释：官方 LiquidGlassLayer 是 Standard/Premium 唯一允许创建实时
    // BackdropFilterLayer 的位置；具体轮廓只决定是否跳过 geometry texture，
    // 不能决定是否改走另一套合成链。
    expect(
      GlassEffect.shouldUseOfficialPremiumLayer(
        isImpeller: true,
        quality: GlassQuality.premium,
      ),
      isTrue,
    );
    expect(
      GlassEffect.shouldUseOfficialPremiumLayer(
        isImpeller: true,
        quality: GlassQuality.standard,
      ),
      isTrue,
    );
    expect(
      GlassEffect.shouldUseOfficialPremiumLayer(
        isImpeller: true,
        quality: GlassQuality.minimal,
      ),
      isFalse,
    );
    expect(
      GlassEffect.shouldUseOfficialPremiumLayer(
        isImpeller: false,
        quality: GlassQuality.premium,
      ),
      isFalse,
    );

    expect(
      GlassEffect.shouldUseAnalyticPremium(
        isImpeller: true,
        shape: shape,
      ),
      isTrue,
    );
    expect(
      GlassEffect.shouldUseAnalyticPremium(
        isImpeller: false,
        shape: shape,
      ),
      isFalse,
    );
    expect(
      GlassEffect.shouldUseAnalyticPremium(
        isImpeller: true,
        shape: const LiquidRoundedSuperellipse(borderRadius: 24),
      ),
      isFalse,
    );
  });
}
