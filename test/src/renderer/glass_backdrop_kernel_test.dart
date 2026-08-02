import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/src/renderer/glass_backdrop_kernel.dart';

void main() {
  setUp(GlassBackdropKernel.resetForTesting);

  test('相同参数会复用高斯与饱和度组合滤镜', () {
    final first = GlassBackdropKernel.exact(sigma: 3, saturation: 1.5);
    final second = GlassBackdropKernel.exact(sigma: 3, saturation: 1.5);

    // 回归保护：概要页两个相同 blur/saturation 的玻璃不应各自构造滤镜图。
    expect(second, same(first));
  });

  test('Standard 与 Minimal 的历史饱和度矩阵分别缓存', () {
    final standard = GlassBackdropKernel.saturationFilter(
      1.5,
      profile: GlassSaturationProfile.rec709,
    );
    final minimal = GlassBackdropKernel.saturationFilter(
      1.5,
      profile: GlassSaturationProfile.bt601,
    );

    // 两个档位的亮度权重历史上并不相同，不能为追求共享而混用实例。
    expect(minimal, isNot(same(standard)));
    expect(
      GlassBackdropKernel.saturationFilter(
        1.5,
        profile: GlassSaturationProfile.rec709,
      ),
      same(standard),
    );
  });
}
