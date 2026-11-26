// ignore_for_file: constant_identifier_names
// contracts/v0.1/openapi.yaml 스키마를 손으로 옮긴 DTO.
// 규칙(conventions.md): 클래스 이름 = 스키마 이름, JSON 키 = camelCase,
// 시각은 UTC ISO-8601, 무게는 kg. 이 파일은 트랙 리드 소유이며 WP는 바꾸지 않는다.

// ---------- 공통 헬퍼 ----------

DateTime? _dt(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();
String? _iso(DateTime? v) => v?.toUtc().toIso8601String();
double? _num(Object? v) => v == null ? null : (v as num).toDouble();

/// null 값은 키를 빼고 내보낸다.
Map<String, Object?> _compact(Map<String, Object?> m) =>
    Map.fromEntries(m.entries.where((e) => e.value != null));

T _enumByName<T extends Enum>(List<T> values, Object? name) =>
    values.firstWhere((e) => e.name == name, orElse: () => throw FormatException('unknown enum $name for $T'));

// ---------- enum ----------

enum ExerciseType { BARBELL, DUMBBELL, MACHINE, BODYWEIGHT, BAND, CARDIO }

/// v0.1 화면에 제공하는 기록 유형.
const v01ExerciseTypes = [ExerciseType.BARBELL, ExerciseType.DUMBBELL, ExerciseType.MACHINE, ExerciseType.BODYWEIGHT];

enum Muscle {
  CHEST, BACK, LATS, TRAPS, SHOULDERS, REAR_DELTS, BICEPS, TRICEPS, FOREARMS,
  QUADS, HAMSTRINGS, GLUTES, CALVES, ADDUCTORS, ABS, OBLIQUES, LOWER_BACK, FULL_BODY, CARDIO
}

enum ConsentKind { TERMS, PRIVACY, HEALTH_DATA }

enum WeightUnit { KG, LB }

/// 1RM 추정식 (v0.2 engine.md §9).
enum E1rmFormula { EPLEY, BRZYCKI, LOMBARDI }

enum Sex { MALE, FEMALE, OTHER }

enum UserRole { MEMBER, TRAINER }

enum SessionSource { APP, AI_JSON, AI_MCP, IMPORT }

/// v0.3: AI_JSON·AI_MCP·IMPORT 추가(가져오기로 만든 체중).
enum MeasurementSource { MANUAL, HEALTH_CONNECT, HEALTHKIT, OCR, AI_JSON, AI_MCP, IMPORT }

enum SyncEntity { exercise, workout_session, session_exercise, workout_set, body_measurement }

enum ChangeOp { UPSERT, DELETE }

enum ChangeStatus { applied, conflict, rejected }

// ---------- auth / account ----------

class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final bool isNewUser;
  const AuthTokens({required this.accessToken, required this.refreshToken, required this.expiresIn, required this.isNewUser});

  factory AuthTokens.fromJson(Map<String, Object?> j) => AuthTokens(
        accessToken: j['accessToken'] as String,
        refreshToken: j['refreshToken'] as String,
        expiresIn: j['expiresIn'] as int,
        isNewUser: j['isNewUser'] as bool,
      );
  Map<String, Object?> toJson() =>
      {'accessToken': accessToken, 'refreshToken': refreshToken, 'expiresIn': expiresIn, 'isNewUser': isNewUser};
}

class Me {
  final String id;
  final String email;
  final String? displayName;
  final UserRole role;
  final List<ConsentKind> consentsRequired;
  const Me({required this.id, required this.email, this.displayName, required this.role, required this.consentsRequired});

  factory Me.fromJson(Map<String, Object?> j) => Me(
        id: j['id'] as String,
        email: j['email'] as String,
        displayName: j['displayName'] as String?,
        role: _enumByName(UserRole.values, j['role']),
        consentsRequired: [for (final k in (j['consentsRequired'] as List? ?? const [])) _enumByName(ConsentKind.values, k)],
      );
}

class Settings {
  final WeightUnit weightUnit;
  final int defaultRestSec;
  final bool keepScreenOn;
  final bool rpeInputEnabled;
  final double? heightCm;
  final Sex? sex;
  final int? birthYear;
  final E1rmFormula e1rmFormula;

