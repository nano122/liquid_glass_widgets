import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/src/engine/liquid_glass_backdrop_share.dart';

/// 中文说明：记录构建时读到的共享 backdrop id，便于断言作用域解析结果。
class _KeyProbe extends StatelessWidget {
  const _KeyProbe(this.onKey);

  final void Function(BackdropKey?) onKey;

  @override
  Widget build(BuildContext context) {
    onKey(LiquidGlassSharedBackdropScope.maybeKeyOf(context));
    return const SizedBox.shrink();
  }
}

/// 中文说明：带内部状态的子组件，用于验证切换 enabled 不会重建子树。
class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int value = 0;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Widget _wrap(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

void main() {
  group('resolveShaderPassBackdropKey', () {
    final key = BackdropKey();

    test('未共享时返回 null（保持上游各自翻转背景）', () {
      expect(
        resolveShaderPassBackdropKey(sharedBackdropKey: null, effectiveBlur: 0),
        isNull,
      );
    });

    test('共享且无模糊时返回共享 id', () {
      expect(
        resolveShaderPassBackdropKey(sharedBackdropKey: key, effectiveBlur: 0),
        same(key),
      );
    });

    test('共享但开启模糊时返回 null，避免折射 Pass 读不到本层模糊结果', () {
      expect(
        resolveShaderPassBackdropKey(sharedBackdropKey: key, effectiveBlur: 3),
        isNull,
      );
    });
  });

  group('LiquidGlassBackdropShareGroup / LiquidGlassBackdropShare', () {
    testWidgets('同一分组下的多个参与者拿到同一个 id', (tester) async {
      BackdropKey? first;
      BackdropKey? second;
      await tester.pumpWidget(_wrap(
        LiquidGlassBackdropShareGroup(
          child: Column(
            children: [
              LiquidGlassBackdropShare(child: _KeyProbe((k) => first = k)),
              LiquidGlassBackdropShare(child: _KeyProbe((k) => second = k)),
            ],
          ),
        ),
      ));
      expect(first, isNotNull);
      expect(second, same(first));
    });

    testWidgets('只有分组、没有声明参与的子树不共享', (tester) async {
      BackdropKey? key = BackdropKey();
      await tester.pumpWidget(_wrap(
        LiquidGlassBackdropShareGroup(child: _KeyProbe((k) => key = k)),
      ));
      expect(key, isNull);
    });

    testWidgets('不同分组使用不同 id', (tester) async {
      BackdropKey? a;
      BackdropKey? b;
      await tester.pumpWidget(_wrap(
        Column(
          children: [
            LiquidGlassBackdropShareGroup(
              child: LiquidGlassBackdropShare(child: _KeyProbe((k) => a = k)),
            ),
            LiquidGlassBackdropShareGroup(
              child: LiquidGlassBackdropShare(child: _KeyProbe((k) => b = k)),
            ),
          ],
        ),
      ));
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a, isNot(same(b)));
    });

    testWidgets('isolate 为嵌套玻璃屏蔽共享', (tester) async {
      BackdropKey? nested = BackdropKey();
      await tester.pumpWidget(_wrap(
        LiquidGlassBackdropShareGroup(
          child: LiquidGlassBackdropShare(
            child: LiquidGlassSharedBackdropScope.isolate(
              child: _KeyProbe((k) => nested = k),
            ),
          ),
        ),
      ));
      expect(nested, isNull);
    });

    testWidgets('切换 enabled 只改变 id，不重建子树状态', (tester) async {
      BackdropKey? key;
      Widget build({required bool enabled}) => _wrap(
            LiquidGlassBackdropShareGroup(
              child: LiquidGlassBackdropShare(
                enabled: enabled,
                child: Column(
                  children: [_KeyProbe((k) => key = k), const _Counter()],
                ),
              ),
            ),
          );

      await tester.pumpWidget(build(enabled: true));
      expect(key, isNotNull);
      final state = tester.state<_CounterState>(find.byType(_Counter))
        ..value = 42;

      await tester.pumpWidget(build(enabled: false));
      expect(key, isNull);
      expect(tester.state<_CounterState>(find.byType(_Counter)), same(state));
      expect(state.value, 42);

      await tester.pumpWidget(build(enabled: true));
      expect(key, isNotNull);
      expect(tester.state<_CounterState>(find.byType(_Counter)), same(state));
    });

    testWidgets('缺少分组时 debug 断言失败，尽早暴露接入错误', (tester) async {
      await tester.pumpWidget(_wrap(
        LiquidGlassBackdropShare(child: _KeyProbe((_) {})),
      ));
      expect(tester.takeException(), isA<AssertionError>());
    });

    testWidgets('缺少分组但 enabled=false 时不报错', (tester) async {
      BackdropKey? key = BackdropKey();
      await tester.pumpWidget(_wrap(
        LiquidGlassBackdropShare(
          enabled: false,
          child: _KeyProbe((k) => key = k),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(key, isNull);
    });
  });
}
