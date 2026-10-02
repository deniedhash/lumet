import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'nav_link.dart';
import 'speed_fusion.dart';

/// Top of the gauge scale, in km/h.
const _maxScaleKmh = 200.0;

void main() {
  runApp(const SpeedApp());
}

class SpeedApp extends StatelessWidget {
  const SpeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'JetBrainsMono'),
      home: const SpeedScreen(),
    );
  }
}

class SpeedScreen extends StatefulWidget {
  const SpeedScreen({super.key});

  @override
  State<SpeedScreen> createState() => _SpeedScreenState();
}

class _SpeedScreenState extends State<SpeedScreen> {
  StreamSubscription<Position>? _sub;
  StreamSubscription<AccelerometerEvent>? _rawAccel;
  StreamSubscription<UserAccelerometerEvent>? _accel;
  Timer? _clock;

  final _fusion = SpeedFusion();
  StreamSubscription<NavInfo?>? _navSub;
  NavInfo? _nav;
  bool _navAccess = false;
  DateTime? _rawAccelAt;
  DateTime? _accelAt;
  DateTime _lastPaint = DateTime.now();

  double? _speedKmh;
  double _tripMetres = 0;
  double _heading = 0;
  bool _hasHeading = false;
  double _altitude = 0;
  double _accuracy = 0;
  DateTime _now = DateTime.now();
  DateTime? _startedAt;
  DateTime? _lastFixAt;
  final List<DateTime> _fixTimes = [];
  Position? _last;
  bool _denied = false;
  bool _mirrored = false;

  @override
  void initState() {
    super.initState();
    // One fixed landscape: a mounted HUD should never flip, and allowing
    // both directions reads as auto-rotate.
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    ScreenBrightness.instance.setApplicationScreenBrightness(1);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _startSensors();
    _startNav();
    _start();
  }

  /// The accelerometer runs far faster than GPS; it is what makes the number
  /// move between fixes.
  void _startSensors() {
    _rawAccel = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen((e) {
      final dt = _tick(_rawAccelAt);
      _rawAccelAt = DateTime.now();
      if (dt != null) _fusion.onRawAcceleration(e.x, e.y, e.z, dt);
    });

    _accel = userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen((e) {
      final dt = _tick(_accelAt);
      _accelAt = DateTime.now();
      if (dt == null) return;
      _fusion.onAcceleration(e.x, e.y, e.z, dt);

      // Repaint at about 30Hz. The filter runs at the full sensor rate; only
      // the screen is throttled.
      final now = DateTime.now();
      if (_fusion.active &&
          now.difference(_lastPaint) > const Duration(milliseconds: 33)) {
        _lastPaint = now;
        if (mounted) setState(() {});
      }
    });
  }

  /// Turn instructions from whatever navigation app is running, if the user
  /// has granted notification access.
  Future<void> _startNav() async {
    final granted = await NavLink.isEnabled();
    if (mounted) setState(() => _navAccess = granted);
    if (!granted) return;
    _navSub = NavLink.stream().listen((info) {
      if (mounted) setState(() => _nav = info);
    });
  }

