// 프로그램 편집기의 정의 모델. 정의(program.schema.json)를 Map 그대로 들고 있어서
// 편집기가 모르는 필드(weekly, family, derive, rules …)는 손대지 않고 그대로 저장된다.
import 'dart:convert';

typedef Json = Map<String, dynamic>;

/// JSON으로 표현 가능한 값의 깊은 복사.
T deepCopy<T>(T v) => jsonDecode(jsonEncode(v)) as T;

const kWeekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
const kRuleTypes = ['NONE', 'LINEAR', 'DOUBLE', 'STAGES', 'AMRAP_TABLE', 'CYCLE', 'CUSTOM'];
const kLoadTypes = ['PERCENT_TM', 'WORKING', 'FIXED', 'BODYWEIGHT', 'NONE'];

final _liftKeyRe = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
bool isValidLiftKey(String k) => _liftKeyRe.hasMatch(k);

class ProgramDef {
  ProgramDef(Json json) : json = deepCopy(json);

  /// 새 프로그램의 빈 정의. 날 하나만 들어 있다.
  factory ProgramDef.blank({String dayName = '1일차'}) => ProgramDef({
    'schemaVersion': 1,
    'name': '',
    'lifts': <String, dynamic>{},
    'days': [
      {'key': 'A', 'name': dayName, 'exercises': <dynamic>[]},
    ],
  });

  final Json json;

  /// 저장용 사본. 안 쓰는 종목 키·규칙을 정리한다([keepUnused]는 처음부터 안 쓰던 키라 그대로 둔다).
  Json toJson({Set<String> keepUnused = const {}}) {
    final out = deepCopy(json);
    final used = usedLiftKeys(out);
    final lifts = (out['lifts'] as Map?)?.cast<String, dynamic>();
    if (lifts != null) {
      lifts.removeWhere((k, _) => !used.contains(k) && !keepUnused.contains(k));
    }
    final prog = (out['progression'] as Map?)?.cast<String, dynamic>();
    if (prog != null) {
      prog.removeWhere((k, _) => lifts == null || !lifts.containsKey(k));
      if (prog.isEmpty) out.remove('progression');
    }
    return out;
  }

  /// 지금 정의에서 쓰이지 않는 종목 키.
  Set<String> unusedLiftKeys() {
    final used = usedLiftKeys(json);
    return {
      for (final k in lifts.keys)
        if (!used.contains(k)) k,
    };
  }

  /// 날 안 종목, 다른 종목의 tmFrom·derive.from·load.of 가 가리키는 키.
  static Set<String> usedLiftKeys(Json def) {
    final used = <String>{};
    for (final d in (def['days'] as List? ?? const [])) {
      for (final e in ((d as Map)['exercises'] as List? ?? const [])) {
        final lift = (e as Map)['lift'];
        if (lift is String) used.add(lift);
        for (final s in (e['sets'] as List? ?? const [])) {
          final of = (((s as Map)['load']) as Map?)?['of'];
          if (of is String) used.add(of);
        }
      }
    }
    for (final l in ((def['lifts'] as Map?)?.values ?? const <dynamic>[])) {
      if (l is Map) {
        if (l['tmFrom'] is String) used.add(l['tmFrom'] as String);
        final from = (l['derive'] as Map?)?['from'];
        if (from is String) used.add(from);
      }
    }
    return used;
  }

  // ---------- 읽기 ----------
  Json get lifts => (json['lifts'] ??= <String, dynamic>{}) as Json;
  Json get progression => (json['progression'] ??= <String, dynamic>{}) as Json;
  List<dynamic> get days => (json['days'] ??= <dynamic>[]) as List<dynamic>;
  Json day(int i) => days[i] as Json;
  List<dynamic> exercises(int day) => (this.day(day)['exercises'] ??= <dynamic>[]) as List<dynamic>;
  Json exercise(int day, int ex) => exercises(day)[ex] as Json;
  List<dynamic> sets(int day, int ex) => (exercise(day, ex)['sets'] ??= <dynamic>[]) as List<dynamic>;

  /// 종목 키가 가리키는 종목 id. 이름으로만 적혀 있으면 null.
  String? liftExerciseId(String key) {
    final ex = (lifts[key] as Map?)?['exercise'];
    final id = ex is Map ? ex['id'] : null;
    return id is String ? id : null;
  }

  String? liftExerciseName(String key) {
    final ex = (lifts[key] as Map?)?['exercise'];
    final n = ex is Map ? ex['name'] : null;
    return n is String ? n : null;
  }

  String ruleType(String key) {
    final r = progression[key];
    return r is Map && r['type'] is String ? r['type'] as String : 'NONE';
  }

