/// Decides whether the dashcam should be running, from context alone.
///
/// There is no record button. Recording is a consequence of the car moving with
/// the phone pointing out of the windscreen, the same way the nav panel is a
/// consequence of a route being active — see the README on "no buttons".
///
/// Pure except for the [now] passed in, and cheap enough to call at fix rate.
class DashcamArming {
  /// Below this you might be walking with the phone, or the fix might be
  /// drifting at a standstill. Above it you are definitely driving.
  static const startKmh = 20.0;

  /// Sustained for this long, so one bad fix cannot open a camera.
  static const startDwell = Duration(seconds: 5);

  /// Stationary. Red lights, level crossings and toll booths must not end a
  /// broadcast either, which is what the long dwell is for: every stop/start pair
  /// costs a new YouTube archive and a fresh RTMPS handshake.
  ///
  /// Creeping in traffic therefore does not count as stopped, and keeps recording.
  static const stopKmh = 0.0;

  /// Sensor and floating-point noise, not a speed allowance. The shown speed is
  /// the fused estimate when the accelerometer axis has been learned, and that
  /// can sit a hair above zero at a standstill; comparing strictly against zero
  /// would risk a dwell that never expires. 0.2 km/h is 5.5 cm/s.
  static const _stopNoise = 0.2;

  static const stopDwell = Duration(minutes: 5);

  /// Mirroring means the phone went face-up and the camera now sees the roof, so
  /// it stops recording — but not instantly. Tap is the app's only gesture, an
  /// accidental one while handling the phone is likely, and a few seconds of
  /// ceiling footage is cheaper than tearing a stream down and rebuilding it.
  static const mirrorGrace = Duration(seconds: 5);

  /// After a short trip to another app, pick the recording back up instead of
  /// waiting out [startDwell] again.
  static const resumeWindow = Duration(seconds: 60);

  /// Arms on readiness alone, ignoring speed. Off unless compiled in with
  /// `--dart-define=LUMET_FORCE_ARM=true`, and unreachable at runtime.
  ///
  /// Exists because the capture path is otherwise untestable without a vehicle:
  /// GPS speed is Doppler-derived, so carrying or swinging the phone produces
  /// nothing, and [startKmh] sustained for [startDwell] needs about seven
  /// consecutive fixes above the threshold. Mirroring and the disarm gesture
  /// still stop it, so those stay testable too.
  static const forceArm = bool.fromEnvironment('LUMET_FORCE_ARM');

  bool _desired = false;
  bool _disarmed = false;
  DateTime? _fastSince;
  DateTime? _slowSince;
  DateTime? _mirroredSince;

  bool get desired => _desired;

  bool get disarmed => _disarmed;

  /// Long-press. Disarming lasts for the trip rather than forever: it clears
  /// itself once the car has been stopped for [stopDwell], so the next drive
  /// arms normally without the user having to remember anything.
  void toggleDisarm() => _setDisarmed(!_disarmed);

  /// Idempotent, for stops that did not come from the gesture — the Stop action
  /// on the recorder's notification has to land here too, or the policy simply
  /// restarts what the user just stopped.
  void disarm() => _setDisarmed(true);

  void _setDisarmed(bool value) {
    _disarmed = value;
    if (_disarmed) {
      _desired = false;
      _fastSince = null;
      _slowSince = null;
    }
  }

  /// Call on every fix, on every mirror toggle, on long-press, on resume, and on
  /// the one-second clock — the dwells are time-based and must expire even when
  /// fixes stop arriving.
  bool evaluate({
    required DateTime now,
    required double? speedKmh,
    required bool mirrored,
    required bool ready,
    bool resumeHint = false,
  }) {
    if (!ready) {
      _desired = false;
      _fastSince = null;
      _slowSince = null;
      return _desired;
    }

    if (_disarmed) {
      final kmh = speedKmh;
      if (kmh != null && kmh <= stopKmh + _stopNoise) {
        _slowSince ??= now;
        if (now.difference(_slowSince!) >= stopDwell) {
          _disarmed = false;
          _slowSince = null;
        }
      } else {
        _slowSince = null;
      }
      _desired = false;
      return _desired;
    }

    if (mirrored) {
      _mirroredSince ??= now;
      if (now.difference(_mirroredSince!) >= mirrorGrace) _desired = false;
      return _desired;
    }
    _mirroredSince = null;

    if (forceArm) {
      _desired = true;
      return _desired;
    }

    final kmh = speedKmh;
    // No fix, a stale stream, a tunnel: hold the current decision rather than
    // thrash. Losing GPS in a tunnel is exactly when you want the camera rolling.
    if (kmh == null) return _desired;

    if (kmh >= startKmh) {
      _slowSince = null;
      _fastSince ??= now;
      if (resumeHint || now.difference(_fastSince!) >= startDwell) _desired = true;
    } else if (kmh <= stopKmh + _stopNoise) {
      _fastSince = null;
      _slowSince ??= now;
      if (now.difference(_slowSince!) >= stopDwell) _desired = false;
    } else {
      // Between the thresholds: neither dwell is accumulating.
      _fastSince = null;
      _slowSince = null;
    }
    return _desired;
  }

  void reset() {
    _desired = false;
    _disarmed = false;
    _fastSince = null;
    _slowSince = null;
    _mirroredSince = null;
  }
}
