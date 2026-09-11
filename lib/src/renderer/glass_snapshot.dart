import 'dart:ui' as ui;

/// 中文说明：由宿主持有的原分辨率背景快照，仅供独立玻璃层只读采样。
/// 调用方保证 image 覆盖玻璃后方，并在路由退场结束后才释放；本对象不拥有纹理。
/// overlayOpacity 对应黑色 ModalBarrier，避免每帧重新捕获遮罩后的整屏背景。
class GlassSnapshot {
  /// 创建一份由外部宿主管理生命周期的只读玻璃背景快照描述。
  ///
  /// 中文说明：这里只保存纹理引用、根视图原点和遮罩透明度，不复制或释放
  /// [image]；资源所有权始终留在捕获该快照的路由宿主。
  const GlassSnapshot({
    required this.image,
    this.origin = ui.Offset.zero,
    this.overlayOpacity = 0,
  });

  /// 中文说明：与当前视图 DPR 一致的完整背景纹理，禁止传入缩略图。
  final ui.Image image;

  /// 中文说明：捕获边界在根视图中的逻辑像素原点。
  final ui.Offset origin;

  /// 中文说明：已应用路由 barrierCurve 的黑色遮罩透明度。
  final double overlayOpacity;
}
