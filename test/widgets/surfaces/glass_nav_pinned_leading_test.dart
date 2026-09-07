import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/widgets/surfaces/shared/glass_nav_pinned_host.dart';

void main() {
  setUp(() {
    // Headless test runs report no shader support; force the gate open so the
    // pinned path is exercised. Individual tests override to test the gate.
    GlassNavigationShellState.debugPinningSupported = true;
  });

  tearDown(() {
    GlassNavigationShellState.debugPinningSupported = null;
  });

  Widget shellApp(
    Widget home, {
    bool enabled = true,
    List<LocalizationsDelegate<dynamic>>? localizationsDelegates,
  }) {
    return CupertinoApp(
      localizationsDelegates: localizationsDelegates,
      builder: (context, child) =>
          GlassNavigationShell(enabled: enabled, child: child!),
      home: home,
    );
  }

  /// Settles the route transition and the post-frame registration handover.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump();
  }

  /// The [Semantics] node an item declares, rather than the merged semantics
  /// tree, so the assertion does not need a semantics handle.
  Finder semanticsLabelled(String label) => find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == label,
      );

  Finder inHost(Finder matching) => find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: matching,
      );

  group('the automatic back button', () {
    testWidgets('a back-only cluster is still the 44pt circle', (tester) async {
      await tester.pumpWidget(shellApp(const _Screen(title: 'Root')));
      await settle(tester);
      await _push(tester, const _Screen(title: 'Detail'));
      await settle(tester);

      // The shell it renders now comes from the same cluster machinery as the
      // actions capsule, so this asserts the geometry has not shifted: 44pt
      // square, where the capsule's 22pt radius clamps to exactly a circle.
      expect(
        tester.getSize(inHost(find.byType(GlassButton))),
        const Size(
          GlassNavPinnedMetrics.backDiameter,
          GlassNavPinnedMetrics.backDiameter,
        ),
      );
    });

    testWidgets('its label comes from CupertinoLocalizations', (tester) async {
      await tester.pumpWidget(shellApp(
        const _Screen(title: 'Root'),
        localizationsDelegates: const [
          _StubCupertinoLocalizationsDelegate(),
          DefaultWidgetsLocalizations.delegate,
        ],
      ));
      await settle(tester);
      await _push(tester, const _Screen(title: 'Detail'));
      await settle(tester);

      expect(inHost(semanticsLabelled('Atrás')), findsOneWidget);
    });

    testWidgets('defaults to the untranslated label with no delegates',
        (tester) async {
      await tester.pumpWidget(shellApp(const _Screen(title: 'Root')));
      await settle(tester);
      await _push(tester, const _Screen(title: 'Detail'));
      await settle(tester);

      expect(inHost(semanticsLabelled('Back')), findsOneWidget);
    });
  });

  group('replace versus supplement', () {
    testWidgets('a leading item replaces the back button', (tester) async {
      await tester.pumpWidget(shellApp(const _Screen(title: 'Root')));
      await settle(tester);
      await _push(tester, _Screen(title: 'Detail', leading: [_cancel()]));
      await settle(tester);

      expect(inHost(find.byIcon(CupertinoIcons.xmark)), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.back), findsNothing);
    });

    testWidgets('leadingItemsSupplementBackButton shows both', (tester) async {
      await tester.pumpWidget(shellApp(const _Screen(title: 'Root')));
      await settle(tester);
      await _push(
          tester,
          _Screen(
            title: 'Detail',
            leading: [_cancel()],
            supplement: true,
          ));
      await settle(tester);

      expect(inHost(find.byIcon(CupertinoIcons.back)), findsOneWidget);
      expect(inHost(find.byIcon(CupertinoIcons.xmark)), findsOneWidget);
      // Two shells, because the back button shares its background with nothing.
      expect(inHost(find.byType(GlassButton)), findsNWidgets(2));
    });

    testWidgets('backButton: false wins over supplementing', (tester) async {
      await tester.pumpWidget(shellApp(const _Screen(title: 'Root')));
      await settle(tester);
      await _push(
          tester,
          _Screen(
            title: 'Detail',
            leading: [_cancel()],
            supplement: true,
            backButton: false,
          ));
      await settle(tester);

      expect(find.byIcon(CupertinoIcons.back), findsNothing);
      expect(inHost(find.byIcon(CupertinoIcons.xmark)), findsOneWidget);
    });

    testWidgets('a leading on a root route pins without a back button',
        (tester) async {
      await tester.pumpWidget(
        shellApp(_Screen(title: 'Root', leading: [_cancel()])),
      );
      await settle(tester);

      expect(inHost(find.byIcon(CupertinoIcons.xmark)), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.back), findsNothing);
    });
  });

  group('backgrounds', () {
    testWidgets('an item that hides its background gets no glass shell',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        leading: [
          const GlassBarItem.custom(
            child: SizedBox(width: 44, height: 44, child: Text('avatar')),
            background: GlassBarItemBackground.none,
          ),
        ],
      )));
      await settle(tester);

      expect(inHost(find.text('avatar')), findsOneWidget);
      expect(inHost(find.byType(GlassButton)), findsNothing);
    });

    testWidgets('a separate item is its own shell beside a shared capsule',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        leading: [
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.xmark),
            background: GlassBarItemBackground.separate,
            onTap: () {},
          ),
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.add),
            onTap: () {},
          ),
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.search),
            onTap: () {},
          ),
        ],
      )));
      await settle(tester);

      final shells = inHost(find.byType(GlassButton));
      expect(shells, findsNWidgets(2));
      // The lone separate item is the 44pt circle; the two shared ones are one
      // capsule at the taller icon-slot height.
      expect(
        tester.getSize(shells.first).height,
        GlassNavPinnedMetrics.backDiameter,
      );
      expect(
        tester.getSize(shells.last).height,
        GlassNavPinnedMetrics.slot,
      );
    });
    testWidgets('a lone shell grows into a shared capsule', (tester) async {
      await tester.pumpWidget(shellApp(const _Screen(title: 'Root')));
      await settle(tester);
      await _push(tester, const _Screen(title: 'Detail'));
      await settle(tester);

      // The back button shares with nothing, so it is the circular shell.
      Size shell() => tester.getSize(inHost(find.byType(GlassButton)));
      expect(shell().height, GlassNavPinnedMetrics.backDiameter);

      await _push(
          tester,
          _Screen(
            title: 'Library',
            backButton: false,
            leading: [
              GlassBarItem.icon(
                icon: const Icon(CupertinoIcons.sidebar_left),
                onTap: () {},
              ),
              GlassBarItem.icon(
                icon: const Icon(CupertinoIcons.slider_horizontal_3),
                onTap: () {},
              ),
            ],
          ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      // Mid-morph both dimensions are in flight, which is the whole point:
      // one element, geometry animating, no remount. The gel swell can carry
      // them past both endpoints while the shell puffs, so the upper bound is
      // the swollen size, not the destination's.
      const swollen = 1.0 + GlassNavPinnedMetrics.swellAmount;
      final mid = shell();
      expect(mid.height, greaterThan(GlassNavPinnedMetrics.backDiameter));
      expect(mid.height, lessThan(GlassNavPinnedMetrics.slot * swollen));
      expect(mid.width, greaterThan(GlassNavPinnedMetrics.backDiameter));
      expect(mid.width, lessThan(GlassNavPinnedMetrics.slot * 2 * swollen));

      await settle(tester);
      expect(
        shell(),
        const Size(
          GlassNavPinnedMetrics.slot * 2,
          GlassNavPinnedMetrics.slot,
        ),
      );
    });
  });

  group('anchoring', () {
    testWidgets('a leading cluster grows away from the leading edge',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        leading: [
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.add),
            id: 'add',
            onTap: () {},
          ),
        ],
      )));
      await settle(tester);
      final before = tester.getTopLeft(inHost(find.byIcon(CupertinoIcons.add)));

      await _push(
          tester,
          _Screen(
            title: 'Detail',
            backButton: false,
            leading: [
              GlassBarItem.icon(
                icon: const Icon(CupertinoIcons.add),
                id: 'add',
                onTap: () {},
              ),
              GlassBarItem.icon(
                icon: const Icon(CupertinoIcons.search),
                id: 'search',
                onTap: () {},
              ),
            ],
          ));
      await settle(tester);

      // The matched item holds its place while the capsule grows trailing-ward.
      // Anchored at the trailing edge instead, it would have shifted by a slot.
      expect(
        tester.getTopLeft(inHost(find.byIcon(CupertinoIcons.add))).dx,
        moreOrLessEquals(before.dx, epsilon: 0.5),
      );
    });

    test('matchGlassNavActions counts positions from the anchored edge', () {
      final a =
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {});
      final b = GlassBarItem.icon(
          icon: const Icon(CupertinoIcons.search), onTap: () {});
      final c = GlassBarItem.icon(
          icon: const Icon(CupertinoIcons.bell), onTap: () {});

      // Leading-anchored: the first item of each cluster is the same slot.
      final leading = matchGlassNavActions(
        [a as GlassBarActionItem],
        [b as GlassBarActionItem, c as GlassBarActionItem],
        anchoredAtStart: true,
      );
      expect(leading.singleWhere((s) => s.toItem == b).fromItem, same(a));
      expect(leading.singleWhere((s) => s.toItem == c).isEnter, isTrue);

      // Trailing-anchored: the last item of each cluster is, which is the
      // existing default.
      final trailing = matchGlassNavActions([a], [b, c]);
      expect(trailing.singleWhere((s) => s.toItem == c).fromItem, same(a));
      expect(trailing.singleWhere((s) => s.toItem == b).isEnter, isTrue);
    });
  });

  group('interaction', () {
    testWidgets('leading items are tappable at rest and inert mid-transition',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        leading: [
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.xmark),
            onTap: () => taps++,
          ),
        ],
      )));
      await settle(tester);

      await tester.tap(inHost(find.byIcon(CupertinoIcons.xmark)));
      expect(taps, 1);

      // Mid-push the chrome shows a blend of two routes, so taps are swallowed.
      // Before the midpoint the leading cluster is still the outgoing route's.
      await _push(tester, const _Screen(title: 'Detail'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(inHost(find.byIcon(CupertinoIcons.xmark)),
          warnIfMissed: false);
      await settle(tester);
      expect(taps, 1);
    });
  });

  group('fallback rendering', () {
    testWidgets('without a shell the leading items render in-route',
        (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: _Screen(title: 'Root', leading: [_cancel()]),
      ));
      await settle(tester);

      expect(find.byType(GlassNavPinnedHost), findsNothing);
      expect(
        find.descendant(
          of: find.byType(GlassAppBar),
          matching: find.byIcon(CupertinoIcons.xmark),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a bare leading item renders in-route without a shell',
        (tester) async {
      await tester.pumpWidget(const CupertinoApp(
        home: _Screen(
          title: 'Root',
          leading: [
            GlassBarItem.custom(
              child: Text('avatar'),
              background: GlassBarItemBackground.none,
            ),
          ],
        ),
      ));
      await settle(tester);

      expect(find.text('avatar'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GlassAppBar),
          matching: find.byType(GlassButtonGroup),
        ),
        findsNothing,
      );
    });
  });

  group('API guards', () {
    testWidgets('spacers are rejected in leading too', (tester) async {
      await tester.pumpWidget(shellApp(const _Screen(
        title: 'Root',
        leading: [GlassBarItem.spacer()],
      )));
      expect(tester.takeException(), isA<AssertionError>());
    });
  });
}

