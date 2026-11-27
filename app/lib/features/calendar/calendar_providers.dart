import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/dto.dart';
import '../../data/providers.dart';
import 'calendar_logic.dart';

/// 로컬 날짜 [first, last]에 걸친 끝난 세션(날짜로 묶음). 키는 (first,last) 날짜.
final calendarRangeProvider =
    StreamProvider.autoDispose.family<Map<DateTime, List<SessionSummary>>, ({DateTime first, DateTime last})>((ref, r) {
  final range = paddedUtcRange(r.first, r.last);
  return ref
      .watch(sessionRepositoryProvider)
      .watchSessionsBetween(range.from, range.to)
      .map((l) => byLocalDay(l));
});

/// 주간 띠를 눌렀을 때 기록 탭을 달력으로 열라는 신호.
class HistoryCalendarRequest extends Notifier<bool> {
  @override
  bool build() => false;
  void request() => state = true;
  void clear() => state = false;
}

final historyCalendarRequestProvider = NotifierProvider<HistoryCalendarRequest, bool>(HistoryCalendarRequest.new);
