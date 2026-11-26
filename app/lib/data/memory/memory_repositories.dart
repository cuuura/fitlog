// 메모리 구현. 위젯 테스트와, 로컬 DB가 붙기 전 화면 개발용. 트랙 리드 소유.
import 'dart:async';

import '../../core/api/dto.dart';
import '../../core/ids.dart';
import '../../domain/repositories.dart';

class _Bus<T> {
  final _c = StreamController<void>.broadcast();
  Stream<T> watch(T Function() read) async* {
    yield read();
    yield* _c.stream.map((_) => read());
  }

  void emit() => _c.add(null);
}

class MemoryExerciseRepository implements ExerciseRepository {
  final Map<String, Exercise> _items = {};
  final _bus = _Bus<List<Exercise>>();
  final DateTime Function() now;

  MemoryExerciseRepository({List<Exercise> seed = const [], DateTime Function()? now})
      : now = now ?? (() => DateTime.now().toUtc()) {
    for (final e in seed) {
      _items[e.id] = e;
    }
  }

  List<Exercise> _sorted() => _items.values.toList()..sort((a, b) => a.nameKo.compareTo(b.nameKo));

  @override
  Stream<List<Exercise>> watchAll() => _bus.watch(_sorted);

  @override
  Future<List<Exercise>> search({String? query, Muscle? muscle, ExerciseType? type}) async {
    final q = query?.trim().toLowerCase();
    return _sorted().where((e) {
      if (muscle != null && e.primaryMuscle != muscle && !e.secondaryMuscles.contains(muscle)) return false;
      if (type != null && e.type != type) return false;
      if (q != null && q.isNotEmpty) {
        return e.nameKo.toLowerCase().contains(q) || (e.nameEn?.toLowerCase().contains(q) ?? false);
      }
      return true;
    }).toList();
  }

  @override
  Future<Exercise?> byId(String id) async => _items[id];

  Exercise _fromInput(ExerciseInput i) => Exercise(
        id: i.id,
        nameKo: i.nameKo,
        nameEn: i.nameEn,
        type: i.type,
        primaryMuscle: i.primaryMuscle,
        secondaryMuscles: i.secondaryMuscles,
        builtIn: false,
        updatedAt: now(),
      );

  @override
  Future<Exercise> createCustom(ExerciseInput input) async {
    final e = _fromInput(input);
    _items[e.id] = e;
    _bus.emit();
    return e;
  }

  @override
  Future<Exercise> updateCustom(ExerciseInput input) async {
    final old = _items[input.id];
    if (old == null || old.builtIn) throw StateError('not a custom exercise: ${input.id}');
    return createCustom(input);
  }

  @override
  Future<void> deleteCustom(String id) async {
    if (_items[id]?.builtIn ?? true) throw StateError('not a custom exercise: $id');
    _items.remove(id);
    _bus.emit();
  }

  @override
  Future<void> refreshFromServer() async {}
}

class MemorySessionRepository implements SessionRepository {
  final Map<String, Session> _sessions = {};
  final _bus = _Bus<Object?>();
  final DateTime Function() now;
  MemorySessionRepository({DateTime Function()? now}) : now = now ?? (() => DateTime.now().toUtc());

  Session? _active() => _sessions.values.where((s) => s.isActive).firstOrNull;

  ({Session session, int exIndex})? _findSe(String seId) {
    for (final s in _sessions.values) {
      final i = s.exercises.indexWhere((e) => e.id == seId);
      if (i >= 0) return (session: s, exIndex: i);
    }
    return null;
  }

  Session _copy(Session s, {DateTime? Function()? endedAt, String? Function()? note, List<SessionExercise>? exercises}) =>
      Session(
        id: s.id,
        startedAt: s.startedAt,
        endedAt: endedAt != null ? endedAt() : s.endedAt,
        tz: s.tz,
        note: note != null ? note() : s.note,
        source: s.source,
        exercises: exercises ?? s.exercises,
        updatedAt: now(),
      );

  SessionExercise _copySe(SessionExercise e, {String? Function()? note, List<WorkoutSet>? sets}) => SessionExercise(
        id: e.id,
        exerciseId: e.exerciseId,
        position: e.position,
        note: note != null ? note() : e.note,
        sets: sets ?? e.sets,
      );

  void _put(Session s) {
    _sessions[s.id] = s;
    _bus.emit();
  }

  @override
  Stream<Session?> watchActiveSession() => _bus.watch(_active).cast<Session?>();

  @override
  Stream<Session?> watchSession(String id) => _bus.watch(() => _sessions[id]).cast<Session?>();

