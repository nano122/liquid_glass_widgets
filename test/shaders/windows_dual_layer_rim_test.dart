import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/src/renderer/shaders.dart';

// 中文说明：回归 2026-09-26 的 Windows 白色描边问题。Windows 原生 Premium
// 使用独立的有界合成 Shader，旧版本删除了 edge_treatment.glsl，导致浅灰环、
// 左右深边和白光内缩全部缺失，Fresnel 直接把最外轮廓提亮成纯白。
// 这里直接在 flutter_tester 中执行 Windows 专用 Shader 并读取像素，而不是只
// 匹配源码字符串，确保真正的输出颜色与 Android 通用 Shader 的描边语义一致。

/// 画布与胶囊几何：DPR 固定为 1，一个物理像素正好对应一个逻辑像素，
/// 便于精确定位最外侧像素列。
const double _canvasWidth = 120;
const double _canvasHeight = 60;
const double _shapeLeft = 10;
const double _shapeTop = 10;
const double _shapeWidth = 100;
const double _shapeHeight = 40;
const double _shapeRadius = 20;

/// 与 LiquidGlassRenderObject 一致：geometry texture 的本地边界向外扩 2 逻辑
/// 像素，保证 AA 外沿和 RGSS 外侧样本读到的是透明纹素而不是被钳制的边缘。
const double _geometryPadding = 2;
const double _geometryWidth = _shapeWidth + _geometryPadding * 2;
const double _geometryHeight = _shapeHeight + _geometryPadding * 2;
const double _devicePixelRatio = 1;

/// 与宿主一致：物理厚度 = 逻辑厚度 * (DPR / 3)。
const double _dprScale = _devicePixelRatio / 3.0;
const double _thickness = 20 * _dprScale;

/// 暖白背景，对应截图中概要页的奶白底色 (249, 248, 245)。
const ui.Color _backdropColor = ui.Color(0xFFF9F8F5);

/// 读取 straight RGBA 像素的轻量封装。
class _Pixels {
  _Pixels(this._bytes, this._width);

  final ByteData _bytes;
  final int _width;

  List<int> at(int x, int y) {
    final offset = (y * _width + x) * 4;
    return <int>[
      _bytes.getUint8(offset),
      _bytes.getUint8(offset + 1),
      _bytes.getUint8(offset + 2),
      _bytes.getUint8(offset + 3),
    ];
  }

  /// Rec.601 亮度，与 Shader 的 kLumaWeights 一致。
  double luma(int x, int y) {
    final pixel = at(x, y);
    return pixel[0] * 0.299 + pixel[1] * 0.587 + pixel[2] * 0.114;
  }
}

Future<ui.Image> _solidImage(int width, int height, ui.Color color) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = color,
  );
  return recorder.endRecording().toImage(width, height);
}

/// 用 Windows 专用几何 Shader 生成与生产一致的 geometry texture。
///
/// 中文说明：形状类型 3 是超椭圆；Windows 几何 Pass 会把它近似成同半径圆角
/// 矩形，正是底部导航在 Windows 上实际走的纹理路径。纹理坐标即玻璃本地
/// 逻辑坐标（DPR = 1），与宿主启用逆仿射时的 uGeometryOffset/Size 语义一致。
Future<ui.Image> _windowsGeometryTexture() async {
  final program = await ui.FragmentProgram.fromAsset(
    ShaderKeys.blendedGeometryForPlatform(
      TargetPlatform.windows,
      isWeb: false,
    ),
  );
  final shader = program.fragmentShader();
  final shapeData = List<double>.filled(16 * 7, 0);
  shapeData.setAll(0, <double>[
    3, // 超椭圆
    _geometryPadding + _shapeWidth / 2,
    _geometryPadding + _shapeHeight / 2,
    _shapeWidth,
    _shapeHeight,
    _shapeRadius,
    _shapeRadius,
  ]);
  var index = 0;
  void write(List<double> values) {
    for (final value in values) {
      shader.setFloat(index++, value);
    }
  }

  write(<double>[_geometryWidth, _geometryHeight]); // uSize
  write(<double>[1.2, 0.01, _thickness, 0]); // uOpticalProps（blend = 0）
  write(<double>[1, _devicePixelRatio]); // uShapeSettings
  write(shapeData); // uShapeData

  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, _geometryWidth, _geometryHeight),
    ui.Paint()..shader = shader,
  );
  final image = await recorder
      .endRecording()
      .toImage(_geometryWidth.toInt(), _geometryHeight.toInt());
  shader.dispose();
  return image;
}

