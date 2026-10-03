/// Dashcam tuning, and the one place that knows where a stream key comes from.
///
/// The key is a credential. It is compiled in with `--dart-define` rather than
/// typed into the app, because the HUD has no text input and should not grow one:
///
/// ```sh
/// flutter run --dart-define=LUMET_INGEST_KEY=$(cat .secrets/youtube_key)
/// ```
///
/// It must never be printed, never be interpolated into an error message and
/// never be committed. [redacted] is the only form allowed anywhere near a log.
class DashcamConfig {
  /// YouTube's primary RTMPS ingest. The key is appended natively, so no string
  /// on this side ever holds both halves.
  static const ingestUrl = 'rtmps://a.rtmps.youtube.com/live2';

  static const _key = String.fromEnvironment('LUMET_INGEST_KEY');

  /// Web OAuth client id from the Google Cloud project, used only to list the
  /// channel's own broadcasts. Not a secret — it ships in every app that signs in
  /// with Google, and the Android client is matched by package name and signing
  /// certificate rather than by anything embedded here.
  static const _googleClientId = String.fromEnvironment('LUMET_GOOGLE_CLIENT_ID');

  static String? get googleServerClientId =>
      _googleClientId.isEmpty ? null : _googleClientId;

  /// Keep the last quarter hour on disk as insurance against upload dropouts.
  static const bufferMinutes = 15;

  static const segmentSeconds = 60;

  /// Hard ceiling regardless of [bufferMinutes], so a bitrate spike cannot
  /// outrun the segment-count estimate.
  static const maxBufferBytes = 2 * 1024 * 1024 * 1024; // 2 GiB

  /// Below this much free space, recording stops and streaming continues —
  /// YouTube is the primary store, and the user's own files are not ours to evict.
  static const minFreeBytes = 500 * 1024 * 1024;

  static const width = 1280;
  static const height = 720;
  static const fps = 30;

  /// Bits per second. Below YouTube's recommended 3-8 Mbps band for 720p30, to
  /// hold mobile data near 1.2 GB/hour. Raise to 4000000 if number plates turn
  /// out illegible — the encoder costs about 0.2 W, so this is a data decision
  /// rather than a thermal one.
  static const videoBitrate = 2500000;

  static const audioBitrate = 128000;

  /// Drop screen brightness to this once the device reports thermal throttling.
  /// Worth more watts than halving the video bitrate.
  static const throttledBrightness = 0.6;

  /// Resolves the key to use, preferring one entered in the app over one baked in
  /// at build time.
  ///
  /// Stays pure — [stored] is passed in rather than fetched — so it is testable
  /// without a platform channel. This is the single seam that knows where a key
  /// comes from: pointing it at a backend later changes nothing else.
  static Future<String?> resolveKey({String? stored}) async {
    for (final candidate in [stored, _key]) {
      final key = candidate?.trim() ?? '';
      if (key.isNotEmpty) return key;
    }
    return null;
  }

  /// `yt_••••3f7a` — safe to print, and enough to tell two keys apart.
  static String redacted(String? key) {
    if (key == null || key.isEmpty) return 'yt_<none>';
    final tail = key.length <= 4 ? key : key.substring(key.length - 4);
    return 'yt_••••$tail';
  }
}
