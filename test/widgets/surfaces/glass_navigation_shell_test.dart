import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/widgets/effects/shared/glass_materialize_effect.dart';
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

  Widget shellApp(Widget home, {bool enabled = true}) {
    return CupertinoApp(
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

  /// How materialized the pinned actions capsule is this frame, 0 to 1.
  ///
  /// Reads the effect wrapper the host puts around the capsule; a capsule
  /// that is not mounted at all reads as 0.
  double capsulePhase(WidgetTester tester) {
    final effects = find.descendant(
      of: find.byType(GlassNavPinnedHost),
      matching: find.byType(GlassMaterializeEffect),
    );
    for (final element in effects.evaluate()) {
      final effect = element.widget as GlassMaterializeEffect;
      if (effect.alignment == Alignment.centerRight) return effect.progress;
    }
    return 0.0;
  }

  /// How materialized the pinned back button is this frame, 0 to 1; -1 when
  /// it is not mounted at all.
  double backPhase(WidgetTester tester) {
    final effects = find.descendant(
      of: find.byType(GlassNavPinnedHost),
      matching: find.byType(GlassMaterializeEffect),
    );
    for (final element in effects.evaluate()) {
      final effect = element.widget as GlassMaterializeEffect;
      if (effect.alignment == Alignment.centerLeft) return effect.progress;
    }
    return -1.0;
  }

  /// The back button drawn by the shell, as opposed to any in-route fallback.
  Finder pinnedBack() => find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byIcon(CupertinoIcons.back),
      );

  group('registration and hoisting', () {
    testWidgets('a screen with pinnedActions hands its items to the host',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.add),
            onTap: () {},
          ),
        ],
      )));
      await settle(tester);

      // The host renders the capsule above the navigator...
      expect(find.byType(GlassNavPinnedHost), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.add),
        ),
        findsOneWidget,
      );
      // ...and the in-route bar holds only an unpainted measuring placeholder.
      expect(
        find.descendant(
          of: find.byType(GlassAppBar),
          matching: find.byType(GlassButtonGroup),
        ),
        findsNothing,
      );
    });

    testWidgets('no back button on a root route', (tester) async {
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);

      expect(find.byIcon(CupertinoIcons.back), findsNothing);
    });

    testWidgets('pushed route gets a pinned back button that pops',
        (tester) async {
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);

      await _push(tester, const _Screen(title: 'Detail', actions: []));
      await settle(tester);

      expect(find.text('Detail'), findsOneWidget);
      final back = find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byIcon(CupertinoIcons.back),
      );
      expect(back, findsOneWidget);

      await tester.tap(back);
      await settle(tester);
      expect(find.text('Detail'), findsNothing);
      // Back at the root, the button is gone again.
      expect(find.byIcon(CupertinoIcons.back), findsNothing);
    });

    testWidgets('onBack overrides the default pop', (tester) async {
      var custom = 0;
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await _push(
        tester,
        _Screen(title: 'Detail', actions: const [], onBack: () => custom++),
      );
      await settle(tester);

      await tester.tap(find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byIcon(CupertinoIcons.back),
      ));
      await settle(tester);

      expect(custom, 1);
      expect(find.text('Detail'), findsOneWidget); // custom handler didn't pop
    });

    testWidgets('pinned items are tappable at rest', (tester) async {
      var taps = 0;
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.add),
            label: 'Add',
            onTap: () => taps++,
          ),
        ],
      )));
      await settle(tester);

      await tester.tap(find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byIcon(CupertinoIcons.add),
      ));
      expect(taps, 1);
    });

    testWidgets('custom items are measured at their intrinsic width',
        (tester) async {
      const wide = SizedBox(width: 120, height: 20);
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {}),
          const GlassBarItem.custom(child: wide),
        ],
      )));
      await settle(tester);

      final capsule = tester.getSize(find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byType(GlassButton),
      ));
      // One 46pt icon slot + the 120pt custom child.
      expect(capsule.width, greaterThanOrEqualTo(166));
    });

    testWidgets('in-place pinnedActions update reaches the host',
        (tester) async {
      await tester.pumpWidget(shellApp(const _TogglingScreen()));
      await settle(tester);
      expect(find.byIcon(CupertinoIcons.bell), findsNothing);

      await tester.tap(find.text('toggle'));
      await settle(tester);

      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.bell),
        ),
        findsOneWidget,
      );
    });
  });

  group('transitions', () {
    testWidgets('chrome renders mid-transition while items morph',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.add),
            id: 'add',
            onTap: () {},
          ),
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.ellipsis),
            onTap: () {},
          ),
        ],
      )));
      await settle(tester);

      await _push(
        tester,
        _Screen(
          title: 'Detail',
          actions: [
            GlassBarItem.icon(
              icon: const Icon(CupertinoIcons.add),
              id: 'add',
              onTap: () {},
            ),
            GlassBarItem.icon(
              icon: const Icon(CupertinoIcons.search),
              onTap: () {},
            ),
          ],
        ),
      );

      // Past the swap point: incoming side shows, matched item cross-fades.
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(GlassNavPinnedHost), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.search),
        ),
        findsOneWidget,
      );

      await settle(tester);
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.ellipsis),
        ),
        findsNothing,
      );
    });

    testWidgets(
        'exiting item smoothly fades out during morph without abrupt pop',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.add),
            id: 'add',
            onTap: () {},
          ),
          GlassBarItem.icon(
            icon: const Icon(CupertinoIcons.ellipsis),
            id: 'more',
            onTap: () {},
          ),
        ],
      )));
      await settle(tester);

      await _push(
        tester,
        _Screen(
          title: 'Detail',
          actions: [
            GlassBarItem.icon(
              icon: const Icon(CupertinoIcons.ellipsis),
              id: 'more',
              onTap: () {},
            ),
          ],
        ),
      );

      // Mid-transition: exiting item ('add') is still mounted with fading opacity
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.add),
        ),
        findsOneWidget,
      );

      await settle(tester);
      // Once settled, only the destination screen's items remain
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.add),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.ellipsis),
        ),
        findsOneWidget,
      );
    });

    testWidgets('capsule switches off when the destination has no actions',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {}),
        ],
      )));
      await settle(tester);

      await _push(tester, const _Screen(title: 'Empty', actions: []));
      await settle(tester);

      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.add),
        ),
        findsNothing,
      );
      // The back button still pins: empty list opts in, it does not opt out.
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.back),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a capsule with nowhere to go dematerializes, it does not pop',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {}),
        ],
      )));
      await settle(tester);

      await _push(tester, const _Screen(title: 'Empty', actions: []));
      // Part-way into the push the outgoing capsule must still be mounted and
      // mid-dissolve: a phase of exactly 0 or 1 here is the old hard switch.
      await tester.pump(const Duration(milliseconds: 120));
      final phase = capsulePhase(tester);
      expect(phase, greaterThan(0.0));
      expect(phase, lessThan(1.0));

      await settle(tester);
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.add),
        ),
        findsNothing,
      );
    });

    testWidgets('a settled capsule sits at a paint-neutral phase',
        (tester) async {
      // The effect wraps the capsule unconditionally so its glass shell is
      // never remounted as a transition starts; at rest it must be inert.
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {}),
        ],
      )));
      await settle(tester);
      expect(capsulePhase(tester), 1.0);
    });

    testWidgets('the chrome holds still under an uncommitted back-swipe',
        (tester) async {
      // Dragging is not deciding. Until the pop commits there is no answer to
      // which route's chrome wins, so scrubbing the dissolve under the finger
      // reads as the bar guessing — and a swipe the user abandons should
      // never have half-dissolved anything.
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {}),
        ],
      )));
      await settle(tester);
      await _push(tester, const _Screen(title: 'Empty', actions: []));
      await settle(tester);

      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final resting = capsulePhase(tester);

      final gesture = await tester.startGesture(const Offset(2, 300));
      await gesture.moveTo(Offset(width * 0.48, 300));
      await tester.pump();
      expect(
        capsulePhase(tester),
        resting,
        reason: 'the capsule must not move while the finger is still down',
      );

      // Committing releases it: the hold lifts and the chrome transitions.
      await gesture.moveTo(Offset(width * 0.9, 300));
      await gesture.up();

      // It must play, and play long enough to see. Two regressions live here:
      //
      // The hold was keyed on `userGestureInProgress`, which Cupertino leaves
      // true until the commit animation has finished, so the chrome stayed
      // frozen for the whole pop and snapped at the end.
      //
      // Then, re-timed over the route's remaining travel, it technically
      // animated but Cupertino sizes a committed swipe by how far the drag
      // got — a late release left about five frames, which reads as no
      // transition at all. Counting frames is what tells those apart; a bare
      // "did it move" assertion passes on both.
      var moving = 0;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final phase = capsulePhase(tester);
        if (phase > resting && phase < 1.0) moving++;
      }
      expect(moving, greaterThanOrEqualTo(6),
          reason: 'the capsule must animate across the commit for long enough '
              'to be seen, not snap or flash past in a couple of frames');

      await settle(tester);
      expect(capsulePhase(tester), 1.0,
          reason: 'the root capsule is back once the pop commits');
    });

    testWidgets('a cancelled back-swipe leaves the chrome exactly as it was',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {}),
        ],
      )));
      await settle(tester);
      await _push(tester, const _Screen(title: 'Empty', actions: []));
      await settle(tester);

      // Scrub deep past the point the dissolve window used to open, then drag
      // back to the edge so the gesture is cancelled rather than committed.
      // Because the chrome never started moving there is nothing to rewind:
      // it reads the same at every point of an abandoned swipe.
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final resting = capsulePhase(tester);
      final gesture = await tester.startGesture(const Offset(2, 300));
      await gesture.moveTo(Offset(width * 0.48, 300));
      await tester.pump();
      expect(capsulePhase(tester), resting);

      await gesture.moveTo(const Offset(4, 300));
      await tester.pump();
      expect(capsulePhase(tester), resting);
      await gesture.up();
      await settle(tester);
      expect(capsulePhase(tester), resting,
          reason: 'an abandoned swipe leaves the chrome untouched');
      // Back where it started: the destination still has no capsule.
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.add),
        ),
        findsNothing,
      );
    });

    testWidgets('reduce motion switches instead of dissolving', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        builder: (context, child) => GlassAccessibilityScope(
          reduceMotion: true,
          child: GlassNavigationShell(child: child!),
        ),
        home: _Screen(
          title: 'Root',
          actions: [
            GlassBarItem.icon(
              icon: const Icon(CupertinoIcons.add),
              onTap: () {},
            ),
          ],
        ),
      ));
      await settle(tester);

      await _push(tester, const _Screen(title: 'Empty', actions: []));
      await tester.pump(const Duration(milliseconds: 120));
      // Identity: fully present or fully gone, never in between.
      expect(capsulePhase(tester), anyOf(0.0, 1.0));
    });

    testWidgets('GlassEffectTransition.identity restores the hard switch',
        (tester) async {
      await tester.pumpWidget(CupertinoApp(
        builder: (context, child) => GlassNavigationShell(
          effectTransition: GlassEffectTransition.identity,
          child: child!,
        ),
        home: _Screen(
          title: 'Root',
          actions: [
            GlassBarItem.icon(
              icon: const Icon(CupertinoIcons.add),
              onTap: () {},
            ),
          ],
        ),
      ));
      await settle(tester);

      await _push(tester, const _Screen(title: 'Empty', actions: []));
      await tester.pump(const Duration(milliseconds: 120));
      expect(capsulePhase(tester), anyOf(0.0, 1.0));
    });

    testWidgets('entering chrome never flashes solid before it materializes',
        (tester) async {
      // Regression: a route's `animation` is a ProxyAnimation reporting itself
      // complete at 1.0 until the navigator attaches the real controller,
      // which happens after the first build — the build that registers the
      // bar. The shell read that as "fully entered" and painted the incoming
      // back button solid for one frame before it dropped back and animated.
      await tester.pumpWidget(shellApp(const _Screen(
        title: 'Root',
        actions: [],
      )));
      await settle(tester);

      await _push(tester, const _Screen(title: 'Detail', actions: []));

      var sawRamp = false;
      for (var i = 0; i < 30; i++) {
        await tester
            .pump(i == 0 ? Duration.zero : const Duration(milliseconds: 16));
        final phase = backPhase(tester);
        if (phase > 0.0 && phase < 1.0) sawRamp = true;
        // Before the ramp has started the button must be absent, never solid.
        if (!sawRamp) {
          expect(
            phase,
            lessThan(1.0),
            reason: 'frame $i painted the back button solid before the '
                'transition had begun',
          );
        }
      }
      expect(sawRamp, isTrue, reason: 'the back button should materialize');
    });

    testWidgets('chrome retreats under a non-participating route',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {}),
        ],
      )));
      await settle(tester);

      await _push(
        tester,
        const CupertinoPageScaffold(child: Center(child: Text('Plain'))),
      );
      await settle(tester);

      // The plain route does not register; the host renders no chrome while
      // fully covered (the widget itself stays mounted at zero size).
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.add),
        ),
        findsNothing,
      );

      Navigator.of(tester.element(find.text('Plain'))).pop();
      await settle(tester);
      expect(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.add),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the back button is inert for the length of a push',
        (tester) async {
      var custom = 0;
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await _push(
        tester,
        _Screen(title: 'Detail', actions: const [], onBack: () => custom++),
      );

      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(pinnedBack(), warnIfMissed: false);
      await tester.pump();
      expect(custom, 0);

      await settle(tester);
      await tester.tap(pinnedBack());
      expect(custom, 1);
    });

    testWidgets('the back button is inert from the first frame of a pop',
        (tester) async {
      var custom = 0;
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await _push(
        tester,
        _Screen(title: 'Detail', actions: const [], onBack: () => custom++),
      );
      await settle(tester);

      // A pop leaves progress at 1.0 for its first frames, so by value alone
      // this is indistinguishable from being at rest — only the controller's
      // status says the transition is running.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.tap(pinnedBack(), warnIfMissed: false);
      await tester.pump();
      expect(custom, 0);

      await settle(tester);
    });

    testWidgets(
        'the back button is inert mid back-swipe and live again once '
        'a cancelled swipe rebounds', (tester) async {
      var custom = 0;
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await _push(
        tester,
        _Screen(title: 'Detail', actions: const [], onBack: () => custom++),
      );
      await settle(tester);

      final swipe = await tester.startGesture(const Offset(2, 300));
      await swipe.moveBy(const Offset(80, 0));
      await tester.pump();

      await tester.tap(pinnedBack(), warnIfMissed: false);
      await tester.pump();
      expect(custom, 0);

      // Cancelling springs the route back. The rebound's final value tick
      // lands on 1.0 before the controller reports itself completed, so the
      // chrome only learns it is at rest again from the status change.
      await swipe.moveBy(const Offset(-70, 0));
      await swipe.up();
      await settle(tester);

      await tester.tap(pinnedBack());
      expect(custom, 1);
      expect(find.text('Detail'), findsOneWidget);
    });

    testWidgets('pinned actions are inert mid-transition', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await _push(
        tester,
        _Screen(
          title: 'Detail',
          actions: [
            GlassBarItem.icon(
              icon: const Icon(CupertinoIcons.add),
              onTap: () => taps++,
            ),
          ],
        ),
      );

      await tester.pump(const Duration(milliseconds: 300));
      final add = find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byIcon(CupertinoIcons.add),
      );
      expect(add, findsOneWidget);
      await tester.tap(add, warnIfMissed: false);
      await tester.pump();
      expect(taps, 0);

      await settle(tester);
      await tester.tap(add);
      expect(taps, 1);
    });
  });

  group('presented routes', () {
    /// The back button drawn by the route's own bar, as opposed to the shell's.
    Finder inRouteBack() => find.descendant(
          of: find.byType(GlassAppBar),
          matching: find.byIcon(CupertinoIcons.back),
        );

    /// Pushes a screen that shows a pinned back button.
    Future<void> pushDetail(WidgetTester tester) async {
      await _push(tester, const _Screen(title: 'Detail', actions: []));
      await settle(tester);
    }

    /// Exactly one copy of the back button is on screen, never two or none.
    void expectOneCopy(String when) {
      final copies =
          pinnedBack().evaluate().length + inRouteBack().evaluate().length;
      expect(copies, 1, reason: 'copies of the back button $when');
    }

    testWidgets('a modal popup takes the chrome back into the route',
        (tester) async {
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await pushDetail(tester);
      expect(pinnedBack(), findsOneWidget);

      showCupertinoModalPopup<void>(
        context: tester.element(find.text('Detail body')),
        builder: (_) => const SizedBox(height: 400),
      );
      await settle(tester);

      // The shell draws above the navigator, so it cannot draw beneath a route
      // pushed into it. The route renders its own buttons instead.
      expect(pinnedBack(), findsNothing);
      expect(inRouteBack(), findsOneWidget);
    });

    testWidgets('so does a dialog', (tester) async {
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await pushDetail(tester);

      showCupertinoDialog<void>(
        context: tester.element(find.text('Detail body')),
        builder: (_) => const CupertinoAlertDialog(title: Text('Alert')),
      );
      await settle(tester);

      expect(pinnedBack(), findsNothing);
      expect(inRouteBack(), findsOneWidget);
    });

    testWidgets('and a fullscreen dialog, which drives no exit transition',
        (tester) async {
      // `CupertinoRouteTransitionMixin.canTransitionTo` refuses one, so the
      // covered route's `secondaryAnimation` never runs and the retreat that
      // handles an ordinary push never starts.
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await pushDetail(tester);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(CupertinoPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const CupertinoPageScaffold(
          child: Center(child: Text('Compose')),
        ),
      ));
      await settle(tester);

      expect(find.text('Compose'), findsOneWidget);
      expect(pinnedBack(), findsNothing);
    });

    testWidgets('the chrome is pinned again once the presentation is gone',
        (tester) async {
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await pushDetail(tester);

      final context = tester.element(find.text('Detail body'));
      showCupertinoDialog<void>(
        context: context,
        builder: (_) => const CupertinoAlertDialog(title: Text('Alert')),
      );
      await settle(tester);
      Navigator.of(context, rootNavigator: true).pop();
      await settle(tester);

      expect(pinnedBack(), findsOneWidget);
      expect(inRouteBack(), findsNothing);

      // ...and it is live again, not just drawn.
      await tester.tap(pinnedBack());
      await settle(tester);
      expect(find.text('Detail body'), findsNothing);
    });

    testWidgets('a committed swipe onto a non-pinned root keeps one copy',
        (tester) async {
      // Where the hand-back meets the commit-exit path. A committed swipe
      // plays from a frozen snapshot while the outgoing route is popped but
      // not yet unregistered, and the destination here contributes no chrome
      // of its own — so this is the thinnest the registry ever gets with the
      // shell still drawing.
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root')), // null actions: not pinned
      );
      await settle(tester);
      await _push(tester, const _Screen(title: 'Detail', actions: []));
      await settle(tester);
      expectOneCopy('at rest before the swipe');

      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final gesture = await tester.startGesture(const Offset(2, 300));
      await gesture.moveTo(Offset(width * 0.9, 300));
      await gesture.up();

      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final copies =
            pinnedBack().evaluate().length + inRouteBack().evaluate().length;
        expect(copies, lessThanOrEqualTo(1),
            reason: 'copies of the back button at commit frame $frame');
      }

      await settle(tester);
      // Root shows no back button at all, from either side.
      expect(find.byIcon(CupertinoIcons.back), findsNothing);
    });

    testWidgets('exactly one copy is on screen for every frame of the swap',
        (tester) async {
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await pushDetail(tester);
      expectOneCopy('at rest');

      final context = tester.element(find.text('Detail body'));
      showCupertinoDialog<void>(
        context: context,
        builder: (_) => const CupertinoAlertDialog(title: Text('Alert')),
      );
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expectOneCopy('at presentation frame $frame');
      }

      Navigator.of(context, rootNavigator: true).pop();
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expectOneCopy('at dismissal frame $frame');
      }
    });

    testWidgets('and for every frame of a push and pop between two routes',
        (tester) async {
      // The outgoing route has to keep its placeholder for the whole
      // transition: the shell is drawing a blend of both routes' items, and a
      // bar that took its own chrome back would slide a second copy out from
      // underneath the pinned one.
      await tester.pumpWidget(
        shellApp(const _Screen(title: 'Root', actions: [])),
      );
      await settle(tester);
      await pushDetail(tester);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(CupertinoPageRoute<void>(
        builder: (_) => const _Screen(title: 'Third', actions: []),
      ));
      // The first frame is Flutter's offstage build of the incoming route,
      // where neither copy is on stage yet.
      await tester.pump(const Duration(milliseconds: 16));
      for (var frame = 1; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expectOneCopy('at push frame $frame');
      }

      navigator.pop();
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expectOneCopy('at pop frame $frame');
      }
    });
  });

  group('pull-down menus', () {
    List<GlassBarItem> menuActions({String label = 'Copy'}) => [
          GlassBarItem.menu(
            icon: const Icon(CupertinoIcons.ellipsis),
            id: 'more',
            label: 'More',
            menuItems: [GlassMenuItem(title: label, onTap: () {})],
          ),
        ];

    testWidgets('a menu item opens the pull-down from the pinned capsule',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: menuActions(),
      )));
      await settle(tester);

      expect(find.text('Copy'), findsNothing);
      await tester.tap(find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byIcon(CupertinoIcons.ellipsis),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('a menu cannot be opened mid-transition', (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: menuActions(),
      )));
      await settle(tester);
      await _push(
        tester,
        _Screen(title: 'Detail', actions: menuActions(label: 'Delete')),
      );

      await tester.pump(const Duration(milliseconds: 150));
      await tester.tap(
        find.descendant(
          of: find.byType(GlassNavPinnedHost),
          matching: find.byIcon(CupertinoIcons.ellipsis),
        ),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Delete'), findsNothing);

      await settle(tester);
    });

    testWidgets('an open menu is dismissed when navigation starts',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: menuActions(),
      )));
      await settle(tester);

      await tester.tap(find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byIcon(CupertinoIcons.ellipsis),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);

      // The capsule outlives the route, so nothing else would take the menu
      // down as the page slides out from under it.
      await _push(tester, const _Screen(title: 'Detail', actions: []));
      await settle(tester);

      expect(find.text('Copy'), findsNothing);
    });

    testWidgets('only the first menu item in a cluster opens a menu',
        (tester) async {
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.menu(
            icon: const Icon(CupertinoIcons.ellipsis),
            menuItems: [GlassMenuItem(title: 'First', onTap: () {})],
          ),
          GlassBarItem.menu(
            icon: const Icon(CupertinoIcons.square_arrow_up),
            menuItems: [GlassMenuItem(title: 'Second', onTap: () {})],
          ),
        ],
      )));
      await settle(tester);

      await tester.tap(find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byIcon(CupertinoIcons.square_arrow_up),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsNothing);

      await tester.tap(find.descendant(
        of: find.byType(GlassNavPinnedHost),
        matching: find.byIcon(CupertinoIcons.ellipsis),
      ));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
    });

    testWidgets('without a shell the menu still opens in-route',
        (tester) async {
      GlassNavigationShellState.debugPinningSupported = false;
      await tester.pumpWidget(CupertinoApp(
        home: _Screen(title: 'Root', actions: menuActions()),
      ));
      await settle(tester);

      expect(find.byType(GlassNavPinnedHost), findsNothing);
      await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
      await tester.pumpAndSettle();

      expect(find.text('Copy'), findsOneWidget);
    });
  });

  group('fallback rendering', () {
    Finder inRouteCapsule() => find.descendant(
          of: find.byType(GlassAppBar),
          matching: find.byType(GlassButtonGroup),
        );

    testWidgets('without a shell the bar renders the same items in-route',
        (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: _Screen(
          title: 'Root',
          actions: [
            GlassBarItem.icon(
              icon: const Icon(CupertinoIcons.add),
              onTap: () {},
            ),
          ],
        ),
      ));
      await settle(tester);

      expect(find.byType(GlassNavPinnedHost), findsNothing);
      expect(inRouteCapsule(), findsOneWidget);
    });

    testWidgets('in-route back button appears on pushed routes and pops',
        (tester) async {
      await tester.pumpWidget(const CupertinoApp(home: _Screen(title: 'Root')));
      await settle(tester);
      await _push(tester, const _Screen(title: 'Detail', actions: []));
      await settle(tester);

      final back = find.descendant(
        of: find.byType(GlassAppBar),
        matching: find.byIcon(CupertinoIcons.back),
      );
      expect(back, findsOneWidget);
      await tester.tap(back);
      await settle(tester);
      expect(find.text('Detail'), findsNothing);
    });

    testWidgets('a disabled shell behaves like no shell', (tester) async {
      await tester.pumpWidget(shellApp(
        enabled: false,
        _Screen(
          title: 'Root',
          actions: [
            GlassBarItem.icon(
              icon: const Icon(CupertinoIcons.add),
              onTap: () {},
            ),
          ],
        ),
      ));
      await settle(tester);

      expect(find.byType(GlassNavPinnedHost), findsNothing);
      expect(inRouteCapsule(), findsOneWidget);
    });

    testWidgets('an unsupported device falls back in-route', (tester) async {
      GlassNavigationShellState.debugPinningSupported = false;
      await tester.pumpWidget(shellApp(_Screen(
        title: 'Root',
        actions: [
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {}),
        ],
      )));
      await settle(tester);

      expect(find.byType(GlassNavPinnedHost), findsNothing);
      expect(inRouteCapsule(), findsOneWidget);
    });
  });

  group('API guards', () {
    testWidgets('the two constructors cannot mix widget and data APIs',
        (tester) async {
      // Structurally impossible now: the plain constructor has no pinned
      // parameters and the pinned constructor has no widget parameters, so
      // the two APIs cannot be mixed on one bar.
      expect(
        const GlassAppBar.pinned().pinnedActions,
        isEmpty,
      );
      expect(const GlassAppBar(actions: [SizedBox()]).pinnedActions, isNull);
    });

    testWidgets('spacers are rejected until multi-capsule rendering lands',
        (tester) async {
      await tester.pumpWidget(shellApp(const _Screen(
        title: 'Root',
        actions: [GlassBarItem.spacer()],
      )));
      expect(tester.takeException(), isAssertionError);
    });

    testWidgets('pinning stays active at GlassQuality.minimal', (tester) async {
      // Regression: the gate borrowed the modal sheet morph's quality floor,
      // so a step down to `minimal` switched pinning off entirely. That is not
      // only a developer opt-in — GlassQualityAdapter steps down on its own
      // when frame times regress, so an adaptive decision about blur cost was
      // silently changing an unrelated layout behaviour.
      //
      // Pinning costs no shader; the pinned bar resolves its own quality, so
      // at `minimal` it should simply be a BackdropFilter-only bar that stays
      // put across routes.
      GlassNavigationShellState.debugPinningSupported = null;
      GlassNavigationShellState? found;
      await tester.pumpWidget(
        GlassTheme(
          data: GlassThemeData.simple(quality: GlassQuality.minimal),
          child: CupertinoApp(
            builder: (context, child) => GlassNavigationShell(child: child!),
            home: Builder(
              builder: (context) {
                found = GlassNavigationShell.maybeOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(found, isNotNull);
      expect(found!.isActive, isTrue);
    });

    testWidgets('an explicitly disabled shell is still inactive',
        (tester) async {
      // Guard for the other direction: dropping the quality gate must not
      // make `enabled: false` stop being honoured.
      GlassNavigationShellState.debugPinningSupported = null;
      GlassNavigationShellState? found;
      await tester.pumpWidget(CupertinoApp(
        builder: (context, child) =>
            GlassNavigationShell(enabled: false, child: child!),
        home: Builder(
          builder: (context) {
            found = GlassNavigationShell.maybeOf(context);
            return const SizedBox();
          },
        ),
      ));
      expect(found, isNotNull);
      expect(found!.isActive, isFalse);
    });

    testWidgets('maybeOf finds the shell from a route subtree', (tester) async {
      GlassNavigationShellState? found;
      await tester.pumpWidget(CupertinoApp(
        builder: (context, child) => GlassNavigationShell(child: child!),
        home: Builder(
          builder: (context) {
            found = GlassNavigationShell.maybeOf(context);
            return const SizedBox();
          },
        ),
      ));
      expect(found, isNotNull);
      expect(found!.isActive, isTrue);
    });
  });
}

Future<void> _push(WidgetTester tester, Widget screen) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  navigator.push(CupertinoPageRoute<void>(builder: (_) => screen));
  await tester.pump();
}

/// A minimal screen with a pinned bar.
class _Screen extends StatelessWidget {
  const _Screen({required this.title, this.actions, this.onBack});

  final String title;
  final List<GlassBarItem>? actions;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    // Screens with actions use the pinned constructor; a null actions list
    // means this screen deliberately uses the widget-based bar and does not
    // participate in pinning.
    final items = actions;
    return GlassScaffold(
      appBar: items == null
          ? GlassAppBar(title: Text(title))
          : GlassAppBar.pinned(
              title: Text(title),
              actions: items,
              onBack: onBack,
            ),
      body: Center(child: Text('$title body')),
    );
  }
}

/// A screen whose actions change with setState.
class _TogglingScreen extends StatefulWidget {
  const _TogglingScreen();

  @override
  State<_TogglingScreen> createState() => _TogglingScreenState();
}

class _TogglingScreenState extends State<_TogglingScreen> {
  bool _extra = false;

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: GlassAppBar.pinned(
        title: const Text('Toggle'),
        actions: [
          GlassBarItem.icon(icon: const Icon(CupertinoIcons.add), onTap: () {}),
          if (_extra)
            GlassBarItem.icon(
              icon: const Icon(CupertinoIcons.bell),
              onTap: () {},
            ),
        ],
      ),
      body: Center(
        child: CupertinoButton(
          onPressed: () => setState(() => _extra = !_extra),
          child: const Text('toggle'),
        ),
      ),
    );
  }
}
