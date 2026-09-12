import 'package:flutter/foundation.dart';

/// SDR 表面的标准白点。
const double kSdrGlassHighlightHeadroom = 1.0;

/// Poiesis 在 iOS 原生 EDR surface 上使用的玻璃高光峰值。
///
/// 中文说明：Flutter 3.47 的 iOS 宽色域 surface 使用 BGRA10_XR，单通道
/// 可表达上限约为 1.25098。选择 1.22 为最亮反射保留明确的 EDR 层次，同时
/// 给插值、色彩转换和后续系统合成留出余量；该值只用于高光，不抬升玻璃体。
const double kIosGlassHighlightHeadroom = 1.22;

/// 根据渲染平台解析玻璃高光白点。
///
/// Web 即使报告 iOS 目标平台，也不拥有本应用原生配置的 Metal EDR layer，
/// 因此必须保持 1.0。其余非 iOS surface 同样维持原有 SDR 输出。
double resolveGlassHighlightHeadroom({
  required TargetPlatform platform,
  required bool isWeb,
}) {
  if (!isWeb && platform == TargetPlatform.iOS) {
    return kIosGlassHighlightHeadroom;
  }
  return kSdrGlassHighlightHeadroom;
}

/// 当前 Flutter surface 应写入最终合成 Shader 的高光白点。
double get glassHighlightHeadroom => resolveGlassHighlightHeadroom(
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
    );
