// 슈퍼세트 묶음 순수 함수(LOG-9). 묶음 = 한 세션에서 supersetGroup이 같은 종목들.
import '../../core/api/dto.dart';
import 'current_set.dart';

/// 묶음 이름 후보(색 띠 옆 글자). 묶음 값이 이미 짧은 글자면 그대로 쓴다.
const _letters = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];

/// 세션 안 묶음 값들(처음 나온 순서, 종목이 2개 이상인 묶음만).
List<String> supersetGroups(Session session) {
  final count = <String, int>{};
  for (final e in session.exercises) {
    final g = e.supersetGroup;
    if (g != null) count[g] = (count[g] ?? 0) + 1;
  }
  return [
    for (final g in count.keys)
      if (count[g]! >= 2) g,
  ];
}

/// 이 종목이 속한 (2개 이상짜리) 묶음 값. 혼자뿐이거나 묶음이 없으면 null.
String? groupOf(Session session, SessionExercise se) {
  final g = se.supersetGroup;
  if (g == null) return null;
  return session.exercises.where((e) => e.supersetGroup == g).length >= 2 ? g : null;
}

/// 묶음 색 번호(0부터, 처음 나온 순서). 묶음이 아니면 -1.
int groupColorIndex(Session session, SessionExercise se) {
  final g = groupOf(session, se);
  return g == null ? -1 : supersetGroups(session).indexOf(g);
}

/// 묶음 표시 글자: 값이 3자 이하면 그대로, 길면 묶음 순서의 A, B, ...
String groupLetter(Session session, String group) {
  if (group.length <= 3) return group;
  final i = supersetGroups(session).indexOf(group);
  return _letters[(i < 0 ? 0 : i) % _letters.length];
}

/// 새 묶음 값: 세션에서 안 쓰는 첫 글자(A~H).
String newGroupValue(Session session) {
  final used = {for (final e in session.exercises) e.supersetGroup};
  return _letters.firstWhere((g) => !used.contains(g), orElse: () => _letters.first);
}

/// "다음 종목과 묶기": [se] 와 바로 다음 종목([next])이 들어갈 묶음 값과 바뀔 종목들.
/// 이미 둘이 같은 묶음이면 빈 맵.
Map<String, String> bindWithNext(Session session, SessionExercise se, SessionExercise next) {
  if (se.supersetGroup != null && se.supersetGroup == next.supersetGroup) return const {};
  final g = se.supersetGroup ?? next.supersetGroup ?? newGroupValue(session);
  return {se.id: g, next.id: g};
}

/// "묶음 풀기": [se]를 풀고, 남은 종목이 하나뿐이면 그 종목도 푼다. (종목 id -> null)
List<String> unbindIds(Session session, SessionExercise se) {
  final g = se.supersetGroup;
  if (g == null) return const [];
  final rest = session.exercises.where((e) => e.supersetGroup == g && e.id != se.id).toList();
  return [se.id, if (rest.length == 1) rest.single.id];
}

/// [done] 세트를 완료한 직후, 휴식 타이머를 띄우지 않아야 하는지(5절).
/// - 다음 세트가 DROP이면 쉬지 않는다.
/// - 슈퍼세트에서 다음 세트가 같은 묶음의 뒤쪽 종목이면(아직 묶음 한 바퀴가 안 끝남) 쉬지 않는다.
bool skipRestAfter(Session session, SessionExercise se, CurrentSet? next) {
  if (next == null) return false;
  if (next.set.setType == SetType.DROP) return true;
  final g = se.supersetGroup;
  if (g == null || next.se.supersetGroup != g || next.se.id == se.id) return false;
  final order = [for (final e in session.exercises) e.id];
  return order.indexOf(next.se.id) > order.indexOf(se.id);
}
