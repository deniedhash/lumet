import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'dashcam_link.dart';
import 'hud_glow.dart';

/// The dashcam's only presence on screen.
///
/// Deliberately the same visual grammar as the GPS block in the opposite corner:
/// an 11px dot, a short label, and a dim detail line. The dot order is reversed
/// because a recording light reads left to right, where the GPS block is
/// right-aligned.
///
/// A public widget rather than a method on the HUD's State, so it can be tested
/// on its own and so main.dart does not grow another sixty lines.
class RecIndicator extends StatelessWidget {
  const RecIndicator({
    super.key,
    required this.state,
    required this.now,
    required this.mirrored,
    required this.armed,
    required this.disarmed,
    this.onOpenRecordings,
    this.onToggleMute,
  });

  /// A notifier rather than a plain value: recorder updates arrive about twice a
  /// second, and routing them through setState would put a second whole-tree
  /// repaint source next to the existing 30Hz one — a bitrate sample would
  /// repaint the gauge.
  final ValueListenable<DashcamState> state;

  /// From the HUD's existing one-second clock, so the elapsed label needs no
  /// timer of its own and the platform needs to send no heartbeat for it.
  final DateTime now;

  final bool mirrored;

  /// Key present, permissions granted, device capable.
  final bool armed;

  final bool disarmed;

  /// Tapping opens the recordings view. A nested gesture detector, so it wins
  /// over the HUD's root tap-to-mirror the way the nav prompt does.
  final VoidCallback? onOpenRecordings;

  /// Long-pressing toggles the microphone, and beats the root long-press, which
  /// disarms.
  final VoidCallback? onToggleMute;

  @override
  Widget build(BuildContext context) {
    // Recording only happens unmirrored, so the live form is never flipped — and
    // the dim forms would read backwards, so they are hidden rather than shown
    // the wrong way round.
    if (mirrored) return const SizedBox.shrink();

    return RepaintBoundary(
      child: ValueListenableBuilder<DashcamState>(
        valueListenable: state,
        builder: (context, value, _) => _body(value),
      ),
    );
  }

  Widget _body(DashcamState value) {
    final look = _lookFor(value);
    if (look == null) return const SizedBox.shrink();

    // Centred, not start-aligned: the detail line changes width constantly
    // (elapsed time, bitrate, ` · muted`), and left-aligning both lines would
    // walk the dot sideways every time it did.
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          // Without this the row fills whatever width it is given, which stretches
          // the column and pins the dot to the left edge instead of the centre.
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(color: look.dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              look.label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                // The only red glow on screen, so LIVE registers peripherally
                // without having to be read.
                shadows: look.glowing ? glow(look.dot, blur: 18, opacity: 0.45) : null,
              ),
            ),
          ],
        ),
        if (look.detail != null)
          Text(
            look.detail!,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 14,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );

    if (onOpenRecordings == null && onToggleMute == null) return column;
    return GestureDetector(
      onTap: onOpenRecordings,
      onLongPress: onToggleMute,
      child: column,
    );
  }

  _Look? _lookFor(DashcamState value) {
    final elapsed = _elapsed(value);
    final muted = value.muted ? '  ·  muted' : '';

    switch (value.phase) {
      case DashcamPhase.live:
        return _Look(
          dot: const Color(0xFFF87171),
          label: 'LIVE',
          detail: '$elapsed  ·  ${_rate(value.uplinkBitrate)}$muted',
          glowing: true,
        );

      case DashcamPhase.reconnecting:
        return _Look(
          dot: const Color(0xFFFBBF24),
          label: 'RETRY',
          detail: '$elapsed  ·  buffering$muted',
        );

      case DashcamPhase.localOnly:
        return _Look(
          dot: const Color(0xFFFBBF24),
          label: 'REC',
          detail: '$elapsed  ·  ${value.lowStorage ? 'storage full' : 'local only'}$muted',
        );

      case DashcamPhase.starting:
        return const _Look(
          dot: Colors.white38,
          label: 'REC',
          detail: 'opening camera',
        );

      case DashcamPhase.error:
        return _Look(
          dot: Colors.grey,
          label: 'DASHCAM',
          detail: value.message ?? 'unavailable',
        );

      case DashcamPhase.unsupported:
        return const _Look(dot: Colors.grey, label: 'DASHCAM', detail: 'unavailable');

      case DashcamPhase.idle:
        if (disarmed) {
          return _Look(dot: Colors.white24, label: 'OFF', detail: muted.trim().isEmpty ? null : 'muted');
        }
        if (!armed) return null;
        // Standby exists so the mute gesture has somewhere to show its result
        // before there is anything to record.
        return _Look(
          dot: Colors.white24,
          label: 'STBY',
          detail: value.muted ? 'muted' : null,
        );
    }
  }

  String _elapsed(DashcamState value) {
    final d = value.elapsedAt(now);
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  /// Bits per second in, Mb/s out. Zero means nothing measured yet.
  String _rate(int bitsPerSecond) {
    if (bitsPerSecond <= 0) return 'connecting';
    return '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mb/s';
  }
}

class _Look {
  const _Look({
    required this.dot,
    required this.label,
    this.detail,
    this.glowing = false,
  });

  final Color dot;
  final String label;
  final String? detail;
  final bool glowing;
}
