import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

/// One broadcast, as YouTube reports it.
///
/// An unlisted video is playable by anyone holding the link, so [url] needs no
/// authentication. Discovering that the video exists is the part that does: an
/// unlisted broadcast appears in no search, no public uploads playlist and no
/// channel page, which is the whole point of unlisted.
@immutable
class YouTubeDrive {
  const YouTubeDrive({
    required this.videoId,
    required this.title,
    this.startedAt,
    this.endedAt,
    this.thumbnailUrl,
    this.live = false,
    this.privacy,
  });

  final String videoId;
  final String title;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final String? thumbnailUrl;

  /// Still streaming right now.
  final bool live;

  /// `unlisted`, `private` or `public`. Surfaced so a drive that is not unlisted
  /// is visible as such rather than quietly public.
  final String? privacy;

  String get url => 'https://www.youtube.com/watch?v=$videoId';

  Duration? get duration {
    final start = startedAt;
    final end = endedAt;
    if (start == null || end == null) return null;
    return end.difference(start);
  }

  static DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;

  /// Tolerant by design: a field YouTube stops sending must drop a detail, not
  /// take the list down.
  static YouTubeDrive? parse(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final snippet = json['snippet'] as Map<String, dynamic>? ?? const {};
    final status = json['status'] as Map<String, dynamic>? ?? const {};
    final thumbnails = snippet['thumbnails'] as Map<String, dynamic>? ?? const {};
    final thumb = (thumbnails['medium'] ?? thumbnails['default'])
        as Map<String, dynamic>?;

    final lifeCycle = status['lifeCycleStatus'];
    return YouTubeDrive(
      videoId: id,
      title: (snippet['title'] as String?)?.trim().isNotEmpty == true
          ? snippet['title'] as String
          : 'Untitled drive',
      startedAt: _time(snippet['actualStartTime']) ?? _time(snippet['publishedAt']),
      endedAt: _time(snippet['actualEndTime']),
      thumbnailUrl: thumb?['url'] as String?,
      live: lifeCycle == 'live' || lifeCycle == 'liveStarting',
      privacy: status['privacyStatus'] as String?,
    );
  }

  /// Newest first, live always on top.
  static int byRecency(YouTubeDrive a, YouTubeDrive b) {
    if (a.live != b.live) return a.live ? -1 : 1;
    final at = a.startedAt;
    final bt = b.startedAt;
    if (at == null || bt == null) return 0;
    return bt.compareTo(at);
  }
}

/// The ingest endpoint a channel's persistent stream is configured with.
///
/// This is why signing in removes the copy-paste from Studio: `liveStreams.list`
/// reports both halves of the endpoint, and it does so under the same read-only
/// scope the recordings list already needs.
@immutable
class YouTubeIngest {
  const YouTubeIngest({
    required this.streamKey,
    required this.ingestUrl,
    this.title,
  });

  /// `cdn.ingestionInfo.streamName` — the stream key an encoder uses.
  final String streamKey;

  /// `cdn.ingestionInfo.rtmpsIngestionAddress`, falling back to the plain RTMP
  /// address only if YouTube ever stops reporting the secure one.
  final String ingestUrl;

  final String? title;

  static YouTubeIngest? parse(Map<String, dynamic> json) {
    final cdn = json['cdn'] as Map<String, dynamic>? ?? const {};
    final info = cdn['ingestionInfo'] as Map<String, dynamic>? ?? const {};
    final key = (info['streamName'] as String?)?.trim() ?? '';
    final rtmps = (info['rtmpsIngestionAddress'] as String?)?.trim() ?? '';
    final rtmp = (info['ingestionAddress'] as String?)?.trim() ?? '';
    final url = rtmps.isNotEmpty ? rtmps : rtmp;
    if (key.isEmpty || url.isEmpty) return null;

    final snippet = json['snippet'] as Map<String, dynamic>? ?? const {};
    return YouTubeIngest(
      streamKey: key,
      // Trailing slashes would double up when the key is appended natively.
      ingestUrl: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
      title: (snippet['title'] as String?)?.trim(),
    );
  }
}

/// Read-only access to the signed-in channel's broadcasts.
///
/// Read-only on purpose: the app pushes to a persistent stream key and has no
/// business editing anything on the account. The narrower scope is also a
/// smaller consent prompt.
class YouTubeAccount {
  static const scopes = <String>['https://www.googleapis.com/auth/youtube.readonly'];

  static const _endpoint = 'https://www.googleapis.com/youtube/v3/liveBroadcasts';
  static const _streamsEndpoint = 'https://www.googleapis.com/youtube/v3/liveStreams';

  bool _initialized = false;
  GoogleSignInAccount? _account;
  String? _token;