  /// 서버 기본값(V1__init.sql user_settings)과 같다.
  const Settings({
    this.weightUnit = WeightUnit.KG,
    this.defaultRestSec = 120,
    this.keepScreenOn = true,
    this.rpeInputEnabled = true,
    this.heightCm,
    this.sex,
    this.birthYear,
    this.e1rmFormula = E1rmFormula.EPLEY,
  });

  factory Settings.fromJson(Map<String, Object?> j) => Settings(
        weightUnit: j['weightUnit'] == null ? WeightUnit.KG : _enumByName(WeightUnit.values, j['weightUnit']),
        defaultRestSec: j['defaultRestSec'] as int? ?? 120,
        keepScreenOn: j['keepScreenOn'] as bool? ?? true,
        rpeInputEnabled: j['rpeInputEnabled'] as bool? ?? true,
        heightCm: _num(j['heightCm']),
        sex: j['sex'] == null ? null : _enumByName(Sex.values, j['sex']),
        birthYear: j['birthYear'] as int?,
        e1rmFormula: j['e1rmFormula'] == null ? E1rmFormula.EPLEY : _enumByName(E1rmFormula.values, j['e1rmFormula']),
      );

  /// v0.2: PUT은 JSON merge-patch. heightCm·sex·birthYear는 null을 명시해서 보내야 서버에서 비워진다.
  Map<String, Object?> toJson() => {
        'weightUnit': weightUnit.name,
        'defaultRestSec': defaultRestSec,
        'keepScreenOn': keepScreenOn,
        'rpeInputEnabled': rpeInputEnabled,
        'heightCm': heightCm,
        'sex': sex?.name,
        'birthYear': birthYear,
        'e1rmFormula': e1rmFormula.name,
      };

  Settings copyWith({
    WeightUnit? weightUnit,
    int? defaultRestSec,
    bool? keepScreenOn,
    bool? rpeInputEnabled,
    double? Function()? heightCm,
    Sex? Function()? sex,
    int? Function()? birthYear,
    E1rmFormula? e1rmFormula,
  }) =>
      Settings(
        weightUnit: weightUnit ?? this.weightUnit,
        defaultRestSec: defaultRestSec ?? this.defaultRestSec,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        rpeInputEnabled: rpeInputEnabled ?? this.rpeInputEnabled,
        heightCm: heightCm != null ? heightCm() : this.heightCm,
        sex: sex != null ? sex() : this.sex,
        birthYear: birthYear != null ? birthYear() : this.birthYear,
        e1rmFormula: e1rmFormula ?? this.e1rmFormula,
      );
}

class ConsentInput {
  final ConsentKind kind;
  final String version;
  final bool granted;
  const ConsentInput({required this.kind, required this.version, required this.granted});
  Map<String, Object?> toJson() => {'kind': kind.name, 'version': version, 'granted': granted};
}

class Consent extends ConsentInput {
  final DateTime? createdAt;
  const Consent({required super.kind, required super.version, required super.granted, this.createdAt});
  factory Consent.fromJson(Map<String, Object?> j) => Consent(
        kind: _enumByName(ConsentKind.values, j['kind']),
        version: j['version'] as String,
        granted: j['granted'] as bool,
        createdAt: _dt(j['createdAt']),
      );
}

// ---------- exercise ----------

class ExerciseInput {
  final String id;
  final String nameKo;
  final String? nameEn;
  final ExerciseType type;
  final Muscle primaryMuscle;
  final List<Muscle> secondaryMuscles;
  const ExerciseInput({
    required this.id,
    required this.nameKo,
    this.nameEn,
    required this.type,
    required this.primaryMuscle,
    this.secondaryMuscles = const [],
  });

  Map<String, Object?> toJson() => _compact({
        'id': id,
        'nameKo': nameKo,
        'nameEn': nameEn,
        'type': type.name,
        'primaryMuscle': primaryMuscle.name,
        'secondaryMuscles': [for (final m in secondaryMuscles) m.name],
      });
}

class Exercise extends ExerciseInput {
  final bool builtIn;
  final DateTime updatedAt;

  /// v0.3 출처(내 종목만 의미 있음). null = APP.
  final SessionSource? source;
  final String? importBatchId;
  const Exercise({
    required super.id,
    required super.nameKo,
    super.nameEn,
    required super.type,
    required super.primaryMuscle,
    super.secondaryMuscles,
    required this.builtIn,
    required this.updatedAt,
    this.source,
    this.importBatchId,
  });

