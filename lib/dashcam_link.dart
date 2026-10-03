import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where the recorder is, flattened for the indicator.
///
/// The platform reports orthogonal facts — a phase, a connection state, and
/// separate recording and streaming flags — because "writing an MP4 but not
/// uploading" is a real and important state that a single enum would lose.
/// [DashcamState.parse] collapses them into this for display.
enum DashcamPhase {
  /// Nothing running.
  idle,

  /// Camera opening, RTMPS handshake not finished.
  starting,

  /// Writing locally and uploading.
  live,

  /// Writing locally, upload dropped, retrying.
  reconnecting,

  /// Writing locally, not uploading. The dropout the buffer exists for.
  localOnly,

  /// Not capturing, and not by choice. [DashcamState.message] says why.
  error,

  /// No camera on this device. Never going to work.
  unsupported,
}

/// Where the RTMPS upload is. A dead upload never implies a dead recording.
enum DashcamConnection { disconnected, connecting, connected, reconnecting, failed }

int? _int(Object? value) => value is num ? value.toInt() : null;

bool _bool(Object? value) => value == true;

String? _str(Object? value) => value is String && value.isNotEmpty ? value : null;

/// One snapshot of the recorder.
///
/// Held in a [ValueNotifier] rather than in `State`, so a bitrate sample does not
/// repaint the gauge.
@immutable
class DashcamState {
  const DashcamState({
    this.phase = DashcamPhase.idle,
    this.connection = DashcamConnection.disconnected,
    this.recording = false,
    this.streaming = false,
    this.muted = false,
    this.startedAt,
    this.ingestHost,
    this.videoBitrate = 0,
    this.uplinkBitrate = 0,
    this.droppedVideoFrames = 0,
    this.congested = false,
    this.resolution,
    this.sessionId,
    this.directory,
    this.segment,
    this.segmentCount = 0,
    this.bufferBytes = 0,
    this.freeBytes = 0,
    this.lowStorage = false,
    this.thermalStatus = 0,
    this.thermalThrottled = false,
    this.retryCount = 0,
    this.userStopped = false,
    this.errorCode,
    this.message,
    this.warningCode,
  });

  static const idle = DashcamState();
  static const unsupported = DashcamState(phase: DashcamPhase.unsupported);

  final DashcamPhase phase;
  final DashcamConnection connection;
  final bool recording;
  final bool streaming;
  final bool muted;

  /// Wall clock of the session, so elapsed can be derived against the clock the
  /// HUD already ticks instead of the platform sending heartbeats for it.
  final DateTime? startedAt;

  /// Host only. The full ingest URL contains the stream key.
  final String? ingestHost;

  /// Bits per second, as configured.
  final int videoBitrate;

  /// Bits per second, as measured leaving the device.
  final int uplinkBitrate;

  final int droppedVideoFrames;
  final bool congested;
  final String? resolution;

  /// Shared stem for this session's files, `yyyyMMdd-HHmmss` in UTC. The
  /// telemetry sidecar uses the same stem, which is how footage and telemetry
  /// are matched up later.
  final String? sessionId;

  /// Where the rolling buffer lives. The platform owns this directory, which is
  /// why there is no `path_provider` dependency.
  final String? directory;

  /// Segment file currently being written.
  final String? segment;

  final int segmentCount;
  final int bufferBytes;
  final int freeBytes;

  /// Recording has stopped to protect the volume. Streaming continues.
  final bool lowStorage;

  /// `PowerManager.THERMAL_STATUS_*`, 0..6.
  final int thermalStatus;

  final bool thermalThrottled;
  final int retryCount;

  /// Stopped from the recorder's notification rather than by the arming policy.
  /// The HUD disarms on this, or it would restart on the very next fix.
  final bool userStopped;

  final String? errorCode;

  /// Human-readable detail. The platform is contractually required to keep the
  /// stream key out of this.
  final String? message;

  final String? warningCode;

  bool get isRecording =>
      phase == DashcamPhase.live ||
      phase == DashcamPhase.reconnecting ||
      phase == DashcamPhase.localOnly;

  bool get isUploading => phase == DashcamPhase.live;

  /// Connected but nothing actually leaving the device. Mobile uplinks produce
  /// half-open sockets where writes land in a buffer that never drains, so
  /// "connected" alone is not evidence that the upload is working.
  bool get isStalled => streaming && connection == DashcamConnection.connected && uplinkBitrate == 0;

  Duration elapsedAt(DateTime now) =>
      startedAt == null ? Duration.zero : now.difference(startedAt!);