  @override
  Stream<List<SessionSummary>> watchRecentSessions({int limit = 20}) => _bus.watch(() {
        final list = _sessions.values.toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));
        return list.take(limit).map(summarize).toList();
      }).cast<List<SessionSummary>>();

  /// SessionSummary 계산 규칙(openapi): setCount·totalVolumeKg는 워밍업 제외, 완료 여부와 무관하게 값이 있는 세트.
  static SessionSummary summarize(Session s) {
    var sets = 0;
    var volume = 0.0;
    for (final e in s.exercises) {
      for (final w in e.sets.where((w) => !w.isWarmup)) {
        sets++;
        volume += (w.weightKg ?? 0) * (w.reps ?? 0);
      }
    }
    return SessionSummary(
      id: s.id,
      startedAt: s.startedAt,
      endedAt: s.endedAt,
      tz: s.tz,
      exerciseCount: s.exercises.length,
      setCount: sets,
      totalVolumeKg: volume,
    );
  }

  @override
  Future<Session> startSession({required String tz}) async {
    final a = _active();
    if (a != null) return a;
    final s = Session(
        id: newId(),
        startedAt: now(),
        tz: tz,
        source: SessionSource.APP,
        updatedAt: now());
    _put(s);
    return s;
  }

  @override
  Future<void> endSession(String sessionId) async => _put(_copy(_sessions[sessionId]!, endedAt: () => now()));

  @override
  Future<void> updateSessionNote(String sessionId, String? note) async =>
      _put(_copy(_sessions[sessionId]!, note: () => note));

  @override
  Future<void> deleteSession(String sessionId) async {
    _sessions.remove(sessionId);
    _bus.emit();
  }

  @override
  Future<SessionExercise> addExercise(String sessionId, String exerciseId) async {
    final s = _sessions[sessionId]!;
    final pos = s.exercises.isEmpty ? 0 : s.exercises.map((e) => e.position).reduce((a, b) => a > b ? a : b) + 1;
    final se = SessionExercise(id: newId(), exerciseId: exerciseId, position: pos);
    _put(_copy(s, exercises: [...s.exercises, se]));
    return se;
  }

  @override
  Future<void> removeExercise(String sessionExerciseId) async {
    final f = _findSe(sessionExerciseId)!;
    _put(_copy(f.session, exercises: [...f.session.exercises]..removeAt(f.exIndex)));
  }

  @override
  Future<void> updateExerciseNote(String sessionExerciseId, String? note) async {
    final f = _findSe(sessionExerciseId)!;
    final list = [...f.session.exercises];
    list[f.exIndex] = _copySe(list[f.exIndex], note: () => note);
    _put(_copy(f.session, exercises: list));
  }

  @override
  Future<WorkoutSet> addSet(String sessionExerciseId, WorkoutSet draft) async {
    final f = _findSe(sessionExerciseId)!;
    final se = f.session.exercises[f.exIndex];
    final pos = se.sets.isEmpty ? 0 : se.sets.map((e) => e.position).reduce((a, b) => a > b ? a : b) + 1;
    final set = draft.copyWith(position: pos);
    final list = [...f.session.exercises];
    list[f.exIndex] = _copySe(se, sets: [...se.sets, set]);
    _put(_copy(f.session, exercises: list));
    return set;
  }

  void _editSet(String setId, List<WorkoutSet> Function(List<WorkoutSet> sets, int i) edit) {
    for (final s in _sessions.values) {
      for (var ei = 0; ei < s.exercises.length; ei++) {
        final se = s.exercises[ei];
        final i = se.sets.indexWhere((w) => w.id == setId);
        if (i >= 0) {
          final list = [...s.exercises];
          list[ei] = _copySe(se, sets: edit([...se.sets], i));
          _put(_copy(s, exercises: list));
          return;
        }
      }
    }
    throw StateError('set not found: $setId');
  }

  @override
  Future<void> updateSet(WorkoutSet set) async => _editSet(set.id, (sets, i) => sets..[i] = set);

  @override
  Future<void> deleteSet(String setId) async => _editSet(setId, (sets, i) => sets..removeAt(i));

  @override
  Future<LastSets?> lastSetsFor(String exerciseId, {String? excludeSessionId}) async {
    final list = _sessions.values.where((s) => !s.isActive && s.id != excludeSessionId).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    for (final s in list) {
      final se = s.exercises.where((e) => e.exerciseId == exerciseId).firstOrNull;
      if (se != null && se.sets.isNotEmpty) return LastSets(sessionId: s.id, startedAt: s.startedAt, sets: se.sets);
    }
    return null;
  }
}

class MemoryBodyRepository implements BodyRepository {
  final Map<String, BodyMeasurement> _items = {};
  final _bus = _Bus<List<BodyMeasurement>>();

  @override
  Stream<List<BodyMeasurement>> watchMeasurements() =>
      _bus.watch(() => _items.values.toList()..sort((a, b) => b.measuredAt.compareTo(a.measuredAt)));

  @override
  Future<void> add(BodyMeasurement m) async {
    _items[m.id] = m;
    _bus.emit();
  }

  @override
  Future<void> delete(String id) async {
    _items.remove(id);
    _bus.emit();
  }
}

class NoopSyncService implements SyncService {
  @override
  Stream<SyncStatus> watchStatus() => Stream.value(const SyncStatus());
  @override
  Future<void> syncNow() async {}
  @override
  void schedule({Duration delay = const Duration(seconds: 5)}) {}
}

class NoopLocalDataStore implements LocalDataStore {
  @override
  Future<void> clearAll() async {}
}
