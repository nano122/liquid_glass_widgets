// ignore_for_file: public_member_api_docs

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

/// A callback used by [MultiShaderBuilder].
typedef MultiShaderBuilderCallback = Widget Function(
  BuildContext context,
  List<ui.FragmentShader> shaders,
  Widget? child,
);

/// A callback used by [ShaderBuilder].
typedef ShaderBuilderCallback = Widget Function(
  BuildContext context,
  ui.FragmentShader shader,
  Widget? child,
);

/// A widget that loads and caches a single [ui.FragmentProgram] based on an [assetKey].
class ShaderBuilder extends StatelessWidget {
  /// Create a new [ShaderBuilder].
  const ShaderBuilder(
    this.builder, {
    required this.assetKey,
    super.key,
    this.child,
  });

  /// The asset key used to lookup the shader.
  final String assetKey;

  /// The child widget to pass through to the [builder], optional.
  final Widget? child;

  /// The builder that provides access to the [ui.FragmentShader].
  final ShaderBuilderCallback builder;

  @override
  Widget build(BuildContext context) {
    return MultiShaderBuilder(
      (context, shaders, child) => builder(context, shaders.first, child),
      assetKeys: [assetKey],
      child: child,
    );
  }
}

/// A widget that loads and caches [ui.FragmentProgram]s based on asset keys.
///
/// Usage of this widget avoids the need for a user authored stateful widget
/// for managing the lifecycle of loading shaders. Once shaders are cached,
/// subsequent usages of them via a [MultiShaderBuilder] will always be
/// available synchronously. These shaders can also be precached imperatively
/// with [MultiShaderBuilder.precacheShader].
///
/// If the shaders are not yet loaded, the provided child widget or a [SizedBox]
/// is returned instead of invoking the builder callback.
///
/// Example: providing access to [ui.FragmentShader] instances.
///
/// ```dart
/// Widget build(BuildContext context) {
///  return ShaderBuilder(
///    builder: (BuildContext context, List<ui.FragmentShader> shaders, Widget?
/// child) {
///      return WidgetThatUsesFragmentShaders(
///        shaders: shaders,
///        child: child,
///      );
///    },
///    assetKeys: ['shader1.frag', 'shader2.frag'],
///    child: Text('Hello, Shaders'),
///  );
/// }
/// ```
class MultiShaderBuilder extends StatefulWidget {
  /// Create a new [MultiShaderBuilder].
  const MultiShaderBuilder(
    this.builder, {
    required this.assetKeys,
    super.key,
    this.child,
  });

  /// The asset keys used to lookup shaders.
  final List<String> assetKeys;

  /// The child widget to pass through to the [builder], optional.
  final Widget? child;

  /// The builder that provides access to [ui.FragmentShader]s.
  final MultiShaderBuilderCallback builder;

  @override
  State<StatefulWidget> createState() {
    return _MultiShaderBuilderState();
  }

  /// Precache a [ui.FragmentProgram] based on its [assetKey].
  ///
  /// When this future has completed, any newly created [MultiShaderBuilder]s
  /// that reference this asset will be guaranteed to immediately have access to
  /// the shader.
  static Future<void> precacheShader(String assetKey) {
    if (_MultiShaderBuilderState._shaderCache.containsKey(assetKey)) {
      return Future<void>.value();
    }
    return ui.FragmentProgram.fromAsset(assetKey).then(
      (ui.FragmentProgram program) {
        _MultiShaderBuilderState._shaderCache[assetKey] = program;
      },
      onError: (Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stackTrace),
        );
      },
    );
  }

  /// Precache multiple [ui.FragmentProgram]s based on their [assetKeys].
  ///
  /// When this future has completed, any newly created [MultiShaderBuilder]s
  /// that reference these assets will be guaranteed to immediately have access
  /// to the shaders.
  static Future<void> precacheShaders(List<String> assetKeys) {
    return Future.wait(
      assetKeys.map(precacheShader),
    );
  }

  /// Returns the cached [ui.FragmentProgram] for [assetKey], or `null` if it
  /// has not been precached yet.
  ///
  /// This is an internal accessor used by the pipeline warm-up path in
  /// [LiquidGlassWidgets.initialize] to reuse already-compiled program objects
  /// rather than loading them a second time from the asset bundle.
  ///
  /// Must only be called after [precacheShaders] has completed for the
  /// requested [assetKey].
  // ignore: library_private_types_in_public_api
  static ui.FragmentProgram? cachedProgram(String assetKey) =>
      _MultiShaderBuilderState._shaderCache[assetKey];
}

