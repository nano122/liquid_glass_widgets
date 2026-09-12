import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/src/renderer/internal/glass_highlight_headroom.dart';

void main() {
  tearDown(resetGlassHighlightHeadroomForTesting);

  group('resolveGlassHighlightHeadroom', () {
    test('原生 iOS 采用实时 headroom，并限制在 1.22 以内', () {
      expect(
        resolveGlassHighlightHeadroom(
          platform: TargetPlatform.iOS,
          isWeb: false,
          currentEdrHeadroom: 1.14,
        ),
        1.14,
      );
      expect(
        resolveGlassHighlightHeadroom(
          platform: TargetPlatform.iOS,
          isWeb: false,
          currentEdrHeadroom: 4.0,
        ),
        kIosGlassHighlightHeadroom,
      );
    });

    test('iOS 的 SDR、空值和非法值都保持 SDR 白点', () {
      for (final headroom in <double?>[
        null,
        0.8,
        1.0,
        double.nan,
        double.infinity,
      ]) {
        expect(
          resolveGlassHighlightHeadroom(
            platform: TargetPlatform.iOS,
            isWeb: false,
            currentEdrHeadroom: headroom,
          ),
          kSdrGlassHighlightHeadroom,
        );
      }
    });

    test('Web 与非 iOS 平台忽略宿主上报值并保持 SDR 白点', () {
      // 中文说明：同一 Shader 会被多平台复用。这个对抗性用例覆盖浏览器伪装
      // 成 iOS 与桌面/Android 原生两类路径，防止 EDR 数值泄漏到 SDR surface。
      for (final platform in TargetPlatform.values) {
        expect(
          resolveGlassHighlightHeadroom(
            platform: platform,
            isWeb: true,
            currentEdrHeadroom: 1.22,
          ),
          1.0,
        );
        if (platform != TargetPlatform.iOS) {
          expect(
            resolveGlassHighlightHeadroom(
              platform: platform,
              isWeb: false,
              currentEdrHeadroom: 1.22,
            ),
            1.0,
          );
        }
      }
    });
  });

  group('initializeGlassHighlightHeadroom', () {
    test('iOS 缓存宿主实时值供所有 Shader 路径复用', () async {
      var callCount = 0;

      await initializeGlassHighlightHeadroom(
        platform: TargetPlatform.iOS,
        isWeb: false,
        resolver: () async {
          callCount += 1;
          return 1.18;
        },
      );

      expect(callCount, 1);
      expect(glassHighlightHeadroom, 1.18);
    });

    test('非 iOS 不调用宿主 resolver，并清回 SDR 基线', () async {
      await initializeGlassHighlightHeadroom(
        platform: TargetPlatform.iOS,
        isWeb: false,
        resolver: () async => 1.2,
      );
      var callCount = 0;

      await initializeGlassHighlightHeadroom(
        platform: TargetPlatform.android,
        isWeb: false,
        resolver: () async {
          callCount += 1;
          return 1.2;
        },
      );

      expect(callCount, 0);
      expect(glassHighlightHeadroom, kSdrGlassHighlightHeadroom);
    });
  });
}
