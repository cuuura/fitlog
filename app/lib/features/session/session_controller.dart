// B2 소유. 세션 기록 화면이 쓰는 Provider와 컨트롤러. 저장소 호출은 여기서만 한다.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/settings/settings_controller.dart';
import '../../data/providers.dart';
import '../../domain/repositories.dart';
import '../rest_timer/rest_timer_controller.dart';
import 'current_set.dart' show restSecFor;

/// 기기의 IANA 시간대. 테스트에서 override 한다.
final deviceTimezoneProvider = Provider<Future<String> Function()>((ref) {
  return () async => (await FlutterTimezone.getLocalTimezone()).identifier;
});

final activeSessionProvider = StreamProvider<Session?>(
  (ref) => ref.watch(sessionRepositoryProvider).watchActiveSession(),
);

final recentSessionsProvider = StreamProvider<List<SessionSummary>>(
  (ref) => ref.watch(sessionRepositoryProvider).watchRecentSessions(),
);

final sessionByIdProvider = StreamProvider.family<Session?, String>(
  (ref, id) => ref.watch(sessionRepositoryProvider).watchSession(id),
);

/// id -> Exercise. 세션 화면에서 종목 이름·유형을 찾는 데 쓴다.
final exerciseMapProvider = StreamProvider<Map<String, Exercise>>((ref) {
  return ref
      .watch(exerciseRepositoryProvider)
      .watchAll()
      .map((l) => {for (final e in l) e.id: e});
});

/// 지난 세션의 같은 종목 세트(기본값·참고 표시용). key = (exerciseId, 현재 sessionId).
final lastSetsProvider =
    FutureProvider.family<LastSets?, ({String exerciseId, String sessionId})>((
      ref,
      k,
    ) {
      return ref
          .watch(sessionRepositoryProvider)
          .lastSetsFor(k.exerciseId, excludeSessionId: k.sessionId);
    });

/// 활성 인스턴스와 다음 회차(계획 캐시 기준). 홈 "오늘 할 운동".
final planItemsProvider = StreamProvider<List<InstancePlan>>(
  (ref) => ref.watch(planCacheProvider).watchActive(),
);

/// 같은 인스턴스·같은 dayKey로 끝난 가장 최근 세션(지난 같은 세션 비교).
final lastDaySessionProvider =
    FutureProvider.family<
      Session?,
      ({String instanceId, String dayKey, String sessionId})
    >(
      (ref, k) => ref
          .watch(sessionRepositoryProvider)
          .lastSessionForDay(
            k.instanceId,
            k.dayKey,
            excludeSessionId: k.sessionId,
          ),
    );

/// 시작한 회차의 표시 이름(프로그램·dayName·주차). 앱을 다시 켜면 사라지고 화면이 캐시·dayKey로 대신한다.
class PlanLabel {
  final String programName;
  final String dayName;
  final int week;
  const PlanLabel({
    required this.programName,
    required this.dayName,
    required this.week,
  });
}

final planLabelsProvider = Provider<Map<String, PlanLabel>>((ref) => {});

/// 입력 검증 범위(openapi WorkoutSet).
abstract final class SetLimits {
  static bool validReps(int? v) => v == null || v >= 0;
  static bool validWeight(double? v) => v == null || v >= 0;
  static bool validRpe(double? v) =>
      v == null || (v >= 1 && v <= 10 && (v * 2) == (v * 2).roundToDouble());
  static bool validRir(int? v) => v == null || (v >= 0 && v <= 10);
}

/// 세트 입력이 기록 유형에 맞게 채워졌는지(완료 체크 전 확인).
enum SetCheck { ok, needsReps, needsWeight }

SetCheck checkComplete(ExerciseType type, WorkoutSet s) {
  if (s.reps == null) return SetCheck.needsReps;
  final needsWeight =
      type == ExerciseType.BARBELL ||
      type == ExerciseType.DUMBBELL ||
      type == ExerciseType.MACHINE;
  if (needsWeight && s.weightKg == null) return SetCheck.needsWeight;
  return SetCheck.ok;
}

class SessionController {
  SessionController(this._ref);
  final Ref _ref;

  SessionRepository get _repo => _ref.read(sessionRepositoryProvider);

  DateTime _now() => _ref.read(clockProvider)();

  /// 진행 중 세션이 있으면 그것을, 없으면 새로 시작한다.
  Future<Session> start() async {
    final tz = await _ref.read(deviceTimezoneProvider)();
    return _repo.startSession(tz: tz);
  }

  /// 프로그램 회차 세션 시작(PRG-5): 계획을 받아 세션을 만든다. 무게 없는 계획 세트는 지난 기록으로 채운다.
  Future<Session> startProgram(String instanceId, {String? programName}) async {
    final tz = await _ref.read(deviceTimezoneProvider)();
    final plan = await _ref.read(planCacheProvider).nextPlan(instanceId);
    if (plan == null) throw StateError('no plan for $instanceId');
    final session = await _repo.startSession(tz: tz, plan: plan);
    if (session.programInstanceId == instanceId &&
        session.planSeq == plan.planSeq) {
      _ref.read(planLabelsProvider)[session.id] = PlanLabel(
        programName: programName ?? '',
        dayName: plan.dayName,
        week: plan.week,
      );
      await _fillMissingWeights(session);
    }
    return session;
  }

