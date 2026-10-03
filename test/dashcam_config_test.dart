import 'package:flutter_test/flutter_test.dart';
import 'package:lumet/dashcam_config.dart';

void main() {
  group('redacted', () {
    test('never returns the key itself', () {
      expect(DashcamConfig.redacted('abcd-efgh-ijkl-mnop-qrst'),
          isNot(contains('abcd-efgh-ijkl')));
    });

    test('keeps the last four characters so two keys can be told apart', () {
      expect(DashcamConfig.redacted('abcd-efgh-ijkl-mnop-qrst'), 'yt_••••qrst');
      expect(DashcamConfig.redacted('xxxx-yyyy'), 'yt_••••yyyy');
    });

    test('handles a missing or short key without throwing', () {
      expect(DashcamConfig.redacted(null), 'yt_<none>');
      expect(DashcamConfig.redacted(''), 'yt_<none>');
      expect(DashcamConfig.redacted('ab'), 'yt_••••ab');
    });
  });

  group('resolveKey', () {
    test('is null when nothing is stored and nothing was compiled in', () async {
      // Tests run without --dart-define, so this is the unconfigured path.
      expect(await DashcamConfig.resolveKey(), isNull);
    });

    test('prefers a key entered in the app', () async {
      expect(await DashcamConfig.resolveKey(stored: 'entered-key'), 'entered-key');
    });

    test('ignores a blank stored value and falls through', () async {
      expect(await DashcamConfig.resolveKey(stored: '   '), isNull);
      expect(await DashcamConfig.resolveKey(stored: ''), isNull);
    });

    test('trims surrounding whitespace from a paste', () async {
      expect(await DashcamConfig.resolveKey(stored: '  abcd-efgh \n'), 'abcd-efgh');
    });
  });

  group('resolveIngestUrl', () {
    test('falls back to the built-in address', () async {
      expect(await DashcamConfig.resolveIngestUrl(), DashcamConfig.defaultIngestUrl);
      expect(await DashcamConfig.resolveIngestUrl(stored: '   '),
          DashcamConfig.defaultIngestUrl);
    });

    test('prefers whatever the account reported', () async {
      expect(
        await DashcamConfig.resolveIngestUrl(stored: 'rtmps://b.rtmps.youtube.com/live2'),
        'rtmps://b.rtmps.youtube.com/live2',
      );
    });
  });

  group('defaults', () {
    test('ingest url carries no key and no trailing slash', () {
      expect(DashcamConfig.defaultIngestUrl, 'rtmps://a.rtmps.youtube.com/live2');
      expect(DashcamConfig.defaultIngestUrl, isNot(endsWith('/')));
    });

    test('the segment count covers the retention window with one to spare', () {
      final segments =
          (DashcamConfig.bufferMinutes * 60 / DashcamConfig.segmentSeconds).ceil();
      expect(segments, 15);
      // Worst case on disk must stay under the hard ceiling.
      final bytesPerSegment =
          (DashcamConfig.videoBitrate + DashcamConfig.audioBitrate) /
              8 *
              DashcamConfig.segmentSeconds;
      expect(bytesPerSegment * (segments + 1), lessThan(DashcamConfig.maxBufferBytes));
    });
  });
}
