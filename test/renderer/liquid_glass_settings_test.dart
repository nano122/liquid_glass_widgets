import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/constants/glass_defaults.dart';
import 'package:liquid_glass_widgets/src/renderer/liquid_glass_settings.dart';

void main() {
  group('LiquidGlassSettings', () {
    // ─── Defaults ────────────────────────────────────────────────────────────

    group('defaults', () {
      const s = LiquidGlassSettings();

      test('visibility is 1.0', () => expect(s.visibility, 1.0));
      test('thickness is 20', () => expect(s.thickness, 20));
      test('blur is 5', () => expect(s.blur, 5));
      test('refractiveIndex is 1.2', () => expect(s.refractiveIndex, 1.2));
      test('saturation is 1.5', () => expect(s.saturation, 1.5));
      test('lightIntensity is 0.5', () => expect(s.lightIntensity, 0.5));
      test('ambientStrength is 0', () => expect(s.ambientStrength, 0));
      test('chromaticAberration is 0.01',
          () => expect(s.chromaticAberration, 0.01));
      test('lightAngle is 3π/4 (GlassDefaults.lightAngle — iOS 26 upper-left)',
          () => expect(s.lightAngle, closeTo(GlassDefaults.lightAngle, 1e-10)));
      test('glassColor is fully transparent white', () {
        expect(s.glassColor, const Color.fromARGB(0, 255, 255, 255));
      });
    });

    // ─── effectiveXxx at full visibility ─────────────────────────────────────

    group('effective values at visibility=1.0', () {
      const s = LiquidGlassSettings(
        blur: 8,
        thickness: 30,
        chromaticAberration: 0.05,
        lightIntensity: 0.7,
        ambientStrength: 0.3,
        saturation: 2.0,
        glassColor: Color.fromARGB(128, 255, 0, 0),
      );

      test('effectiveBlur == blur', () => expect(s.effectiveBlur, 8));
      test('effectiveThickness == thickness',
          () => expect(s.effectiveThickness, 30));
      test('effectiveChromaticAberration == chromaticAberration',
          () => expect(s.effectiveChromaticAberration, 0.05));
      test('effectiveLightIntensity == lightIntensity',
          () => expect(s.effectiveLightIntensity, 0.7));
      test('effectiveAmbientStrength == ambientStrength',
          () => expect(s.effectiveAmbientStrength, 0.3));
      test('effectiveSaturation == saturation when visibility=1',
          () => expect(s.effectiveSaturation, closeTo(2.0, 1e-10)));
      test('effectiveGlassColor alpha unchanged at visibility=1', () {
        expect(s.effectiveGlassColor.a, closeTo(128 / 255, 0.01));
      });
    });

    // ─── visibility scaling ───────────────────────────────────────────────────

    group('visibility=0 collapses all effective values', () {
      const s = LiquidGlassSettings(
        visibility: 0,
        blur: 10,
        thickness: 40,
        chromaticAberration: 0.1,
        lightIntensity: 0.8,
        ambientStrength: 0.5,
        saturation: 2.0,
        glassColor: Color.fromARGB(200, 0, 0, 255),
      );

      test('effectiveBlur is 0', () => expect(s.effectiveBlur, 0));
      test('effectiveThickness is 0', () => expect(s.effectiveThickness, 0));
      test('effectiveChromaticAberration is 0',
          () => expect(s.effectiveChromaticAberration, 0));
      test('effectiveLightIntensity is 0',
          () => expect(s.effectiveLightIntensity, 0));
      test('effectiveAmbientStrength is 0',
          () => expect(s.effectiveAmbientStrength, 0));
      test('effectiveSaturation is 1.0 (neutral) when visibility=0',
          () => expect(s.effectiveSaturation, closeTo(1.0, 1e-10)));
      test('effectiveGlassColor alpha is 0',
          () => expect(s.effectiveGlassColor.a, closeTo(0.0, 0.01)));
    });

    group('visibility=0.5 scales linearly', () {
      const s = LiquidGlassSettings(
        visibility: 0.5,
        blur: 10,
        thickness: 20,
        chromaticAberration: 0.04,
        lightIntensity: 1.0,
        ambientStrength: 0.4,
      );

      test('effectiveBlur is halved',
          () => expect(s.effectiveBlur, closeTo(5.0, 1e-10)));
      test('effectiveThickness is halved',
          () => expect(s.effectiveThickness, closeTo(10.0, 1e-10)));
      test('effectiveChromaticAberration is halved',
          () => expect(s.effectiveChromaticAberration, closeTo(0.02, 1e-10)));
      test('effectiveLightIntensity is halved',
          () => expect(s.effectiveLightIntensity, closeTo(0.5, 1e-10)));
      test('effectiveAmbientStrength is halved',
          () => expect(s.effectiveAmbientStrength, closeTo(0.2, 1e-10)));
    });

    // ─── effectiveSaturation formula ─────────────────────────────────────────

    group('effectiveSaturation formula: 1 + (saturation - 1) * visibility', () {
      test('saturation=1.0 always gives 1.0 regardless of visibility', () {
        for (final v in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          final s = LiquidGlassSettings(saturation: 1.0, visibility: v);
          expect(s.effectiveSaturation, closeTo(1.0, 1e-10),
              reason: 'visibility=$v');
        }
      });

      test('saturation=2.0 at visibility=0.5 gives 1.5', () {
        const s = LiquidGlassSettings(saturation: 2.0, visibility: 0.5);
        expect(s.effectiveSaturation, closeTo(1.5, 1e-10));
      });

      test('saturation=0.0 (full desaturation) at visibility=1.0 gives 0.0',
          () {
        const s = LiquidGlassSettings(saturation: 0.0, visibility: 1.0);
        expect(s.effectiveSaturation, closeTo(0.0, 1e-10));
      });

      test('saturation=0.0 at visibility=0.0 gives neutral 1.0', () {
        const s = LiquidGlassSettings(saturation: 0.0, visibility: 0.0);
        expect(s.effectiveSaturation, closeTo(1.0, 1e-10));
      });
    });

    // ─── effectiveGlassColor ─────────────────────────────────────────────────

    group('effectiveGlassColor scales alpha by visibility', () {
      test('fully opaque glass at visibility=1.0', () {
        const s = LiquidGlassSettings(
          glassColor: Color.fromARGB(255, 100, 150, 200),
        );
        expect(s.effectiveGlassColor.a, closeTo(1.0, 0.01));
      });

      test('half alpha glass at visibility=0.5', () {
        const s = LiquidGlassSettings(
          visibility: 0.5,
          glassColor: Color.fromARGB(255, 100, 150, 200),
        );
        expect(s.effectiveGlassColor.a, closeTo(0.5, 0.01));
      });

      test('rgb channels are not affected by visibility', () {
        const s = LiquidGlassSettings(
          visibility: 0.5,
          glassColor: Color.fromARGB(255, 100, 150, 200),
        );
        expect(s.effectiveGlassColor.r, closeTo(100 / 255, 0.01));
        expect(s.effectiveGlassColor.g, closeTo(150 / 255, 0.01));
        expect(s.effectiveGlassColor.b, closeTo(200 / 255, 0.01));
      });
    });

    // ─── copyWith ────────────────────────────────────────────────────────────

    group('copyWith', () {
      const base = LiquidGlassSettings(
        visibility: 0.8,
        blur: 6,
        thickness: 25,
        refractiveIndex: 1.4,
        saturation: 1.8,
        lightIntensity: 0.6,
        ambientStrength: 0.2,
        chromaticAberration: 0.03,
        lightAngle: 1.0,
        glassColor: Color(0x80FF0000),
      );

      test('copy with no changes equals original', () {
        expect(base.copyWith(), equals(base));
      });

      test('copy with single field change only changes that field', () {
        final copy = base.copyWith(blur: 12);
        expect(copy.blur, 12);
        expect(copy.thickness, base.thickness);
        expect(copy.visibility, base.visibility);
        expect(copy.refractiveIndex, base.refractiveIndex);
        expect(copy.saturation, base.saturation);
      });

      test('copyWith can change multiple fields', () {
        final copy = base.copyWith(thickness: 50, saturation: 1.0);
        expect(copy.thickness, 50);
        expect(copy.saturation, 1.0);
        expect(copy.blur, base.blur);
      });

      test('copyWith glassColor replaces the color', () {
        final copy = base.copyWith(glassColor: Colors.blue);
        expect(copy.glassColor, Colors.blue);
        expect(copy.blur, base.blur);
      });
    });

    // ─── figma() constructor ─────────────────────────────────────────────────

    group('figma() constructor mapping', () {
      test('refraction=0 maps to refractiveIndex=1.0 (no refraction)', () {
        final s = LiquidGlassSettings.figma(
          refraction: 0,
          depth: 20,
          dispersion: 0,
          frost: 5,
        );
        expect(s.refractiveIndex, closeTo(1.0, 1e-10));
      });

      test('refraction=100 maps to refractiveIndex=1.2 (max refraction)', () {
        final s = LiquidGlassSettings.figma(
          refraction: 100,
          depth: 20,
          dispersion: 0,
          frost: 5,
        );
        expect(s.refractiveIndex, closeTo(1.2, 1e-10));
      });

      test('depth maps directly to thickness', () {
        final s = LiquidGlassSettings.figma(
          refraction: 50,
          depth: 42,
          dispersion: 0,
          frost: 5,
        );
        expect(s.thickness, closeTo(42, 1e-10));
      });

      test('frost maps directly to blur', () {
        final s = LiquidGlassSettings.figma(
          refraction: 50,
          depth: 20,
          dispersion: 0,
          frost: 15,
        );
        expect(s.blur, closeTo(15, 1e-10));
      });

      test('dispersion=0 gives chromaticAberration=0', () {
        final s = LiquidGlassSettings.figma(
          refraction: 50,
          depth: 20,
          dispersion: 0,
          frost: 5,
        );
        expect(s.chromaticAberration, closeTo(0, 1e-10));
      });

      test('dispersion=100 maps to chromaticAberration=4', () {
        final s = LiquidGlassSettings.figma(
          refraction: 50,
          depth: 20,
          dispersion: 100,
          frost: 5,
        );
        expect(s.chromaticAberration, closeTo(4.0, 1e-10));
      });

      test('lightIntensity default is 0.5 (50/100)', () {
        final s = LiquidGlassSettings.figma(
          refraction: 50,
          depth: 20,
          dispersion: 0,
          frost: 5,
        );
        expect(s.lightIntensity, closeTo(0.5, 1e-10));
      });

      test('lightIntensity=0 gives 0.0', () {
        final s = LiquidGlassSettings.figma(
          refraction: 50,
          depth: 20,
          dispersion: 0,
          frost: 5,
          lightIntensity: 0,
        );
        expect(s.lightIntensity, closeTo(0.0, 1e-10));
      });
    });

    // ─── Equatable equality ───────────────────────────────────────────────────

    group('equality (Equatable)', () {
      test('identical settings are equal', () {
        const a = LiquidGlassSettings(blur: 5, thickness: 20);
        const b = LiquidGlassSettings(blur: 5, thickness: 20);
        expect(a, equals(b));
      });

      test('different blur values are not equal', () {
        const a = LiquidGlassSettings(blur: 5);
        const b = LiquidGlassSettings(blur: 10);
        expect(a, isNot(equals(b)));
      });

      test('different visibility values are not equal', () {
        const a = LiquidGlassSettings(visibility: 1.0);
        const b = LiquidGlassSettings(visibility: 0.5);
        expect(a, isNot(equals(b)));
      });

      test('copyWith no-op produces equal instance', () {
        const original = LiquidGlassSettings(blur: 7, thickness: 15);
        expect(original.copyWith(), equals(original));
      });
    });

    // ─── whitenStrength / whitenGated ────────────────────────────────────────

    group('whitenStrength / whitenGated', () {
      test('whitenStrength defaults to 0.0 (no-op)', () {
        const s = LiquidGlassSettings();
        expect(s.whitenStrength, 0.0);
      });

      test('whitenGated defaults to true', () {
        const s = LiquidGlassSettings();
        expect(s.whitenGated, isTrue);
      });

      test('copyWith round-trips whitenStrength', () {
        const base = LiquidGlassSettings();
        final copy = base.copyWith(whitenStrength: 0.7);
        expect(copy.whitenStrength, 0.7);
        // Other fields untouched.
        expect(copy.whitenGated, base.whitenGated);
        expect(copy.blur, base.blur);
        // Round-trip back.
        expect(copy.copyWith(whitenStrength: 0.0), equals(base));
      });

      test('copyWith round-trips whitenGated', () {
        const base = LiquidGlassSettings();
        final copy = base.copyWith(whitenGated: false);
        expect(copy.whitenGated, isFalse);
        expect(copy.whitenStrength, base.whitenStrength);
        expect(copy.copyWith(whitenGated: true), equals(base));
      });

      test('lerp interpolates whitenStrength linearly', () {
        const a = LiquidGlassSettings(whitenStrength: 0.0);
        const b = LiquidGlassSettings(whitenStrength: 1.0);
        expect(
          LiquidGlassSettings.lerp(a, b, 0.25).whitenStrength,
          closeTo(0.25, 1e-10),
        );
        expect(
          LiquidGlassSettings.lerp(a, b, 0.75).whitenStrength,
          closeTo(0.75, 1e-10),
        );
      });

      test('lerp switches whitenGated at t=0.5', () {
        const a = LiquidGlassSettings(whitenGated: true);
        const b = LiquidGlassSettings(whitenGated: false);
        expect(LiquidGlassSettings.lerp(a, b, 0.49).whitenGated, isTrue);
        expect(LiquidGlassSettings.lerp(a, b, 0.5).whitenGated, isFalse);
        expect(LiquidGlassSettings.lerp(a, b, 1.0).whitenGated, isFalse);
      });

      test('equality includes whitenStrength', () {
        const a = LiquidGlassSettings(whitenStrength: 0.3);
        const b = LiquidGlassSettings(whitenStrength: 0.3);
        const c = LiquidGlassSettings(whitenStrength: 0.6);
        expect(a, equals(b));
        expect(a, isNot(equals(c)));
      });

      test('equality includes whitenGated', () {
        const a = LiquidGlassSettings();
        const b = LiquidGlassSettings(whitenGated: false);
        expect(a, isNot(equals(b)));
      });

      test('hashCode includes both whiten fields', () {
        const s1 = LiquidGlassSettings(whitenStrength: 0.4, whitenGated: false);
        const s2 = LiquidGlassSettings(whitenStrength: 0.4, whitenGated: false);
        const s3 = LiquidGlassSettings(whitenStrength: 0.4, whitenGated: true);
        expect(s1.hashCode, equals(s2.hashCode));
        expect(s1.hashCode, isNot(equals(s3.hashCode)));
      });
    });

    group('backerColor', () {
      test('defaults to null (no backer, no behavior change)', () {
        const s = LiquidGlassSettings();
        expect(s.backerColor, isNull);
      });

      test('copyWith sets backerColor without touching other fields', () {
        const base = LiquidGlassSettings();
        final copy = base.copyWith(backerColor: const Color(0x59000000));
        expect(copy.backerColor, const Color(0x59000000));
        expect(copy.glassColor, base.glassColor);
        expect(copy.blur, base.blur);
      });

      test('lerp fades backerColor smoothly (not a midpoint switch)', () {
        const a = LiquidGlassSettings(backerColor: Color(0x00000000));
        const b = LiquidGlassSettings(backerColor: Color(0xFF000000));
        expect(LiquidGlassSettings.lerp(a, b, 0.25).backerColor!.a,
            closeTo(0.25, 0.02));
        expect(LiquidGlassSettings.lerp(a, b, 0.75).backerColor!.a,
            closeTo(0.75, 0.02));
      });

      test('lerp from null fades in from transparent (Color.lerp semantics)',
          () {
        const a = LiquidGlassSettings(); // backerColor null
        const b = LiquidGlassSettings(backerColor: Color(0xFF000000));
        expect(LiquidGlassSettings.lerp(a, b, 0.5).backerColor!.a,
            closeTo(0.5, 0.02));
      });

      test('lerp of two null backers stays null', () {
        const a = LiquidGlassSettings();
        const b = LiquidGlassSettings();
        expect(LiquidGlassSettings.lerp(a, b, 0.5).backerColor, isNull);
      });

      test('equality includes backerColor', () {
        const a = LiquidGlassSettings(backerColor: Color(0x59000000));
        const b = LiquidGlassSettings(backerColor: Color(0x59000000));
        const c = LiquidGlassSettings();
        expect(a, equals(b));
        expect(a, isNot(equals(c)));
      });

      test('hashCode includes backerColor', () {
        const a = LiquidGlassSettings(backerColor: Color(0x59000000));
        const b = LiquidGlassSettings(backerColor: Color(0x59000000));
        const c = LiquidGlassSettings();
        expect(a.hashCode, equals(b.hashCode));
        expect(a.hashCode, isNot(equals(c.hashCode)));
      });
    });

    group('refractionEnabled', () {
      test('默认开启，既有组件不改变渲染行为', () {
        const settings = LiquidGlassSettings();
        expect(settings.refractionEnabled, isTrue);
      });

      test('copyWith 和交互 pinch 传递都保留关闭状态', () {
        const settings = LiquidGlassSettings(refractionEnabled: false);

        // 中文注释：indicator 动画会通过 copyWithPinch 重建完整设置；这里专门
        // 锁定该路径，防止按压或拖动一开始就把已关闭的折射重新打开。
        expect(settings.copyWith(blur: 12).refractionEnabled, isFalse);
        expect(settings.copyWithPinch(0.7).refractionEnabled, isFalse);
      });

      test('离散开关在 lerp 中点切换并参与相等性', () {
        const enabled = LiquidGlassSettings(refractionEnabled: true);
        const disabled = LiquidGlassSettings(refractionEnabled: false);

        expect(
          LiquidGlassSettings.lerp(enabled, disabled, 0.49).refractionEnabled,
          isTrue,
        );
        expect(
          LiquidGlassSettings.lerp(enabled, disabled, 0.5).refractionEnabled,
          isFalse,
        );
        expect(enabled, isNot(equals(disabled)));
      });

      test('figma 构造器允许显式关闭折射', () {
        const settings = LiquidGlassSettings.figma(
          refraction: 80,
          depth: 20,
          dispersion: 40,
          frost: 5,
          refractionEnabled: false,
        );

        // 中文注释：关闭开关不改写艺术参数本身；以后再次开启时仍应恢复调用者
        // 配置的折射率与色散，而不是被不可逆地归零。
        expect(settings.refractionEnabled, isFalse);
        expect(settings.refractiveIndex, closeTo(1.16, 1e-10));
        expect(settings.chromaticAberration, closeTo(1.6, 1e-10));
      });
    });

    group('topRefractionOnly', () {
      test('默认关闭，既有组件继续全区域折射', () {
        const settings = LiquidGlassSettings();
        expect(settings.topRefractionOnly, isFalse);
      });

      test('copyWith 和交互 pinch 传递都保留顶部限制', () {
        const settings = LiquidGlassSettings(topRefractionOnly: true);

        // 中文注释：pinch 是交互指示器每帧重建设定的内部路径；同时锁定普通
        // copyWith，防止任何材质参数更新后区域限制静默回退到默认 false。
        expect(settings.copyWith(blur: 12).topRefractionOnly, isTrue);
        expect(settings.copyWithPinch(0.7).topRefractionOnly, isTrue);
      });

      test('离散限制在 lerp 中点切换并参与相等性', () {
        const fullArea = LiquidGlassSettings(topRefractionOnly: false);
        const topOnly = LiquidGlassSettings(topRefractionOnly: true);

        expect(
          LiquidGlassSettings.lerp(fullArea, topOnly, 0.49).topRefractionOnly,
          isFalse,
        );
        expect(
          LiquidGlassSettings.lerp(fullArea, topOnly, 0.5).topRefractionOnly,
          isTrue,
        );
        expect(fullArea, isNot(equals(topOnly)));
      });

      test('figma 构造器允许启用顶部限制且不改写折射参数', () {
        const settings = LiquidGlassSettings.figma(
          refraction: 80,
          depth: 20,
          dispersion: 40,
          frost: 5,
          topRefractionOnly: true,
        );

        // 中文注释：区域限制只决定 Shader 在哪里执行折射，不应通过压低折射率
        // 或色散强度模拟，否则关闭限制后无法恢复调用者原始视觉配置。
        expect(settings.topRefractionOnly, isTrue);
        expect(settings.refractiveIndex, closeTo(1.16, 1e-10));
        expect(settings.chromaticAberration, closeTo(1.6, 1e-10));
      });
    });
  });
}