  /// Tolerant on purpose. A renamed or missing platform field must degrade the
  /// indicator, never crash the HUD.
  static DashcamState parse(Map<dynamic, dynamic> data) {
    final native = _str(data['phase']);
    final connection = DashcamConnection.values.firstWhere(
      (c) => c.name == _str(data['connection']),
      orElse: () => DashcamConnection.disconnected,
    );
    final recording = _bool(data['recording']);
    final streaming = _bool(data['streaming']);
    final error = data['error'];
    final warning = data['warning'];

    return DashcamState(
      phase: _derive(
        native: native,
        connection: connection,
        recording: recording,
        streaming: streaming,
      ),
      connection: connection,
      recording: recording,
      streaming: streaming,
      muted: _bool(data['muted']),
      startedAt: _int(data['startedAtMs']) == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(_int(data['startedAtMs'])!),
      ingestHost: _str(data['ingestHost']),
      videoBitrate: _int(data['videoBitrate']) ?? 0,
      uplinkBitrate: _int(data['uplinkBitrate']) ?? 0,
      droppedVideoFrames: _int(data['droppedVideoFrames']) ?? 0,
      congested: _bool(data['congested']),
      resolution: _str(data['resolution']),
      sessionId: _str(data['sessionId']),
      directory: _str(data['dir']),
      segment: _str(data['segmentPath']),
      segmentCount: _int(data['segmentCount']) ?? 0,
      bufferBytes: _int(data['bufferBytes']) ?? 0,
      freeBytes: _int(data['freeBytes']) ?? 0,
      lowStorage: _bool(data['lowStorage']),
      thermalStatus: _int(data['thermalStatus']) ?? 0,
      thermalThrottled: _bool(data['thermalThrottled']),
      retryCount: _int(data['retryCount']) ?? 0,
      userStopped: _bool(data['userStopped']),
      errorCode: error is Map ? _str(error['code']) : null,
      message: error is Map ? _str(error['message']) : null,
      warningCode: warning is Map ? _str(warning['code']) : null,
    );
  }

  /// Note the ordering: once we are recording, a failed or dropped connection is
  /// [DashcamPhase.localOnly] rather than an error. Streaming failure is expected
  /// and is precisely what the local buffer is for — only a failure that is not
  /// capturing anything deserves to be called an error.
  static DashcamPhase _derive({
    required String? native,
    required DashcamConnection connection,
    required bool recording,
    required bool streaming,
  }) {
    if (native == 'error') return DashcamPhase.error;
    if (native == 'starting') return DashcamPhase.starting;
    if (streaming && connection == DashcamConnection.connected) return DashcamPhase.live;
    if (streaming &&
        (connection == DashcamConnection.connecting ||
            connection == DashcamConnection.reconnecting)) {
      return DashcamPhase.reconnecting;
    }
    if (recording) return DashcamPhase.localOnly;
    if (connection == DashcamConnection.failed) return DashcamPhase.error;
    return DashcamPhase.idle;
  }

  /// Carries no credential-shaped field, so it is safe to log.
  @override
  String toString() => 'DashcamState(${phase.name}, ${connection.name}, '
      'muted: $muted, ${uplinkBitrate ~/ 1000} kbps, dropped: $droppedVideoFrames)';
}

/// Camera, microphone and notification grants.
@immutable
class DashcamPermissionState {
  const DashcamPermissionState({
    this.camera = false,
    this.microphone = false,
    this.notifications = false,
    this.cameraPermanentlyDenied = false,
    this.microphonePermanentlyDenied = false,
  });

  final bool camera;
  final bool microphone;
  final bool notifications;
  final bool cameraPermanentlyDenied;
  final bool microphonePermanentlyDenied;

  /// Notifications are not required — without them the service still runs, the
  /// persistent notification is simply not shown.
  bool get ready => camera && microphone;

  bool get permanentlyDenied => cameraPermanentlyDenied || microphonePermanentlyDenied;

  static DashcamPermissionState parse(Map<dynamic, dynamic>? data) {
    if (data == null) return const DashcamPermissionState();
    return DashcamPermissionState(
      camera: _bool(data['camera']),
      microphone: _bool(data['microphone']),
      notifications: _bool(data['notifications']),
      cameraPermanentlyDenied: _bool(data['cameraPermanentlyDenied']),
      microphonePermanentlyDenied: _bool(data['microphonePermanentlyDenied']),
    );
  }
}

/// What the recorder needs to open a session.
///
/// [ingestUrl] and [streamKey] are separate all the way down, so that nothing
/// which might end up in a log holds both halves.
@immutable
class DashcamSession {
  const DashcamSession({
    required this.ingestUrl,
    required this.streamKey,
    required this.muted,
    required this.width,
    required this.height,
    required this.fps,
    required this.videoBitrate,
    required this.audioBitrate,
    required this.bufferMinutes,
    required this.segmentSeconds,
    required this.maxBufferBytes,
    required this.minFreeBytes,
  });

  final String ingestUrl;
  final String streamKey;
  final bool muted;
  final int width;
  final int height;
  final int fps;

  /// Bits per second.
  final int videoBitrate;
  final int audioBitrate;

  final int bufferMinutes;
  final int segmentSeconds;
  final int maxBufferBytes;
  final int minFreeBytes;

  Map<String, Object?> toArguments() => {
        'ingestUrl': ingestUrl,
        'streamKey': streamKey,
        'muted': muted,
        'width': width,
        'height': height,
        'fps': fps,
        'videoBitrate': videoBitrate,
        'audioBitrate': audioBitrate,
        'bufferMinutes': bufferMinutes,
        'segmentSeconds': segmentSeconds,
        'maxBufferBytes': maxBufferBytes,
        'minFreeBytes': minFreeBytes,
      };
}