  factory Exercise.fromJson(Map<String, Object?> j) => Exercise(
        id: j['id'] as String,
        nameKo: j['nameKo'] as String,
        nameEn: j['nameEn'] as String?,
        type: _enumByName(ExerciseType.values, j['type']),
        primaryMuscle: _enumByName(Muscle.values, j['primaryMuscle']),
        secondaryMuscles: [for (final m in (j['secondaryMuscles'] as List? ?? const [])) _enumByName(Muscle.values, m)],
        builtIn: j['builtIn'] as bool,
        updatedAt: _dt(j['updatedAt'])!,
        source: j['source'] == null ? null : _enumByName(SessionSource.values, j['source']),
        importBatchId: j['importBatchId'] as String?,
      );

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'builtIn': builtIn, 'updatedAt': _iso(updatedAt)};
}

// ---------- session ----------

class WorkoutSet {
  final String id;
  final int position;
  final bool isWarmup;
  final double? weightKg;
  final double? addedWeightKg;
  final int? reps;
  final int? durationSec;
  final double? distanceM;
  final String? bandLevel;
  final double? rpe;
  final int? rir;
  final int? restSec;
  final String? note;
  final DateTime? completedAt;

  // v0.2 계획 연결(프로그램 세션일 때만). 계획 값은 기록 값과 따로 보관한다.
  final String? plannedSetKey;
  final int? targetReps;
  final double? targetWeightKg;
  final bool isAmrap;

  const WorkoutSet({
    required this.id,
    required this.position,
    this.isWarmup = false,
    this.weightKg,
    this.addedWeightKg,
    this.reps,
    this.durationSec,
    this.distanceM,
    this.bandLevel,
    this.rpe,
    this.rir,
    this.restSec,
    this.note,
    this.completedAt,
    this.plannedSetKey,
    this.targetReps,
    this.targetWeightKg,
    this.isAmrap = false,
  });

  bool get isPlanned => plannedSetKey != null;

  bool get isCompleted => completedAt != null;

  factory WorkoutSet.fromJson(Map<String, Object?> j) => WorkoutSet(
        id: j['id'] as String,
        position: j['position'] as int,
        isWarmup: j['isWarmup'] as bool? ?? false,
        weightKg: _num(j['weightKg']),
        addedWeightKg: _num(j['addedWeightKg']),
        reps: j['reps'] as int?,
        durationSec: j['durationSec'] as int?,
        distanceM: _num(j['distanceM']),
        bandLevel: j['bandLevel'] as String?,
        rpe: _num(j['rpe']),
        rir: j['rir'] as int?,
        restSec: j['restSec'] as int?,
        note: j['note'] as String?,
        completedAt: _dt(j['completedAt']),
        plannedSetKey: j['plannedSetKey'] as String?,
        targetReps: j['targetReps'] as int?,
        targetWeightKg: _num(j['targetWeightKg']),
        isAmrap: j['isAmrap'] as bool? ?? false,
      );

  Map<String, Object?> toJson() => _compact({
        'id': id,
        'position': position,
        'isWarmup': isWarmup,
        'weightKg': weightKg,
        'addedWeightKg': addedWeightKg,
        'reps': reps,
        'durationSec': durationSec,
        'distanceM': distanceM,
        'bandLevel': bandLevel,
        'rpe': rpe,
        'rir': rir,
        'restSec': restSec,
        'note': note,
        'completedAt': _iso(completedAt),
        'plannedSetKey': plannedSetKey,
        'targetReps': targetReps,
        'targetWeightKg': targetWeightKg,
        'isAmrap': isAmrap,
      });

