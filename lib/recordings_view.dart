import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'clip_player.dart';
import 'dashcam_link.dart';
import 'youtube_account.dart';

/// Everything the dashcam has recorded: the drives YouTube is holding, and the
/// rolling buffer still on the phone.
///
/// Two sources because they answer different questions. YouTube has the whole of
/// every drive but only once it has been uploaded; the device has the last few
/// minutes including whatever the cellular link dropped.
class RecordingsView extends StatefulWidget {
  const RecordingsView({
    super.key,
    required this.account,
    required this.onEditKey,
    this.serverClientId,
  });

  final YouTubeAccount account;

  /// Opens the stream key editor. It lives here now rather than on a gesture.
  final Future<void> Function() onEditKey;

  final String? serverClientId;

  @override
  State<RecordingsView> createState() => _RecordingsViewState();
}

class _RecordingsViewState extends State<RecordingsView> {
  List<YouTubeDrive>? _drives;
  List<Map<String, Object?>> _clips = const [];
  bool _loading = true;
  bool _busy = false;
  bool _hasKey = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // Nothing here is allowed to leave the view spinning: a platform error or a
    // failed token refresh has to land as an empty section.
    List<Map<String, Object?>> clips = const [];
    List<YouTubeDrive>? drives;
    try {
      clips = await DashcamLink.segments();
    } on PlatformException catch (e) {
      debugPrint('segment listing failed: ${e.code}');
    }
    try {
      if (widget.account.signedIn || await widget.account.restore()) {
        drives = await widget.account.drives();
      }
    } on Exception catch (e) {
      debugPrint('youtube listing failed: $e');
    }
    final key = await DashcamLink.streamKey();
    if (!mounted) return;
    setState(() {
      _clips = clips.reversed.toList(); // newest first
      _drives = drives;
      _hasKey = (key ?? '').isNotEmpty;
      _loading = false;
    });
  }

  /// Pulls the channel's persistent stream key and ingest address.
  ///
  /// Only ever stores automatically when nothing is set, so an account that is
  /// not the one being streamed to cannot quietly replace a working key. Pulling
  /// it deliberately asks first.
  Future<void> _useAccountKey({required bool replacing}) async {
    if (replacing) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF0E0E0E),
          content: const Text(
            'Replace the stream key with the one from this channel?',
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Replace', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _busy = true);
    final ingest = await widget.account.fetchIngest();
    if (ingest != null) {
      await DashcamLink.setStreamKey(ingest.streamKey);
      await DashcamLink.setIngestUrl(ingest.ingestUrl);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hasKey = ingest != null || _hasKey;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF111111),
        content: Text(
          ingest == null
              ? 'No stream key on this channel. Enable live streaming in Studio first.'
              : 'Stream key loaded from ${ingest.title ?? 'your channel'}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    await widget.account.initialize(serverClientId: widget.serverClientId);
    final ok = await widget.account.signIn();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    await _load();
    // The whole point of signing in is that the key no longer has to be copied
    // out of Studio by hand. Only fills a gap; never overwrites.
    if (!_hasKey && mounted) await _useAccountKey(replacing: false);
  }

  Future<void> _signOut() async {
    await widget.account.signOut();
    if (!mounted) return;
    setState(() => _drives = null);
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    final side = (insets.left > insets.right ? insets.left : insets.right) + 28;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        left: false,
        right: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, 14, side, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'RECORDINGS',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        letterSpacing: 3,
                      ),
                    ),
                  ),
                  if (widget.account.signedIn)
                    _action(
                      _hasKey ? 'Refresh key' : 'Get key',
                      () => _useAccountKey(replacing: _hasKey),
                    ),
                  if (_clips.isNotEmpty) _action('Delete all', _purge),
                  _action('Stream key', () async {
                    await widget.onEditKey();
                    if (mounted) await _load();
                  }),
                  if (widget.account.signedIn) _action('Sign out', _signOut),
                  _action('Close', () => Navigator.of(context).pop()),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _loading
                    ? const Center(
                        child: Text(
                          'Loading…',
                          style: TextStyle(color: Colors.white24, fontSize: 15),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        backgroundColor: const Color(0xFF111111),
                        color: Colors.white54,
                        child: ListView(
                          children: [
                            ..._youtubeSection(),
                            const SizedBox(height: 22),
                            ..._deviceSection(),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirm(String message, Future<void> Function() action) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0E0E0E),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete', style: TextStyle(color: Color(0xFFF87171))),
          ),
        ],
      ),
    );
    if (yes == true) await action();
  }

  Future<void> _purge() => _confirm(
        'Delete every clip on this device? Anything already uploaded to YouTube '
        'is unaffected.',
        () async {
          final deleted = await DashcamLink.purgeSegments();
          if (!mounted) return;
          await _load();
          _say('Deleted $deleted ${deleted == 1 ? 'clip' : 'clips'}');
        },
      );

  Future<void> _delete(String path, String name) => _confirm(
        'Delete $name?',
        () async {
          final gone = await DashcamLink.deleteSegment(path);
          if (!mounted) return;
          await _load();
          if (!gone) _say('Could not delete $name');
        },
      );

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF111111),
        content: Text(message, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _action(String label, VoidCallback onTap) {
    return TextButton(
      onPressed: _busy ? null : onTap,
      child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14)),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            letterSpacing: 2,
          ),
        ),
      );

  List<Widget> _youtubeSection() {
    final drives = _drives;
    if (drives == null) {
      return [
        _heading('ON YOUTUBE'),
        const Text(
          'Unlisted drives are playable by anyone with the link, but nothing '
          'public can list them — that is what unlisted means. Sign in to the '
          'channel you stream to and they appear here.',
          style: TextStyle(
            fontFamily: 'Roboto',
            color: Colors.white38,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _busy ? null : _signIn,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24),
            ),
            child: Text(
              _busy ? 'Signing in…' : 'Sign in with Google',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ];
    }
    if (drives.isEmpty) {
      return [
        _heading('ON YOUTUBE'),
        const Text(
          'No broadcasts on this channel yet.',
          style: TextStyle(color: Colors.white24, fontSize: 14),
        ),
      ];
    }
    return [
      _heading('ON YOUTUBE${widget.account.email == null ? '' : '  ·  ${widget.account.email}'}'),
      for (final drive in drives) _driveRow(drive),
    ];
  }

  Widget _driveRow(YouTubeDrive drive) {
    final duration = drive.duration;
    final detail = [
      if (drive.startedAt != null) _stamp(drive.startedAt!),
      if (duration != null) _length(duration),
      // Surfaced deliberately: a drive that is not unlisted should be obvious.
      if (drive.privacy != null && drive.privacy != 'unlisted') drive.privacy!,
    ].join('  ·  ');

    return InkWell(
      onTap: () => DashcamLink.openUrl(drive.url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            if (drive.thumbnailUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Image.network(
                  drive.thumbnailUrl!,
                  width: 96,
                  height: 54,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const SizedBox(width: 96, height: 54),
                ),
              )
            else
              const SizedBox(width: 96, height: 54),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (drive.live) ...[
                        Container(
                          width: 9,
                          height: 9,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF87171),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 7),
                      ],
                      Flexible(
                        child: Text(
                          drive.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail.isEmpty ? drive.videoId : detail,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _deviceSection() {
    if (_clips.isEmpty) {
      return [
        _heading('ON THIS DEVICE'),
        const Text(
          'The rolling buffer is empty. It fills while recording and keeps the '
          'last fifteen minutes, which is what covers a tunnel.',
          style: TextStyle(
            fontFamily: 'Roboto',
            color: Colors.white24,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ];
    }
    return [
      _heading('ON THIS DEVICE  ·  ${_clips.length} '
          '${_clips.length == 1 ? 'CLIP' : 'CLIPS'}'),
      for (final clip in _clips) _clipRow(clip),
    ];
  }

  Widget _clipRow(Map<String, Object?> clip) {
    final name = clip['name'] as String? ?? '';
    final bytes = (clip['bytes'] as num?)?.toInt() ?? 0;
    final path = clip['path'] as String?;
    final complete = clip['complete'] != false;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              // The file still being written has no moov atom yet, so there is
              // nothing to play and nothing worth exporting.
              onTap: path == null || !complete
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) =>
                              ClipPlayer(path: path, name: name),
                        ),
                      ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  children: [
                    Icon(
                      complete ? Icons.play_arrow : Icons.fiber_manual_record,
                      size: 18,
                      color: complete ? Colors.white38 : const Color(0xFFF87171),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Text(
                      complete ? _size(bytes) : 'recording',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (complete && path != null) ...[
            TextButton(
              onPressed: () async {
                final uris = await DashcamLink.exportSegments([path]);
                if (!mounted) return;
                _say(uris.isEmpty
                    ? 'Could not export $name'
                    : 'Saved to Movies/Lumet');
              },
              child: const Text(
                'export',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => _delete(path, name),
              child: const Text(
                'delete',
                style: TextStyle(color: Color(0x88F87171), fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _size(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';

  static String _length(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static String _stamp(DateTime t) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = t.hour.toString().padLeft(2, '0');
    final minute = t.minute.toString().padLeft(2, '0');
    return '${t.day} ${months[t.month - 1]}  $hour:$minute';
  }
}
