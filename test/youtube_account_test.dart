import 'package:flutter_test/flutter_test.dart';
import 'package:lumet/youtube_account.dart';

void main() {
  String body(String items) => '{"items":[$items]}';

  const completed = '''
    {"id":"abc123",
     "snippet":{"title":"Drive home","publishedAt":"2026-10-02T13:50:00Z",
                "actualStartTime":"2026-10-02T14:00:00Z",
                "actualEndTime":"2026-10-02T14:42:30Z",
                "thumbnails":{"medium":{"url":"https://i.ytimg.com/vi/abc123/mq.jpg"}}},
     "status":{"privacyStatus":"unlisted","lifeCycleStatus":"complete"}}
  ''';

  group('parseDrives', () {
    test('reads a completed broadcast', () {
      final drives = YouTubeAccount.parseDrives(body(completed));
      expect(drives.length, 1);
      final drive = drives.single;
      expect(drive.videoId, 'abc123');
      expect(drive.title, 'Drive home');
      expect(drive.privacy, 'unlisted');
      expect(drive.live, isFalse);
      expect(drive.duration, const Duration(minutes: 42, seconds: 30));
      expect(drive.thumbnailUrl, contains('abc123'));
      expect(drive.url, 'https://www.youtube.com/watch?v=abc123');
    });

    test('marks a live broadcast', () {
      final drives = YouTubeAccount.parseDrives(body('''
        {"id":"live1","snippet":{"title":"Now"},
         "status":{"lifeCycleStatus":"live","privacyStatus":"unlisted"}}
      '''));
      expect(drives.single.live, isTrue);
      expect(drives.single.duration, isNull);
    });

    test('falls back to publishedAt when there is no actual start', () {
      final drives = YouTubeAccount.parseDrives(body('''
        {"id":"x","snippet":{"title":"t","publishedAt":"2026-10-02T13:50:00Z"},
         "status":{}}
      '''));
      expect(drives.single.startedAt, isNotNull);
    });

    test('names an untitled broadcast rather than showing an empty row', () {
      final drives = YouTubeAccount.parseDrives(body(
          '{"id":"x","snippet":{"title":"  "},"status":{}}'));
      expect(drives.single.title, 'Untitled drive');
    });

    test('skips an item with no id instead of throwing', () {
      final drives = YouTubeAccount.parseDrives(body(
          '{"snippet":{"title":"orphan"}}, {"id":"keep","snippet":{}}'));
      expect(drives.map((d) => d.videoId), ['keep']);
    });

    test('survives missing sections, bad json and wrong shapes', () {
      expect(YouTubeAccount.parseDrives('{"items":[]}'), isEmpty);
      expect(YouTubeAccount.parseDrives('{}'), isEmpty);
      expect(YouTubeAccount.parseDrives('not json'), isEmpty);
      expect(YouTubeAccount.parseDrives('[]'), isEmpty);
      expect(YouTubeAccount.parseDrives('{"items":"nope"}'), isEmpty);
      expect(
        YouTubeAccount.parseDrives(body('{"id":"x"}')).single.title,
        'Untitled drive',
      );
    });

    test('surfaces a privacy status that is not unlisted', () {
      final drives = YouTubeAccount.parseDrives(body(
          '{"id":"x","snippet":{"title":"t"},"status":{"privacyStatus":"public"}}'));
      expect(drives.single.privacy, 'public');
    });
  });

  group('byRecency', () {
    YouTubeDrive drive(String id, {DateTime? at, bool live = false}) =>
        YouTubeDrive(videoId: id, title: id, startedAt: at, live: live);

    test('live sorts above everything, then newest first', () {
      final list = [
        drive('old', at: DateTime.utc(2026, 10, 1)),
        drive('new', at: DateTime.utc(2026, 10, 3)),
        drive('now', at: DateTime.utc(2025, 1, 1), live: true),
      ]..sort(YouTubeDrive.byRecency);
      expect(list.map((d) => d.videoId), ['now', 'new', 'old']);
    });
  });
}
