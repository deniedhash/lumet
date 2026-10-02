import 'dart:math' as math;

/// Fuses GPS speed with accelerometer dead reckoning.
///
/// GPS is the truth but lands roughly once a second and is already a fraction
/// of a second old when it arrives. The accelerometer runs at 50Hz but only
/// measures *change*, so integrating it alone drifts away within seconds.
///
/// So: every GPS fix resets the estimate to truth, and between fixes we
/// integrate acceleration forward from there. Error can only accumulate for
/// the gap between two fixes, never longer.
///
/// The hard part is that the accelerometer reports in *device* axes, and we
/// have no idea how the phone sits in the mount. Rather than ask the user to
/// calibrate, the forward axis is learned: when GPS says the speed changed by
/// some amount, whichever direction the phone felt acceleration in during that
/// window must be forward.
class SpeedFusion {
  /// Time constant of the gravity low-pass, in seconds.
  static const _gravityTau = 0.8;

  /// Accelerations below this are sensor noise, not motion (m/s^2).
  static const _deadband = 0.15;

  /// The estimate is never allowed to run further than this from the last
  /// fix (m/s), so a mislearned axis cannot produce a runaway number.
  static const _maxDrift = 6.0;

  /// Below this speed change a GPS window teaches us nothing useful (m/s).
  static const _minLearnDelta = 0.25;

  /// Gravity direction, low-pass filtered out of the raw accelerometer.
  double _gx = 0, _gy = 0, _gz = 0;
  bool _haveGravity = false;

  /// Unit vector pointing along travel, expressed in device axes.
  double _fx = 0, _fy = 0, _fz = 0;
  bool _learned = false;

  double _v = 0;
  double? _gpsV;
  DateTime? _lastGpsAt;

  /// Mean horizontal acceleration since the last fix, used for learning.
  double _sumX = 0, _sumY = 0, _sumZ = 0;
  int _samples = 0;

  /// Current speed estimate in m/s.
  double get speed => _v;

  /// True once the forward axis has been learned and the estimate is usable.
  bool get active => _learned && _gpsV != null;

  /// Raw accelerometer, gravity included. Used only to track which way is down.
  void onRawAcceleration(double x, double y, double z, double dt) {
    final alpha = dt / (_gravityTau + dt);
    if (!_haveGravity) {
      _gx = x;
      _gy = y;
      _gz = z;
      _haveGravity = true;
      return;
    }
    _gx += alpha * (x - _gx);
    _gy += alpha * (y - _gy);
    _gz += alpha * (z - _gz);
  }

  /// Linear acceleration, gravity already removed by the platform.
  void onAcceleration(double x, double y, double z, double dt) {
    if (!_haveGravity) return;

    final gm = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    if (gm < 1) return;

    // Strip the vertical component: bumps in the road are not speed.
    final ux = _gx / gm, uy = _gy / gm, uz = _gz / gm;
    final vertical = x * ux + y * uy + z * uz;
    final hx = x - vertical * ux;
    final hy = y - vertical * uy;
    final hz = z - vertical * uz;

    _sumX += hx;
    _sumY += hy;
    _sumZ += hz;
    _samples++;

    if (!_learned) return;

    final forward = hx * _fx + hy * _fy + hz * _fz;
    if (forward.abs() > _deadband) {
      _v += forward * dt;
    }
    if (_v < 0) _v = 0;

    final anchor = _gpsV;
    if (anchor != null) {
      _v = _v.clamp(math.max(0, anchor - _maxDrift), anchor + _maxDrift);
    }
  }

  /// A new GPS fix: ground truth. Snap to it, and learn from the window.
  void onGpsSpeed(double metresPerSecond, DateTime at) {
    final previous = _gpsV;
    final previousAt = _lastGpsAt;

    if (previous != null && previousAt != null && _samples > 0) {
      final dt = at.difference(previousAt).inMilliseconds / 1000;
      final delta = metresPerSecond - previous;

      // Only learn from windows short enough that the phone cannot have been
      // reoriented, and where the speed actually changed.
      if (dt > 0.2 && dt < 3 && delta.abs() > _minLearnDelta) {
        final mx = _sumX / _samples;
        final my = _sumY / _samples;
        final mz = _sumZ / _samples;
        final mag = math.sqrt(mx * mx + my * my + mz * mz);

        if (mag > 0.08) {
          // Speeding up means the felt acceleration points forward; slowing
          // down means it points backward.
          final sign = delta > 0 ? 1.0 : -1.0;
          final cx = sign * mx / mag;
          final cy = sign * my / mag;
          final cz = sign * mz / mag;

          // Blend towards the new estimate so one noisy window cannot
          // redefine which way forward is.
          final k = _learned ? 0.25 : 1.0;
          final nx = _fx * (1 - k) + cx * k;
          final ny = _fy * (1 - k) + cy * k;
          final nz = _fz * (1 - k) + cz * k;
          final nm = math.sqrt(nx * nx + ny * ny + nz * nz);
          if (nm > 0.01) {
            _fx = nx / nm;
            _fy = ny / nm;
            _fz = nz / nm;
            _learned = true;
          }
        }
      }
    }

    // Standing still: kill the estimate outright rather than let noise
    // integrate into a phantom crawl.
    _v = metresPerSecond < 0.5 ? 0 : metresPerSecond;

    _gpsV = metresPerSecond;
    _lastGpsAt = at;
    _sumX = _sumY = _sumZ = 0;
    _samples = 0;
  }

  /// GPS has gone away; the estimate is no longer anchored to anything.
  void reset() {
    _v = 0;
    _gpsV = null;
    _lastGpsAt = null;
    _sumX = _sumY = _sumZ = 0;
    _samples = 0;
  }
}
