import 'dart:ui';

/// The HUD's one visual trick: text and dots carry a soft bloom so they read as
/// light rather than as pixels, which is what survives a reflection off glass.
///
/// Shared so the gauge and the dashcam indicator cannot drift apart.
List<Shadow> glow(Color colour, {double blur = 26, double opacity = 0.5}) {
  return [Shadow(color: colour.withValues(alpha: opacity), blurRadius: blur)];
}
