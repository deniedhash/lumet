/// One file in the rolling buffer, as the pruner sees it.
///
/// Deliberately not a `File`: the rule is pure so it can be tested without
/// touching a filesystem.
class BufferEntry {
  const BufferEntry(this.name, this.recordedAt, this.bytes);

  final String name;
  final DateTime recordedAt;
  final int bytes;
}

/// Session stamps are UTC, which is what keeps this DST-proof.
///
/// Accepts `yyyyMMdd-HHmmss` anywhere in [name], so both `20261002-140511.jsonl`
/// and `lumet_20261002-140511-0007.mp4` parse. Returns null when it does not
/// look like a stamp at all.
DateTime? parseSessionStamp(String name) {
  final match = RegExp(r'(\d{8})-(\d{6})').firstMatch(name);
  if (match == null) return null;
  final date = match.group(1)!;
  final time = match.group(2)!;
  final year = int.parse(date.substring(0, 4));
  final month = int.parse(date.substring(4, 6));
  final day = int.parse(date.substring(6, 8));
  final hour = int.parse(time.substring(0, 2));
  final minute = int.parse(time.substring(2, 4));
  final second = int.parse(time.substring(4, 6));
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  final parsed = DateTime.utc(year, month, day, hour, minute, second);
  // DateTime.utc rolls overflow forward (Feb 31 becomes Mar 3), so reject
  // anything that did not survive the round trip.
  if (parsed.month != month || parsed.day != day) return null;
  return parsed;
}

/// Which entries to delete, oldest first, to honour both the time window and the
/// byte ceiling.
///
/// [keepNewest] protects the file currently being written. An entry whose name
/// does not parse is never returned: an unrecognised name means the caller does
/// not understand it, and deleting what you do not understand is how a pruner
/// eats someone's footage.
List<BufferEntry> prunable(
  List<BufferEntry> entries, {
  required DateTime now,
  required Duration retention,
  required int maxBytes,
  int keepNewest = 1,
}) {
  final known = entries.where((e) => parseSessionStamp(e.name) != null).toList()
    ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  if (known.length <= keepNewest) return const [];

  // Never a candidate, however old or large.
  final candidates = known.sublist(0, known.length - keepNewest);
  final doomed = <BufferEntry>[];

  for (final entry in candidates) {
    if (now.difference(entry.recordedAt) > retention) doomed.add(entry);
  }

  var total = known.fold<int>(0, (sum, e) => sum + e.bytes) -
      doomed.fold<int>(0, (sum, e) => sum + e.bytes);
  for (final entry in candidates) {
    if (total <= maxBytes) break;
    if (doomed.contains(entry)) continue;
    doomed.add(entry);
    total -= entry.bytes;
  }

  doomed.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  return doomed;
}