  /// nullable 필드는 `() => null`처럼 함수로 넘겨야 null로 바꿀 수 있다.
  WorkoutSet copyWith({
    int? position,
    bool? isWarmup,
    double? Function()? weightKg,
    double? Function()? addedWeightKg,
    int? Function()? reps,
    int? Function()? durationSec,
    double? Function()? distanceM,
    String? Function()? bandLevel,
    double? Function()? rpe,
    int? Function()? rir,
    int? Function()? restSec,
    String? Function()? note,
    DateTime? Function()? completedAt,
  }) =>
      WorkoutSet(
        id: id,
        position: position ?? this.position,
        isWarmup: isWarmup ?? this.isWarmup,
        weightKg: weightKg != null ? weightKg() : this.weightKg,
        addedWeightKg: addedWeightKg != null ? addedWeightKg() : this.addedWeightKg,
        reps: reps != null ? reps() : this.reps,
        durationSec: durationSec != null ? durationSec() : this.durationSec,
        distanceM: distanceM != null ? distanceM() : this.distanceM,
        bandLevel: bandLevel != null ? bandLevel() : this.bandLevel,
        rpe: rpe != null ? rpe() : this.rpe,
        rir: rir != null ? rir() : this.rir,
        restSec: restSec != null ? restSec() : this.restSec,
        note: note != null ? note() : this.note,
        completedAt: completedAt != null ? completedAt() : this.completedAt,
        plannedSetKey: plannedSetKey,
        targetReps: targetReps,
        targetWeightKg: targetWeightKg,
        isAmrap: isAmrap,
      );
}

class SessionExercise {
  final String id;
  final String exerciseId;
  final int position;
  final String? note;
  final List<WorkoutSet> sets;

  /// v0.2: 프로그램 종목이면 lifts 키(인스턴스 보조운동은 `acc:<id>`), 보조운동이면 accessory=true.
  final String? liftKey;
  final bool accessory;
  const SessionExercise({
    required this.id,
    required this.exerciseId,
    required this.position,
    this.note,
    this.sets = const [],
    this.liftKey,
    this.accessory = false,
  });

  factory SessionExercise.fromJson(Map<String, Object?> j) => SessionExercise(
        id: j['id'] as String,
        exerciseId: j['exerciseId'] as String,
        position: j['position'] as int,
        note: j['note'] as String?,
        sets: [for (final s in (j['sets'] as List? ?? const [])) WorkoutSet.fromJson((s as Map).cast())],
        liftKey: j['liftKey'] as String?,
        accessory: j['accessory'] as bool? ?? false,
      );
  Map<String, Object?> toJson() => _compact({
        'id': id,
        'exerciseId': exerciseId,
        'position': position,
        'note': note,
        'liftKey': liftKey,
        'accessory': accessory,
        'sets': [for (final s in sets) s.toJson()],
      });
}

class Session {
  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String tz;
  final String? note;
  final SessionSource? source;
  final List<SessionExercise> exercises;
  final DateTime? updatedAt;

  /// v0.2: 프로그램 회차로 시작한 세션이면 채워진다. 자유 세션이면 null.
  final String? programInstanceId;
  final int? planSeq;
  final String? planDayKey;

  /// v0.3: 가져오기 묶음으로 만든 세션이면 그 묶음 id(readOnly). 출처 배지·되돌리기용.
  final String? importBatchId;
  const Session({
    required this.id,
    required this.startedAt,
    this.endedAt,
    required this.tz,
    this.note,
    this.source,
    this.exercises = const [],
    this.updatedAt,
    this.programInstanceId,
    this.planSeq,
    this.planDayKey,
    this.importBatchId,
  });

  /// AI가 넣은 데이터(출처 배지 대상).
  bool get isFromAi => source == SessionSource.AI_JSON || source == SessionSource.AI_MCP;

  bool get isProgram => programInstanceId != null;

  bool get isActive => endedAt == null;

  factory Session.fromJson(Map<String, Object?> j) => Session(
        id: j['id'] as String,
        startedAt: _dt(j['startedAt'])!,
        endedAt: _dt(j['endedAt']),
        tz: j['tz'] as String,
        note: j['note'] as String?,
        source: j['source'] == null ? null : _enumByName(SessionSource.values, j['source']),
        exercises: [for (final e in (j['exercises'] as List? ?? const [])) SessionExercise.fromJson((e as Map).cast())],
        updatedAt: _dt(j['updatedAt']),
        programInstanceId: j['programInstanceId'] as String?,
        planSeq: j['planSeq'] as int?,
        planDayKey: j['planDayKey'] as String?,
        importBatchId: j['importBatchId'] as String?,
      );

  /// source, updatedAt, importBatchId는 readOnly라 보내지 않는다.
  Map<String, Object?> toJson() => _compact({
        'id': id,
        'startedAt': _iso(startedAt),
        'endedAt': _iso(endedAt),
        'tz': tz,
        'note': note,
        'programInstanceId': programInstanceId,
        'planSeq': planSeq,
        'planDayKey': planDayKey,
        'exercises': [for (final e in exercises) e.toJson()],
      });
}

