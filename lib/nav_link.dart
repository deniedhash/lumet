import 'package:flutter/services.dart';

/// One turn, as reported by whichever navigation app is running.
class NavInfo {
  const NavInfo({
    this.distance,
    this.instruction,
    this.duration,
    this.remaining,
    this.arrival,
    this.icon,
  });

  /// Distance to the next turn, already formatted by the nav app ("700 m").
  final String? distance;

  /// The turn itself ("Turn right onto Outer Ring Road").
  final String? instruction;

  /// Time left on the route ("9 min").
  final String? duration;

  /// Distance left on the route ("3.3 km").
  final String? remaining;

  /// Clock time of arrival ("3:20 am").
  final String? arrival;

  /// The turn arrow, as PNG bytes.
  final Uint8List? icon;

  /// Google Maps packs the trip summary into one string, separated by
  /// middle dots: "9 min · 3.3 km · 3:20 am ETA".
  static NavInfo parse(Map<dynamic, dynamic> data) {
    final parts = (data['eta'] as String?)
            ?.split('·')
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .toList() ??
        const <String>[];

    String? at(int i) => i < parts.length ? parts[i] : null;

    return NavInfo(
      distance: data['distance'] as String?,
      instruction: data['instruction'] as String?,
      duration: at(0),
      remaining: at(1),
      // Drop the trailing "ETA" label; the HUD has its own.
      arrival: at(2)?.replaceAll(RegExp(r'\s*ETA\s*$', caseSensitive: false), ''),
      icon: data['icon'] as Uint8List?,
    );
  }
}

/// Bridge to the Android notification listener.
///
/// Notification access is a special permission: it cannot be requested with a
/// dialog, only granted by the user in Settings. [openSettings] takes them
/// straight to the right screen.
class NavLink {
  static const _events = EventChannel('lumet/nav');
  static const _control = MethodChannel('lumet/nav_control');

  /// Emits a [NavInfo] per turn update, or null when navigation stops.
  static Stream<NavInfo?> stream() {
    return _events.receiveBroadcastStream().map((event) {
      final data = event as Map<dynamic, dynamic>;
      if (data['active'] != true) return null;
      return NavInfo.parse(data);
    });
  }

  static Future<bool> isEnabled() async {
    return await _control.invokeMethod<bool>('isEnabled') ?? false;
  }

  static Future<void> openSettings() => _control.invokeMethod('openSettings');
}
