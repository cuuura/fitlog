import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../data/providers.dart';
import '../../domain/repositories.dart';
import '../calendar/calendar_logic.dart';
import 'scheduled_logic.dart';

/// 예정 운동을 가리키는 세션들(상태 계산 재료).
final scheduledLinksProvider = StreamProvider<List<ScheduledLink>>(
  (ref) => ref.watch(sessionRepositoryProvider).watchScheduledLinks(),
);

/// plannedDate가 [from, to](YYYY-MM-DD, 포함)인 예정.
final scheduledRangeProvider = StreamProvider.autoDispose.family<List<ScheduledWorkout>, ({String from, String to})>(
  (ref, r) => ref.watch(scheduledWorkoutRepositoryProvider).watchBetween(r.from, r.to),
);

/// 같은 범위의 예정 + 계산 상태.
final scheduledViewsProvider = Provider.autoDispose.family<List<ScheduledView>, ({String from, String to})>((ref, r) {
  final ws = ref.watch(scheduledRangeProvider(r)).value ?? const <ScheduledWorkout>[];
  final links = ref.watch(scheduledLinksProvider).value ?? const <ScheduledLink>[];
  return scheduledViews(ws, links);
});

/// 홈 카드용: 오늘 −7일 ~ 먼 미래를 읽고 걸러 쓴다(예정일이 미래인 것을 앞당겨 시작해 진행 중인 경우도 보이게).
/// 불러오는 중·실패 상태를 그대로 전달한다(홈이 로딩 표시·다시 시도를 보여 줄 수 있게).
final homeScheduledProvider = Provider.autoDispose<AsyncValue<HomeScheduled>>((ref) {
  final today = dateOnly(ref.watch(clockProvider)().toLocal());
  final range = (from: shiftDayKey(today, -7), to: shiftDayKey(today, 400));
  final ws = ref.watch(scheduledRangeProvider(range));
  final links = ref.watch(scheduledLinksProvider);
  if (ws.hasError) return AsyncError(ws.error!, ws.stackTrace ?? StackTrace.empty);
  if (links.hasError) return AsyncError(links.error!, links.stackTrace ?? StackTrace.empty);
  if (!ws.hasValue || !links.hasValue) return const AsyncLoading();
  return AsyncData(homeScheduled(scheduledViews(ws.requireValue, links.requireValue), dayKey(today)));
});

/// 목록 화면용: 오늘 −90일 ~ +365일.
final scheduledListProvider = Provider.autoDispose<List<ScheduledView>>((ref) {
  final today = dateOnly(ref.watch(clockProvider)().toLocal());
  return ref.watch(scheduledViewsProvider((from: shiftDayKey(today, -90), to: shiftDayKey(today, 365))));
});

/// 예정 한 건(수정 화면).
final scheduledByIdProvider = FutureProvider.autoDispose.family<ScheduledWorkout?, String>(
  (ref, id) => ref.watch(scheduledWorkoutRepositoryProvider).byId(id),
);
