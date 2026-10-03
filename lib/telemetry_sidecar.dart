import 'dart:convert';
import 'dart:io';

/// Where sidecar lines go. Abstracted so the writer can be tested without a
/// filesystem, and so a failing disk can never take the HUD down with it.
abstract class TelemetrySink {
  void writeln(String line);

  Future<void> flush();

  Future<void> close();
}

/// Appends to `<sessionId>.jsonl` beside the video segments.
class FileTelemetrySink implements TelemetrySink {
  FileTelemetrySink(File file)
      : _sink = file.openWrite(mode: FileMode.writeOnlyAppend);

  final IOSink _sink;

  @override
  void writeln(String line) => _sink.writeln(line);

  @override
  Future<void> flush() => _sink.flush();

  @override
  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }
}

/// In-memory sink, for tests.
class BufferTelemetrySink implements TelemetrySink {
  final _buffer = StringBuffer();
  int flushes = 0;
  bool closed = false;

  List<String> get lines =>
      _buffer.toString().split('\n').where((l) => l.isNotEmpty).toList();

  @override
  void writeln(String line) => _buffer.writeln(line);

  @override
  Future<void> flush() async => flushes++;

  @override
  Future<void> close() async => closed = true;
}

/// Six decimals of latitude is about 11 cm, which is already finer than the fix
/// is worth; more than that just burns bytes.
String _coord(double value) => value.toStringAsFixed(6);

bool _usable(double? value) =>
    value != null && !value.isNaN && !value.isInfinite;

/// One fix as a JSON Lines record.
///
/// Hand-built rather than passed through [jsonEncode] because this runs at fix
/// rate. `toStringAsFixed` is locale-independent, so no comma decimal separators
/// can leak in.
///
/// Absent values are omitted rather than written as null: a consumer should never
/// have to work out whether `"hdg":null` means "no heading" or "heading zero".
String encodeFix({
  required DateTime at,
  required double latitude,
  required double longitude,
  double? shownKmh,
  double? gpsKmh,
  double? heading,
  double? altitude,
  double? accuracy,
  double? tripMetres,
}) {
  final parts = <String>[
    '"t":${at.millisecondsSinceEpoch}',
    '"lat":${_coord(latitude)}',
    '"lon":${_coord(longitude)}',
  ];
  if (_usable(shownKmh)) parts.add('"spd":${shownKmh!.toStringAsFixed(1)}');
  if (_usable(gpsKmh)) parts.add('"gps":${gpsKmh!.toStringAsFixed(1)}');
  // geolocator reports -1 for an absent heading, and NaN on some devices.
  if (_usable(heading) && heading! >= 0) parts.add('"hdg":${heading.round()}');
  if (_usable(altitude)) parts.add('"alt":${altitude!.round()}');
  if (_usable(accuracy)) parts.add('"acc":${accuracy!.toStringAsFixed(1)}');
  if (_usable(tripMetres)) parts.add('"trip":${tripMetres!.round()}');
  return '{${parts.join(',')}}';
}

/// A named event. Goes through [jsonEncode], which also guarantees the result
/// contains no raw newline however odd the field values are.
String encodeEvent(String name, DateTime at, [Map<String, Object?> fields = const {}]) {
  return jsonEncode({
    't': at.millisecondsSinceEpoch,
    'ev': name,
    ...fields,
  });
}

/// Writes speed and position alongside the footage, so a drive can be
/// reconstructed without burning a HUD overlay into the video.
///
/// JSON Lines rather than GPX: a car loses power mid-recording, and every finished
/// NDJSON line survives that where an unclosed `<gpx>` does not. GPX also has
/// nowhere to put accuracy, the fused speed, or mute and segment events without
/// resorting to `<extensions>`.
///
/// At roughly 110 bytes per fix and 1.4 fixes a second this is about 550 kB an
/// hour — nothing next to the video.
class TelemetrySidecar {
  TelemetrySidecar(this._sink, {this.flushEvery = 50});

  final TelemetrySink _sink;

  /// About 35 seconds of fixes. Short enough that a crash loses little, long
  /// enough that the position handler never waits on a disk.
  final int flushEvery;

  int _pending = 0;
  bool _closed = false;

  /// The anchor for matching against the YouTube archive: an offset into the
  /// video plus this timestamp gives the moment to look up.
  void start({
    required String sessionId,
    required DateTime at,
    String? appVersion,
  }) {
    _write(encodeEvent('start', at, {
      'session': sessionId,
      'tz': at.timeZoneOffset.inMinutes,
      'app': ?appVersion,
    }));
  }

  /// Call from the position handler. Never awaits — a buffered write at 1.4 Hz is
  /// nothing, but a filesystem await inside that handler is a visible stutter.
  void fix({
    required DateTime at,
    required double latitude,
    required double longitude,
    double? shownKmh,
    double? gpsKmh,
    double? heading,
    double? altitude,
    double? accuracy,
    double? tripMetres,
  }) {
    _write(encodeFix(
      at: at,
      latitude: latitude,
      longitude: longitude,
      shownKmh: shownKmh,
      gpsKmh: gpsKmh,
      heading: heading,
      altitude: altitude,
      accuracy: accuracy,
      tripMetres: tripMetres,
    ));
  }

  void event(String name, {DateTime? at, Map<String, Object?> fields = const {}}) {
    _write(encodeEvent(name, at ?? DateTime.now(), fields));
  }

  void _write(String line) {
    if (_closed) return;
    _sink.writeln(line);
    if (++_pending >= flushEvery) {
      _pending = 0;
      _sink.flush();
    }
  }

  Future<void> flush() async {
    if (_closed) return;
    _pending = 0;
    await _sink.flush();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.close();
  }
}
