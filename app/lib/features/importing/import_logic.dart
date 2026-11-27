// B1 소유. 가져오기의 순수 함수: 코드 블록 벗기기, JSON 파싱, 큰 묶음 분할.
import 'dart:convert';

/// 서버 한도(import.md §1).
const importMaxSessions = 200;
const importMaxBodyMeasurements = 1000;
const importMaxScheduledWorkouts = 30;

/// AI가 붙이는 ```json … ``` 표시를 벗긴다. 표시가 없으면 앞뒤 공백만 뺀다.
String stripCodeFence(String text) {
  final t = text.trim();
  if (!t.contains('```')) return t;
  final block = RegExp(r'```[A-Za-z0-9_-]*[ \t]*\r?\n?([\s\S]*?)```').firstMatch(t);
  if (block != null) return block.group(1)!.trim();
  // 닫는 표시가 없으면 ``` 로 시작하는 줄만 지운다.
  return t.split('\n').where((l) => !l.trimLeft().startsWith('```')).join('\n').trim();
}

sealed class BundleParse {
  const BundleParse();
}

class BundleParsed extends BundleParse {
  final Map<String, Object?> bundle;
  const BundleParsed(this.bundle);
}

enum BundleParseProblem { empty, notObject, syntax }

class BundleParseError extends BundleParse {
  final BundleParseProblem problem;

  /// syntax일 때 벗긴 텍스트 기준 1부터 시작하는 위치.
  final int line;
  final int column;
  const BundleParseError(this.problem, {this.line = 0, this.column = 0});
}

BundleParse parseBundle(String raw) {
  final text = stripCodeFence(raw);
  if (text.isEmpty) return const BundleParseError(BundleParseProblem.empty);
  try {
    final v = jsonDecode(text);
    if (v is! Map) return const BundleParseError(BundleParseProblem.notObject);
    return BundleParsed(v.cast<String, Object?>());
  } on FormatException catch (e) {
    final off = (e.offset ?? 0).clamp(0, text.length);
    final before = text.substring(0, off);
    final line = '\n'.allMatches(before).length + 1;
    final column = off - (before.lastIndexOf('\n') + 1) + 1;
    return BundleParseError(BundleParseProblem.syntax, line: line, column: column);
  }
}

List<List<T>> _chunks<T>(List<T> l, int size) => [for (var i = 0; i < l.length; i += size) l.sublist(i, i + size > l.length ? l.length : i + size)];

/// 한도를 넘는 묶음을 순서대로 보낼 조각으로 나눈다. 한도 안이면 원본 하나.
/// 첫 조각에 exercises·programs·startPrograms·note와 첫 예정 운동·세션·체중 조각을 담고,
/// 나머지는 예정 운동 조각 → 세션 조각 → 체중 조각 순으로 해당 배열만 담는다.
/// (세션이 가리키는 예정이 먼저 저장되게 예정 조각을 세션 조각보다 앞에 둔다.)
List<Map<String, Object?>> splitBundle(Map<String, Object?> bundle) {
  final sessions = (bundle['sessions'] as List?) ?? const [];
  final bodies = (bundle['bodyMeasurements'] as List?) ?? const [];
  final scheduled = (bundle['scheduledWorkouts'] as List?) ?? const [];
  if (sessions.length <= importMaxSessions &&
      bodies.length <= importMaxBodyMeasurements &&
      scheduled.length <= importMaxScheduledWorkouts) {
    return [bundle];
  }

  final sChunks = _chunks<Object?>(sessions.cast(), importMaxSessions);
  final bChunks = _chunks<Object?>(bodies.cast(), importMaxBodyMeasurements);
  final scChunks = _chunks<Object?>(scheduled.cast(), importMaxScheduledWorkouts);
  final first = Map<String, Object?>.of(bundle)
    ..remove('sessions')
    ..remove('bodyMeasurements')
    ..remove('scheduledWorkouts');
  if (scChunks.isNotEmpty) first['scheduledWorkouts'] = scChunks.first;
  if (sChunks.isNotEmpty) first['sessions'] = sChunks.first;
  if (bChunks.isNotEmpty) first['bodyMeasurements'] = bChunks.first;
  final version = bundle['schemaVersion'] ?? 1;
  return [
    first,
    for (final w in scChunks.skip(1)) {'schemaVersion': version, 'scheduledWorkouts': w},
    for (final s in sChunks.skip(1)) {'schemaVersion': version, 'sessions': s},
    for (final b in bChunks.skip(1)) {'schemaVersion': version, 'bodyMeasurements': b},
  ];
}
