// ignore_for_file: constant_identifier_names
// contracts/v0.2/openapi.yaml 스키마를 손으로 옮긴 DTO(프로그램·인스턴스·계획·기록). 트랙 리드 소유.
// 프로그램 정의(program.schema.json)는 앱이 해석하지 않고 Map 그대로 다룬다(계산은 서버에서만).

DateTime? _dt(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();
double? _num(Object? v) => v == null ? null : (v as num).toDouble();
T _enumByName<T extends Enum>(List<T> values, Object? name) =>
    values.firstWhere((e) => e.name == name, orElse: () => throw FormatException('unknown enum $name for $T'));
Map<String, double> _kgMap(Object? v) => {
  for (final e in ((v as Map?) ?? const {}).entries) e.key as String: (e.value as num).toDouble(),
};
Map<String, int> _intMap(Object? v) => {
  for (final e in ((v as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt(),
};

/// `startDate`, `scheduledDate` 같은 날짜(시간 없음). 'YYYY-MM-DD'.
String formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

/// v1.1: 회당 운동 시간 어림(분). min==max면 한 값.
class SessionMinutes {
  final int min;
  final int max;
  const SessionMinutes({required this.min, required this.max});

  /// 객체가 아니거나 숫자가 아니면 null(숨김).
  static SessionMinutes? tryParse(Object? v) {
    if (v is! Map) return null;
    final a = v['min'], b = v['max'];
    if (a is! num || b is! num) return null;
    final lo = a.toInt(), hi = b.toInt();
    if (lo <= 0 || hi < lo) return null;
    return SessionMinutes(min: lo, max: hi);
  }
}

enum ProgramSource { TEMPLATE, USER, AI_JSON, AI_MCP }

/// GET /v1/programs?source=
enum ProgramListSource { TEMPLATE, MINE }

enum InstanceStatus { ACTIVE, PAUSED, FINISHED }

enum SkipPolicy { SHIFT, FIXED_DATE }

enum SuggestNeeds { TM, WORKING }

enum OneRmSource { MEASURED, ESTIMATED }

class ProgramSummary {
  final String id;
  final String? templateKey;
  final String name;
  final String? description;
  final bool builtIn;
  final int dayCount;
  final ProgramSource? source;

  /// v0.3: 가져오기로 만든 프로그램이면 묶음 id.
  final String? importBatchId;

  /// BODYBUILDING | POWERBUILDING | POWERLIFTING | GENERAL_STRENGTH | BODYWEIGHT.
  /// 옛 서버는 보내지 않고, 미래 값이 올 수 있어 enum이 아닌 문자열로 둔다.
  final String? category;

  /// BEGINNER | INTERMEDIATE | ADVANCED. 미래 값이 올 수 있어 문자열로 둔다.
  final String? level;

  /// 같은 기준 무게 체계의 변형 묶음 키와 묶음 안 구성 이름.
  final String? family;
  final String? variantLabel;

  /// 흔히 부르는 이름(검색용). 없으면 빈 목록.
  final List<String> aka;

  /// 쉬운 말 규칙 세 줄. 없거나 형식이 틀리면 null.
  final ProgramRules? rules;

  /// v1.1: 회당 시간 어림. 없으면 null.
  final SessionMinutes? sessionMinutes;
  const ProgramSummary({
    required this.id,
    this.templateKey,
    required this.name,
    this.description,
    required this.builtIn,
    required this.dayCount,
    this.source,
    this.importBatchId,
    this.category,
    this.level,
    this.family,
    this.variantLabel,
    this.aka = const [],
    this.rules,
    this.sessionMinutes,
  });

  factory ProgramSummary.fromJson(Map<String, Object?> j) => ProgramSummary(
    id: j['id'] as String? ?? '', // POST /programs/validate 응답은 id 생략
    templateKey: j['templateKey'] as String?,
    name: j['name'] as String,
    description: j['description'] as String?,
    builtIn: j['builtIn'] as bool,
    dayCount: j['dayCount'] as int,
    source: j['source'] == null ? null : _enumByName(ProgramSource.values, j['source']),
    importBatchId: j['importBatchId'] as String?,
    category: j['category'] is String ? j['category'] as String : null,
    level: j['level'] is String ? j['level'] as String : null,
    family: j['family'] is String ? j['family'] as String : null,
    variantLabel: j['variantLabel'] is String ? j['variantLabel'] as String : null,
    aka: j['aka'] is List ? [for (final e in j['aka'] as List) if (e is String) e] : const [],
    rules: ProgramRules.tryParse(j['rules']),
    sessionMinutes: SessionMinutes.tryParse(j['sessionMinutes']),
  );
}

/// 템플릿 규칙 세 줄(오르면 / 실패하면 / 낮출 때). 서버가 ko 로 내려준다.
class ProgramRules {
  final String progress;
  final String failure;
  final String deload;
  const ProgramRules({required this.progress, required this.failure, required this.deload});

  /// 객체가 아니거나 세 줄 중 하나라도 문자열이 아니면 null.
  static ProgramRules? tryParse(Object? v) {
    if (v is! Map) return null;
    final p = v['progress'], f = v['failure'], d = v['deload'];
    if (p is String && f is String && d is String) return ProgramRules(progress: p, failure: f, deload: d);
    return null;
  }
}

class Program extends ProgramSummary {
  /// program.schema.json 형식 그대로. 화면 표시에 필요한 부분만 읽는다(days[].name, days[].exercises[].lift, lifts 등).
  final Map<String, Object?> definition;

  /// v1.2: PUT /v1/programs/{id} 응답에만 있다. 이 프로그램의 ACTIVE·PAUSED 인스턴스 id.
  final List<String> activeInstanceIds;
  const Program({
    required super.id,
    super.templateKey,
    required super.name,
    super.description,
    required super.builtIn,
    required super.dayCount,
    super.source,
    super.importBatchId,
    super.category,
    super.level,
    super.family,
    super.variantLabel,
    super.aka,
    super.rules,
    super.sessionMinutes,
    required this.definition,
    this.activeInstanceIds = const [],
  });

  factory Program.fromJson(Map<String, Object?> j) {
    final s = ProgramSummary.fromJson(j);
    return Program(
      id: s.id,
      templateKey: s.templateKey,
      name: s.name,
      description: s.description,
      builtIn: s.builtIn,
      dayCount: s.dayCount,
      source: s.source,
      importBatchId: s.importBatchId,
      category: s.category,
      level: s.level,
      family: s.family,
      variantLabel: s.variantLabel,
      aka: s.aka,
      rules: s.rules,
      sessionMinutes: s.sessionMinutes,
      definition: (j['definition'] as Map).cast<String, Object?>(),
      activeInstanceIds: j['activeInstanceIds'] is List
          ? [for (final e in j['activeInstanceIds'] as List) if (e is String) e]
          : const [],
    );
  }
}

/// GET /v1/programs/{id}/suggest 한 줄.
class SuggestItem {
  final String key;
  final String exerciseId;
  final SuggestNeeds needs;
  final double? oneRmKg;
  final OneRmSource? oneRmSource;

  /// null이면 사용자가 입력해야 한다.
  final double? suggestedKg;

  /// v1.1: true면 시작 시 값을 비워둘 수 있다(첫 운동 기록으로 정함).
  final bool optional;

  /// v1.1: 자동 계산 종목이면 기준 종목 키와 비율(예: squat, 0.8). 아니면 null.
  final String? derivedFrom;
  final double? derivedRatio;
  const SuggestItem({
    required this.key,
    required this.exerciseId,
    required this.needs,
    this.oneRmKg,
    this.oneRmSource,
    this.suggestedKg,
    this.optional = false,
    this.derivedFrom,
    this.derivedRatio,
  });

  /// 자동 계산 종목(기준 종목이 있음).
  bool get isDerived => derivedFrom != null;

  /// 비워도 시작할 수 있는 종목(첫 운동에서 정하기·자동 계산).
  bool get canSkip => optional || isDerived;

  factory SuggestItem.fromJson(Map<String, Object?> j) => SuggestItem(
    key: j['key'] as String,
    exerciseId: j['exerciseId'] as String,
    needs: _enumByName(SuggestNeeds.values, j['needs']),
    oneRmKg: _num(j['oneRmKg']),
    // 모르는 출처 값(앞으로 추가될 수 있음)은 예외 대신 null.
    oneRmSource: OneRmSource.values.where((e) => e.name == j['oneRmSource']).firstOrNull,
    suggestedKg: _num(j['suggestedKg']),
    optional: j['optional'] as bool? ?? false,
    derivedFrom: j['derivedFrom'] is String ? j['derivedFrom'] as String : null,
    derivedRatio: j['derivedRatio'] is num ? (j['derivedRatio'] as num).toDouble() : null,
  );
}

class StartInstance {
  final String id;
  final String programId;
  final DateTime startDate;
  final String tz;
  final SkipPolicy skipPolicy;
  final Map<String, double> tm;
  final Map<String, double> working;

  /// v1.1: 날 키 → 요일(MON~SUN). 바꾼 날만 담는다. 비면 보내지 않는다.
  final Map<String, String> weekdays;
  const StartInstance({
    required this.id,
    required this.programId,
    required this.startDate,
    required this.tz,
    this.skipPolicy = SkipPolicy.SHIFT,
    this.tm = const {},
    this.working = const {},
    this.weekdays = const {},
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'programId': programId,
    'startDate': formatDate(startDate),
    'tz': tz,
    'skipPolicy': skipPolicy.name,
    if (tm.isNotEmpty) 'tm': tm,
    if (working.isNotEmpty) 'working': working,
    if (weekdays.isNotEmpty) 'weekdays': weekdays,
  };
}

/// POST /v1/programs/{id}/preview 요청: StartInstance에서 id·programId를 뺀 모양 + count.
class StartPreviewRequest {
  final DateTime startDate;
  final String tz;
  final SkipPolicy skipPolicy;
  final Map<String, double> tm;
  final Map<String, double> working;
  final Map<String, String> weekdays;
  final int count;
  const StartPreviewRequest({
    required this.startDate,
    required this.tz,
    this.skipPolicy = SkipPolicy.SHIFT,
    this.tm = const {},
    this.working = const {},
    this.weekdays = const {},
    this.count = 1,
  });

  Map<String, Object?> toJson() => {
    'startDate': formatDate(startDate),
    'tz': tz,
    'skipPolicy': skipPolicy.name,
    'tm': tm,
    'working': working,
    if (weekdays.isNotEmpty) 'weekdays': weekdays,
    'count': count,
  };
}

/// 미리 계산 응답. 저장하지 않는다.
class StartPreview {
  final List<PlannedWorkout> workouts;

  /// 실제로 시작될 값(자동 계산이 채운 값 포함).
  final Map<String, double> inputsTm;
  final Map<String, double> inputsWorking;

  /// inputs 중 요청에 없어서 서버가 채운 키.
  final List<String> derived;
  const StartPreview({
    this.workouts = const [],
    this.inputsTm = const {},
    this.inputsWorking = const {},
    this.derived = const [],
  });

  factory StartPreview.fromJson(Map<String, Object?> j) {
    final inputs = j['inputs'] is Map ? (j['inputs'] as Map).cast<String, Object?>() : const <String, Object?>{};
    Map<String, double> kg(Object? v) => v is Map
        ? {for (final e in v.entries) if (e.value is num) '${e.key}': (e.value as num).toDouble()}
        : const {};
    return StartPreview(
      workouts: [
        for (final w in (j['workouts'] as List? ?? const []))
          if (w is Map) PlannedWorkout.fromJson(w.cast()),
      ],
      inputsTm: kg(inputs['tm']),
      inputsWorking: kg(inputs['working']),
      derived: [for (final d in (j['derived'] as List? ?? const [])) if (d is String) d],
    );
  }
}

class InstanceState {
  final Map<String, double> tm;
  final Map<String, double> working;
  final Map<String, int> stage;
  final Map<String, int> failStreak;
  final int? week;
  final int? cycle;
  final int? seq;
  const InstanceState({
    this.tm = const {},
    this.working = const {},
    this.stage = const {},
    this.failStreak = const {},
    this.week,
    this.cycle,
    this.seq,
  });

  factory InstanceState.fromJson(Map<String, Object?> j) => InstanceState(
    tm: _kgMap(j['tm']),
    working: _kgMap(j['working']),
    stage: _intMap(j['stage']),
    failStreak: _intMap(j['failStreak']),
    week: j['week'] as int?,
    cycle: j['cycle'] as int?,
    seq: j['seq'] as int?,
  );
  Map<String, Object?> toJson() => {
    'tm': tm,
    'working': working,
    'stage': stage,
    'failStreak': failStreak,
    'week': ?week,
    'cycle': ?cycle,
    'seq': ?seq,
  };
}

class Instance {
  final String id;
  final String programId;
  final String name;
  final InstanceStatus status;
  final SkipPolicy skipPolicy;
  final DateTime startDate;
  final InstanceState state;
  final PlannedWorkout? next;

  /// v1.2: 서버가 인스턴스에 저장한 정의(시작 시점 스냅샷). 없으면 null.
  final Map<String, Object?>? definition;
  /// v1.2: 날(dayKey)별 기억한 운동 순서(정의 인덱스 순열). 없으면 빈 맵.
  final Map<String, List<int>> dayOrder;
  const Instance({
    required this.id,
    required this.programId,
    required this.name,
    required this.status,
    required this.skipPolicy,
    required this.startDate,
    required this.state,
    this.next,
    this.definition,
    this.dayOrder = const {},
  });

  factory Instance.fromJson(Map<String, Object?> j) => Instance(
    id: j['id'] as String,
    programId: j['programId'] as String,
    name: j['name'] as String,
    status: _enumByName(InstanceStatus.values, j['status']),
    skipPolicy: _enumByName(SkipPolicy.values, j['skipPolicy']),
    startDate: _date(j['startDate'])!,
    state: InstanceState.fromJson(((j['state'] as Map?) ?? const {}).cast()),
    next: j['next'] == null ? null : PlannedWorkout.fromJson((j['next'] as Map).cast()),
    definition: j['definition'] is Map ? (j['definition'] as Map).cast<String, Object?>() : null,
    dayOrder: {
      for (final e in ((j['dayOrder'] as Map?) ?? const {}).entries)
        e.key as String: [for (final i in (e.value as List)) (i as num).toInt()],
    },
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'programId': programId,
    'name': name,
    'status': status.name,
    'skipPolicy': skipPolicy.name,
    'startDate': formatDate(startDate),
    'state': state.toJson(),
    if (next != null) 'next': next!.toJson(),
    if (dayOrder.isNotEmpty) 'dayOrder': dayOrder,
  };
}

/// PATCH /v1/program-instances/{id}. null인 필드는 보내지 않는다.
class InstancePatch {
  final InstanceStatus? status;
  final SkipPolicy? skipPolicy;
  final Map<String, double>? adjustTm;
  final Map<String, double>? adjustWorking;
  const InstancePatch({this.status, this.skipPolicy, this.adjustTm, this.adjustWorking});

  Map<String, Object?> toJson() => {
    if (status != null) 'status': status!.name,
    if (skipPolicy != null) 'skipPolicy': skipPolicy!.name,
    if (adjustTm != null || adjustWorking != null) 'adjust': {'tm': ?adjustTm, 'working': ?adjustWorking},
  };
}

class PlannedSet {
  /// "{dayKey}.{exerciseIndex}.{setIndex}". 기록 세트(WorkoutSet.plannedSetKey)와 잇는 키.
  final String plannedSetKey;
  final int targetReps;

  /// null이면 무게 없음(NONE: 앱이 지난 기록으로 채움) 또는 맨몸.
  final double? targetWeightKg;
  final bool isAmrap;
  final bool isWarmup;

  /// v1.1: 범위 상한(없으면 null).
  final int? targetRepsMax;

  /// v1.1: 세트 휴식(초). 없으면 null(앱 기본 휴식).
  final int? restSec;

  /// v1.2: "DROP"이면 드롭 세트(없으면 null = 일반).
  final String? setType;
  const PlannedSet({
    required this.plannedSetKey,
    required this.targetReps,
    this.targetWeightKg,
    required this.isAmrap,
    required this.isWarmup,
    this.targetRepsMax,
    this.restSec,
    this.setType,
  });

  bool get isDrop => setType == 'DROP';

  factory PlannedSet.fromJson(Map<String, Object?> j) => PlannedSet(
    plannedSetKey: j['plannedSetKey'] as String,
    targetReps: j['targetReps'] as int,
    targetWeightKg: _num(j['targetWeightKg']),
    isAmrap: j['isAmrap'] as bool? ?? false,
    isWarmup: j['isWarmup'] as bool? ?? false,
    targetRepsMax: j['targetRepsMax'] as int?,
    restSec: j['restSec'] as int?,
    setType: j['setType'] as String?,
  );
  Map<String, Object?> toJson() => {
    'plannedSetKey': plannedSetKey,
    'targetReps': targetReps,
    'targetRepsMax': ?targetRepsMax,
    'targetWeightKg': ?targetWeightKg,
    'isAmrap': isAmrap,
    'isWarmup': isWarmup,
    'restSec': ?restSec,
    'setType': ?setType,
  };
}

class PlannedExercise {
  /// lifts 키. 인스턴스 보조운동은 `acc:<accessoryId>`.
  final String key;
  final String exerciseId;
  final bool accessory;
  final List<PlannedSet> sets;

  /// v1.2: 슈퍼세트 묶음(같은 날 같은 값끼리). 없으면 null.
  final String? superset;
  const PlannedExercise({
    required this.key,
    required this.exerciseId,
    required this.accessory,
    required this.sets,
    this.superset,
  });

  factory PlannedExercise.fromJson(Map<String, Object?> j) => PlannedExercise(
    key: j['key'] as String,
    exerciseId: j['exerciseId'] as String,
    accessory: j['accessory'] as bool? ?? false,
    sets: [for (final s in (j['sets'] as List? ?? const [])) PlannedSet.fromJson((s as Map).cast())],
    superset: j['superset'] as String?,
  );
  Map<String, Object?> toJson() => {
    'key': key,
    'exerciseId': exerciseId,
    'accessory': accessory,
    'superset': ?superset,
    'sets': [for (final s in sets) s.toJson()],
  };
}

class PlannedWorkout {
  final String instanceId;
  final int planSeq;
  final int dayIndex;
  final String dayKey;
  final String dayName;
  final int week;
  final int cycle;
  final DateTime? scheduledDate;

  /// true = 첫 회차(확정). false = 모두 성공 가정 예상치(오프라인 캐시용).
  final bool confirmed;

  /// v1.1: 회차 시간 어림(분). 없으면 null.
  final int? estimatedMinutes;
  final List<PlannedExercise> exercises;
  const PlannedWorkout({
    required this.instanceId,
    required this.planSeq,
    required this.dayIndex,
    required this.dayKey,
    required this.dayName,
    required this.week,
    required this.cycle,
    this.scheduledDate,
    this.confirmed = false,
    this.estimatedMinutes,
    required this.exercises,
  });

  factory PlannedWorkout.fromJson(Map<String, Object?> j) => PlannedWorkout(
    instanceId: j['instanceId'] as String? ?? '', // 미리 계산 응답은 instanceId 없음
    planSeq: j['planSeq'] as int,
    dayIndex: j['dayIndex'] as int,
    dayKey: j['dayKey'] as String,
    dayName: j['dayName'] as String,
    week: j['week'] as int,
    cycle: j['cycle'] as int,
    scheduledDate: _date(j['scheduledDate']),
    confirmed: j['confirmed'] as bool? ?? false,
    estimatedMinutes: j['estimatedMinutes'] is num ? (j['estimatedMinutes'] as num).toInt() : null,
    exercises: [for (final e in (j['exercises'] as List? ?? const [])) PlannedExercise.fromJson((e as Map).cast())],
  );
  Map<String, Object?> toJson() => {
    'instanceId': instanceId,
    'planSeq': planSeq,
    'dayIndex': dayIndex,
    'dayKey': dayKey,
    'dayName': dayName,
    'week': week,
    'cycle': cycle,
    if (scheduledDate != null) 'scheduledDate': formatDate(scheduledDate!),
    'confirmed': confirmed,
    'estimatedMinutes': ?estimatedMinutes,
    'exercises': [for (final e in exercises) e.toJson()],
  };

  /// 오프라인에서 캐시를 다 썼을 때: 같은 무게·횟수로 planSeq만 바꾼 사본.
  PlannedWorkout withPlanSeq(int seq) => PlannedWorkout(
    instanceId: instanceId,
    planSeq: seq,
    dayIndex: dayIndex,
    dayKey: dayKey,
    dayName: dayName,
    week: week,
    cycle: cycle,
    scheduledDate: scheduledDate,
    confirmed: false,
    estimatedMinutes: estimatedMinutes,
    exercises: exercises,
  );
}

/// 인스턴스 보조운동(PRG-8).
class Accessory {
  final String id;
  final String dayKey;
  final String exerciseId;
  final int position;
  final int sets;
  final int reps;
  final double? weightKg;
  const Accessory({
    required this.id,
    required this.dayKey,
    required this.exerciseId,
    required this.position,
    required this.sets,
    required this.reps,
    this.weightKg,
  });

  factory Accessory.fromJson(Map<String, Object?> j) => Accessory(
    id: j['id'] as String,
    dayKey: j['dayKey'] as String,
    exerciseId: j['exerciseId'] as String,
    position: j['position'] as int,
    sets: j['sets'] as int,
    reps: j['reps'] as int,
    weightKg: _num(j['weightKg']),
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'dayKey': dayKey,
    'exerciseId': exerciseId,
    'position': position,
    'sets': sets,
    'reps': reps,
    'weightKg': ?weightKg,
  };
}

class OneRmMeasurement {
  final String id;
  final String? exerciseId;
  final double weightKg;
  final DateTime measuredAt;
  final String? note;
  const OneRmMeasurement({
    required this.id,
    this.exerciseId,
    required this.weightKg,
    required this.measuredAt,
    this.note,
  });

  factory OneRmMeasurement.fromJson(Map<String, Object?> j) => OneRmMeasurement(
    id: j['id'] as String,
    exerciseId: j['exerciseId'] as String?,
    weightKg: _num(j['weightKg'])!,
    measuredAt: _dt(j['measuredAt'])!,
    note: j['note'] as String?,
  );

  /// exerciseId는 readOnly라 보내지 않는다.
  Map<String, Object?> toJson() => {
    'id': id,
    'weightKg': weightKg,
    'measuredAt': measuredAt.toUtc().toIso8601String(),
    'note': ?note,
  };
}

class RecordPoint {
  final double weightKg;
  final int reps;
  final double? e1rmKg;
  final String sessionId;
  final String setId;
  final DateTime achievedAt;
  const RecordPoint({
    required this.weightKg,
    required this.reps,
    this.e1rmKg,
    required this.sessionId,
    required this.setId,
    required this.achievedAt,
  });

  factory RecordPoint.fromJson(Map<String, Object?> j) => RecordPoint(
    weightKg: _num(j['weightKg'])!,
    reps: j['reps'] as int,
    e1rmKg: _num(j['e1rmKg']),
    sessionId: j['sessionId'] as String,
    setId: j['setId'] as String,
    achievedAt: _dt(j['achievedAt'])!,
  );
}

class ExerciseRecords {
  final String exerciseId;
  final String formula;
  final RecordPoint? bestWeight;
  final RecordPoint? bestE1rm;
  final OneRmMeasurement? latestMeasured;

  /// 횟수(1~10)별 최고 무게.
  final List<({int reps, RecordPoint point})> byReps;
  const ExerciseRecords({
    required this.exerciseId,
    required this.formula,
    this.bestWeight,
    this.bestE1rm,
    this.latestMeasured,
    this.byReps = const [],
  });

  factory ExerciseRecords.fromJson(Map<String, Object?> j) => ExerciseRecords(
    exerciseId: j['exerciseId'] as String,
    formula: j['formula'] as String,
    bestWeight: j['bestWeight'] == null ? null : RecordPoint.fromJson((j['bestWeight'] as Map).cast()),
    bestE1rm: j['bestE1rm'] == null ? null : RecordPoint.fromJson((j['bestE1rm'] as Map).cast()),
    latestMeasured: j['latestMeasured'] == null ? null : OneRmMeasurement.fromJson((j['latestMeasured'] as Map).cast()),
    byReps: [
      for (final r in (j['byReps'] as List? ?? const []))
        (reps: (r as Map)['reps'] as int, point: RecordPoint.fromJson((r['point'] as Map).cast())),
    ],
  );
}
