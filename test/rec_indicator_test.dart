import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumet/dashcam_link.dart';
import 'package:lumet/rec_indicator.dart';

void main() {
  final now = DateTime.utc(2026, 10, 2, 14, 12, 4);
  final startedAt = now.subtract(const Duration(minutes: 12, seconds: 4));

  Future<void> pump(
    WidgetTester tester, {
    required DashcamState state,
    bool mirrored = false,
    bool armed = true,
    bool disarmed = false,
    VoidCallback? onToggleMute,
    VoidCallback? onOpenRecordings,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: RecIndicator(
            state: ValueNotifier<DashcamState>(state),
            now: now,
            mirrored: mirrored,
            armed: armed,
            disarmed: disarmed,
            onToggleMute: onToggleMute,
            onOpenRecordings: onOpenRecordings,
          ),
        ),
      ),
    );
  }

  DashcamState live({int uplink = 2400000, bool muted = false, bool lowStorage = false}) {
    return DashcamState.parse({
      'phase': 'active',
      'connection': 'connected',
      'recording': true,
      'streaming': true,
      'uplinkBitrate': uplink,
      'muted': muted,
      'lowStorage': lowStorage,
      'startedAtMs': startedAt.millisecondsSinceEpoch,
    });
  }

  testWidgets('mirrored renders nothing whatever the phase', (tester) async {
    await pump(tester, state: live(), mirrored: true);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('live shows the label, elapsed time and rate', (tester) async {
    await pump(tester, state: live());
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.textContaining('12:04'), findsOneWidget);
    expect(find.textContaining('2.4 Mb/s'), findsOneWidget);
  });

  testWidgets('live uses a red dot with a glow', (tester) async {
    await pump(tester, state: live());
    final label = tester.widget<Text>(find.text('LIVE'));
    expect(label.style?.shadows, isNotNull);
    final dot = tester.widget<Container>(find.byType(Container).first);
    expect((dot.decoration as BoxDecoration).color, const Color(0xFFF87171));
  });

  testWidgets('a measured rate of zero reads as connecting, not 0.0 Mb/s', (tester) async {
    await pump(tester, state: live(uplink: 0));
    expect(find.textContaining('connecting'), findsOneWidget);
    expect(find.textContaining('0.0 Mb/s'), findsNothing);
  });

  testWidgets('localOnly is amber and says so', (tester) async {
    await pump(
      tester,
      state: DashcamState.parse({
        'phase': 'active',
        'connection': 'disconnected',
        'recording': true,
        'startedAtMs': startedAt.millisecondsSinceEpoch,
      }),
    );
    expect(find.text('REC'), findsOneWidget);
    expect(find.textContaining('local only'), findsOneWidget);
    final dot = tester.widget<Container>(find.byType(Container).first);
    expect((dot.decoration as BoxDecoration).color, const Color(0xFFFBBF24));
  });

  testWidgets('low storage replaces the local-only detail', (tester) async {
    await pump(
      tester,
      state: DashcamState.parse({
        'phase': 'active',
        'connection': 'disconnected',
        'recording': true,
        'lowStorage': true,
        'startedAtMs': startedAt.millisecondsSinceEpoch,
      }),
    );
    expect(find.textContaining('storage full'), findsOneWidget);
  });

  testWidgets('reconnecting says buffering', (tester) async {
    await pump(
      tester,
      state: DashcamState.parse({
        'phase': 'active',
        'connection': 'reconnecting',
        'recording': true,
        'streaming': true,
        'startedAtMs': startedAt.millisecondsSinceEpoch,
      }),
    );
    expect(find.text('RETRY'), findsOneWidget);
    expect(find.textContaining('buffering'), findsOneWidget);
  });

  testWidgets('muted is appended to the detail line', (tester) async {
    await pump(tester, state: live(muted: true));
    expect(find.textContaining('muted'), findsOneWidget);
  });

  testWidgets('armed but idle shows standby', (tester) async {
    await pump(tester, state: DashcamState.idle);
    expect(find.text('STBY'), findsOneWidget);
  });

  testWidgets('not armed shows nothing at all', (tester) async {
    await pump(tester, state: DashcamState.idle, armed: false);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('disarmed says OFF even when armed', (tester) async {
    await pump(tester, state: DashcamState.idle, disarmed: true);
    expect(find.text('OFF'), findsOneWidget);
    expect(find.text('STBY'), findsNothing);
  });

  testWidgets('an error surfaces the platform message', (tester) async {
    await pump(
      tester,
      state: DashcamState.parse({
        'phase': 'error',
        'error': {'code': 'cameraError', 'message': 'Camera in use'},
      }),
    );
    expect(find.text('DASHCAM'), findsOneWidget);
    expect(find.text('Camera in use'), findsOneWidget);
  });

  testWidgets('unsupported devices say unavailable', (tester) async {
    await pump(tester, state: DashcamState.unsupported);
    expect(find.text('unavailable'), findsOneWidget);
  });

  testWidgets('tapping it opens the recordings view', (tester) async {
    var taps = 0;
    await pump(tester, state: live(), onOpenRecordings: () => taps++);
    await tester.tap(find.text('LIVE'));
    expect(taps, 1);
  });

  testWidgets('long-pressing it toggles mute', (tester) async {
    var presses = 0;
    await pump(tester, state: live(), onToggleMute: () => presses++);
    await tester.longPress(find.text('LIVE'));
    expect(presses, 1);
  });

  testWidgets('sizes to its content so a Stack can centre it', (tester) async {
    // It is stacked over the clock and GPS blocks rather than sharing a row with
    // them. If it fills the width instead of hugging its content, the dot ends up
    // pinned to the left edge on top of the clock.
    tester.view.physicalSize = const Size(2340, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            alignment: Alignment.topCenter,
            children: [
              const SizedBox(width: 2340, height: 100),
              RecIndicator(
                state: ValueNotifier<DashcamState>(live()),
                now: now,
                mirrored: false,
                armed: true,
                disarmed: false,
              ),
            ],
          ),
        ),
      ),
    );

    final box = tester.renderObject<RenderBox>(find.byType(RecIndicator));
    expect(box.size.width, lessThan(800));
    final centre = box.localToGlobal(Offset.zero).dx + box.size.width / 2;
    expect(centre, moreOrLessEquals(1170, epsilon: 1));
  });

  testWidgets('elapsed crosses into hours cleanly', (tester) async {
    await pump(
      tester,
      state: DashcamState.parse({
        'phase': 'active',
        'connection': 'connected',
        'recording': true,
        'streaming': true,
        'uplinkBitrate': 2400000,
        'startedAtMs':
            now.subtract(const Duration(hours: 2, minutes: 3, seconds: 7)).millisecondsSinceEpoch,
      }),
    );
    expect(find.textContaining('2:03:07'), findsOneWidget);
  });
}