/// Bridge to the Android capture and RTMPS pipeline.
///
/// Camera and microphone are ordinary runtime permissions, but they are requested
/// on the platform side rather than through a package: a camera foreground service
/// may only be started while the app is visible, so the request has to come from
/// the activity regardless. Same shape as [NavLink].
class DashcamLink {
  static const _events = EventChannel('lumet/dashcam');
  static const _control = MethodChannel('lumet/dashcam_control');

  /// Replays the current state on subscribe, like `lumet/nav` does — the service
  /// outlives the engine, so a fresh engine has to be told where things stand.
  static Stream<DashcamState> stream() {
    return _events
        .receiveBroadcastStream()
        .map((event) => DashcamState.parse(event as Map<dynamic, dynamic>));
  }

  static Future<bool> isSupported() async =>
      await _control.invokeMethod<bool>('isSupported') ?? false;

  static Future<DashcamPermissionState> permissions() async =>
      DashcamPermissionState.parse(
        await _control.invokeMapMethod<dynamic, dynamic>('permissions'),
      );

  /// Shows the system dialogs. Resolves to the final answer.
  static Future<DashcamPermissionState> requestPermissions() async =>
      DashcamPermissionState.parse(
        await _control.invokeMapMethod<dynamic, dynamic>('requestPermissions'),
      );

  static Future<void> openAppSettings() => _control.invokeMethod('openAppSettings');

  /// The stored stream key, or null when none has been entered.
  ///
  /// Kept on the platform side rather than in a Dart package: storage already
  /// lives there, and it keeps this side dependency-free.
  static Future<String?> streamKey() async =>
      await _control.invokeMethod<String>('streamKey');

  /// An empty or blank value clears it.
  static Future<void> setStreamKey(String key) =>
      _control.invokeMethod('setStreamKey', {'key': key});

  static Future<void> clearStreamKey() => _control.invokeMethod('clearStreamKey');

  /// The stored RTMPS ingest address, when one has been learned from the account.
  static Future<String?> ingestUrl() async =>
      await _control.invokeMethod<String>('ingestUrl');

  static Future<void> setIngestUrl(String url) =>
      _control.invokeMethod('setIngestUrl', {'url': url});

  /// Hands a watch page to the browser. Native rather than a package, for one
  /// intent.
  static Future<void> openUrl(String url) =>
      _control.invokeMethod('openUrl', {'url': url});

  /// Starts capture. Setup is asynchronous on the platform side, so the returned
  /// state is the starting snapshot — the session id and buffer directory arrive
  /// on [stream] once the recorder has opened them.
  static Future<DashcamState> start(DashcamSession session) async {
    final result = await _control.invokeMapMethod<dynamic, dynamic>(
      'start',
      session.toArguments(),
    );
    return result == null ? DashcamState.idle : DashcamState.parse(result);
  }

  static Future<void> stop() => _control.invokeMethod('stop');

  static Future<void> setMuted(bool muted) =>
      _control.invokeMethod('setMuted', {'muted': muted});

  /// Stops or starts the upload without touching the local recording.
  static Future<void> setStreamEnabled(bool enabled) =>
      _control.invokeMethod('setStreamEnabled', {'enabled': enabled});

  /// Bits per second. Clamped platform-side; returns what was actually applied.
  static Future<int> setVideoBitrate(int bitsPerSecond) async =>
      await _control.invokeMethod<int>('setVideoBitrate', {'bitrate': bitsPerSecond}) ??
          0;

  /// Best effort, and documented as such: with a persistent stream key there is
  /// no supported way to deterministically close one archive and open the next.
  /// Local recording continues across the gap.
  static Future<bool> splitBroadcast() async =>
      await _control.invokeMethod<bool>('splitBroadcast') ?? false;

  /// The rolling buffer, oldest first.
  static Future<List<Map<String, Object?>>> segments() async {
    final result = await _control.invokeListMethod<dynamic>('segments');
    return result
            ?.whereType<Map<dynamic, dynamic>>()
            .map((e) => e.cast<String, Object?>())
            .toList() ??
        const [];
  }

  /// Copies segments into the shared video collection, where Gallery and Files
  /// can see them — `/Android/data` has not been browsable since Android 11.
  /// Returns the new content URIs.
  static Future<List<String>> exportSegments(List<String> paths) async =>
      await _control.invokeListMethod<String>('exportSegments', {'paths': paths}) ??
          const [];

  /// Deletes one clip. Refuses the file currently being written.
  static Future<bool> deleteSegment(String path) async =>
      await _control.invokeMethod<bool>('deleteSegment', {'path': path}) ?? false;

  /// Deletes every complete segment. Returns how many went.
  static Future<int> purgeSegments() async =>
      await _control.invokeMethod<int>('purgeSegments') ?? 0;

  static Future<Map<String, Object?>> storage() async =>
      (await _control.invokeMapMethod<String, Object?>('storage')) ?? const {};
}
