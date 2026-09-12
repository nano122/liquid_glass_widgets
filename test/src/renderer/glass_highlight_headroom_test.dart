import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/src/renderer/internal/glass_highlight_headroom.dart';

void main() {
  group('resolveGlassHighlightHeadroom', () {
    test('原生 iOS 使用 1.22 EDR 高光峰值', () {
      expect(
        resolveGlassHighlightHeadroom(
          platform: TargetPlatform.iOS,
          isWeb: false,
        ),
        1.22,
      );
    });

    test('Web 与非 iOS 平台保持 SDR 白点', () {
      // 中文说明：同一 Shader 会被多平台复用。这个对抗性用例覆盖浏览器伪装
      // 成 iOS 与桌面/Android 原生两类路径，防止 EDR 数值泄漏到 SDR surface。
      for (final platform in TargetPlatform.values) {
        expect(
          resolveGlassHighlightHeadroom(platform: platform, isWeb: true),
          1.0,
        );
        if (platform != TargetPlatform.iOS) {
          expect(
            resolveGlassHighlightHeadroom(
              platform: platform,
              isWeb: false,
            ),
            1.0,
          );
        }
      }
    });
  });
}
