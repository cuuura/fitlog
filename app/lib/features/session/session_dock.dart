// 세션 화면 하단: "N세트 완료" 버튼 + 휴식 타이머 막대(다음 세트 안내 포함).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../rest_timer/rest_timer_bar.dart';
import 'current_set.dart';
import 'set_row.dart';
import 'session_format.dart';

class SessionDock extends ConsumerWidget {
  const SessionDock({
    super.key,
    required this.session,
    required this.exercises,
  });
  final Session session;
  final Map<String, Exercise> exercises;

  String _name(BuildContext context, SessionExercise se) {
    final e = exercises[se.exerciseId];
    return e == null ? '…' : exerciseDisplayName(context, e);
  }

  /// 가장 최근에 완료한 세트의 종목(없으면 null).
  SessionExercise? _lastDoneExercise() {
    SessionExercise? best;
    DateTime? at;
    for (final e in session.exercises) {
      for (final w in e.sets) {
        final c = w.completedAt;
        if (c != null && (at == null || c.isAfter(at))) {
          at = c;
          best = e;
        }
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider.select((s) => s.weightUnit));
    final cur = currentSetOf(session);
    final hasSets = session.exercises.any((e) => e.sets.isNotEmpty);

    String? nextText;
    Widget? button;
    if (cur != null) {
      final type = exercises[cur.se.exerciseId]?.type ?? ExerciseType.BARBELL;
      final name = _name(context, cur.se);
      final label = setLongLabel(l, cur.se, cur.set);
      final summary = formatSetBrief(cur.set, type, unit);
      final last = _lastDoneExercise();
      nextText = (last == null || last.id == cur.se.id)
          ? l.sessionCurNext(label, summary)
          : l.sessionCurNextOther(name, label, summary);
      button = FilledButton(
        key: const Key('complete-current'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: () => completeSetChecked(
          context,
          ref,
          session: session,
          se: cur.se,
          set: cur.set,
          type: type,
          exerciseName: name,
          done: true,
          n: cur.se.sets.indexOf(cur.set) + 1,
        ),
        child: Text(
          l.sessionCurComplete(name, label),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
    } else if (hasSets) {
      button = FilledButton(
        key: const Key('complete-current'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: null,
        child: Text(l.sessionCurAllDone),
      );
    }

    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 휴식 중엔 남은 시간이 가장 먼저 보이도록 막대를 버튼 위에 둔다(목업 4).
            RestTimerBar(nextText: nextText),
            if (button != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: SizedBox(width: double.infinity, child: button),
              ),
          ],
        ),
      ),
    );
  }
}
