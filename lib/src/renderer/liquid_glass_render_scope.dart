// ignore_for_file: public_member_api_docs

import 'package:flutter/widgets.dart';
import 'liquid_glass_renderer.dart';

class LiquidGlassRenderScope extends InheritedWidget {
  /// Creates a new [LiquidGlassRenderScope].
  const LiquidGlassRenderScope({
    required this.settings,
    required super.child,
    super.key,
  });

  final LiquidGlassSettings settings;

  /// Returns the nearest native renderer scope, if this widget is already
  /// inside a [LiquidGlassLayer].
  ///
  /// 中文说明：AdaptiveGlass 需要区分“可以加入共享原生层”和“完全没有
  /// 原生层”这两种场景。直接调用 [of] 会在普通独立组件上触发断言，因此
  /// 这里提供一个不抛异常的查询入口，让上层在缺少父层时自动创建 own layer。
  static LiquidGlassRenderScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<LiquidGlassRenderScope>();
  }

  static LiquidGlassRenderScope of(BuildContext context) {
    final scope = maybeOf(context);
    assert(
      scope != null,
      'No liquid glass renderer found in context. '
      'Make sure to wrap your liquid glass widgets in a LiquidGlassLayer.',
    );
    return scope!;
  }

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) {
    return oldWidget is! LiquidGlassRenderScope ||
        oldWidget.settings != settings;
  }
}
