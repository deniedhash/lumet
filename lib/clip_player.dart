import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Plays one segment from the rolling buffer.
///
/// In-app rather than handing the file to an external player: the buffer lives in
/// app-private storage, so an external viewer would need a FileProvider and a URI
/// grant for every clip. Playing it here is less machinery, and keeps the
/// landscape orientation the HUD already locks.
class ClipPlayer extends StatefulWidget {
  const ClipPlayer({super.key, required this.path, required this.name});

  final String path;
  final String name;

  @override
  State<ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<ClipPlayer> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final controller = VideoPlayerController.file(File(widget.path));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } on Exception catch (e) {
      await controller.dispose();
      if (!mounted) return;
      // A segment that was mid-write when the process died has no moov atom and
      // will not open. Say so rather than showing an empty black screen.
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      controller.value.isPlaying ? controller.pause() : controller.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: switch ((controller, _error)) {
                (final VideoPlayerController c, _) => GestureDetector(
                    onTap: _togglePlay,
                    child: AspectRatio(
                      aspectRatio: c.value.aspectRatio,
                      child: VideoPlayer(c),
                    ),
                  ),
                (_, final String _) => const Text(
                    'This clip will not open. It was probably still being '
                    'written when recording stopped.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Roboto',
                      color: Colors.white38,
                      fontSize: 14,
                    ),
                  ),
                _ => const Text(
                    'Opening…',
                    style: TextStyle(color: Colors.white24, fontSize: 15),
                  ),
              },
            ),
            if (controller != null)
              Positioned(
                left: 24,
                right: 24,
                bottom: 12,
                child: VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Color(0xFFF87171),
                    bufferedColor: Colors.white24,
                    backgroundColor: Colors.white10,
                  ),
                ),
              ),
            Positioned(
              top: 8,
              left: 24,
              right: 24,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.name,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text(
                      'Close',
                      style: TextStyle(color: Colors.white54),
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
}
