import 'package:flutter_test/flutter_test.dart';
import 'package:lumet/telemetry_sidecar.dart';

void main() {
  final at = DateTime.fromMillisecondsSinceEpoch(1759412711412, isUtc: true);

  group('encodeFix', () {
    test('writes a full record in the documented shape', () {
      expect(
        encodeFix(
          at: at,
          latitude: 12.971599,
          longitude: 77.594566,
          shownKmh: 18.44,
          gpsKmh: 17.9,
          heading: 112.4,
          altitude: 255.3,
          accuracy: 3.22,
          tripMetres: 12643.2,
        ),
        '{"t":1759412711412,"lat":12.971599,"lon":77.594566,'
        '"spd":18.4,"gps":17.9,"hdg":112,"alt":255,"acc":3.2,"trip":12643}',
      );
    });

    test('keeps six decimals of coordinate', () {
      final line = encodeFix(at: at, latitude: 12.9, longitude: -77.1);
      expect(line, contains('"lat":12.900000'));
      expect(line, contains('"lon":-77.100000'));
    });

    test('omits absent values rather than writing null', () {
      final line = encodeFix(at: at, latitude: 1, longitude: 2);
      expect(line, isNot(contains('null')));
      expect(line, isNot(contains('spd')));
      expect(line, isNot(contains('hdg')));
      expect(line, '{"t":1759412711412,"lat":1.000000,"lon":2.000000}');
    });

    test("drops geolocator's -1 heading", () {
      expect(encodeFix(at: at, latitude: 1, longitude: 2, heading: -1),
          isNot(contains('hdg')));
      expect(encodeFix(at: at, latitude: 1, longitude: 2, heading: 0),
          contains('"hdg":0'));
    });

    test('drops NaN and infinity', () {
      final line = encodeFix(
        at: at,
        latitude: 1,
        longitude: 2,
        heading: double.nan,
        altitude: double.infinity,
        accuracy: double.negativeInfinity,
        shownKmh: double.nan,
      );
      expect(line, '{"t":1759412711412,"lat":1.000000,"lon":2.000000}');
    });

    test('never contains a newline', () {
      expect(encodeFix(at: at, latitude: 1, longitude: 2), isNot(contains('\n')));
    });

    test('is locale independent', () {
      // A comma decimal separator would silently corrupt every consumer.
      expect(encodeFix(at: at, latitude: 1.5, longitude: 2.5, shownKmh: 3.5),
          isNot(contains(',"lat":1,5')));
      expect(encodeFix(at: at, latitude: 1.5, longitude: 2.5), contains('1.500000'));
    });
  });

  group('encodeEvent', () {
    test('writes the timestamp and name', () {
      expect(encodeEvent('mute', at, {'on': true}),
          '{"t":1759412711412,"ev":"mute","on":true}');
    });

    test('escapes a newline in a field rather than emitting one', () {
      final line = encodeEvent('segment', at, {'file': 'a\nb.mp4'});
      expect(line, isNot(contains('\n')));
      expect(line, contains(r'a\nb.mp4'));
    });

    test('takes no fields', () {
      expect(encodeEvent('resume', at), '{"t":1759412711412,"ev":"resume"}');
    });
  });

  group('TelemetrySidecar', () {
    late BufferTelemetrySink sink;
    late TelemetrySidecar sidecar;

    setUp(() {
      sink = BufferTelemetrySink();
      sidecar = TelemetrySidecar(sink, flushEvery: 3);
    });

    test('the header is the first line and anchors the session', () {
      sidecar.start(sessionId: '20261002-140511', at: at, appVersion: '1.0.0+1');
      expect(sink.lines.first, contains('"ev":"start"'));
      expect(sink.lines.first, contains('"session":"20261002-140511"'));
      expect(sink.lines.first, contains('"app":"1.0.0+1"'));
      expect(sink.lines.first, contains('"t":1759412711412'));
    });

    test('flushes on the configured interval, not every line', () {
      for (var i = 0; i < 3; i++) {
        sidecar.fix(at: at, latitude: 1, longitude: 2);
      }
      expect(sink.flushes, 1);
      sidecar.fix(at: at, latitude: 1, longitude: 2);
      expect(sink.flushes, 1);
    });

    test('an explicit flush resets the counter', () async {
      sidecar.fix(at: at, latitude: 1, longitude: 2);
      await sidecar.flush();
      expect(sink.flushes, 1);
      sidecar.fix(at: at, latitude: 1, longitude: 2);
      sidecar.fix(at: at, latitude: 1, longitude: 2);
      expect(sink.flushes, 1);
    });

    test('close flushes and then refuses further writes', () async {
      sidecar.fix(at: at, latitude: 1, longitude: 2);
      await sidecar.close();
      expect(sink.closed, isTrue);
      final before = sink.lines.length;
      sidecar.fix(at: at, latitude: 9, longitude: 9);
      sidecar.event('late');
      expect(sink.lines.length, before);
    });

    test('close twice is harmless', () async {
      await sidecar.close();
      await sidecar.close();
    });

    test('events and fixes interleave in order', () {
      sidecar.start(sessionId: '20261002-140511', at: at);
      sidecar.fix(at: at, latitude: 1, longitude: 2);
      sidecar.event('segment', at: at, fields: {'file': 'lumet_20261002-140511-0001.mp4'});
      expect(sink.lines.map((l) => l.contains('"ev"')).toList(), [true, false, true]);
    });
  });
}
