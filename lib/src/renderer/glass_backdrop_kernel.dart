import 'dart:ui' as ui;

/// 兼容两个历史渲染路径使用的亮度权重。
///
/// Standard 一直使用 Rec.709，而 Minimal 的旧实现实际使用 BT.601。
/// 无损阶段保留这个差异，避免统一实现时悄悄改变任一档位的色彩。
enum GlassSaturationProfile {
  /// Standard / Premium 使用的 Rec.709 亮度权重。
  rec709,

  /// Minimal 历史路径使用的 BT.601 亮度权重。
  bt601,
}

/// Standard 与 Minimal 共用的背景滤镜构造器。
///
/// 这里集中维护高斯模糊和 Rec.709 饱和度矩阵，避免两个质量档位各自
/// 分配等价的 [ui.ImageFilter]。缓存只保留最近使用的一小组参数：主题切换、
/// 动画和调试滑杆可能产生大量离散 sigma，有限缓存可以复用常用值，同时
/// 不让一次长时间动画永久占住所有历史滤镜对象。
class GlassBackdropKernel {
  GlassBackdropKernel._();

  static const int _cacheCapacity = 32;
  static final Map<(double, double, GlassSaturationProfile), ui.ImageFilter>
      _filterCache = {};
  static final Map<(double, GlassSaturationProfile), ui.ColorFilter>
      _saturationCache = {};

  /// 返回“先模糊、后饱和度”的视觉等价滤镜。
  ///
  /// [saturation] 为 1 时直接返回高斯滤镜，省掉没有视觉输出的颜色矩阵。
  static ui.ImageFilter exact({
    required double sigma,
    double saturation = 1.0,
    GlassSaturationProfile saturationProfile = GlassSaturationProfile.rec709,
  }) {
    final key = (sigma, saturation, saturationProfile);
    final cached = _filterCache.remove(key);
    if (cached != null) {
      // 删除后重新插入，使 Map 的迭代顺序承担轻量 LRU 的职责。
      _filterCache[key] = cached;
      return cached;
    }

    final blur = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    final ui.ImageFilter filter;
    if ((saturation - 1.0).abs() <= 0.01) {
      filter = blur;
    } else {
      filter = ui.ImageFilter.compose(
        outer: saturationFilter(
          saturation,
          profile: saturationProfile,
        ),
        inner: blur,
      );
    }

    if (_filterCache.length >= _cacheCapacity) {
      _filterCache.remove(_filterCache.keys.first);
    }
    _filterCache[key] = filter;
    return filter;
  }

  /// 按指定历史档位构造饱和度矩阵。
  static ui.ColorFilter saturationFilter(
    double saturation, {
    GlassSaturationProfile profile = GlassSaturationProfile.bt601,
  }) {
    final key = (saturation, profile);
    final cached = _saturationCache.remove(key);
    if (cached != null) {
      _saturationCache[key] = cached;
      return cached;
    }

    final (lumR, lumG, lumB) = switch (profile) {
      GlassSaturationProfile.rec709 => (0.2126, 0.7152, 0.0722),
      GlassSaturationProfile.bt601 => (0.299, 0.587, 0.114),
    };
    final inv = 1.0 - saturation;
    final filter = ui.ColorFilter.matrix(<double>[
      lumR * inv + saturation,
      lumG * inv,
      lumB * inv,
      0,
      0,
      lumR * inv,
      lumG * inv + saturation,
      lumB * inv,
      0,
      0,
      lumR * inv,
      lumG * inv,
      lumB * inv + saturation,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]);
    if (_saturationCache.length >= _cacheCapacity) {
      _saturationCache.remove(_saturationCache.keys.first);
    }
    _saturationCache[key] = filter;
    return filter;
  }

  /// 仅供测试隔离静态状态，避免用例顺序影响缓存断言。
  static void resetForTesting() {
    _filterCache.clear();
    _saturationCache.clear();
  }
}
