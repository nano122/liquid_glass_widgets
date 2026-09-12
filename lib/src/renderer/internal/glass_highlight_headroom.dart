import 'package:flutter/foundation.dart';

/// SDR 表面的标准白点。
const double kSdrGlassHighlightHeadroom = 1.0;

/// Poiesis 在 iOS 原生 EDR surface 上允许使用的玻璃高光峰值上限。
///
/// 中文说明：Flutter 3.47 的 iOS 宽色域 surface 使用 BGRA10_XR，单通道
/// 可表达上限约为 1.25098。选择 1.22 为最亮反射保留明确的 EDR 层次，同时
/// 给插值、色彩转换和后续系统合成留出余量。实际写入 Shader 的值还必须受
/// 当前屏幕实时 EDR headroom 限制，不能再仅凭“运行于 iOS”直接启用上限。
const double kIosGlassHighlightHeadroom = 1.22;

double _glassHighlightHeadroom = kSdrGlassHighlightHeadroom;

/// 根据渲染平台与宿主读取到的实时 EDR 能力解析玻璃高光白点。
///
/// Web 即使报告 iOS 目标平台，也不拥有本应用原生配置的 Metal EDR layer，
/// 因此必须保持 1.0。其余非 iOS surface 同样维持原有 SDR 输出。iOS 上的
/// 空值、非有限值和不超过 SDR 白点的值都按 1.0 处理；超过设计上限的值会
/// 截断到 1.22，避免 Shader 输出超过当前 BGRA10_XR 配方的安全范围。
double resolveGlassHighlightHeadroom({
  required TargetPlatform platform,
  required bool isWeb,
  required double? currentEdrHeadroom,
}) {
  if (isWeb || platform != TargetPlatform.iOS) {
    return kSdrGlassHighlightHeadroom;
  }

  final headroom = currentEdrHeadroom;
  if (headroom == null ||
      !headroom.isFinite ||
      headroom <= kSdrGlassHighlightHeadroom) {
    return kSdrGlassHighlightHeadroom;
  }

  return headroom
      .clamp(
        kSdrGlassHighlightHeadroom,
        kIosGlassHighlightHeadroom,
      )
      .toDouble();
}

/// 在 Shader 预热前读取一次宿主当前屏幕的 EDR headroom。
///
/// 中文说明：组件库本身不持有平台通道，宿主通过 [resolver] 注入原生读取逻辑，
/// 从而让包继续保持平台无关。只有原生 iOS 会调用 resolver；未提供 resolver
/// 时明确退回 SDR，避免任意 iOS/模拟器/普通屏幕被错误地写入 1.22。
Future<void> initializeGlassHighlightHeadroom({
  required TargetPlatform platform,
  required bool isWeb,
  Future<double?> Function()? resolver,
}) async {
  if (isWeb || platform != TargetPlatform.iOS || resolver == null) {
    _glassHighlightHeadroom = kSdrGlassHighlightHeadroom;
    return;
  }

  final currentEdrHeadroom = await resolver();
  _glassHighlightHeadroom = resolveGlassHighlightHeadroom(
    platform: platform,
    isWeb: isWeb,
    currentEdrHeadroom: currentEdrHeadroom,
  );
  debugPrint(
    '[LiquidGlass] iOS 当前 EDR headroom: '
    '${currentEdrHeadroom ?? '不可用'}，Shader 白点: '
    '$_glassHighlightHeadroom',
  );
}

/// 当前 Flutter surface 应写入最终合成 Shader 的高光白点。
///
/// 初始化完成前以及任何能力不可用场景都保持 1.0，保证 SDR 是稳定基线。
double get glassHighlightHeadroom => _glassHighlightHeadroom;

/// 仅供单元测试隔离进程级缓存，生产代码不应主动重置。
@visibleForTesting
void resetGlassHighlightHeadroomForTesting() {
  _glassHighlightHeadroom = kSdrGlassHighlightHeadroom;
}