  /// 예정 운동 시작(scheduled-workout.md §5). 로컬에서 세션을 만든다(오프라인 가능).
  /// 진행 중 세션이 있으면 저장소가 그것을 돌려준다(호출 쪽이 먼저 걸러야 한다, start_scheduled_flow.dart).
  /// 목표 무게가 없는 세트는 프로그램 시작과 같이 지난 기록으로 채운다.
  Future<Session> startScheduled(ScheduledWorkout w) async {
    final tz = await _ref.read(deviceTimezoneProvider)();
    final session = await _repo.startSession(tz: tz, scheduled: w);
    if (session.scheduledWorkoutId == w.id) await _fillMissingWeights(session);
    return session;
  }

  Future<void> _fillMissingWeights(Session session) async {
    final exercises = await _ref
        .read(exerciseRepositoryProvider)
        .watchAll()
        .first;
    final byId = {for (final e in exercises) e.id: e};
    for (final se in session.exercises) {
      final type = byId[se.exerciseId]?.type ?? ExerciseType.BARBELL;
      final needs = [
        for (final s in se.sets)
          if ((s.isPlanned || session.scheduledWorkoutId != null) &&
              s.targetWeightKg == null &&
              s.weightKg == null &&
              s.addedWeightKg == null)
            s,
      ];
      if (needs.isEmpty) continue;
      final last = await _repo.lastSetsFor(
        se.exerciseId,
        excludeSessionId: session.id,
      );
      final prev = last?.sets.where((w) => !w.isWarmup).toList();
      if (prev == null || prev.isEmpty) continue;
      for (var i = 0; i < needs.length; i++) {
        final p = i < prev.length ? prev[i] : prev.last;
        final s = needs[i];
        await _repo.updateSet(
          type == ExerciseType.BODYWEIGHT
              ? s.copyWith(addedWeightKg: () => p.addedWeightKg)
              : s.copyWith(weightKg: () => p.weightKg),
        );
      }
    }
  }

  Future<void> reorderExercises(String sessionId, List<String> ids) =>
      _repo.reorderExercises(sessionId, ids);
  Future<void> reorderSets(String seId, List<String> ids) =>
      _repo.reorderSets(seId, ids);

  Future<void> end(String sessionId) async {
    await _repo.endSession(sessionId);
    _ref.read(restTimerProvider.notifier).stop();
  }

  Future<void> deleteSession(String sessionId) =>
      _repo.deleteSession(sessionId);
  Future<void> setSessionNote(String sessionId, String? note) =>
      _repo.updateSessionNote(sessionId, _blank(note));

  /// 종목을 붙인다. [firstSet]이면(자유 세션) 첫 세트도 바로 붙여 줄이 즉시 보이게 한다.
  Future<SessionExercise> addExercise(
    String sessionId,
    String exerciseId, {
    bool accessory = false,
    bool firstSet = false,
  }) async {
    final se = await _repo.addExercise(
      sessionId,
      exerciseId,
      accessory: accessory,
    );
    if (firstSet) await _addSetTo(sessionId, se);
    return se;
  }

  Future<void> removeExercise(String seId) => _repo.removeExercise(seId);
  Future<void> setExerciseNote(String seId, String? note) =>
      _repo.updateExerciseNote(seId, _blank(note));
  Future<void> updateSet(WorkoutSet s) => _repo.updateSet(s);
  Future<void> deleteSet(String setId) => _repo.deleteSet(setId);

  static String? _blank(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  /// 새 세트를 붙인다. 기본값: 이 종목의 마지막 세트 -> 지난 세션 같은 position -> 빈 값.
  Future<WorkoutSet> addSet(Session session, SessionExercise se) =>
      _addSetTo(session.id, se);

  Future<WorkoutSet> _addSetTo(String sessionId, SessionExercise se) async {
    final WorkoutSet? base;
    if (se.sets.isNotEmpty) {
      base = se.sets.last;
    } else {
      final last = await _ref
          .read(sessionRepositoryProvider)
          .lastSetsFor(se.exerciseId, excludeSessionId: sessionId);
      final prev = last?.sets;
      if (prev == null || prev.isEmpty) {
        base = null;
      } else {
        base = se.sets.length < prev.length ? prev[se.sets.length] : prev.last;
      }
    }
    final draft = WorkoutSet(
      id: newId(),
      position: se.sets.length,
      weightKg: base?.weightKg,
      addedWeightKg: base?.addedWeightKg,
      reps: base?.reps,
    );
    return await _ref.read(sessionRepositoryProvider).addSet(se.id, draft);
  }

  /// 세트 완료/해제. 완료하면 직전 완료 세트의 restSec을 채우고 휴식 타이머를 시작한다.
  Future<void> setCompleted(
    Session session,
    WorkoutSet set,
    bool done, {
    required String timerLabel,
    String? nextText,
  }) async {
    final repo = _ref.read(sessionRepositoryProvider);
    if (!done) {
      await repo.updateSet(
        set.copyWith(completedAt: () => null, restSec: () => null),
      );
      return;
    }
    final now = _now();
    WorkoutSet? prev;
    for (final e in session.exercises) {
      for (final w in e.sets) {
        if (w.id == set.id || w.completedAt == null) continue;
        if (prev == null || w.completedAt!.isAfter(prev.completedAt!)) prev = w;
      }
    }
    if (prev != null && prev.restSec == null) {
      final gap = now.difference(prev.completedAt!).inSeconds;
      await repo.updateSet(
        prev.copyWith(restSec: () => math.min(3600, math.max(0, gap))),
      );
    }
    await repo.updateSet(set.copyWith(completedAt: () => now));
    _ref
        .read(restTimerProvider.notifier)
        .start(
          restSecFor(set, _ref.read(settingsProvider).defaultRestSec),
          label: timerLabel,
          body: nextText,
        );
  }
}

final sessionControllerProvider = Provider<SessionController>(
  (ref) => SessionController(ref),
);