/// 执行 Windows 最终合成 Shader，返回整张画布像素。
///
/// [useTexturePath] 为 true 时关闭解析圆角矩形（uAnalyticRect.w = 0），
/// 改为读取 Windows 几何 Shader 生成的纹理；为 false 时走 mode 1 解析路径。
Future<_Pixels> _renderWindowsGlass({required bool useTexturePath}) async {
  final program = await ui.FragmentProgram.fromAsset(
    ShaderKeys.liquidGlassRenderForPlatform(
      TargetPlatform.windows,
      isWeb: false,
    ),
  );
  final shader = program.fragmentShader();
  final backdrop = await _solidImage(
    _canvasWidth.toInt(),
    _canvasHeight.toInt(),
    _backdropColor,
  );
  final geometry = useTexturePath
      ? await _windowsGeometryTexture()
      : await _solidImage(1, 1, const ui.Color(0x00000000));

  var index = 0;
  void write(List<double> values) {
    for (final value in values) {
      shader.setFloat(index++, value);
    }
  }

  // 中文说明：以下 49 个 float 的顺序与 LiquidGlassRenderObject 写入的
  // slot 完全一致；参数取 LiquidGlassSettings 默认值和应用的中性玻璃底色。
  write(<double>[_canvasWidth, _canvasHeight]); // 0-1 uSize
  write(useTexturePath
      ? <double>[
          -_geometryPadding,
          -_geometryPadding,
          _geometryWidth,
          _geometryHeight,
        ]
      : <double>[0, 0, 0, 0]); // 2-5 uGeometryOffset / uGeometrySize
  write(<double>[224 / 255, 224 / 255, 228 / 255, 49 / 255]); // 6-9 uGlassColor
  write(<double>[1.2, 0.01, _thickness, 1.0]); // 10-13 uOpticalProps
  write(<double>[0.5, 0.0, 1.5]); // 14-16 uLightConfig
  write(<double>[0.5, -0.8660254]); // 17-18 uLightDirection
  write(<double>[0, 0, 0]); // 19-21 uWhiten / uWhitenGated / uPinchStrength
  write(<double>[0, 0, 0, 0]); // 22-25 uBackgroundFallback
  write(<double>[0, 0]); // 26-27 uCaptureOffset
  write(<double>[0, 1.0, _dprScale, 0]); // 28-31 uEdgeConfig
  write(<double>[
    _shapeWidth,
    _shapeHeight,
    _shapeRadius,
    useTexturePath ? 0 : 1,
  ]); // 32-35 uAnalyticRect
  // 36-43：屏幕物理像素 → 玻璃本地逻辑像素的逆仿射；w 分量启用法线变换。
  write(<double>[1 / _devicePixelRatio, 0, -_shapeLeft, 1]);
  write(<double>[0, 1 / _devicePixelRatio, -_shapeTop, 0]);
  write(<double>[0, 1, 0]); // 44-46 PlatformView / 折射开关 / 顶部折射
  write(<double>[0, 0]); // 47-48 uCaptureConfig
  shader
    ..setImageSampler(0, backdrop)
    ..setImageSampler(1, geometry, filterQuality: ui.FilterQuality.medium);

  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, _canvasWidth, _canvasHeight),
    ui.Paint()..shader = shader,
  );
  final image = await recorder
      .endRecording()
      .toImage(_canvasWidth.toInt(), _canvasHeight.toInt());
  final bytes =
      await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  image.dispose();
  backdrop.dispose();
  geometry.dispose();
  shader.dispose();
  return _Pixels(bytes!, _canvasWidth.toInt());
}

