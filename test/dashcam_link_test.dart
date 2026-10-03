import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumet/dashcam_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DashcamState.parse phase derivation', () {
    DashcamPhase phaseOf({
      String? phase,
      String? connection,
      bool recording = false,
      bool streaming = false,
    }) {
      return DashcamState.parse({
        'phase': phase,
        'connection': connection,
        'recording': recording,
        'streaming': streaming,
      }).phase;
    }

    test('uploading and connected is live', () {
      expect(
        phaseOf(phase: 'active', connection: 'connected', recording: true, streaming: true),
        DashcamPhase.live,
      );
    });

    test('uploading but connecting or reconnecting is reconnecting', () {
      expect(
        phaseOf(phase: 'active', connection: 'connecting', recording: true, streaming: true),
        DashcamPhase.reconnecting,
      );
      expect(
        phaseOf(
            phase: 'active', connection: 'reconnecting', recording: true, streaming: true),
        DashcamPhase.reconnecting,
      );
    });

    test('recording without uploading is localOnly', () {
      expect(
        phaseOf(phase: 'active', connection: 'disconnected', recording: true),
        DashcamPhase.localOnly,
      );
    });

    test('a failed upload while still recording is localOnly, not an error', () {
      // Streaming failure is expected and is exactly what the buffer is for.
      expect(
        phaseOf(phase: 'active', connection: 'failed', recording: true),
        DashcamPhase.localOnly,
      );
    });

    test('a failed connection with nothing captured is an error', () {
      expect(phaseOf(phase: 'active', connection: 'failed'), DashcamPhase.error);
    });

    test('the platform error phase wins over everything', () {
      expect(
        phaseOf(phase: 'error', connection: 'connected', recording: true, streaming: true),
        DashcamPhase.error,
      );
    });

    test('starting is reported before any connection exists', () {
      expect(phaseOf(phase: 'starting', connection: 'disconnected'), DashcamPhase.starting);
    });

    test('nothing happening is idle', () {
      expect(phaseOf(phase: 'idle', connection: 'disconnected'), DashcamPhase.idle);
      expect(phaseOf(phase: 'stopping', connection: 'disconnected'), DashcamPhase.idle);
    });
  });

  group('DashcamState.parse tolerance', () {
    test('an empty map yields a usable idle state', () {
      final state = DashcamState.parse({});
      expect(state.phase, DashcamPhase.idle);
      expect(state.muted, isFalse);
      expect(state.uplinkBitrate, 0);
      expect(state.startedAt, isNull);
      expect(state.isRecording, isFalse);
    });

    test('all-null values do not throw', () {
      final state = DashcamState.parse({
        for (final key in [
          'phase', 'connection', 'recording', 'streaming', 'muted', 'startedAtMs',
          'ingestHost', 'videoBitrate', 'uplinkBitrate', 'droppedVideoFrames',
          'congested', 'resolution', 'sessionId', 'dir', 'segmentPath',
          'segmentCount', 'bufferBytes', 'freeBytes', 'lowStorage',
          'thermalStatus', 'thermalThrottled', 'retryCount', 'error', 'warning',
        ])
          key: null,
      });
      expect(state.phase, DashcamPhase.idle);
      expect(state.sessionId, isNull);
    });

    test('wrong types degrade rather than crash', () {
      // A platform field changing type must not take the HUD down with it.
      final state = DashcamState.parse({
        'phase': 42,
        'connection': ['connected'],
        'videoBitrate': '2500000',
        'uplinkBitrate': 2400000.7,
        'startedAtMs': 'yesterday',
        'segmentCount': {'n': 3},
        'error': 'boom',
      });
      expect(state.phase, DashcamPhase.idle);
      expect(state.connection, DashcamConnection.disconnected);
      expect(state.videoBitrate, 0);
      expect(state.uplinkBitrate, 2400000);
      expect(state.startedAt, isNull);
      expect(state.segmentCount, 0);
      expect(state.errorCode, isNull);
    });

    test('an unknown connection value falls back to disconnected', () {
      expect(
        DashcamState.parse({'connection': 'quantum'}).connection,
        DashcamConnection.disconnected,
      );
    });

    test('error and warning maps are unpacked', () {
      final state = DashcamState.parse({
        'error': {'code': 'authError', 'message': 'Stream key rejected'},
        'warning': {'code': 'notificationsDenied'},
      });
      expect(state.errorCode, 'authError');
      expect(state.message, 'Stream key rejected');
      expect(state.warningCode, 'notificationsDenied');
    });

    test('elapsed is derived from the start timestamp', () {
      final start = DateTime.utc(2026, 10, 2, 14, 0, 0);
      final state = DashcamState.parse({'startedAtMs': start.millisecondsSinceEpoch});
      expect(state.elapsedAt(start.add(const Duration(minutes: 12))),
          const Duration(minutes: 12));
    });

    test('a stalled upload is detected', () {
      final stalled = DashcamState.parse({
        'phase': 'active',
        'connection': 'connected',
        'recording': true,
        'streaming': true,
        'uplinkBitrate': 0,
      });
      expect(stalled.isStalled, isTrue);
      expect(stalled.phase, DashcamPhase.live);
    });

    test('toString carries nothing credential-shaped', () {
      final state = DashcamState.parse({
        'phase': 'active',
        'connection': 'connected',
        'streaming': true,
        'ingestHost': 'a.rtmps.youtube.com',
      });
      expect(state.toString(), isNot(contains('rtmps')));
      expect(state.toString(), isNot(contains('youtube')));
    });
  });

  group('DashcamPermissionState', () {
    test('notifications are not required for readiness', () {
      const state = DashcamPermissionState(camera: true, microphone: true);
      expect(state.ready, isTrue);
      expect(state.notifications, isFalse);
    });

    test('a missing grant blocks readiness', () {
      expect(const DashcamPermissionState(camera: true).ready, isFalse);
      expect(const DashcamPermissionState(microphone: true).ready, isFalse);
    });

    test('a null map parses to nothing granted', () {
      expect(DashcamPermissionState.parse(null).ready, isFalse);
    });

    test('permanent denial is surfaced', () {
      expect(
        DashcamPermissionState.parse({'cameraPermanentlyDenied': true}).permanentlyDenied,
        isTrue,
      );
    });
  });

  group('DashcamLink', () {
    const channel = MethodChannel('lumet/dashcam_control');
    final calls = <MethodCall>[];
    Object? reply;

    setUp(() {
      calls.clear();
      reply = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    const session = DashcamSession(
      ingestUrl: 'rtmps://a.rtmps.youtube.com/live2',
      streamKey: 'abcd-efgh-ijkl-mnop-qrst',
      muted: false,
      width: 1280,
      height: 720,
      fps: 30,
      videoBitrate: 2500000,
      audioBitrate: 128000,
      bufferMinutes: 15,
      segmentSeconds: 60,
      maxBufferBytes: 2147483648,
      minFreeBytes: 524288000,
    );

    test('start sends the url and the key as separate arguments', () async {
      reply = {'phase': 'starting'};
      await DashcamLink.start(session);
      final args = calls.single.arguments as Map;
      expect(args['ingestUrl'], 'rtmps://a.rtmps.youtube.com/live2');
      expect(args['streamKey'], 'abcd-efgh-ijkl-mnop-qrst');
      // The invariant that keeps the key out of any logged URL.
      expect(args['ingestUrl'], isNot(contains('abcd')));
    });

    test('start reports the starting phase', () async {
      reply = {'phase': 'starting'};
      expect((await DashcamLink.start(session)).phase, DashcamPhase.starting);
    });

    test('a malformed start reply yields idle rather than throwing', () async {
      reply = null;
      expect((await DashcamLink.start(session)).phase, DashcamPhase.idle);
    });

    test('setMuted sends the flag', () async {
      await DashcamLink.setMuted(true);
      expect(calls.single.method, 'setMuted');
      expect((calls.single.arguments as Map)['muted'], isTrue);
    });

    test('isSupported defaults to false when the platform says nothing', () async {
      reply = null;
      expect(await DashcamLink.isSupported(), isFalse);
    });

    test('permissions parses the platform snapshot', () async {
      reply = {'camera': true, 'microphone': true, 'notifications': false};
      final permissions = await DashcamLink.permissions();
      expect(permissions.ready, isTrue);
      expect(permissions.notifications, isFalse);
    });

    test('segments tolerates a null or ragged reply', () async {
      reply = null;
      expect(await DashcamLink.segments(), isEmpty);
      reply = [
        {'path': '/a/lumet_20261002-140511-0000.mp4', 'bytes': 10},
        'not a map',
      ];
      final segments = await DashcamLink.segments();
      expect(segments.length, 1);
      expect(segments.single['bytes'], 10);
    });

    test('exportSegments passes the paths through', () async {
      reply = <String>['content://media/external/video/media/42'];
      final uris = await DashcamLink.exportSegments(['/a/b.mp4']);
      expect((calls.single.arguments as Map)['paths'], ['/a/b.mp4']);
      expect(uris.single, contains('content://'));
    });

    test('numeric helpers default rather than throw on a null reply', () async {
      reply = null;
      expect(await DashcamLink.setVideoBitrate(2500000), 0);
      expect(await DashcamLink.purgeSegments(), 0);
      expect(await DashcamLink.splitBroadcast(), isFalse);
      expect(await DashcamLink.storage(), isEmpty);
    });

    test('stop takes no arguments', () async {
      await DashcamLink.stop();
      expect(calls.single.method, 'stop');
      expect(calls.single.arguments, isNull);
    });
  });
}
