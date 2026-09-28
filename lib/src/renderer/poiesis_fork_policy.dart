import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Poiesis fork 补丁的渲染器分流策略。
///
/// 中文说明：Poiesis 的全部定制（双层描边、区域高光、EDR、外投影策略、
/// 按钮镂空投影、底栏超椭圆、跨帧复用 layer 等）都是针对 Impeller 调校的。
/// Skia 与 Web 不支持 `ImageFilter.shader`，只能走上游的轻量 Shader 回退，
/// 在这些渲染器上继续叠加 Poiesis 调校既无对应的原生合成链，也会偏离上游
/// 已经验证过的视觉基线。因此：
///
/// - `ui.ImageFilter.isShaderFilterSupported == true`（Impeller）
///   → [patchesEnabled] 为 `true`，使用 Poiesis 定制；
/// - `false`（Skia、Web）→ [patchesEnabled] 为 `false`，所有受影响的分支
///   回到官方 `liquid_glass_widgets 1.7.2` 的原始实现，Shader 也改为加载
///   `shaders/upstream/` 下逐字节复制的官方版本。
///
/// 该值只取决于进程启动时确定的渲染后端，运行期间不会变化，所以各处
/// 静态缓存（例如 [ui.FragmentProgram]）按首次读取的结果加载即可。
abstract final class PoiesisForkPolicy {
  static bool? _debugPatchesEnabledOverride;
  static bool _loggedMode = false;

  /// 当前进程是否启用 Poiesis 补丁。
  ///
  /// 生产环境严格等价于 `ui.ImageFilter.isShaderFilterSupported`；只有测试
  /// 可以通过 [debugPatchesEnabledOverride] 改写。
  static bool get patchesEnabled =>
      _debugPatchesEnabledOverride ?? ui.ImageFilter.isShaderFilterSupported;

  /// 测试专用覆盖值。
  ///
  /// 中文说明：`flutter test` 没有 GPU 渲染器，`isShaderFilterSupported`
  /// 恒为 `false`。组件库既有的 Poiesis 回归测试需要在该环境下验证补丁，
  /// 因此 `test/flutter_test_config.dart` 默认把它设为 `true`；验证上游
  /// 原版行为的用例再显式设为 `false`，结束后恢复。传 `null` 表示回到真实
  /// 渲染器判断。
  @visibleForTesting
  static bool? get debugPatchesEnabledOverride => _debugPatchesEnabledOverride;

  @visibleForTesting
  static set debugPatchesEnabledOverride(bool? value) {
    _debugPatchesEnabledOverride = value;
  }

  /// 在初始化阶段打印一次当前分流结果，便于真机日志确认走了哪条渲染链。
  static void logModeOnce() {
    if (_loggedMode) return;
    _loggedMode = true;
    debugPrint(
      patchesEnabled
          ? '[LiquidGlass] Renderer=Impeller → Poiesis 定制补丁已启用'
          : '[LiquidGlass] Renderer=Skia/Web → 使用上游 1.7.2 原版实现',
    );
  }

  /// 返回轻量 Shader 在当前模式下应加载的 shaders 目录内相对路径。
  ///
  /// 中文说明：上游原版 Shader 保存在 `shaders/upstream/`，与 fork 版本
  /// 同名，因此只需切换目录前缀；uniform 布局由各 RenderObject 按同一
  /// [patchesEnabled] 选择，保证程序与写入顺序一致。
  static String lightweightShaderPath(String fileName) =>
      patchesEnabled ? 'shaders/$fileName' : 'shaders/upstream/$fileName';
}
