// B2 소유. 가져오기 이력·삭제 요청이 같이 쓰는 라벨.
import '../../l10n/gen/app_localizations.dart';

/// 서버 entity 이름 → 사용자에게 보일 이름.
String aiEntityLabel(AppLocalizations l, String entity) => switch (entity) {
  'exercise' => l.aiEntityExercise,
  'program' => l.aiEntityProgram,
  'program_instance' => l.aiEntityProgramInstance,
  'workout_session' => l.aiEntitySession,
  'body_measurement' => l.aiEntityBody,
  _ => entity,
};

/// "세션 3개" 형태.
String aiEntityCount(AppLocalizations l, String entity, int n) => switch (entity) {
  'exercise' => l.aiCountExercise(n),
  'program' => l.aiCountProgram(n),
  'program_instance' => l.aiCountProgramInstance(n),
  'workout_session' => l.aiCountSession(n),
  'body_measurement' => l.aiCountBody(n),
  _ => '$entity $n',
};

/// 화면에 보여주는 순서.
const aiEntityOrder = ['workout_session', 'program', 'program_instance', 'exercise', 'body_measurement'];

String _two(int v) => v.toString().padLeft(2, '0');

/// UTC 시각을 로컬 "2026-11-26 18:00"로.
String aiDateTime(DateTime utc) {
  final t = utc.toLocal();
  return '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
}
