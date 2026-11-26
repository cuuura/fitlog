// B1 소유. 프로그램 화면 공통: 정의 읽기, 세트 요약, 오류 문구.
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../domain/repositories.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';

List<Map<String, Object?>> programDays(Map<String, Object?> def) => [
  for (final d in (def['days'] as List? ?? const [])) (d as Map).cast<String, Object?>(),
];

/// 모든 날에 weekday가 있어야 FIXED_DATE를 쓸 수 있다.
bool programHasWeekdays(Map<String, Object?> def) {
  final days = programDays(def);
  return days.isNotEmpty && days.every((d) => d['weekday'] != null);
}

/// lifts[key].exercise → {id} 이면 id, {name} 이면 null.
String? liftExerciseId(Map<String, Object?> def, String key) {
  final lift = ((def['lifts'] as Map?)?[key] as Map?)?.cast<String, Object?>();
  final ex = (lift?['exercise'] as Map?)?.cast<String, Object?>();
  return ex?['id'] as String?;
}

String? liftExerciseName(Map<String, Object?> def, String key) {
  final lift = ((def['lifts'] as Map?)?[key] as Map?)?.cast<String, Object?>();
  final ex = (lift?['exercise'] as Map?)?.cast<String, Object?>();
  return ex?['name'] as String?;
}

/// 세트 요약. 같은 횟수 반복이면 "5×5", 아니면 "8,6,4,4+". 웜업 세트는 뺀다.
String summarizeSets(List<Object?> sets) {
  final reps = <String>[];
  var allSame = true;
  int? first;
  var anyAmrap = false;
  for (final raw in sets) {
    final s = (raw as Map).cast<String, Object?>();
    if (s['warmup'] == true) continue;
    final count = (s['count'] as num?)?.toInt() ?? 1;
    final r = (s['reps'] as num).toInt();
    final amrap = s['amrap'] == true;
    anyAmrap |= amrap;
    first ??= r;
    if (r != first) allSame = false;
    for (var i = 0; i < count; i++) {
      reps.add(amrap ? '$r+' : '$r');
    }
  }
  if (reps.isEmpty) return '';
  if (allSame && !anyAmrap && reps.length > 1) return '${reps.length}×$first';
  return reps.join(',');
}

/// lift 하나의 종목 정보. 종목을 못 찾으면 정의의 name, 그것도 없으면 키를 보인다.
class LiftRef {
  const LiftRef(this.exercise, this.fallback);
  final Exercise? exercise;
  final String fallback;
  String name(BuildContext context) => exercise == null ? fallback : exerciseDisplayName(context, exercise!);
}

Future<Map<String, LiftRef>> loadLiftRefs(ExerciseRepository repo, Map<String, Object?> def) async {
  final out = <String, LiftRef>{};
  final lifts = (def['lifts'] as Map?)?.keys.cast<String>() ?? const <String>[];
  for (final key in lifts) {
    final id = liftExerciseId(def, key);
    final e = id == null ? null : await repo.byId(id);
    out[key] = LiftRef(e, liftExerciseName(def, key) ?? key);
  }
  return out;
}

String weekdayLabel(AppLocalizations l, String w) => switch (w) {
  'MON' => l.programWeekdayMon,
  'TUE' => l.programWeekdayTue,
  'WED' => l.programWeekdayWed,
  'THU' => l.programWeekdayThu,
  'FRI' => l.programWeekdayFri,
  'SAT' => l.programWeekdaySat,
  _ => l.programWeekdaySun,
};

String statusLabel(AppLocalizations l, InstanceStatus s) => switch (s) {
  InstanceStatus.ACTIVE => l.instanceStatusActive,
  InstanceStatus.PAUSED => l.instanceStatusPaused,
  InstanceStatus.FINISHED => l.instanceStatusFinished,
};

/// 네트워크 오류면 오프라인 문구, 아니면 서버 메시지.
String errorMessage(AppLocalizations l, Object e, {String? fallback}) {
  if (e is ApiException) return e.isNetwork ? l.programsOffline : (e.message.isEmpty ? (fallback ?? l.commonError) : e.message);
  return fallback ?? l.commonError;
}

/// 오류(오프라인 포함)와 다시 시도 버튼.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorMessage(l, error, fallback: l.programsLoadError), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: Text(l.commonRetry)),
          ],
        ),
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? body,
  required String action,
}) async {
  final l = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
      ],
    ),
  );
  return ok ?? false;
}

/// 입력한 숫자(소수점 쉼표 허용). 비었거나 잘못되면 null.
double? parseNumber(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
