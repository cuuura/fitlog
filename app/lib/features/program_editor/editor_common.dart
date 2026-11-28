// 편집기 공통: 검증 에러 경로 매칭, 종목 이름 캐시, 세트 한 줄 요약.
import '../../core/api/dto.dart';
import '../../domain/repositories.dart';
import 'editor_fields.dart';
import 'editor_text.dart';
import 'program_definition.dart';

/// 서버 검증 에러(JSON 포인터 경로)를 칸 아래에 붙이기 쉽게 다룬다.
class EditorErrors {
  const EditorErrors(this.items);
  static const none = EditorErrors([]);
  final List<({String path, String message})> items;

  bool get isEmpty => items.isEmpty;

  /// 정확히 이 경로의 에러.
  List<String> at(String path) => [
    for (final e in items)
      if (e.path == path) e.message,
  ];

  /// 이 경로 또는 그 아래 경로의 에러.
  List<String> under(String prefix) => [
    for (final e in items)
      if (e.path == prefix || e.path.startsWith('$prefix/')) e.message,
  ];

  String? textAt(String path) {
    final l = at(path);
    return l.isEmpty ? null : l.join('\n');
  }

  /// [claimed] 중 어느 것에도 안 걸리는(화면에 자리를 못 찾은) 에러.
  List<({String path, String message})> unclaimed(Iterable<String> exact, Iterable<String> prefixes) => [
    for (final e in items)
      if (!exact.contains(e.path) && !prefixes.any((p) => e.path == p || e.path.startsWith('$p/'))) e,
  ];
}

/// 종목 id → 화면 이름. 화면이 열려 있는 동안만 쓴다.
class LiftNames {
  LiftNames(this._repo);
  final ExerciseRepository _repo;
  final Map<String, String> _byId = {};

  void put(String id, String name) => _byId[id] = name;

  Future<void> loadFor(ProgramDef def) async {
    for (final key in def.lifts.keys.toList()) {
      final id = def.liftExerciseId(key);
      if (id == null || _byId.containsKey(id)) continue;
      try {
        final e = await _repo.byId(id);
        if (e != null) _byId[id] = e.nameKo;
      } catch (_) {}
    }
  }

  /// 종목 키의 화면 이름. 모르면 키 그대로.
  String labelFor(ProgramDef def, String key) {
    final id = def.liftExerciseId(key);
    if (id != null && _byId[id] != null) return _byId[id]!;
    return def.liftExerciseName(key) ?? key;
  }

  Map<String, String> labels(ProgramDef def) => {for (final k in def.lifts.keys) k: labelFor(def, k)};
}

/// 종목 키 만들 때 쓸 영문 이름 후보.
String keyNameOf(Exercise e) => (e.nameEn?.isNotEmpty ?? false) ? e.nameEn! : e.primaryMuscle.name;

/// 세트 한 줄 요약: "3×5 · TM의 85% · AMRAP".
String setSummary(Json set) {
  final count = set['count'] is num ? (set['count'] as num).toInt() : 1;
  final reps = set['reps'] is num ? fmtNum(set['reps'] as num) : '?';
  final max = set['repsMax'] is num ? '~${fmtNum(set['repsMax'] as num)}' : '';
  final parts = <String>['$count×$reps$max'];
  final load = set['load'];
  if (load is Map) {
    String pct(Object? v) => v is num ? '${fmtNum(v * 100)}%' : '';
    switch (load['type']) {
      case 'PERCENT_TM':
        parts.add('TM ${pct(load['value'])}');
      case 'WORKING':
        parts.add(load['value'] is num && load['value'] != 1 ? '작업 무게 ${pct(load['value'])}' : '작업 무게');
      case 'FIXED':
        parts.add('${fmtNum(load['kg'] as num?)}kg');
      case 'BODYWEIGHT':
        parts.add('맨몸');
      default:
        parts.add('직접 정함');
    }
  }
  if (set['amrap'] == true) parts.add('AMRAP');
  if (set['warmup'] == true) parts.add(ET.warmup);
  if (set['drop'] == true) parts.add('드롭');
  if (set['restSec'] is num) parts.add('휴식 ${fmtNum(set['restSec'] as num)}초');
  return parts.join(' · ');
}
