// ignore_for_file: constant_identifier_names
// contracts/v0.3/openapi.yaml 스키마(가져오기·삭제 요청·AI 연결·MCP 안내)를 손으로 옮긴 DTO. 트랙 리드 소유.
// 묶음(bundle)은 import.schema.json 형식이며 앱은 Map 그대로 다룬다(검증·해석은 서버).

DateTime? _dt(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();
T _enumByName<T extends Enum>(List<T> values, Object? name) =>
    values.firstWhere((e) => e.name == name, orElse: () => throw FormatException('unknown enum $name for $T'));
Map<String, Object?>? _obj(Object? v) => (v as Map?)?.cast<String, Object?>();

enum ResolutionAction { SKIP, KEEP_BOTH, REPLACE, MAP_TO, CREATE, UNLINK, SET }

enum ConflictCode {
  UNKNOWN_EXERCISE,
  SESSION_OVERLAP,
  BODY_SAME_DAY,
  PROGRAM_NAME_EXISTS,
  ID_EXISTS,
  PLAN_MISMATCH,
  INSTANCE_NEEDS_VALUE,
}

enum OnConflict { ASK, SKIP_ALL }

enum ImportChannel { APP_JSON, MCP }

enum DeletionStatus { PENDING, APPROVED, REJECTED, EXPIRED }

/// 앱 붙여넣기에서 사용자가 고르는 AI 이름(ImportRequest.clientName). 화면 표시 문구는 arb.
const importClientNames = ['Claude', 'ChatGPT', 'Gemini', '기타'];

class Resolution {
  final ResolutionAction action;

  /// MAP_TO
  final String? exerciseId;

  /// CREATE: { type, primaryMuscle, nameKo?, nameEn? }
  final Map<String, Object?>? exercise;

  /// SET: { tm?: {키: kg}, working?: {키: kg} }
  final Map<String, Object?>? value;
  const Resolution(this.action, {this.exerciseId, this.exercise, this.value});

  Map<String, Object?> toJson() => {
    'action': action.name,
    'exerciseId': ?exerciseId,
    'exercise': ?exercise,
    'value': ?value,
  };
}

class ImportRequest {
  /// import.schema.json 묶음.
  final Map<String, Object?> bundle;
  final String? clientName;
  final String? tz;
  final OnConflict onConflict;

  /// conflictId → 해결.
  final Map<String, Resolution> resolutions;
  const ImportRequest({
    required this.bundle,
    this.clientName,
    this.tz,
    this.onConflict = OnConflict.ASK,
    this.resolutions = const {},
  });

  Map<String, Object?> toJson() => {
    'bundle': bundle,
    'channel': 'APP_JSON',
    'clientName': ?clientName,
    'tz': ?tz,
    'onConflict': onConflict.name,
    if (resolutions.isNotEmpty) 'resolutions': {for (final e in resolutions.entries) e.key: e.value.toJson()},
  };

  ImportRequest withResolutions(Map<String, Resolution> r) =>
      ImportRequest(bundle: bundle, clientName: clientName, tz: tz, onConflict: onConflict, resolutions: r);
}

class ExerciseCandidate {
  final String exerciseId;
  final String? nameKo;
  final String? nameEn;
  const ExerciseCandidate({required this.exerciseId, this.nameKo, this.nameEn});
  factory ExerciseCandidate.fromJson(Map<String, Object?> j) => ExerciseCandidate(
    exerciseId: j['exerciseId'] as String,
    nameKo: j['nameKo'] as String?,
    nameEn: j['nameEn'] as String?,
  );
}

class Conflict {
  /// "{code}:{JSON 포인터}" — 같은 묶음이면 항상 같다.
  final String conflictId;

  /// 서버가 모르는 코드가 오면 null(화면은 message만 보여준다).
  final ConflictCode? code;
  final String path;
  final String message;
  final List<ResolutionAction> allowed;
  final Map<String, Object?>? existing;
  final List<ExerciseCandidate> candidates;
  final Map<String, Object?>? suggested;
  const Conflict({
    required this.conflictId,
    this.code,
    required this.path,
    required this.message,
    required this.allowed,
    this.existing,
    this.candidates = const [],
    this.suggested,
  });

  factory Conflict.fromJson(Map<String, Object?> j) => Conflict(
    conflictId: j['conflictId'] as String,
    code: ConflictCode.values.where((c) => c.name == j['code']).firstOrNull,
    path: j['path'] as String? ?? '',
    message: j['message'] as String? ?? '',
    allowed: [
      for (final a in (j['allowed'] as List? ?? const [])) ...ResolutionAction.values.where((r) => r.name == a),
    ],
    existing: _obj(j['existing']),
    candidates: [for (final c in (j['candidates'] as List? ?? const [])) ExerciseCandidate.fromJson((c as Map).cast())],
    suggested: _obj(j['suggested']),
  );
}

class ImportPreview {
  final bool valid;

  /// 종류 → { NEW|UNCHANGED|REPLACE|SKIP: 개수 }. 예: { sessions: { NEW: 3 } }
  final Map<String, Map<String, int>> counts;
  final List<Conflict> conflicts;
  final List<String> unresolved;
  const ImportPreview({
    required this.valid,
    this.counts = const {},
    this.conflicts = const [],
    this.unresolved = const [],
  });

  bool get hasUnresolved => unresolved.isNotEmpty;

  factory ImportPreview.fromJson(Map<String, Object?> j) => ImportPreview(
    valid: j['valid'] as bool? ?? false,
    counts: {
      for (final e in ((j['counts'] as Map?) ?? const {}).entries)
        e.key as String: {
          for (final c in ((e.value as Map?) ?? const {}).entries) c.key as String: (c.value as num).toInt(),
        },
    },
    conflicts: [for (final c in (j['conflicts'] as List? ?? const [])) Conflict.fromJson((c as Map).cast())],
    unresolved: [for (final u in (j['unresolved'] as List? ?? const [])) u as String],
  );
}

class ImportBatch {
  final String id;
  final DateTime createdAt;
  final ImportChannel channel;
  final String? clientName;
  final String? note;

  /// 예: { sessions: 3, programs: 1, replaced: 1 }
  final Map<String, int> summary;
  final DateTime? revertedAt;
  const ImportBatch({
    required this.id,
    required this.createdAt,
    required this.channel,
    this.clientName,
    this.note,
    this.summary = const {},
    this.revertedAt,
  });

  bool get isReverted => revertedAt != null;

  factory ImportBatch.fromJson(Map<String, Object?> j) => ImportBatch(
    id: j['id'] as String,
    createdAt: _dt(j['createdAt'])!,
    channel: _enumByName(ImportChannel.values, j['channel']),
    clientName: j['clientName'] as String?,
    note: j['note'] as String?,
    summary: {for (final e in ((j['summary'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt()},
    revertedAt: _dt(j['revertedAt']),
  );
}

enum ImportItemAction { CREATED, REPLACED_OLD }

class ImportItem {
  /// exercise | program | program_instance | workout_session | body_measurement
  final String entity;
  final String entityId;
  final ImportItemAction action;
  final String? label;
  const ImportItem({required this.entity, required this.entityId, required this.action, this.label});
  factory ImportItem.fromJson(Map<String, Object?> j) => ImportItem(
    entity: j['entity'] as String,
    entityId: j['entityId'] as String,
    action: _enumByName(ImportItemAction.values, j['action']),
    label: j['label'] as String?,
  );
}

class ImportBatchDetail extends ImportBatch {
  final List<ImportItem> items;
  const ImportBatchDetail({
    required super.id,
    required super.createdAt,
    required super.channel,
    super.clientName,
    super.note,
    super.summary,
    super.revertedAt,
    this.items = const [],
  });

  factory ImportBatchDetail.fromJson(Map<String, Object?> j) {
    final b = ImportBatch.fromJson(j);
    return ImportBatchDetail(
      id: b.id,
      createdAt: b.createdAt,
      channel: b.channel,
      clientName: b.clientName,
      note: b.note,
      summary: b.summary,
      revertedAt: b.revertedAt,
      items: [for (final i in (j['items'] as List? ?? const [])) ImportItem.fromJson((i as Map).cast())],
    );
  }
}

/// POST /v1/imports 결과: 저장됐으면 batch(201 또는 200), 해결 안 된 충돌이 있으면 preview(409).
class ImportOutcome {
  final ImportBatch? batch;
  final ImportPreview? preview;
  const ImportOutcome.saved(ImportBatch this.batch) : preview = null;
  const ImportOutcome.needsResolution(ImportPreview this.preview) : batch = null;
  bool get saved => batch != null;
}

class DeletionRequest {
  /// workout_session | program | program_instance | exercise | body_measurement
  final String entity;
  final String id;
  final String entityId;
  final String? label;
  final String? reason;
  final String? clientName;
  final DeletionStatus status;
  final String? note;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? decidedAt;
  const DeletionRequest({
    required this.id,
    required this.entity,
    required this.entityId,
    this.label,
    this.reason,
    this.clientName,
    required this.status,
    this.note,
    required this.createdAt,
    required this.expiresAt,
    this.decidedAt,
  });

  factory DeletionRequest.fromJson(Map<String, Object?> j) => DeletionRequest(
    id: j['id'] as String,
    entity: j['entity'] as String,
    entityId: j['entityId'] as String,
    label: j['label'] as String?,
    reason: j['reason'] as String?,
    clientName: j['clientName'] as String?,
    status: _enumByName(DeletionStatus.values, j['status']),
    note: j['note'] as String?,
    createdAt: _dt(j['createdAt'])!,
    expiresAt: _dt(j['expiresAt'])!,
    decidedAt: _dt(j['decidedAt']),
  );
}

class AiConnection {
  final String id;
  final String clientName;

  /// fitlog.read, fitlog.write
  final List<String> scopes;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  const AiConnection({
    required this.id,
    required this.clientName,
    required this.scopes,
    required this.createdAt,
    this.lastUsedAt,
  });

  bool get canWrite => scopes.contains('fitlog.write');

  factory AiConnection.fromJson(Map<String, Object?> j) => AiConnection(
    id: j['id'] as String,
    clientName: j['clientName'] as String,
    scopes: [for (final s in (j['scopes'] as List? ?? const [])) s as String],
    createdAt: _dt(j['createdAt'])!,
    lastUsedAt: _dt(j['lastUsedAt']),
  );
}

class McpClientGuide {
  /// claude | chatgpt | gemini
  final String key;
  final String name;
  final List<String> steps;
  final String? docUrl;
  const McpClientGuide({required this.key, required this.name, this.steps = const [], this.docUrl});
  factory McpClientGuide.fromJson(Map<String, Object?> j) => McpClientGuide(
    key: j['key'] as String,
    name: j['name'] as String,
    steps: [for (final s in (j['steps'] as List? ?? const [])) s as String],
    docUrl: j['docUrl'] as String?,
  );
}

class McpInfo {
  final String mcpUrl;
  final List<McpClientGuide> clients;
  const McpInfo({required this.mcpUrl, this.clients = const []});
  factory McpInfo.fromJson(Map<String, Object?> j) => McpInfo(
    mcpUrl: j['mcpUrl'] as String,
    clients: [for (final c in (j['clients'] as List? ?? const [])) McpClientGuide.fromJson((c as Map).cast())],
  );
}

enum CsvKind { sets, body }
