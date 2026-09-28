import 'dart:async';

import 'package:liquid_glass_widgets/src/renderer/poiesis_fork_policy.dart';

/// 中文说明：`flutter test` 没有 GPU 渲染器，`isShaderFilterSupported` 恒为
/// false，按生产策略会走 Skia/Web 的上游原版分支。组件库既有测试大多用于
/// 锁定 Poiesis 补丁行为，因此这里默认开启补丁；验证上游原版行为的用例
/// （见 test/poiesis_fork_policy_test.dart 等）在 setUp 中显式改为 false，
/// 并在 tearDown 恢复为 true。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PoiesisForkPolicy.debugPatchesEnabledOverride = true;
  await testMain();
}