  bool get signedIn => _account != null && _token != null;

  String? get email => _account?.email;

  Future<void> initialize({String? serverClientId}) async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
    _initialized = true;
  }

  /// Picks up an existing session without showing anything. Safe to call on
  /// startup; returns false when the user has never signed in.
  Future<bool> restore() async {
    await initialize();
    try {
      final account = await GoogleSignIn.instance.attemptLightweightAuthentication();
      if (account == null) return false;
      _account = account;
      final authorization =
          await account.authorizationClient.authorizationForScopes(scopes);
      _token = authorization?.accessToken;
      return signedIn;
    } on GoogleSignInException catch (e) {
      debugPrint('youtube restore failed: ${e.code}');
      return false;
    }
  }

  /// Shows the account picker and the consent prompt.
  Future<bool> signIn() async {
    await initialize();
    try {
      final account = await GoogleSignIn.instance.authenticate();
      _account = account;
      final authorization =
          await account.authorizationClient.authorizeScopes(scopes);
      _token = authorization.accessToken;
      return signedIn;
    } on GoogleSignInException catch (e) {
      debugPrint('youtube sign-in failed: ${e.code}');
      return false;
    }
  }

  Future<void> signOut() async {
    _token = null;
    _account = null;
    if (!_initialized) return;
    await GoogleSignIn.instance.signOut();
  }

  /// The live broadcast, if any, followed by completed ones, newest first.
  ///
  /// Two calls rather than one: `broadcastStatus` takes a single value, and the
  /// active one is worth having even when the completed list fails.
  Future<List<YouTubeDrive>> drives({int limit = 25}) async {
    final token = _token;
    if (token == null) return const [];

    final results = await Future.wait([
      _list(token, 'active', 5),
      _list(token, 'completed', limit),
    ]);

    final seen = <String>{};
    final drives = <YouTubeDrive>[];
    for (final drive in results.expand((e) => e)) {
      if (seen.add(drive.videoId)) drives.add(drive);
    }
    drives.sort(YouTubeDrive.byRecency);
    return drives;
  }

  /// The channel's persistent stream key and ingest address.
  ///
  /// Fetched once and cached on the device rather than read at arming time: a
  /// Testing-mode token lapses after a week, the car has no guaranteed signal,
  /// and neither should be able to stop a recording from uploading.
  Future<YouTubeIngest?> fetchIngest() async {
    final token = _token;
    if (token == null) return null;

    final uri = Uri.parse(_streamsEndpoint).replace(queryParameters: {
      'part': 'cdn,snippet',
      'mine': 'true',
      'maxResults': '10',
    });
    try {
      final response = await http.get(uri, headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      });
      if (response.statusCode == 401) {
        _token = null;
        return null;
      }
      if (response.statusCode != 200) {
        debugPrint('youtube stream list: HTTP ${response.statusCode}');
        return null;
      }
      final ingests = parseIngests(response.body);
      return ingests.isEmpty ? null : ingests.first;
    } on Exception catch (e) {
      debugPrint('youtube stream list failed: $e');
      return null;
    }
  }

  /// Separated from the request so it can be tested without a network.
  ///
  /// Never log the result: these carry the stream key.
  @visibleForTesting
  static List<YouTubeIngest> parseIngests(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return const [];
      final items = decoded['items'];
      if (items is! List) return const [];
      return items
          .whereType<Map<String, dynamic>>()
          .map(YouTubeIngest.parse)
          .whereType<YouTubeIngest>()
          .toList();
    } on FormatException {
      return const [];
    }
  }

  Future<List<YouTubeDrive>> _list(String token, String status, int limit) async {
    final uri = Uri.parse(_endpoint).replace(queryParameters: {
      'part': 'snippet,status',
      'broadcastStatus': status,
      'broadcastType': 'all',
      'maxResults': '$limit',
    });
    try {
      final response = await http.get(uri, headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      });
      if (response.statusCode == 401) {
        // The token aged out. In a Testing-mode consent screen that happens
        // every seven days.
        _token = null;
        return const [];
      }
      if (response.statusCode != 200) {
        debugPrint('youtube $status list: HTTP ${response.statusCode}');
        return const [];
      }
      return parseDrives(response.body);
    } on Exception catch (e) {
      debugPrint('youtube $status list failed: $e');
      return const [];
    }
  }

  /// Separated from the request so it can be tested without a network.
  @visibleForTesting
  static List<YouTubeDrive> parseDrives(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return const [];
      final items = decoded['items'];
      if (items is! List) return const [];
      return items
          .whereType<Map<String, dynamic>>()
          .map(YouTubeDrive.parse)
          .whereType<YouTubeDrive>()
          .toList();
    } on FormatException {
      return const [];
    }
  }
}
