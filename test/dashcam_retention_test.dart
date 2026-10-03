import 'package:flutter_test/flutter_test.dart';
import 'package:lumet/dashcam_retention.dart';

void main() {
  final now = DateTime.utc(2026, 10, 2, 15, 0, 0);
  const oneMb = 1024 * 1024;

  BufferEntry seg(int minutesAgo, {int bytes = 20 * oneMb}) {
    final at = now.subtract(Duration(minutes: minutesAgo));
    final stamp = '${at.year}'
        '${at.month.toString().padLeft(2, '0')}'
        '${at.day.toString().padLeft(2, '0')}'
        '-${at.hour.toString().padLeft(2, '0')}'
        '${at.minute.toString().padLeft(2, '0')}'
        '${at.second.toString().padLeft(2, '0')}';
    return BufferEntry('lumet_$stamp.mp4', at, bytes);
  }

  List<String> names(List<BufferEntry> entries) => entries.map((e) => e.name).toList();

  group('parseSessionStamp', () {
    test('parses a bare stamp as UTC', () {
      expect(parseSessionStamp('20261002-140511'), DateTime.utc(2026, 10, 2, 14, 5, 11));
    });

    test('finds a stamp inside a longer filename', () {
      expect(
        parseSessionStamp('lumet_20261002-140511-0007.mp4'),
        DateTime.utc(2026, 10, 2, 14, 5, 11),
      );
      expect(parseSessionStamp('20261002-140511.jsonl'),
          DateTime.utc(2026, 10, 2, 14, 5, 11));
    });

    test('rejects anything that is not a stamp', () {
      expect(parseSessionStamp('scratch.mp4'), isNull);
      expect(parseSessionStamp(''), isNull);
      expect(parseSessionStamp('lumet_2026-10-02.mp4'), isNull);
      expect(parseSessionStamp('1234567-123456'), isNull);
    });

    test('rejects impossible dates and times instead of rolling them over', () {
      expect(parseSessionStamp('20260231-120000'), isNull);
      expect(parseSessionStamp('20261302-120000'), isNull);
      expect(parseSessionStamp('20261002-250000'), isNull);
      expect(parseSessionStamp('20261002-126100'), isNull);
    });
  });

  group('prunable', () {
    test('nothing past the window is nothing to delete', () {
      final entries = [seg(3), seg(2), seg(1)];
      expect(
        prunable(entries,
            now: now, retention: const Duration(minutes: 15), maxBytes: 2 * 1024 * oneMb),
        isEmpty,
      );
    });

    test('deletes everything past the window but keeps the newest', () {
      final entries = [seg(40), seg(30), seg(20), seg(2)];
      final doomed = prunable(entries,
          now: now, retention: const Duration(minutes: 15), maxBytes: 2 * 1024 * oneMb);
      expect(names(doomed), names([seg(40), seg(30), seg(20)]));
    });

    test('keepNewest protects the file being written', () {
      final entries = [seg(40), seg(39)];
      final doomed = prunable(entries,
          now: now, retention: const Duration(minutes: 15), maxBytes: 2 * 1024 * oneMb);
      expect(doomed.length, 1);
      expect(doomed.single.name, seg(40).name);
    });

    test('a single entry is never deleted', () {
      expect(
        prunable([seg(600)],
            now: now, retention: const Duration(minutes: 15), maxBytes: oneMb),
        isEmpty,
      );
    });

    test('the byte ceiling prunes inside the time window', () {
      final entries = [seg(5, bytes: 40 * oneMb), seg(4, bytes: 40 * oneMb), seg(1)];
      final doomed = prunable(entries,
          now: now, retention: const Duration(minutes: 15), maxBytes: 60 * oneMb);
      expect(names(doomed), [seg(5).name]);
    });

    test('the two guards combine without double counting', () {
      final entries = [
        seg(40, bytes: 40 * oneMb),
        seg(5, bytes: 40 * oneMb),
        seg(4, bytes: 40 * oneMb),
        seg(1, bytes: 40 * oneMb),
      ];
      final doomed = prunable(entries,
          now: now, retention: const Duration(minutes: 15), maxBytes: 100 * oneMb);
      expect(names(doomed), [seg(40).name, seg(5).name]);
    });

    test('unparseable names are never returned', () {
      final entries = [BufferEntry('mystery.mp4', now.subtract(const Duration(days: 9)), 900 * oneMb), seg(40), seg(1)];
      final doomed = prunable(entries,
          now: now, retention: const Duration(minutes: 15), maxBytes: 10 * oneMb);
      expect(names(doomed), isNot(contains('mystery.mp4')));
      expect(names(doomed), [seg(40).name]);
    });

    test('result is ordered oldest first', () {
      final entries = [seg(20), seg(60), seg(40), seg(1)];
      final doomed = prunable(entries,
          now: now, retention: const Duration(minutes: 15), maxBytes: 2 * 1024 * oneMb);
      expect(names(doomed), names([seg(60), seg(40), seg(20)]));
    });

    test('an empty list is handled', () {
      expect(
        prunable([], now: now, retention: const Duration(minutes: 15), maxBytes: oneMb),
        isEmpty,
      );
    });
  });
}
