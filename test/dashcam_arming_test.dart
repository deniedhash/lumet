import 'package:flutter_test/flutter_test.dart';
import 'package:lumet/dashcam_arming.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 2, 14, 0, 0);
  late DashcamArming arming;

  setUp(() => arming = DashcamArming());

  /// Feeds one sample at [t0] + [after].
  bool at(
    Duration after, {
    double? kmh,
    bool mirrored = false,
    bool ready = true,
    bool resumeHint = false,
  }) {
    return arming.evaluate(
      now: t0.add(after),
      speedKmh: kmh,
      mirrored: mirrored,
      ready: ready,
      resumeHint: resumeHint,
    );
  }

  /// Gets to a recording state the normal way.
  void arm() {
    at(Duration.zero, kmh: 25);
    expect(at(const Duration(seconds: 5), kmh: 25), isTrue);
  }

  group('start dwell', () {
    test('holds off until the speed has been sustained', () {
      expect(at(Duration.zero, kmh: 25), isFalse);
      expect(at(const Duration(seconds: 2), kmh: 25), isFalse);
      expect(at(const Duration(seconds: 5), kmh: 25), isTrue);
    });

    test('a single outlier fix at a standstill never starts it', () {
      expect(at(Duration.zero, kmh: 0), isFalse);
      expect(at(const Duration(seconds: 1), kmh: 60), isFalse);
      expect(at(const Duration(seconds: 2), kmh: 0), isFalse);
      expect(at(const Duration(seconds: 30), kmh: 0), isFalse);
    });

    test('speed between the thresholds accumulates neither dwell', () {
      at(Duration.zero, kmh: 25);
      // Dropping into the dead band resets the start dwell.
      at(const Duration(seconds: 2), kmh: 10);
      expect(at(const Duration(seconds: 5), kmh: 25), isFalse);
      expect(at(const Duration(seconds: 10), kmh: 25), isTrue);
    });

    test('resumeHint skips the dwell', () {
      expect(at(Duration.zero, kmh: 25, resumeHint: true), isTrue);
    });

    test('resumeHint still cannot start it when not ready', () {
      expect(at(Duration.zero, kmh: 25, ready: false, resumeHint: true), isFalse);
    });
  });

  group('stop dwell', () {
    test('a red light does not end the broadcast', () {
      arm();
      expect(at(const Duration(seconds: 10), kmh: 0), isTrue);
      expect(at(const Duration(minutes: 1), kmh: 0), isTrue);
      expect(at(const Duration(minutes: 3), kmh: 0), isTrue);
    });

    test('creeping in traffic is not stopped, so the dwell never starts', () {
      arm();
      at(const Duration(seconds: 10), kmh: 2);
      expect(at(const Duration(minutes: 20), kmh: 2), isTrue);
    });

    test('sensor noise at a standstill still counts as stopped', () {
      // The fused estimate can sit a hair above zero while parked; comparing
      // strictly against zero would mean a dwell that never expires.
      arm();
      at(const Duration(seconds: 10), kmh: 0.1);
      expect(at(const Duration(minutes: 5, seconds: 11), kmh: 0.1), isFalse);
    });

    test('five minutes parked does, and the boundary is inclusive', () {
      arm();
      at(const Duration(seconds: 10), kmh: 0);
      expect(at(const Duration(minutes: 5, seconds: 9), kmh: 0), isTrue);
      expect(at(const Duration(minutes: 5, seconds: 10), kmh: 0), isFalse);
    });

    test('moving off again resets the stop dwell', () {
      arm();
      at(const Duration(minutes: 1), kmh: 0);
      at(const Duration(minutes: 2), kmh: 40);
      expect(at(const Duration(minutes: 4), kmh: 0), isTrue);
      expect(at(const Duration(minutes: 8), kmh: 0), isTrue);
      expect(at(const Duration(minutes: 9, seconds: 1), kmh: 0), isFalse);
    });
  });

  group('mirroring', () {
    test('stops recording only after the grace period', () {
      arm();
      expect(at(const Duration(seconds: 6), kmh: 40, mirrored: true), isTrue);
      expect(at(const Duration(seconds: 8), kmh: 40, mirrored: true), isTrue);
      expect(at(const Duration(seconds: 11), kmh: 40, mirrored: true), isFalse);
    });

    test('an accidental tap undone inside the grace never stops it', () {
      arm();
      at(const Duration(seconds: 6), kmh: 40, mirrored: true);
      at(const Duration(seconds: 8), kmh: 40, mirrored: false);
      expect(at(const Duration(seconds: 20), kmh: 40), isTrue);
    });

    test('the grace expires on the clock alone, with no fixes arriving', () {
      arm();
      expect(at(const Duration(seconds: 6), kmh: null, mirrored: true), isTrue);
      expect(at(const Duration(seconds: 12), kmh: null, mirrored: true), isFalse);
    });
  });

  group('holds and overrides', () {
    test('a lost fix holds the current decision rather than stopping', () {
      arm();
      expect(at(const Duration(seconds: 10), kmh: null), isTrue);
      expect(at(const Duration(minutes: 10), kmh: null), isTrue);
    });

    test('a lost fix does not let it start either', () {
      expect(at(Duration.zero, kmh: null), isFalse);
      expect(at(const Duration(minutes: 10), kmh: null), isFalse);
    });

    test('not ready stops it and clears the dwell state', () {
      arm();
      expect(at(const Duration(seconds: 6), kmh: 40, ready: false), isFalse);
      // The start dwell has to be served again from scratch.
      expect(at(const Duration(seconds: 7), kmh: 40), isFalse);
      expect(at(const Duration(seconds: 12), kmh: 40), isTrue);
    });
  });

  group('manual disarm', () {
    test('long-press stops recording immediately', () {
      arm();
      arming.toggleDisarm();
      expect(arming.disarmed, isTrue);
      expect(at(const Duration(seconds: 6), kmh: 60), isFalse);
    });

    test('it holds for the rest of the drive', () {
      arm();
      arming.toggleDisarm();
      expect(at(const Duration(minutes: 30), kmh: 80), isFalse);
    });

    test('long-press again re-arms', () {
      arm();
      arming.toggleDisarm();
      arming.toggleDisarm();
      expect(arming.disarmed, isFalse);
      at(const Duration(seconds: 6), kmh: 60);
      expect(at(const Duration(seconds: 12), kmh: 60), isTrue);
    });

    test('it clears itself once the car has been parked for the stop dwell', () {
      arm();
      arming.toggleDisarm();
      at(const Duration(minutes: 1), kmh: 0);
      expect(arming.disarmed, isTrue);
      at(const Duration(minutes: 6, seconds: 1), kmh: 0);
      expect(arming.disarmed, isFalse);
      // And the next drive arms normally.
      at(const Duration(minutes: 7), kmh: 40);
      expect(at(const Duration(minutes: 7, seconds: 5), kmh: 40), isTrue);
    });

    test('disarm is idempotent, for stops that did not come from the gesture', () {
      arm();
      arming.disarm();
      expect(arming.disarmed, isTrue);
      arming.disarm();
      expect(arming.disarmed, isTrue);
      expect(at(const Duration(minutes: 30), kmh: 80), isFalse);
    });

    test('a notification stop then a long press re-arms', () {
      arm();
      arming.disarm();
      arming.toggleDisarm();
      expect(arming.disarmed, isFalse);
      at(const Duration(seconds: 6), kmh: 60);
      expect(at(const Duration(seconds: 12), kmh: 60), isTrue);
    });

    test('the force-arm override is off in an ordinary build', () {
      // It takes a --dart-define to enable; nothing at runtime can reach it.
      expect(DashcamArming.forceArm, isFalse);
    });

    test('reset clears everything', () {
      arm();
      arming.toggleDisarm();
      arming.reset();
      expect(arming.desired, isFalse);
      expect(arming.disarmed, isFalse);
    });
  });
}
