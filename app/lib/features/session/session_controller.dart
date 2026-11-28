// B2 소유. 세션 기록 화면이 쓰는 Provider와 컨트롤러. 저장소 호출은 여기서만 한다.
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:material_ui/material_ui.dart' show ScaffoldMessengerState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/ui/undo.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../data/providers.dart';
import '../../domain/repositories.dart';
import '../rest_timer/rest_timer_controller.dart';
import 'current_set.dart' show currentSetOf, restSecFor;
import 'superset.dart';
import 'previous_match.dart';

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
    ) async {
      try {
        return await ref
            .watch(sessionRepositoryProvider)
            .lastSetsFor(k.exerciseId, excludeSessionId: k.sessionId);
      } catch (e, st) {
        debugPrint('lastSetsProvider failed: $e\n$st');
        rethrow; // 호출부는 오류를 "이전 기록 없음"으로 취급한다.
      }
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
    >((ref, k) async {
      try {
        return await ref
            .watch(sessionRepositoryProvider)
            .lastSessionForDay(
              k.instanceId,
              k.dayKey,
              excludeSessionId: k.sessionId,
            );
      } catch (e, st) {
        debugPrint('lastDaySessionProvider failed: $e\n$st');
        rethrow; // 호출부는 오류를 "이전 기록 없음"으로 취급한다.
      }
    });

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

/// 세션 시작 때의 프로그램 본운동 순서(정의 인덱스). 순서 기억(8.2)이 끝낼 때 비교한다. 앱을 다시 켜면 사라진다.
final planOrdersProvider = Provider<Map<String, List<int>>>((ref) => {});

/// 종목의 정의 인덱스: 계획 세트 키 `dayKey.exIndex.setIndex`의 가운데. 계획 세트가 없으면 null.
int? definitionIndexOf(SessionExercise se) {
  for (final w in se.sets) {
    final k = w.plannedSetKey;
    if (k == null) continue;
    final parts = k.split('.');
    if (parts.length >= 3) {
      final i = int.tryParse(parts[parts.length - 2]);
      if (i != null) return i;
    }
  }
  return null;
}

int? _planDefIndex(PlannedExercise e) {
  final p = e.sets.firstOrNull?.plannedSetKey.split('.');
  return p == null || p.length < 3 ? null : int.tryParse(p[p.length - 2]);
}

/// 프로그램 본운동(보조 제외, 정의 인덱스가 있는) 종목들을 세션 순서대로.
List<({SessionExercise se, int index})> programMainExercises(Session session) {
  final sorted = [...session.exercises]..sort((a, b) => a.position.compareTo(b.position));
  return [
    for (final e in sorted)
      if (e.liftKey != null && !e.accessory && !e.liftKey!.startsWith('acc:'))
        if (definitionIndexOf(e) case final i?) (se: e, index: i),
  ];
}

/// 순서 기억으로 저장한 결과(되돌리기용 이전 순서).
class DayOrderSaved {
  const DayOrderSaved({required this.instanceId, required this.dayKey, required this.previous});
  final String instanceId;
  final String dayKey;
  final List<int> previous;
}

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
      _ref.read(planOrdersProvider)[session.id] = [
        for (final e in plan.exercises)
          if (!e.accessory && !e.key.startsWith('acc:'))
            ?_planDefIndex(e),
      ];
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

  /// 세트 종류 바꾸기(일반·드롭·실패).
  Future<void> setSetType(WorkoutSet s, SetType type) => _repo.updateSet(s.copyWith(setType: type));

  /// [se]를 바로 다음 종목과 슈퍼세트로 묶는다. 다음 종목이 없으면 아무것도 하지 않는다.
  Future<void> bindSupersetWithNext(Session session, SessionExercise se) async {
    final i = session.exercises.indexWhere((e) => e.id == se.id);
    if (i < 0 || i + 1 >= session.exercises.length) return;
    final changes = bindWithNext(session, se, session.exercises[i + 1]);
    for (final e in changes.entries) {
      await _repo.setExerciseSuperset(e.key, e.value);
    }
  }

  /// [se]를 묶음에서 푼다(남은 한 종목도 같이 풀린다).
  Future<void> unbindSuperset(Session session, SessionExercise se) async {
    for (final id in unbindIds(session, se)) {
      await _repo.setExerciseSuperset(id, null);
    }
  }

  /// 종목 바꾸기 "이번만": 이 세션 종목의 exerciseId만 바꾼다(liftKey·기록 유지).
  Future<void> swapThisTime(String seId, String exerciseId) => _repo.swapExercise(seId, exerciseId);

  /// 프로그램 종목인지(앞으로 계속 바꾸기를 고를 수 있는지): 세션이 인스턴스에 묶였고 본 종목 키가 있다.
  bool canSwapPersistently(Session session, SessionExercise se) =>
      session.programInstanceId != null &&
      se.liftKey != null &&
      !se.accessory &&
      !se.liftKey!.startsWith('acc:');

  /// 종목 바꾸기 "앞으로 계속": 서버 프로그램의 종목을 바꾼 뒤(온라인 필요, 실패하면 던진다) 이 세션도 바꾼다.
  Future<void> swapPersistent(Session session, SessionExercise se, String exerciseId) async {
    await _ref.read(programRepositoryProvider).swapLift(session.programInstanceId!, se.liftKey!, exerciseId);
    await _repo.swapExercise(se.id, exerciseId);
    try {
      await _ref.read(planCacheProvider).refresh(instanceId: session.programInstanceId);
    } catch (_) {}
  }

  /// 순서 기억(8.2): 끝낸 프로그램 세션의 본운동 순서가 시작 때와 다르면 day-order를 저장한다.
  /// 바뀐 게 없거나 실패하면 null(조용히 넘어간다).
  Future<DayOrderSaved?> saveDayOrderOnFinish(Session session) async {
    final instanceId = session.programInstanceId;
    final dayKey = session.planDayKey;
    if (instanceId == null || dayKey == null) return null;
    try {
      final actual = [for (final m in programMainExercises(session)) m.index];
      if (actual.length < 2) return null;
      final programs = _ref.read(programRepositoryProvider);
      final inst = await programs.getInstance(instanceId);
      final n = _dayExerciseCount(
        (await programs.getProgram(inst.programId)).definition,
        dayKey,
      );
      if (n == null) return null;
      final base = inst.dayOrder[dayKey] ?? [for (var i = 0; i < n; i++) i];
      if (base.length != n) return null;
      final planned = _ref.read(planOrdersProvider)[session.id] ?? base;
      final present = actual.toSet();
      if (_sameList([for (final i in planned) if (present.contains(i)) i], actual)) return null;
      // 계획에 있던 자리에 실제 순서를 차례로 채운다. 이번 계획에 없던 인덱스는 제자리.
      final queue = [...actual];
      final order = [for (final i in base) present.contains(i) ? queue.removeAt(0) : i];
      await programs.putDayOrder(instanceId, dayKey, order);
      return DayOrderSaved(instanceId: instanceId, dayKey: dayKey, previous: base);
    } catch (e) {
      debugPrint('saveDayOrderOnFinish ignored: $e');
      return null;
    }
  }

  /// 순서 기억 되돌리기: 이전 순서로 다시 저장한다.
  Future<void> undoDayOrder(DayOrderSaved saved) =>
      _ref.read(programRepositoryProvider).putDayOrder(saved.instanceId, saved.dayKey, saved.previous);

  static bool _sameList(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int? _dayExerciseCount(Map<String, Object?> def, String dayKey) {
    for (final d in (def['days'] as List? ?? const [])) {
      final m = (d as Map).cast<String, Object?>();
      if (m['key'] == dayKey) return (m['exercises'] as List?)?.length;
    }
    return null;
  }
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
        base = previousForNewSet(se.sets, prev);
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
    // 휴식 규칙(5절): 다음 세트가 DROP이거나 슈퍼세트 한 바퀴 중간이면 타이머를 띄우지 않는다.
    final owner = session.exercises.where((e) => e.sets.any((w) => w.id == set.id)).firstOrNull;
    if (owner != null && skipRestAfter(session, owner, set, currentSetOf(session, excluding: set.id))) return;
    _ref
        .read(restTimerProvider.notifier)
        .start(
          restSecFor(set, _ref.read(settingsProvider).defaultRestSec),
          label: timerLabel,
          body: nextText,
        );
  }
}