GlassBarItem _cancel() => GlassBarItem.icon(
      icon: const Icon(CupertinoIcons.xmark),
      onTap: () {},
    );

Future<void> _push(WidgetTester tester, Widget screen) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  navigator.push(CupertinoPageRoute<void>(builder: (_) => screen));
  await tester.pump();
}

/// A minimal screen with a pinned bar.
class _Screen extends StatelessWidget {
  const _Screen({
    required this.title,
    this.leading = const [],
    this.backButton = true,
    this.supplement = false,
  });

  final String title;
  final List<GlassBarItem> leading;
  final bool backButton;
  final bool supplement;

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: GlassAppBar.pinned(
        title: Text(title),
        leading: leading,
        backButton: backButton,
        leadingItemsSupplementBackButton: supplement,
      ),
      body: Center(child: Text('$title body')),
    );
  }
}

/// [DefaultCupertinoLocalizations] with a translated back label, standing in
/// for a real localisation bundle.
class _StubCupertinoLocalizations extends DefaultCupertinoLocalizations {
  const _StubCupertinoLocalizations();

  @override
  String get backButtonLabel => 'Atrás';
}

class _StubCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _StubCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) async =>
      const _StubCupertinoLocalizations();

  @override
  bool shouldReload(_StubCupertinoLocalizationsDelegate old) => false;
}