class _MultiShaderBuilderState extends State<MultiShaderBuilder> {
  final Map<String, ui.FragmentProgram> _programs = {};
  final Map<String, ui.FragmentShader> _shaders = {};
  int _loadGeneration = 0;

  static final Map<String, ui.FragmentProgram> _shaderCache =
      <String, ui.FragmentProgram>{};

  @override
  void initState() {
    super.initState();
    _loadShaders(widget.assetKeys);
  }

  @override
  void didUpdateWidget(covariant MultiShaderBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 中文说明：ShaderBuilder 每次 build 都会创建新的 `[assetKey]` List；
    // List 默认按身份比较会把内容相同的 key 误判为变化，进而每次父级重建
    // 都重新创建 FragmentShader。这里按顺序比较内容，顺序变化仍会正确重载。
    if (!listEquals(oldWidget.assetKeys, widget.assetKeys)) {
      _loadShaders(widget.assetKeys);
    }
  }

  void _loadShaders(List<String> assetKeys) {
    final generation = ++_loadGeneration;
    _disposeShaders();
    _programs.clear();

    // Check which shaders are already cached
    final uncachedKeys = <String>[];
    for (final assetKey in assetKeys) {
      if (_shaderCache.containsKey(assetKey)) {
        _programs[assetKey] = _shaderCache[assetKey]!;
        _shaders[assetKey] = _programs[assetKey]!.fragmentShader();
      } else {
        uncachedKeys.add(assetKey);
      }
    }

    // If all shaders are cached, we're done
    if (uncachedKeys.isEmpty) {
      return;
    }

    // Load uncached shaders
    for (final assetKey in uncachedKeys) {
      ui.FragmentProgram.fromAsset(assetKey).then(
        (ui.FragmentProgram program) {
          // FragmentProgram 是不可变编译产物，可以跨实例缓存；即便本次请求
          // 已过期，后来挂载的组件仍可复用它，不需要再次读盘和编译。
          _shaderCache[assetKey] = program;
          if (!mounted || generation != _loadGeneration) {
            return;
          }
          setState(() {
            _programs[assetKey] = program;
            _shaders[assetKey] = program.fragmentShader();
          });
        },
        onError: (Object error, StackTrace stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stackTrace),
          );
        },
      );
    }
  }

  void _disposeShaders() {
    // 中文说明：FragmentShader 持有可变 uniform、sampler 和原生 GPU 资源，
    // 不能像 FragmentProgram 一样全局共享；key 变化或组件销毁时必须显式释放。
    for (final shader in _shaders.values) {
      shader.dispose();
    }
    _shaders.clear();
  }

  @override
  void dispose() {
    // 让尚未完成的异步加载回调失效，再释放当前实例，避免旧 Future 把
    // Shader 写回已经销毁或已经切换 key 的 State。
    _loadGeneration++;
    _disposeShaders();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Check if all shaders are loaded
    if (_shaders.length != widget.assetKeys.length) {
      return widget.child ?? const SizedBox.shrink();
    }

    // Build shader list in the same order as assetKeys
    final shaders = widget.assetKeys.map((key) => _shaders[key]!).toList();

    return widget.builder(context, shaders, widget.child);
  }
}
