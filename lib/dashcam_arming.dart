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

  /// Stop only once you have really stopped. Red lights, level crossings and
  /// toll booths must not end a broadcast: every stop/start pair costs a new
  /// YouTube archive and a fresh RTMPS handshake.
  static const stopKmh = 3.0;
  static const stopDwell = Duration(minutes: 5);

  /// Mirroring means the phone went face-up and the camera now sees the roof, so
  /// it stops recording — but not instantly. Tap is the app's only gesture, an
  /// accidental one while handling the phone is likely, and a few seconds of
  /// ceiling footage is cheaper than tearing a stream down and rebuilding it.
  static const mirrorGrace = Duration(seconds: 5);

  /// After a short trip to another app, pick the recording back up instead of
  /// waiting out [startDwell] again.
  static const resumeWindow = Duration(seconds: 60);

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
  void toggleDisarm() {
    _disarmed = !_disarmed;
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
      if (kmh != null && kmh <= stopKmh) {
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

    final kmh = speedKmh;
    // No fix, a stale stream, a tunnel: hold the current decision rather than
    // thrash. Losing GPS in a tunnel is exactly when you want the camera rolling.
    if (kmh == null) return _desired;

    if (kmh >= startKmh) {
      _slowSince = null;
      _fastSince ??= now;
      if (resumeHint || now.difference(_fastSince!) >= startDwell) _desired = true;
    } else if (kmh <= stopKmh) {
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