class SessionSummary {
  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String tz;
  final int exerciseCount;
  final int setCount;
  final double totalVolumeKg;
  const SessionSummary({
    required this.id,
    required this.startedAt,
    this.endedAt,
    required this.tz,
    required this.exerciseCount,
    required this.setCount,
    required this.totalVolumeKg,
  });

  factory SessionSummary.fromJson(Map<String, Object?> j) => SessionSummary(
        id: j['id'] as String,
        startedAt: _dt(j['startedAt'])!,
        endedAt: _dt(j['endedAt']),
        tz: j['tz'] as String,
        exerciseCount: j['exerciseCount'] as int,
        setCount: j['setCount'] as int,
        totalVolumeKg: _num(j['totalVolumeKg'])!,
      );
}

class LastSets {
  final String sessionId;
  final DateTime startedAt;
  final List<WorkoutSet> sets;
  const LastSets({required this.sessionId, required this.startedAt, required this.sets});
  factory LastSets.fromJson(Map<String, Object?> j) => LastSets(
        sessionId: j['sessionId'] as String,
        startedAt: _dt(j['startedAt'])!,
        sets: [for (final s in (j['sets'] as List? ?? const [])) WorkoutSet.fromJson((s as Map).cast())],
      );
}

// ---------- body ----------

class BodyMeasurement {
  final String id;
  final DateTime measuredAt;
  final double weightKg;
  final MeasurementSource source;

  /// v0.3 readOnly.
  final String? importBatchId;
  const BodyMeasurement({
    required this.id,
    required this.measuredAt,
    required this.weightKg,
    this.source = MeasurementSource.MANUAL,
    this.importBatchId,
  });

  factory BodyMeasurement.fromJson(Map<String, Object?> j) => BodyMeasurement(
        id: j['id'] as String,
        measuredAt: _dt(j['measuredAt'])!,
        weightKg: _num(j['weightKg'])!,
        source: j['source'] == null ? MeasurementSource.MANUAL : _enumByName(MeasurementSource.values, j['source']),
        importBatchId: j['importBatchId'] as String?,
      );
  Map<String, Object?> toJson() => {'id': id, 'measuredAt': _iso(measuredAt), 'weightKg': weightKg, 'source': source.name};
}

// ---------- sync ----------

class Change {
  final SyncEntity entity;
  final String id;
  final ChangeOp op;
  final String? parentId;
  final Map<String, Object?>? payload;
  final DateTime clientUpdatedAt;
  final int? serverSeq;
  const Change({
    required this.entity,
    required this.id,
    required this.op,
    this.parentId,
    this.payload,
    required this.clientUpdatedAt,
    this.serverSeq,
  });

  factory Change.fromJson(Map<String, Object?> j) => Change(
        entity: _enumByName(SyncEntity.values, j['entity']),
        id: j['id'] as String,
        op: _enumByName(ChangeOp.values, j['op']),
        parentId: j['parentId'] as String?,
        payload: (j['payload'] as Map?)?.cast<String, Object?>(),
        clientUpdatedAt: _dt(j['clientUpdatedAt'])!,
        serverSeq: j['serverSeq'] as int?,
      );
  Map<String, Object?> toJson() => _compact({
        'entity': entity.name,
        'id': id,
        'op': op.name,
        'parentId': parentId,
        'payload': op == ChangeOp.DELETE ? null : payload,
        'clientUpdatedAt': _iso(clientUpdatedAt),
      });
}

class ChangeResult {
  final String id;
  final ChangeStatus status;
  final String? code;
  final Change? server;
  const ChangeResult({required this.id, required this.status, this.code, this.server});
  factory ChangeResult.fromJson(Map<String, Object?> j) => ChangeResult(
        id: j['id'] as String,
        status: _enumByName(ChangeStatus.values, j['status']),
        code: j['code'] as String?,
        server: j['server'] == null ? null : Change.fromJson((j['server'] as Map).cast()),
      );
}

class PullResult {
  final List<Change> changes;
  final int nextSince;
  final bool hasMore;
  const PullResult({required this.changes, required this.nextSince, required this.hasMore});
  factory PullResult.fromJson(Map<String, Object?> j) => PullResult(
        changes: [for (final c in (j['changes'] as List)) Change.fromJson((c as Map).cast())],
        nextSince: j['nextSince'] as int,
        hasMore: j['hasMore'] as bool,
      );
}
