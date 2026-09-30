// [LOCAL PATCH] Poiesis：互不重叠的玻璃共享同一张背景快照。
//
// 背景（docs/performance/20260930-gpu/REPORT.md）：Impeller 上每个自带图层的
// LiquidGlassLayer 都会各自执行一次 BackdropFilter。没有 backdrop id 时，
// 引擎必须为每一个 BackdropFilter 结束当前 render pass、把整屏内容翻转
// （FlipBackdrop）成纹理、再开启新的 pass 把内容回贴——在 Adreno 等分块渲染
// GPU 的 GLES 后端上，这是整帧提交阶段最昂贵的部分，与玻璃面积无关。
//
// Impeller 的 Canvas::SaveLayer 支持 backdrop id：同一帧内多个 BackdropFilter
// 使用同一个 id 时，只在第一次遇到时翻转一次，后续直接复用缓存的背景纹理。
// 代价是语义变化：后画的玻璃读不到“第一次翻转之后”才画上去的内容。
//
// 因此本机制只适用于满足以下全部条件的玻璃：
// 1. 彼此不重叠，且折射采样范围（约厚度大小）也不会伸进对方区域；
// 2. 第一个参与者之后、最后一个参与者之前，不在它们背后绘制新的内容；
// 3. 全部参与者位于同一个合成 pass 层级——不能有的在 Opacity / ShaderMask /
//    ColorFiltered 等 saveLayer 内、有的在外，否则缓存纹理属于另一个 pass，
//    坐标和内容都会错位。
//
// 嵌套在另一块玻璃里面的玻璃必须看到外层玻璃的渲染结果，所以
// LiquidGlassLayer 会自动为自己的子树屏蔽共享（见 [LiquidGlassSharedBackdropScope.isolate]），
// 内层玻璃始终回到“各自翻转”的上游语义。

import 'package:flutter/widgets.dart';

/// 一组可以共享背景快照的液态玻璃的分组根。
///
/// 中文说明：分组只负责持有同一个 [BackdropKey]，本身不会让任何玻璃参与
/// 共享；需要共享的玻璃子树再用 [LiquidGlassBackdropShare] 显式声明加入。
/// 这样分组可以放在页面 Stack 的根部，而抽屉、弹层等叠加在参与者之上、
/// 必须看到它们的玻璃，只要不包 [LiquidGlassBackdropShare] 就保持原有语义。
///
/// 使用约束见本文件顶部说明；只在 Impeller（`ImageFilter.shader` 路径）生效，
/// Skia/Web 的轻量 Shader 与 FrostedFallback 路径完全不受影响。
class LiquidGlassBackdropShareGroup extends StatefulWidget {
  /// 创建一个背景快照共享分组。
  const LiquidGlassBackdropShareGroup({super.key, required this.child});

  /// 分组内的子树。
  final Widget child;

  /// 读取最近的分组持有的 [BackdropKey]；没有分组时返回 null。
  static BackdropKey? maybeGroupKeyOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<
            _LiquidGlassBackdropShareGroupScope>()
        ?.backdropKey;
  }

  @override
  State<LiquidGlassBackdropShareGroup> createState() =>
      _LiquidGlassBackdropShareGroupState();
}

class _LiquidGlassBackdropShareGroupState
    extends State<LiquidGlassBackdropShareGroup> {
  // 中文说明：key 在 State 生命周期内保持不变，保证跨帧复用同一个 backdrop id，
  // 引擎侧的计数与缓存逻辑每帧都能命中同一组。
  final BackdropKey _backdropKey = BackdropKey();

  @override
  Widget build(BuildContext context) {
    return _LiquidGlassBackdropShareGroupScope(
      backdropKey: _backdropKey,
      child: widget.child,
    );
  }
}

class _LiquidGlassBackdropShareGroupScope extends InheritedWidget {
  const _LiquidGlassBackdropShareGroupScope({
    required this.backdropKey,
    required super.child,
  });