  /// 이 키를 쓰는 날 안 종목 수.
  int usageCount(String key) {
    var n = 0;
    for (var d = 0; d < days.length; d++) {
      for (final e in exercises(d)) {
        if ((e as Map)['lift'] == key) n++;
      }
    }
    return n;
  }

  // ---------- 키 만들기 ----------
  /// 이름에서 알파벳·숫자만 뽑아 종목 키 후보를 만든다. 쓸 글자가 없으면 'lift'.
  static String liftKeyBase(String? name) {
    final s = (name ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    var out = s;
    if (out.isEmpty) {
      out = 'lift';
    } else if (!RegExp(r'^[a-z]').hasMatch(out)) {
      out = 'lift_$out';
    }
    return out.length > 28 ? out.substring(0, 28) : out;
  }

  String newLiftKey(String? name) {
    final base = liftKeyBase(name);
    if (!lifts.containsKey(base)) return base;
    for (var i = 2;; i++) {
      final k = '${base}_$i';
      if (!lifts.containsKey(k)) return k;
    }
  }

  String newDayKey() {
    final used = {for (final d in days) (d as Map)['key']};
    for (var i = 0; i < 26; i++) {
      final k = String.fromCharCode(65 + i);
      if (!used.contains(k)) return k;
    }
    for (var i = 1;; i++) {
      final k = 'D$i';
      if (!used.contains(k)) return k;
    }
  }

  // ---------- 고치기 ----------
  Json addDay(String name) {
    final d = <String, dynamic>{'key': newDayKey(), 'name': name, 'exercises': <dynamic>[]};
    days.add(d);
    return d;
  }

  void removeDay(int i) => days.removeAt(i);

  void moveDay(int from, int to) => days.insert(to, days.removeAt(from));

  /// 종목을 날에 넣는다. 같은 종목(id)을 가리키는 키가 이미 있으면 그 키를 쓰고, 없으면 새 키.
  /// 돌려주는 값은 쓴 종목 키.
  String addExercise(int dayIndex, {required String exerciseId, String? nameForKey}) {
    var key = lifts.keys.where((k) => liftExerciseId(k) == exerciseId).firstOrNull;
    if (key == null) {
      key = newLiftKey(nameForKey);
      lifts[key] = {
        'exercise': {'id': exerciseId},
      };
    }
    exercises(dayIndex).add({
      'lift': key,
      'sets': [defaultSet()],
    });
    return key;
  }

  void moveExercise(int day, int from, int to) {
    final l = exercises(day);
    l.insert(to, l.removeAt(from));
  }

  void setRuleType(String key, String type) {
    if (ruleType(key) == type) return;
    if (type == 'NONE') {
      progression.remove(key);
    } else {
      progression[key] = defaultRule(type);
    }
  }

  static Json defaultRule(String type) => switch (type) {
    'LINEAR' => {'type': 'LINEAR', 'incrementKg': 2.5, 'failuresBeforeDeload': 3, 'deloadPercent': 0.1},
    'DOUBLE' => {'type': 'DOUBLE', 'incrementKg': 2.5, 'failuresBeforeDeload': 3, 'deloadPercent': 0.1},
    'CYCLE' => {'type': 'CYCLE', 'incrementKg': 2.5, 'deloadPercent': 0.1},
    'STAGES' => {
      'type': 'STAGES',
      'incrementKg': 2.5,
      'deloadPercent': 0.15,
      'stages': [
        {'sets': 5, 'reps': 3},
        {'sets': 6, 'reps': 2},
      ],
    },
    'AMRAP_TABLE' => {
      'type': 'AMRAP_TABLE',
      'applyAt': 'WEEK_END',
      'failuresBeforeDeload': 2,
      'deloadPercent': 0.1,
      'table': [
        {'minReps': 0, 'maxReps': 1, 'incrementKg': 0},
        {'minReps': 2, 'incrementKg': 2.5},
      ],
    },
    'CUSTOM' => {
      'type': 'CUSTOM',
      'target': 'WORKING',
      'applyAt': 'SESSION',
      'success': {'when': 'ALL_SETS', 'afterConsecutive': 1, 'method': 'ADD_KG', 'amount': 2.5},
    },
    _ => {'type': 'NONE'},
  };

  static Json defaultSet() => {
    'count': 3,
    'reps': 5,
    'load': {'type': 'WORKING'},
  };

  /// 세트에 주차별 덮어쓰기가 있는지.
  static bool hasWeekly(Json set) => set['weekly'] is List && (set['weekly'] as List).isNotEmpty;
}
