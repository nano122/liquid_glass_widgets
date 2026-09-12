// ignore_for_file: public_member_api_docs

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import '_env_web.dart' if (dart.library.io) '_env_io.dart';

final String _shadersRoot =
    !kIsWeb && isTestEnvironment ? '' : 'packages/liquid_glass_widgets/';

abstract class ShaderKeys {
  const ShaderKeys._();

  /// 返回当前平台应加载的几何预计算 Shader 资产。
  ///
  /// 中文说明：Windows Impeller/OpenGLESSDF 会在首次呈现时由 ANGLE 驱动
  /// 链接运行时 GLSL。通用几何 Shader 的 16 形状双向展开会生成接近 1MB
  /// 的运行时资产，因此原生 Windows 必须在 [FragmentProgram] 加载前选择
  /// 8 形状单向融合版本；只在运行时减少实际形状数无法缩小驱动编译单元。
  static String blendedGeometryForPlatform(
    TargetPlatform platform, {
    required bool isWeb,
  }) {
    final fileName = !isWeb && platform == TargetPlatform.windows
        ? 'liquid_glass_geometry_blended_windows.frag'
        : 'liquid_glass_geometry_blended.frag';
    return '${_shadersRoot}shaders/$fileName';
  }

  static String get blendedGeometry => blendedGeometryForPlatform(
        defaultTargetPlatform,
        isWeb: kIsWeb,
      );

  /// 当前平台是否能把超椭圆解析 SDF 编译进最终合成 Shader。
  ///
  /// 中文说明：Flutter 3.47.x 的 Windows Impeller/OpenGLESSDF 在编译包含
  /// `sdfSquircleAsym` 动态幂函数的最终 Shader 时会整层输出空白，即使运行时
  /// 从未选择 mode 2。Web 不走该原生后端，所以只隔离原生 Windows。
  static bool supportsAnalyticSuperellipseForPlatform(
    TargetPlatform platform, {
    required bool isWeb,
  }) =>
      isWeb || platform != TargetPlatform.windows;

  static bool get supportsAnalyticSuperellipse =>
      supportsAnalyticSuperellipseForPlatform(
        defaultTargetPlatform,
        isWeb: kIsWeb,
      );

  /// 返回当前平台应加载的最终合成 Shader 资产。
  ///
  /// 中文说明：必须在 [FragmentProgram] 加载前选择文件；只把 mode 写成 0
  /// 仍会让 Windows 驱动编译不兼容分支，无法修复首屏空白。
  static String liquidGlassRenderForPlatform(
    TargetPlatform platform, {
    required bool isWeb,
  }) {
    final fileName = supportsAnalyticSuperellipseForPlatform(
      platform,
      isWeb: isWeb,
    )
        ? 'liquid_glass_final_render.frag'
        : 'liquid_glass_final_render_windows.frag';
    return '${_shadersRoot}shaders/$fileName';
  }

  static String get liquidGlassRender => liquidGlassRenderForPlatform(
        defaultTargetPlatform,
        isWeb: kIsWeb,
      );
}
