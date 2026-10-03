import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'dashcam_arming.dart';
import 'dashcam_config.dart';
import 'dashcam_link.dart';
import 'hud_glow.dart';
import 'nav_link.dart';
import 'rec_indicator.dart';
import 'recordings_view.dart';
import 'speed_fusion.dart';
import 'stream_key_editor.dart';
import 'youtube_account.dart';
import 'telemetry_sidecar.dart';

/// Top of the gauge scale, in km/h.
const _maxScaleKmh = 200.0;

/// What is stopping the dashcam, when something is.
enum _Blocker { none, unsupported, noKey, needsPermission, denied }

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

class _SpeedScreenState extends State<SpeedScreen> with WidgetsBindingObserver {
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

  // Dashcam. The state lives in a notifier rather than a field so that a bitrate
  // sample arriving twice a second does not repaint the gauge.
  final _dashcam = ValueNotifier<DashcamState>(DashcamState.idle);
  StreamSubscription<DashcamState>? _dashcamSub;
  final _arming = DashcamArming();
  TelemetrySidecar? _sidecar;
  String? _sidecarSession;
  String? _streamKey;
  String _ingestUrl = DashcamConfig.defaultIngestUrl;
  bool _dashcamSupported = false;
  bool _dashcamPermitted = false;
  bool _dashcamDeniedForever = false;
  _Blocker _blocker = _Blocker.none;
  bool _dashcamBusy = false;
  bool _muted = false;
  bool _recordingWhenPaused = false;
  DateTime? _pausedAt;
  double _brightness = 1;
  final _account = YouTubeAccount();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // One fixed landscape: a mounted HUD should never flip, and allowing
    // both directions reads as auto-rotate.
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
    _applyDisplay();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      // The dwells and the mirror grace are time-based, so they have to be able
      // to expire even when no fixes are arriving at all.
      _syncDashcam();
    });
    _startSensors();
    _startNav();
    _start();
    // After _start, so the location dialog is not racing a camera prompt on a
    // first launch.
    _startDashcam();
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

    _sidecar?.fix(
      at: DateTime.now(),
      latitude: position.latitude,
      longitude: position.longitude,
      shownKmh: _shownKmh,
      gpsKmh: kmh,
      heading: position.hasHeading ? position.heading : null,
      altitude: position.altitude,
      accuracy: position.accuracy,
      tripMetres: _tripMetres,
    );
    _syncDashcam();
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

  static List<Shadow> _glow(Color colour, {double blur = 26, double opacity = 0.5}) =>
      glow(colour, blur: blur, opacity: opacity);

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

  /// Subscribes to the recorder and works out whether the dashcam can run here.
  ///
  /// Deliberately does not request permissions and does not start recording:
  /// prompting is the user's tap, and starting is the arming policy's job.
  Future<void> _startDashcam() async {
    _dashcamSub = DashcamLink.stream().listen(
      (next) {
        final previous = _dashcam.value;
        _dashcam.value = next;
        _muted = next.muted;
        _openSidecar(next);
        if (next.segment != null && next.segment != previous.segment) {
          _sidecar?.event('segment', fields: {'file': next.segment});
        }
        if (next.warningCode != null && next.warningCode != previous.warningCode) {
          debugPrint('dashcam warning: ${next.warningCode}');
        }
        if (next.errorCode != null && next.errorCode != previous.errorCode) {
          debugPrint('dashcam error: ${next.errorCode} ${next.message}');
        }
        _applyThermal(next);
      },
      onError: (Object error) {
        debugPrint('dashcam channel error: $error');
        _dashcam.value = DashcamState.parse(const {'phase': 'error'});
      },
    );

    _dashcamSupported = await DashcamLink.isSupported();
    final permissions = await DashcamLink.permissions();
    _dashcamPermitted = permissions.ready;
    await _resolveIngest();
    debugPrint('dashcam target $_ingestUrl '
        'key ${DashcamConfig.redacted(_streamKey)}');
    if (mounted) setState(_recomputeBlocker);
  }

  /// The drives YouTube is holding, and the clips still on the phone.
  Future<void> _openRecordings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RecordingsView(
          account: _account,
          serverClientId: DashcamConfig.googleServerClientId,
          onEditKey: _editStreamKey,
        ),
      ),
    );
    // The route and any keyboard it showed drop immersive mode on the way out.
    _applyDisplay();
    // Signing in there can populate the key, so never assume it is unchanged.
    await _resolveIngest();
    if (!mounted) return;
    setState(_recomputeBlocker);
    _syncDashcam();
  }

  /// The one-time setup screen, reached from the dim prompt while no key is set
  /// and from the recordings view afterwards.
  Future<void> _editStreamKey() async {
    final existing = await DashcamLink.streamKey();
    if (!mounted) return;

    final entered = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => StreamKeyEditor(initial: existing),
        fullscreenDialog: true,
      ),
    );

    // The editor's keyboard drops immersive mode on the way out.
    _applyDisplay();
    if (entered == null || !mounted) return;

    await DashcamLink.setStreamKey(entered);
    await _resolveIngest();
    if (!mounted) return;
    setState(_recomputeBlocker);
    _syncDashcam();
  }

  /// Reads whichever key and ingest address are currently stored. A key entered
  /// by hand and one fetched from the account land in the same place, so this is
  /// the only path either of them takes.
  Future<void> _resolveIngest() async {
    _streamKey = await DashcamConfig.resolveKey(stored: await DashcamLink.streamKey());
    _ingestUrl = await DashcamConfig.resolveIngestUrl(
      stored: await DashcamLink.ingestUrl(),
    );
  }

  void _recomputeBlocker() {
    _blocker = switch (true) {
      _ when !_dashcamSupported => _Blocker.unsupported,
      _ when _streamKey == null => _Blocker.noKey,
      _ when _dashcamDeniedForever => _Blocker.denied,
      _ when !_dashcamPermitted => _Blocker.needsPermission,
      _ => _Blocker.none,
    };
  }

  bool get _dashcamReady =>
      _dashcamSupported && _dashcamPermitted && _streamKey != null;

  /// The one place an arming decision becomes a channel call.
  ///
  /// Called from the position handler, the one-second clock, the mirror tap, the
  /// long press and on resume — never from the 30Hz accelerometer path.
  Future<void> _syncDashcam({bool resumeHint = false}) async {
    final want = _arming.evaluate(
      now: DateTime.now(),
      speedKmh: _shownKmh,
      mirrored: _mirrored,
      ready: _dashcamReady,
      resumeHint: resumeHint,
    );
    final phase = _dashcam.value.phase;
    final have = _dashcam.value.isRecording || phase == DashcamPhase.starting;
    // start() takes seconds to open a camera and finish a handshake, while fixes
    // keep arriving at about 1.4Hz throughout.
    if (want == have || _dashcamBusy) return;

    _dashcamBusy = true;
    try {
      if (want) {
        await DashcamLink.start(DashcamSession(
          ingestUrl: _ingestUrl,
          streamKey: _streamKey!,
          muted: _muted,
          width: DashcamConfig.width,
          height: DashcamConfig.height,
          fps: DashcamConfig.fps,
          videoBitrate: DashcamConfig.videoBitrate,
          audioBitrate: DashcamConfig.audioBitrate,
          bufferMinutes: DashcamConfig.bufferMinutes,
          segmentSeconds: DashcamConfig.segmentSeconds,
          maxBufferBytes: DashcamConfig.maxBufferBytes,
          minFreeBytes: DashcamConfig.minFreeBytes,
        ));
      } else {
        await DashcamLink.stop();
        await _closeSidecar();
      }
    } on PlatformException catch (e) {
      debugPrint('dashcam ${want ? 'start' : 'stop'} failed: ${e.code}');
      if (e.code == 'permissionDenied') {
        _dashcamPermitted = false;
        if (mounted) setState(_recomputeBlocker);
      }
    } finally {
      _dashcamBusy = false;
    }
  }

  /// Long press. The dashcam's only deliberate control, and the second gesture in
  /// the app.
  void _toggleDisarm() {
    _arming.toggleDisarm();
    _sidecar?.event('disarm', fields: {'on': _arming.disarmed});
    setState(() {});
    _syncDashcam();
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    setState(() => _muted = next);
    _sidecar?.event('mute', fields: {'on': next});
    if (_dashcam.value.isRecording) await DashcamLink.setMuted(next);
  }

  Future<void> _requestDashcamPermission() async {
    final permissions = await DashcamLink.requestPermissions();
    if (!mounted) return;
    setState(() {
      _dashcamPermitted = permissions.ready;
      _dashcamDeniedForever = permissions.permanentlyDenied;
      _recomputeBlocker();
    });
    _syncDashcam();
  }

  /// The screen is the dominant heat source on a sunny dashboard — far more than
  /// the encoder — so dimming it is worth more than any bitrate change the
  /// platform-side governor can make.
  void _applyThermal(DashcamState state) {
    final target = state.thermalThrottled ? DashcamConfig.throttledBrightness : 1.0;
    if (target == _brightness) return;
    _brightness = target;
    ScreenBrightness.instance.setApplicationScreenBrightness(target);
  }

  /// Opens a sidecar beside the video segments once the recorder reports where
  /// they are. Keyed to the same session stem, which is how footage and telemetry
  /// are matched up afterwards.
  void _openSidecar(DashcamState state) {
    final session = state.sessionId;
    final directory = state.directory;
    if (session == null || directory == null || session == _sidecarSession) return;
    try {
      final file = File('$directory${Platform.pathSeparator}$session.jsonl');
      final sidecar = TelemetrySidecar(FileTelemetrySink(file));
      sidecar.start(sessionId: session, at: DateTime.now());
      _sidecar = sidecar;
      _sidecarSession = session;
    } on FileSystemException catch (e) {
      // Telemetry is a nicety; the footage is the point.
      debugPrint('sidecar open failed: ${e.message}');
    }
  }

  Future<void> _closeSidecar() async {
    final sidecar = _sidecar;
    _sidecar = null;
    _sidecarSession = null;
    await sidecar?.close();
  }

  /// Immersive mode, the wakelock and the brightness override are all scoped to a
  /// focused window: Android drops them when focus is lost and nothing brought
  /// them back, so a trip to another app used to return dimmer with the system
  /// bars showing. Re-applied on every resume.
  void _applyDisplay() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    ScreenBrightness.instance.setApplicationScreenBrightness(_brightness);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _applyDisplay();
        _resumeDashcam();

      case AppLifecycleState.inactive:
        // Transient and very common: the notification shade, the volume slider, a
        // permission dialog. Reacting here would fire constantly.
        break;

      case AppLifecycleState.hidden:
        break;

      case AppLifecycleState.paused:
        // A dashcam that stops when you glance at Maps is not a dashcam, so
        // recording carries on in the foreground service and stop() is not called
        // here. Telemetry is a different matter: the isolate is throttled in the
        // background and the position stream has no foreground notification, so
        // mark the hole rather than draw a straight line through it.
        _pausedAt = DateTime.now();
        _recordingWhenPaused = _dashcam.value.isRecording;
        _sidecar?.event('gap', fields: {'why': 'paused'});
        _sidecar?.flush();

      case AppLifecycleState.detached:
        DashcamLink.stop();
        _closeSidecar();
    }
  }

  Future<void> _resumeDashcam() async {
    // A permission may have been granted in Settings while we were away.
    final permissions = await DashcamLink.permissions();
    if (!mounted) return;
    if (permissions.ready != _dashcamPermitted) {
      setState(() {
        _dashcamPermitted = permissions.ready;
        _recomputeBlocker();
      });
    }
    final away = _pausedAt == null
        ? Duration.zero
        : DateTime.now().difference(_pausedAt!);
    _sidecar?.event('resume', fields: {'awayMs': away.inMilliseconds});
    // A quick hop to another app should not cost another start dwell.
    await _syncDashcam(
      resumeHint: _recordingWhenPaused && away < DashcamArming.resumeWindow,
    );
    _pausedAt = null;
    _recordingWhenPaused = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _navSub?.cancel();
    _dashcamSub?.cancel();
    // dispose cannot await, so these are fire and forget.
    DashcamLink.stop();
    _closeSidecar();
    _dashcam.dispose();
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
        onTap: () {
          setState(() => _mirrored = !_mirrored);
          _sidecar?.event('mirror', fields: {'on': _mirrored});
          // Mirrored means the phone went face-up and the camera now sees the
          // roof, so this doubles as the dashcam's kill switch.
          _syncDashcam();
        },
        // The second gesture in the app, and the dashcam's only deliberate
        // control. A quick release still fires the tap above.
        onLongPress: _toggleDisarm,
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
            // The indicator is stacked over the corner blocks rather than sharing
            // a Row with them. All three change width constantly — the clock
            // string, the fix detail, the indicator's own label — and in a Row
            // any of that walks the indicator sideways. Stacked, it is pinned to
            // the true centre and the corners keep their original layout.
            Stack(
              alignment: Alignment.topCenter,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [_clockBlock(), _fixBlock()],
                ),
                _recIndicator(),
              ],
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

  Widget _recIndicator() {
    return RecIndicator(
      state: _dashcam,
      now: _now,
      mirrored: _mirrored,
      armed: _dashcamReady,
      disarmed: _arming.disarmed,
      onOpenRecordings: _openRecordings,
      onToggleMute: _toggleMute,
    );
  }

  /// Dim one-time prompts in the otherwise-empty right-hand column: the same
  /// device as the original "Tap for nav access", for the same reason. Something
  /// is missing, a tap fixes it, and nothing reads as a button.
  ///
  /// Suppressed while mirrored, where Transform.scale would render them
  /// backwards — which the nav prompt used to do.
  Widget _prompts() {
    if (_mirrored) return const SizedBox.shrink();
    final prompts = <Widget>[
      if (!_navAccess) _prompt('Tap for\nnav access', NavLink.openSettings),
    ];
    switch (_blocker) {
      case _Blocker.none:
        break;
      // No tap for these two: there is nothing it could do, and a dead tap would
      // fall through to the root detector and flip mirroring instead.
      case _Blocker.unsupported:
        prompts.add(_prompt('Dashcam:\nunavailable', null));
      case _Blocker.noKey:
        prompts.add(_prompt('Tap to set\ndashcam key', _editStreamKey));
      // Long press reaches the key editor from here too. Without it, a wrong key
      // entered while permissions are refused would be unreachable: the indicator
      // that normally offers the editor is hidden until the dashcam is ready.
      case _Blocker.needsPermission:
        prompts.add(_prompt(
          'Tap to enable\ndashcam',
          _requestDashcamPermission,
          onLongPress: _editStreamKey,
        ));
      case _Blocker.denied:
        prompts.add(_prompt(
          'Dashcam blocked\nTap for settings',
          DashcamLink.openAppSettings,
          onLongPress: _editStreamKey,
        ));
    }
    if (prompts.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: prompts,
    );
  }

  Widget _prompt(String text, VoidCallback? onTap, {VoidCallback? onLongPress}) {
    final label = Text(
      text,
      style: const TextStyle(color: Colors.white24, fontSize: 14, height: 1.4),
    );
    if (onTap == null && onLongPress == null) return label;
    return GestureDetector(onTap: onTap, onLongPress: onLongPress, child: label);
  }

  /// Right of the speed: the instruction and what is left of the trip.
  Widget _navTrip() {
    final nav = _nav;
    if (nav == null) return _prompts();

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