/// 지운 세트를 같은 값(무게·횟수·완료·RPE·목표 등 전부)으로 [index] 자리에 다시 넣는다.
/// 동기화 삭제 표시와 부딪히지 않게 새 id로 넣고, 순서만 원래 자리로 맞춘다.
Future<void> restoreSetAt(
  SessionRepository repo, {
  required String sessionId,
  required String sessionExerciseId,
  required WorkoutSet old,
  required int index,
}) async {
  final added = await repo.addSet(
    sessionExerciseId,
    WorkoutSet(
      id: newId(),
      position: old.position,
      isWarmup: old.isWarmup,
      weightKg: old.weightKg,
      addedWeightKg: old.addedWeightKg,
      reps: old.reps,
      durationSec: old.durationSec,
      distanceM: old.distanceM,
      bandLevel: old.bandLevel,
      rpe: old.rpe,
      rir: old.rir,
      restSec: old.restSec,
      note: old.note,
      completedAt: old.completedAt,
      plannedSetKey: old.plannedSetKey,
      targetReps: old.targetReps,
      targetWeightKg: old.targetWeightKg,
      isAmrap: old.isAmrap,
      targetRepsMax: old.targetRepsMax,
      targetRir: old.targetRir,
      targetRestSec: old.targetRestSec,
      setType: old.setType,
    ),
  );
  final session = await repo.watchSession(sessionId).first;
  final se = session?.exercises.where((e) => e.id == sessionExerciseId).firstOrNull;
  if (se == null) return;
  final ids = [for (final w in se.sets) if (w.id != added.id) w.id];
  ids.insert(index.clamp(0, ids.length), added.id);
  await repo.reorderSets(sessionExerciseId, ids);
}

/// 세트를 확인 없이 지우고 "되돌리기"를 보여 준다(운동 중·세션 수정 화면 공통).
Future<void> deleteSetWithUndo(
  SessionRepository repo,
  ScaffoldMessengerState messenger,
  AppLocalizations l, {
  required String sessionId,
  required SessionExercise se,
  required WorkoutSet set,
}) async {
  final index = se.sets.indexWhere((w) => w.id == set.id);
  await repo.deleteSet(set.id);
  showUndoSnack(
    messenger,
    l,
    message: l.sessionSetDeleted,
    onUndo: () => restoreSetAt(
      repo,
      sessionId: sessionId,
      sessionExerciseId: se.id,
      old: set,
      index: index < 0 ? se.sets.length : index,
    ),
  );
}

final sessionControllerProvider = Provider<SessionController>(
  (ref) => SessionController(ref),
);