  final BackdropKey backdropKey;

  @override
  bool updateShouldNotify(_LiquidGlassBackdropShareGroupScope oldWidget) =>
      backdropKey != oldWidget.backdropKey;
}

/// 声明子树中的顶层液态玻璃加入最近 [LiquidGlassBackdropShareGroup] 的共享快照。
///
/// 中文说明：
/// - [enabled] 为 false 时子树回到各自翻转的上游语义，便于按业务状态临时退出；
///   切换 [enabled] 不会改变 widget 树结构，子树状态（如输入框焦点）不受影响；
/// - 子树中嵌套在其他玻璃内部的玻璃不会参与共享（由 LiquidGlassLayer 自动屏蔽）；
/// - 没有 [LiquidGlassBackdropShareGroup] 祖先属于接入错误：debug 下断言失败以
///   尽早暴露，release 下退化为不共享（视觉与上游一致）。
class LiquidGlassBackdropShare extends StatelessWidget {
  /// 创建一个共享声明。
  const LiquidGlassBackdropShare({
    super.key,
    this.enabled = true,
    required this.child,
  });

  /// 是否让子树中的顶层玻璃参与共享。
  final bool enabled;

  /// 参与共享的子树。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final groupKey = LiquidGlassBackdropShareGroup.maybeGroupKeyOf(context);
    assert(
      !enabled || groupKey != null,
      'LiquidGlassBackdropShare 必须位于 LiquidGlassBackdropShareGroup 之下，'
      '否则无法与其他玻璃共享同一个 backdrop id。',
    );
    return LiquidGlassSharedBackdropScope(
      backdropKey: enabled ? groupKey : null,
      child: child,
    );
  }
}

/// 向下传递“当前子树应使用的共享 backdrop id”。
///
/// 中文说明：null 表示不共享。LiquidGlassLayer 读取它决定 Pass 2（折射 Shader）
/// 是否挂共享 id，并用 [LiquidGlassSharedBackdropScope.isolate] 为自己的子树
/// 重置为 null，保证嵌套玻璃始终能看到外层玻璃。
class LiquidGlassSharedBackdropScope extends InheritedWidget {
  /// 创建共享 id 作用域。
  const LiquidGlassSharedBackdropScope({
    super.key,
    required this.backdropKey,
    required super.child,
  });

  /// 为子树屏蔽共享的便捷构造（嵌套玻璃使用）。
  const LiquidGlassSharedBackdropScope.isolate(
      {super.key, required super.child})
      : backdropKey = null;

  /// 当前子树使用的共享 backdrop id；null 表示不共享。
  final BackdropKey? backdropKey;

  /// 读取当前上下文的共享 backdrop id；不在任何共享声明之下时返回 null。
  static BackdropKey? maybeKeyOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<LiquidGlassSharedBackdropScope>()
        ?.backdropKey;
  }

  @override
  bool updateShouldNotify(LiquidGlassSharedBackdropScope oldWidget) =>
      backdropKey != oldWidget.backdropKey;
}

/// 计算折射 Shader 所在 BackdropFilterLayer 应挂的 backdrop id。
///
/// 中文说明：
/// - 未共享：返回 null，保持上游“每层各自翻转背景”的行为；
/// - 共享且无模糊：返回共享 id，多块玻璃只翻转一次；
/// - 共享但开启了模糊：返回 null。模糊 Pass 1 已使用同一 id 读取共享背景，
///   Pass 2 必须读到本层 Pass 1 的模糊结果，若也挂共享 id 会拿到翻转缓存里
///   “模糊之前”的背景，玻璃会失去模糊。
BackdropKey? resolveShaderPassBackdropKey({
  required BackdropKey? sharedBackdropKey,
  required double effectiveBlur,
}) {
  if (sharedBackdropKey == null) return null;
  if (effectiveBlur > 0) return null;
  return sharedBackdropKey;
}