/// [minEdgeAlpha]：最外侧像素允许的最小覆盖率；[outsideGap]：从最外侧像素
/// 向外多少列之后必须完全透明。
///
/// 中文说明：解析路径逐样本精确求 SDF，外沿 alpha≈0.99、紧邻外侧像素即为 0；
/// 纹理路径的 RGSS 样本经过几何纹理双线性插值，AA 过渡天然再软约 1px
/// （通用 Shader 的纹理路径完全相同），因此阈值按路径区分，颜色断言共用。
void _expectDualLayerRim(
  _Pixels pixels,
  String pathName, {
  required int minEdgeAlpha,
  required int outsideGap,
}) {
  final centerY = (_shapeTop + _shapeHeight / 2).toInt();
  final leftEdgeX = _shapeLeft.toInt();
  final rightEdgeX = (_shapeLeft + _shapeWidth).toInt() - 1;
  final topEdgeY = _shapeTop.toInt();
  final centerX = (_shapeLeft + _shapeWidth / 2).toInt();

  final interiorLuma = pixels.luma(centerX, centerY);
  final leftLuma = pixels.luma(leftEdgeX, centerY);
  final rightLuma = pixels.luma(rightEdgeX, centerY);
  final topLuma = pixels.luma(centerX, topEdgeY);
  final report = '$pathName: interior=${pixels.at(centerX, centerY)} '
      'left=${pixels.at(leftEdgeX, centerY)} '
      'right=${pixels.at(rightEdgeX, centerY)} '
      'top=${pixels.at(centerX, topEdgeY)}';

  // 中文说明：最外侧像素必须大部分位于玻璃内，否则颜色比较会被覆盖率噪声
  // 淹没。读取的是 straight RGBA，颜色本身已除去 alpha。胶囊端点是半圆且
  // 像素中心比圆心低 0.5px，所以解析路径外沿也只有约 0.99（253）。
  expect(pixels.at(leftEdgeX, centerY)[3], greaterThanOrEqualTo(minEdgeAlpha),
      reason: report);
  expect(pixels.at(centerX, centerY)[3], 255, reason: report);

  // 中文说明：离开 AA 过渡带后的外侧像素，所有 RGSS 样本都在形状外，必须
  // 完全透明；这同时保护“中心透明时法线归零”的分支，防止外侧出现亮点。
  expect(pixels.at(leftEdgeX - outsideGap, centerY)[3], 0, reason: report);
  expect(pixels.at(rightEdgeX + outsideGap, centerY)[3], 0, reason: report);

  // 1. 左右外沿必须明显暗于玻璃内部：旧 Windows Shader 在这里输出纯白。
  expect(leftLuma, lessThan(interiorLuma - 20), reason: report);
  expect(rightLuma, lessThan(interiorLuma - 20), reason: report);

  // 2. 深边只在左右法线方向出现；上下只保留浅灰环，因此顶部外沿应比
  //    左侧外沿更亮，但仍因浅灰环而暗于内部。
  expect(leftLuma, lessThan(topLuma - 10), reason: report);
  expect(topLuma, lessThan(interiorLuma), reason: report);

  // 3. 两层描边都是冷调色（B 通道不低于 R），而不是白色 Fresnel 亮边。
  final left = pixels.at(leftEdgeX, centerY);
  expect(left[2], greaterThanOrEqualTo(left[0]), reason: report);
}

/// 与 Shader 入口标记相同的 Adler-32：先统一换行为 LF，再按 UTF-8 字节计算。
String _normalizedAdler32(String source) {
  const modulus = 65521;
  var sumA = 1;
  var sumB = 0;
  final normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  for (final byte in utf8.encode(normalized)) {
    sumA = (sumA + byte) % modulus;
    sumB = (sumB + sumA) % modulus;
  }
  return ((sumB << 16) | sumA).toRadixString(16).padLeft(8, '0');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('所有包含 edge_treatment.glsl 的入口都携带最新校验标记', () {
    // 中文说明：Flutter 增量构建不追踪自定义 #include。若新增入口（如本次
    // 的 Windows 合成 Shader）忘记携带标记，修改共享描边后会继续复用旧
    // 编译产物，出现“源码已修、运行仍是白边”的假象。
    final expected = _normalizedAdler32(
      File('shaders/edge_treatment.glsl').readAsStringSync(),
    );
    final markerPattern = RegExp(
      r'POIESIS_EDGE_TREATMENT_ADLER32:\s*([0-9a-f]{8})',
    );
    final entries = Directory('shaders')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.frag'))
        .where(
          (file) => file
              .readAsStringSync()
              .contains('#include "edge_treatment.glsl"'),
        )
        .toList();

    expect(
      entries.map((file) => file.uri.pathSegments.last),
      containsAll(<String>[
        'liquid_glass_final_render.frag',
        'liquid_glass_final_render_windows.frag',
        'lightweight_glass.frag',
        'interactive_indicator.frag',
      ]),
    );
    for (final entry in entries) {
      final match = markerPattern.firstMatch(entry.readAsStringSync());
      expect(match, isNotNull, reason: '${entry.path} 缺少校验标记');
      expect(match!.group(1), expected, reason: '${entry.path} 校验标记过期');
    }
  });

  test('Windows 合成 Shader 的解析圆角矩形路径保留双层冷灰/深色描边', () async {
    final pixels = await _renderWindowsGlass(useTexturePath: false);
    _expectDualLayerRim(
      pixels,
      'analytic',
      minEdgeAlpha: 250,
      outsideGap: 1,
    );
  });

  test('Windows 合成 Shader 的超椭圆几何纹理路径保留双层冷灰/深色描边', () async {
    // 中文说明：底部导航自 GlassTabBar.bottom 改用超椭圆后，在 Windows 上
    // 会回退到 geometry texture；这是用户截图中白色描边的实际路径。
    final pixels = await _renderWindowsGlass(useTexturePath: true);
    _expectDualLayerRim(
      pixels,
      'texture',
      minEdgeAlpha: 200,
      outsideGap: 2,
    );
  });
}
