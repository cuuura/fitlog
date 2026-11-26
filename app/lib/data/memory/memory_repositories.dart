// 메모리 구현. 위젯 테스트와, 로컬 DB가 붙기 전 화면 개발용. 트랙 리드 소유.
import 'dart:async';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
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

  Session _copy(
    Session s, {
    DateTime? startedAt,
    DateTime? Function()? endedAt,
    String? Function()? note,
    List<SessionExercise>? exercises,
  }) => Session(
    id: s.id,
    startedAt: startedAt ?? s.startedAt,
    endedAt: endedAt != null ? endedAt() : s.endedAt,
    tz: s.tz,
    note: note != null ? note() : s.note,
    source: s.source,
    exercises: exercises ?? s.exercises,
    updatedAt: now(),
    programInstanceId: s.programInstanceId,
    planSeq: s.planSeq,
    planDayKey: s.planDayKey,
  );

  SessionExercise _copySe(SessionExercise e, {int? position, String? Function()? note, List<WorkoutSet>? sets}) =>
      SessionExercise(
        id: e.id,
        exerciseId: e.exerciseId,
        position: position ?? e.position,
        note: note != null ? note() : e.note,
        sets: sets ?? e.sets,
        liftKey: e.liftKey,
        accessory: e.accessory,
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
  Future<Session> startSession({required String tz, PlannedWorkout? plan}) async {
    final a = _active();
    if (a != null) return a;
    final s = Session(
      id: newId(),
      startedAt: now(),
      tz: tz,
      source: SessionSource.APP,
      updatedAt: now(),
      programInstanceId: plan?.instanceId,
      planSeq: plan?.planSeq,
      planDayKey: plan?.dayKey,
      exercises: [
        if (plan != null)
          for (var ei = 0; ei < plan.exercises.length; ei++)
            SessionExercise(
              id: newId(),
              exerciseId: plan.exercises[ei].exerciseId,
              position: ei,
              liftKey: plan.exercises[ei].key,
              accessory: plan.exercises[ei].accessory,
              sets: [
                for (var si = 0; si < plan.exercises[ei].sets.length; si++)
                  WorkoutSet(
                    id: newId(),
                    position: si,
                    isWarmup: plan.exercises[ei].sets[si].isWarmup,
                    weightKg: plan.exercises[ei].sets[si].targetWeightKg,
                    reps: plan.exercises[ei].sets[si].targetReps,
                    plannedSetKey: plan.exercises[ei].sets[si].plannedSetKey,
                    targetReps: plan.exercises[ei].sets[si].targetReps,
                    targetWeightKg: plan.exercises[ei].sets[si].targetWeightKg,
                    isAmrap: plan.exercises[ei].sets[si].isAmrap,
                  ),
              ],
            ),
      ],
    );
    _put(s);
    return s;
  }

  @override
  Future<void> reorderExercises(String sessionId, List<String> sessionExerciseIds) async {
    final s = _sessions[sessionId]!;
    final byId = {for (final e in s.exercises) e.id: e};
    _put(
      _copy(
        s,
        exercises: [
          for (var i = 0; i < sessionExerciseIds.length; i++) _copySe(byId[sessionExerciseIds[i]]!, position: i),
        ],
      ),
    );
  }

  @override
  Future<void> reorderSets(String sessionExerciseId, List<String> setIds) async {
    final f = _findSe(sessionExerciseId)!;
    final se = f.session.exercises[f.exIndex];
    final byId = {for (final w in se.sets) w.id: w};
    final list = [...f.session.exercises];
    list[f.exIndex] = _copySe(
      se,
      sets: [for (var i = 0; i < setIds.length; i++) byId[setIds[i]]!.copyWith(position: i)],
    );
    _put(_copy(f.session, exercises: list));
  }

  @override
  Future<void> updateSessionTimes(String sessionId, {DateTime? startedAt, DateTime? endedAt}) async {
    final s = _sessions[sessionId]!;
    _put(_copy(s, startedAt: startedAt, endedAt: endedAt == null ? null : () => endedAt));
  }

  @override
  Future<Set<int>> planSeqsUsed(String instanceId) async => {
    for (final s in _sessions.values)
      if (s.programInstanceId == instanceId && s.planSeq != null) s.planSeq!,
  };

  @override
  Future<Session?> lastSessionForDay(String instanceId, String dayKey, {String? excludeSessionId}) async {
    final list =
        _sessions.values
            .where(
              (s) =>
                  !s.isActive &&
                  s.programInstanceId == instanceId &&
                  s.planDayKey == dayKey &&
                  s.id != excludeSessionId,
            )
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list.firstOrNull;
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
  Future<SessionExercise> addExercise(String sessionId, String exerciseId, {bool accessory = false}) async {
    final s = _sessions[sessionId]!;
    final pos = s.exercises.isEmpty ? 0 : s.exercises.map((e) => e.position).reduce((a, b) => a > b ? a : b) + 1;
    final se = SessionExercise(id: newId(), exerciseId: exerciseId, position: pos, accessory: accessory);
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

/// 테스트용 프로그램 저장소. programs/instances/plans를 직접 채워 쓴다.
class MemoryProgramRepository implements ProgramRepository {
  final Map<String, Program> programs = {};
  final Map<String, Instance> instances = {};
  final Map<String, List<PlannedWorkout>> plans = {};
  final Map<String, List<SuggestItem>> suggestions = {};
  final Map<String, List<Accessory>> accessoryLists = {};
  final _changes = StreamController<String>.broadcast();

  void _changed(String id) => _changes.add(id);

  @override
  Stream<String> get instanceChanges => _changes.stream;

  @override
  Future<List<ProgramSummary>> listPrograms({ProgramListSource? source}) async => [
    for (final p in programs.values)
      if (source == null || (source == ProgramListSource.TEMPLATE) == p.builtIn) p,
  ];

  @override
  Future<Program> getProgram(String id) async => programs[id] ?? (throw StateError('no program $id'));

  @override
  Future<Program> createProgram(String id, Map<String, Object?> definition) async => programs[id] = Program(
    id: id,
    name: definition['name'] as String? ?? id,
    builtIn: false,
    dayCount: (definition['days'] as List?)?.length ?? 0,
    source: ProgramSource.USER,
    definition: definition,
  );

  @override
  Future<Program> validateProgram(Map<String, Object?> definition) async => Program(
    id: '',
    name: definition['name'] as String? ?? '',
    builtIn: false,
    dayCount: (definition['days'] as List?)?.length ?? 0,
    definition: definition,
  );

  @override
  Future<void> deleteProgram(String id) async => programs.remove(id);

  @override
  Future<List<SuggestItem>> suggest(String programId) async => suggestions[programId] ?? const [];

  @override
  Future<List<Instance>> listInstances({InstanceStatus? status}) async => [
    for (final i in instances.values)
      if (status == null || i.status == status) i,
  ];

  @override
  Future<Instance> getInstance(String id) async => instances[id] ?? (throw StateError('no instance $id'));

  @override
  Future<Instance> startInstance(StartInstance start) async {
    final p = programs[start.programId]!;
    final i = Instance(
      id: start.id,
      programId: p.id,
      name: p.name,
      status: InstanceStatus.ACTIVE,
      skipPolicy: start.skipPolicy,
      startDate: start.startDate,
      state: InstanceState(tm: start.tm, working: start.working, week: 1, cycle: 1, seq: 0),
    );
    instances[i.id] = i;
    _changed(i.id);
    return i;
  }

  Instance _with(Instance i, {InstanceStatus? status, SkipPolicy? skipPolicy}) => Instance(
    id: i.id,
    programId: i.programId,
    name: i.name,
    status: status ?? i.status,
    skipPolicy: skipPolicy ?? i.skipPolicy,
    startDate: i.startDate,
    state: i.state,
    next: i.next,
  );

  @override
  Future<Instance> patchInstance(String id, InstancePatch patch) async {
    final i = _with(instances[id]!, status: patch.status, skipPolicy: patch.skipPolicy);
    instances[id] = i;
    _changed(id);
    return i;
  }

  @override
  Future<void> deleteInstance(String id) async {
    instances.remove(id);
    _changed(id);
  }

  @override
  Future<List<PlannedWorkout>> plan(String instanceId, {int count = 3}) async =>
      (plans[instanceId] ?? const []).take(count).toList();

  @override
  Future<Instance> skip(String instanceId, int planSeq) async {
    final list = plans[instanceId];
    if (list != null && list.isNotEmpty && list.first.planSeq == planSeq) list.removeAt(0);
    _changed(instanceId);
    return instances[instanceId]!;
  }

  @override
  Future<List<Accessory>> accessories(String instanceId) async => accessoryLists[instanceId] ?? const [];

  @override
  Future<List<Accessory>> putAccessories(String instanceId, List<Accessory> list) async {
    accessoryLists[instanceId] = list;
    _changed(instanceId);
    return list;
  }
}

class MemoryRecordsRepository implements RecordsRepository {
  final Map<String, ExerciseRecords> recordsByExercise = {};
  final Map<String, List<OneRmMeasurement>> measured = {};

  @override
  Future<ExerciseRecords> records(String exerciseId) async =>
      recordsByExercise[exerciseId] ?? ExerciseRecords(exerciseId: exerciseId, formula: 'EPLEY');

  @override
  Future<List<OneRmMeasurement>> oneRms(String exerciseId) async =>
      (measured[exerciseId] ?? const []).toList()..sort((a, b) => b.measuredAt.compareTo(a.measuredAt));

  @override
  Future<OneRmMeasurement> addOneRm(String exerciseId, OneRmMeasurement m) async {
    final saved = OneRmMeasurement(
      id: m.id,
      exerciseId: exerciseId,
      weightKg: m.weightKg,
      measuredAt: m.measuredAt,
      note: m.note,
    );
    (measured[exerciseId] ??= []).add(saved);
    return saved;
  }

  @override
  Future<void> deleteOneRm(String id) async {
    for (final l in measured.values) {
      l.removeWhere((m) => m.id == id);
    }
  }
}

/// 테스트용 계획 캐시: 프로그램 저장소의 ACTIVE 인스턴스와 첫 계획을 그대로 보여준다.
class MemoryPlanCache implements PlanCache {
  final ProgramRepository programs;
  final _bus = StreamController<void>.broadcast();
  List<InstancePlan> _items = const [];
  MemoryPlanCache(this.programs);

  @override
  Stream<List<InstancePlan>> watchActive() async* {
    yield _items;
    yield* _bus.stream.map((_) => _items);
  }

  @override
  Future<void> refresh({String? instanceId}) async {
    final list = await programs.listInstances(status: InstanceStatus.ACTIVE);
    _items = [for (final i in list) InstancePlan(instance: i, next: (await programs.plan(i.id, count: 1)).firstOrNull)];
    _bus.add(null);
  }

  @override
  Future<PlannedWorkout?> nextPlan(String instanceId) async => (await programs.plan(instanceId, count: 1)).firstOrNull;
}