  /// Seconds since [previous], ignoring absurd gaps from a stalled stream.
  double? _tick(DateTime? previous) {
    if (previous == null) return null;
    final dt = DateTime.now().difference(previous).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 0.2) return null;
    return dt;
  }

  Future<void> _start() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) setState(() => _denied = true);
      return;
    }

    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 200),
        // Skip the fused provider: it batches and throttles. The legacy
        // LocationManager hands over every raw GPS fix as it lands.
        forceLocationManager: true,
        useMSLAltitude: true,
      ),
    ).listen(_onPosition);
  }

  void _onPosition(Position position) {
    final speed = position.speed;
    final valid = position.hasSpeed && !speed.isNaN && !speed.isNegative;
    final kmh = valid ? speed * 3.6 : null;

    // Only accumulate distance from fixes good enough to trust, so a bad
    // fix jumping across the map does not inflate the trip.
    final last = _last;
    if (last != null && position.accuracy <= 25) {
      _tripMetres += Geolocator.distanceBetween(
        last.latitude,
        last.longitude,
        position.latitude,
        position.longitude,
      );
    }
    _last = position;
    if (valid) {
      _fusion.onGpsSpeed(speed, DateTime.now());
    }

    if (!mounted) return;
    setState(() {
      _startedAt ??= DateTime.now();
      _lastFixAt = DateTime.now();
      _fixTimes.add(_lastFixAt!);
      if (_fixTimes.length > 10) _fixTimes.removeAt(0);
      _speedKmh = kmh;
      _heading = position.heading;
      _hasHeading = position.hasHeading;
      _altitude = position.altitude;
      _accuracy = position.accuracy;
    });
  }

  Duration get _elapsed =>
      _startedAt == null ? Duration.zero : _now.difference(_startedAt!);

  double get _avgKmh {
    final seconds = _elapsed.inSeconds;
    if (seconds == 0) return 0;
    return (_tripMetres / seconds) * 3.6;
  }

  /// The stream asks for a fix every second, so anything older than this
  /// means updates have stopped arriving.
  bool get _stale {
    final at = _lastFixAt;
    if (at == null) return false;
    return _now.difference(at) > const Duration(seconds: 5);
  }

  /// Observed delivery rate in fixes per second, across the last few fixes.
  double? get _fixRate {
    if (_fixTimes.length < 2) return null;
    final span = _fixTimes.last.difference(_fixTimes.first).inMilliseconds;
    if (span <= 0) return null;
    return (_fixTimes.length - 1) * 1000 / span;
  }

  Color get _fixColour {
    if (_accuracy == 0 || _stale) return Colors.grey;
    if (_accuracy <= 10) return const Color(0xFF4ADE80);
    if (_accuracy <= 25) return const Color(0xFFFBBF24);
    return const Color(0xFFF87171);
  }

  /// Null whenever we have no trustworthy reading: no fix yet, a fix that
  /// carried no velocity, or a stream that has stopped delivering.
  double? get _shownKmh {
    if (_stale) return null;
    final gps = _speedKmh;
    if (gps == null) return null;
    return _fusion.active ? _fusion.speed * 3.6 : gps;
  }

  /// Arc colour tracks how fast you are going, so the gauge reads at a glance
  /// without needing the digits.
  Color get _arcColour {
    final kmh = _shownKmh ?? 0;
    if (kmh < 80) return const Color(0xFF7CF03D);
    if (kmh < 120) return const Color(0xFFFBBF24);
    return const Color(0xFFF87171);
  }

  /// True only when the platform supplied a heading AND we are moving fast
  /// enough for course-over-ground to mean anything.
  bool get _headingValid {
    final kmh = _shownKmh;
    return _hasHeading && !_heading.isNaN && kmh != null && kmh >= 5;
  }

  static List<Shadow> _glow(Color colour, {double blur = 26, double opacity = 0.5}) {
    return [Shadow(color: colour.withValues(alpha: opacity), blurRadius: blur)];
  }

  static String _compass(double heading) {
    if (heading.isNaN || heading.isNegative) return '--';
    const points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return points[(((heading % 360) + 22.5) / 45).floor() % 8];
  }

  static String _clockLabel(DateTime t) {
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final minute = t.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  static String _dateLabel(DateTime t) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${days[t.weekday - 1]}, ${t.day} ${months[t.month - 1]}';
  }

  static String _durationLabel(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _navSub?.cancel();
    _rawAccel?.cancel();
    _accel?.cancel();
    _clock?.cancel();
    WakelockPlus.disable();
    ScreenBrightness.instance.resetApplicationScreenBrightness();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _mirrored = !_mirrored),
        child: SizedBox.expand(
          child: Transform.scale(
            scaleX: _mirrored ? -1 : 1,
            child: _denied ? _deniedView() : _hudView(),
          ),
        ),
      ),
    );
  }

  Widget _deniedView() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Location permission is required to show your speed.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: 20),
        ),
      ),
    );
  }

  Widget _hudView() {
    // In landscape the cutout inset lands on one side only, so SafeArea would
    // shift the whole layout sideways. Take the larger inset and apply it to
    // both edges instead, which keeps the gauge on the screen's true centre.
    final insets = MediaQuery.paddingOf(context);
    final side = math.max(insets.left, insets.right) + 28;

    return SafeArea(
      left: false,
      right: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, 6, side, 6),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [_clockBlock(), _fixBlock()],
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 7,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 24),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _navTurn(),
                      ),
                    ),
                  ),
                  Expanded(flex: 11, child: _gauge()),
                  // Equal to the turn slot: symmetric flex is what keeps the
                  // gauge dead centre whatever the sides contain.
                  Expanded(
                    flex: 7,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 24),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _navTrip(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _statsRow(),
          ],
        ),
      ),
    );
  }

  Widget _gauge() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxHeight, constraints.maxWidth);
        final shown = _shownKmh;
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _GaugePainter(
                fraction: ((shown ?? 0) / _maxScaleKmh).clamp(0.0, 1.0),
                colour: _arcColour,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: size * 0.46,
                    child: Center(
                      // The placeholder gets its own size: scaling it to the
                      // digits' height turns two dashes into slabs.
                      child: shown == null
                          ? Text(
                              '--',
                              style: TextStyle(
                                color: Colors.white24,
                                fontSize: size * 0.17,
                                height: 1,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 4,
                              ),
                            )
                          : FittedBox(
                              fit: BoxFit.contain,
                              child: Text(
                                '${shown.round()}',
                                style: TextStyle(
                                  color: _arcColour,
                                  fontSize: 200,
                                  height: 1,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -6,
                                  shadows: _glow(_arcColour, blur: 44, opacity: 0.55),
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),
                  Text(
                    'km/h',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: size * 0.085,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _clockBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _clockLabel(_now),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 30,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          _dateLabel(_now),
          style: const TextStyle(color: Colors.white60, fontSize: 14),
        ),
      ],
    );
  }

  Widget _fixBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          children: [
            Text(
              _fusion.active ? 'GPS+IMU' : 'GPS',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(color: _fixColour, shape: BoxShape.circle),
            ),
          ],
        ),
        Text(
          _accuracy == 0
              ? 'no fix'
              : _stale
                  ? 'stale ${_now.difference(_lastFixAt!).inSeconds}s'
                  : '±${_accuracy.round()} m'
                      '${_fixRate == null ? '' : '  ·  ${_fixRate!.toStringAsFixed(1)}/s'}',
          style: const TextStyle(color: Colors.white60, fontSize: 14),
        ),
      ],
    );
  }

  /// Left of the speed: what the next turn is, and how far away.
  Widget _navTurn() {
    final nav = _nav;
    if (nav == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (nav.icon != null)
          Image.memory(nav.icon!, width: 72, height: 72)
        else
          const Icon(Icons.arrow_upward, size: 64, color: Color(0xFF60A5FA)),
        const SizedBox(height: 6),
        Text(
          nav.distance ?? '',
          textAlign: TextAlign.right,
          style: TextStyle(
            color: Colors.white,
            fontSize: 38,
            height: 1,
            fontWeight: FontWeight.w700,
            shadows: _glow(Colors.white, blur: 20, opacity: 0.35),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if ((nav.instruction ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            nav.instruction!,
            maxLines: 3,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              // Prose, so step out of the mono face.
              fontFamily: 'Roboto',
              color: Colors.white70,
              fontSize: 20,
              height: 1.25,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }

  /// Right of the speed: the instruction and what is left of the trip.
  Widget _navTrip() {
    final nav = _nav;
    if (nav == null) {
      // The one-time grant prompt, shown only while access is missing.
      if (_navAccess) return const SizedBox.shrink();
      return GestureDetector(
        onTap: NavLink.openSettings,
        child: const Text(
          'Tap for\nnav access',
          style: TextStyle(color: Colors.white24, fontSize: 14, height: 1.4),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (nav.arrival != null) ...[
          const Text(
            'ARRIVAL',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            nav.arrival!.replaceAll(RegExp(r'\s*[ap]m', caseSensitive: false), ''),
            style: TextStyle(
              color: Colors.white,
              fontSize: 52,
              height: 1.05,
              fontWeight: FontWeight.w700,
              shadows: _glow(Colors.white, blur: 22, opacity: 0.3),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (nav.duration != null || nav.remaining != null) ...[
          const SizedBox(height: 4),
          Text(
            [nav.duration, nav.remaining].whereType<String>().join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }

  Widget _statsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _stat(Icons.navigation, 'HEADING',
            _headingValid ? _compass(_heading) : '--'),
        _stat(Icons.speed, 'AVG', '${_avgKmh.round()} km/h'),
        _stat(Icons.straighten, 'DISTANCE',
            '${(_tripMetres / 1000).toStringAsFixed(1)} km'),
        _stat(Icons.timer_outlined, 'DURATION', _durationLabel(_elapsed)),
        _stat(Icons.terrain, 'ALTITUDE', '${_altitude.round()} m'),
      ],
    );
  }

  Widget _stat(IconData icon, String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 26, color: Colors.white54),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                letterSpacing: 1,
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.fraction, required this.colour});

  /// 0..1 of the way to [_maxScaleKmh].
  final double fraction;
  final Color colour;

  static const _startAngle = math.pi * 0.78;
  static const _sweepAngle = math.pi * 1.44;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.05;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height)
        .deflate(stroke * 1.2);
    final centre = rect.center;
    final radius = rect.width / 2;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.16
      ..strokeCap = StrokeCap.round
      ..color = Colors.white10;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, track);

    const tickCount = 40;
    for (var i = 0; i <= tickCount; i++) {
      final angle = _startAngle + _sweepAngle * (i / tickCount);
      final major = i % 5 == 0;
      final tick = Paint()
        ..strokeWidth = major ? 2.4 : 1.2
        ..strokeCap = StrokeCap.round
        ..color = major ? Colors.white24 : Colors.white10;
      final inner = radius - stroke * (major ? 0.95 : 0.6);
      canvas.drawLine(
        centre + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        centre + Offset(math.cos(angle) * radius, math.sin(angle) * radius),
        tick,
      );
    }

    if (fraction > 0.012) {
      final progress = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = colour;
      canvas.drawArc(rect, _startAngle, _sweepAngle * fraction, false, progress);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.colour != colour;
}
