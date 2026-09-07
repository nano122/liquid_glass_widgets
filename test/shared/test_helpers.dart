import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/src/renderer/liquid_glass_renderer.dart';
import 'package:liquid_glass_widgets/widgets/shared/adaptive_liquid_glass_layer.dart';

/// Standard constraints for golden test scenarios
final testScenarioConstraints = BoxConstraints.tight(const Size(500, 500));

/// Glass settings without lighting effects for predictable golden tests
const settingsWithoutLighting = LiquidGlassSettings(
  chromaticAberration: 0,
  lightIntensity: 0,
  blur: 0,
);

/// Default glass settings for widget tests
/// Note: Tests should use fake: true on LiquidGlassLayer to avoid shader loading
const defaultTestGlassSettings = LiquidGlassSettings(
  thickness: 30,
  blur: 3,
  refractiveIndex: 1.59,
);

/// Helper to pump a frame before running a golden assertion.
Future<void> pumpOnce(WidgetTester tester) async {
  await tester.pump();
}

/// A scenario within a [GoldenTestGroup].
class GoldenTestScenario extends StatelessWidget {
  /// Creates a [GoldenTestScenario].
  const GoldenTestScenario({
    required this.name,
    required this.child,
    this.constraints,
    super.key,
  });

  /// The name / label of the scenario.
  final String name;

  /// The widget under test.
  final Widget child;

  /// Optional constraints for the scenario.
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    Widget content = child;
    if (constraints != null) {
      content = ConstrainedBox(
        constraints: constraints!,
        child: content,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            name,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontFamily: 'monospace',
              decoration: TextDecoration.none,
            ),
          ),
        ),
        content,
      ],
    );
  }
}

/// Groups multiple [GoldenTestScenario] widgets in a structured layout.
class GoldenTestGroup extends StatelessWidget {
  /// Creates a [GoldenTestGroup].
  const GoldenTestGroup({
    required this.children,
    this.scenarioConstraints,
    this.columns = 2,
    super.key,
  });

  /// List of test scenarios to display.
  final List<GoldenTestScenario> children;

  /// Default constraints applied to each scenario child.
  final BoxConstraints? scenarioConstraints;

  /// Number of columns (when applicable).
  final int columns;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1E1E2E),
      padding: const EdgeInsets.all(20),
      child: Wrap(
        spacing: 20,
        runSpacing: 20,
        children: [
          for (final scenario in children)
            if (scenarioConstraints != null && scenario.constraints == null)
              GoldenTestScenario(
                name: scenario.name,
                constraints: scenarioConstraints,
                child: scenario.child,
              )
            else
              scenario,
        ],
      ),
    );
  }
}

/// Executes a golden test using Flutter SDK's native [matchesGoldenFile].
void goldenTest(
  String description, {
  required String fileName,
  required Widget Function() builder,
  Future<void> Function(WidgetTester)? pumpBeforeTest,
  BoxConstraints? scenarioConstraints,
  BoxConstraints? constraints,
  List<String>? tags,
}) {
  testWidgets(
    description,
    tags: tags,
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: const Color(0xFF1E1E2E),
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: const ValueKey('golden_scenario_root'),
                child: builder(),
              ),
            ),
          ),
        ),
      );

      if (pumpBeforeTest != null) {
        await pumpBeforeTest(tester);
      } else {
        await tester.pumpAndSettle();
      }

      await expectLater(
        find.byKey(const ValueKey('golden_scenario_root')),
        matchesGoldenFile('goldens/$fileName.png'),
      );
    },
  );
}

/// Wraps a widget with grid paper background for visual reference in golden tests
Widget buildWithGridPaper(Widget child) {
  return ColoredBox(
    color: Colors.white,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          const Positioned.fill(
            child: GridPaper(
              color: Colors.black,
            ),
          ),
          Center(
            child: child,
          ),
        ],
      ),
    ),
  );
}

/// Wraps a widget with a colorful gradient background for contrast
Widget buildWithGradientBackground(Widget child) {
  return Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF6366F1),
          Color(0xFF8B5CF6),
          Color(0xFFEC4899),
        ],
      ),
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: child),
    ),
  );
}

/// Wraps a widget with gradient background AND a glass layer for golden tests
Widget buildWithGradientAndGlass(Widget child,
    {LiquidGlassSettings? settings}) {
  return buildWithGradientBackground(
    AdaptiveLiquidGlassLayer(
      settings: settings ?? defaultTestGlassSettings,
      child: child,
    ),
  );
}

/// Creates a standard test wrapper with MaterialApp for widget tests
Widget createTestApp({
  required Widget child,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme ??
        ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.transparent,
        ),
    home: Scaffold(
      backgroundColor: Colors.transparent,
      body: child,
    ),
  );
}

/// Creates a test wrapper with a LiquidGlassLayer configured for testing
Widget createTestAppWithGlassLayer({
  required Widget child,
  LiquidGlassSettings? settings,
  ThemeData? theme,
}) {
  return createTestApp(
    theme: theme,
    child: AdaptiveLiquidGlassLayer(
      settings: settings ?? defaultTestGlassSettings,
      child: child,
    ),
  );
}
