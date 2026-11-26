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

/// 기기의 IANA 시간대. 테스트에서 override 한다.
final deviceTimezoneProvider = Provider<Future<String> Function()>((ref) {
  return () async => (await FlutterTimezone.getLocalTimezone()).identifier;
});

final activeSessionProvider = StreamProvider<Session?>((ref) => ref.watch(sessionRepositoryProvider).watchActiveSession());

final recentSessionsProvider =
    StreamProvider<List<SessionSummary>>((ref) => ref.watch(sessionRepositoryProvider).watchRecentSessions());

final sessionByIdProvider =
    StreamProvider.family<Session?, String>((ref, id) => ref.watch(sessionRepositoryProvider).watchSession(id));

/// id -> Exercise. 세션 화면에서 종목 이름·유형을 찾는 데 쓴다.
final exerciseMapProvider = StreamProvider<Map<String, Exercise>>((ref) {
  return ref.watch(exerciseRepositoryProvider).watchAll().map((l) => {for (final e in l) e.id: e});
});

/// 지난 세션의 같은 종목 세트(기본값·참고 표시용). key = (exerciseId, 현재 sessionId).
final lastSetsProvider = FutureProvider.family<LastSets?, ({String exerciseId, String sessionId})>((ref, k) {
  return ref.watch(sessionRepositoryProvider).lastSetsFor(k.exerciseId, excludeSessionId: k.sessionId);
});

/// 입력 검증 범위(openapi WorkoutSet).
abstract final class SetLimits {
  static bool validReps(int? v) => v == null || v >= 0;
  static bool validWeight(double? v) => v == null || v >= 0;
  static bool validRpe(double? v) => v == null || (v >= 1 && v <= 10 && (v * 2) == (v * 2).roundToDouble());
  static bool validRir(int? v) => v == null || (v >= 0 && v <= 10);
}

/// 세트 입력이 기록 유형에 맞게 채워졌는지(완료 체크 전 확인).
enum SetCheck { ok, needsReps, needsWeight }

SetCheck checkComplete(ExerciseType type, WorkoutSet s) {
  if (s.reps == null) return SetCheck.needsReps;
  final needsWeight = type == ExerciseType.BARBELL || type == ExerciseType.DUMBBELL || type == ExerciseType.MACHINE;
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

  Future<void> end(String sessionId) async {
    await _repo.endSession(sessionId);
    _ref.read(restTimerProvider.notifier).stop();
  }

  Future<void> deleteSession(String sessionId) => _repo.deleteSession(sessionId);
  Future<void> setSessionNote(String sessionId, String? note) =>
      _repo.updateSessionNote(sessionId, _blank(note));
  Future<void> addExercise(String sessionId, String exerciseId) => _repo.addExercise(sessionId, exerciseId);
  Future<void> removeExercise(String seId) => _repo.removeExercise(seId);
  Future<void> setExerciseNote(String seId, String? note) => _repo.updateExerciseNote(seId, _blank(note));
  Future<void> updateSet(WorkoutSet s) => _repo.updateSet(s);
  Future<void> deleteSet(String setId) => _repo.deleteSet(setId);

  static String? _blank(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

  /// 새 세트를 붙인다. 기본값: 이 종목의 마지막 세트 -> 지난 세션 같은 position -> 빈 값.
  Future<WorkoutSet> addSet(Session session, SessionExercise se) async {
    final WorkoutSet? base;
    if (se.sets.isNotEmpty) {
      base = se.sets.last;
    } else {
      final last = await _ref.read(sessionRepositoryProvider).lastSetsFor(se.exerciseId, excludeSessionId: session.id);
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
  Future<void> setCompleted(Session session, WorkoutSet set, bool done, {required String timerLabel}) async {
    final repo = _ref.read(sessionRepositoryProvider);
    if (!done) {
      await repo.updateSet(set.copyWith(completedAt: () => null, restSec: () => null));
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
      await repo.updateSet(prev.copyWith(restSec: () => math.min(3600, math.max(0, gap))));
    }
    await repo.updateSet(set.copyWith(completedAt: () => now));
    _ref.read(restTimerProvider.notifier).start(_ref.read(settingsProvider).defaultRestSec, label: timerLabel);
  }
}

final sessionControllerProvider = Provider<SessionController>((ref) => SessionController(ref));
