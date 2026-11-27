import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../source_badge/source_badge.dart';
import 'active_session_page.dart' show confirmDialog;
import 'session_controller.dart';
import 'session_format.dart';

/// 끝난 세션 읽기 전용 보기. v0.1은 수정 없이 삭제만 된다.
class SessionDetailPage extends ConsumerWidget {
  const SessionDetailPage({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(sessionByIdProvider(sessionId));
    final exercises = ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};
    final unit = ref.watch(settingsProvider).weightUnit;
    final s = async.value;

    if (s == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.sessionDetailTitle)),
        body: Center(child: async.isLoading ? const CircularProgressIndicator() : Text(l.sessionNotFound)),
      );
    }
    final local = sessionLocalTime(s.startedAt, s.tz);
    return Scaffold(
      appBar: AppBar(
        title: Text(formatDate(local)),
        actions: [
          IconButton(
            key: const Key('detail-compare'),
            tooltip: l.progressCompareButton,
            icon: const Icon(Icons.compare_arrows),
            onPressed: () => context.push(Routes.sessionComparison(s.id)),
          ),
          IconButton(
            key: const Key('detail-edit'),
            tooltip: l.historyEdit,
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push(Routes.sessionEdit(s.id)),
          ),
          IconButton(
            key: const Key('detail-delete'),
            tooltip: l.commonDelete,
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await confirmDialog(
                context,
                title: l.sessionDetailDeleteConfirm,
                confirmLabel: l.commonDelete,
                confirmKey: const Key('detail-delete-confirm'),
              );
              if (!ok || !context.mounted) return;
              await ref.read(sessionControllerProvider).deleteSession(s.id);
              if (context.mounted) context.pop();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${formatClock(local)}'
            '${s.endedAt == null ? '' : ' - ${formatClock(sessionLocalTime(s.endedAt!, s.tz))}'}'
            ' · ${l.sessionVolume(formatVolume(sessionVolumeKg(s), unit))}',
            key: const Key('detail-header'),
            style: TextStyle(color: AppColors.of(context).fg2),
          ),
          if (s.source != null && s.source != SessionSource.APP)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SourceBadge(
                  key: const Key('detail-source-badge'),
                  source: s.source,
                  importBatchId: s.importBatchId,
                ),
              ),
            ),
          if (s.note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.note!)),
          const SizedBox(height: 12),
          for (final se in s.exercises)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Builder(
                      builder: (_) {
                        final ex = exercises[se.exerciseId];
                        return Text(
                          ex == null ? '…' : '${exerciseDisplayName(context, ex)} · ${typeLabel(l, ex.type)}',
                          style: Theme.of(context).textTheme.titleMedium,
                        );
                      },
                    ),
                    if (se.note != null) Text(se.note!, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    if (se.sets.isEmpty) Text(l.sessionNoSets),
                    for (var i = 0; i < se.sets.length; i++)
                      _line(context, l, se.sets[i], i, exercises[se.exerciseId]?.type ?? ExerciseType.BARBELL, unit),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, AppLocalizations l, WorkoutSet w, int i, ExerciseType type, WeightUnit unit) {
    final c = AppColors.of(context);
    final extra = [
      if (type == ExerciseType.DUMBBELL) l.sessionPerSide,
      if (w.rpe != null) '${l.sessionRpe} ${w.rpe}',
      if (w.rir != null) '${l.sessionRir} ${w.rir}',
      if (w.note != null) w.note!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 2,
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${w.isWarmup ? l.sessionWarmupShort : i + 1}',
              style: AppNum.table(context, color: c.fg2),
            ),
          ),
          Text(formatSetBrief(w, type, unit), style: AppNum.style(context, 20)),
          if (extra.isNotEmpty) Text(extra, style: TextStyle(fontSize: 12, color: c.fg2)),
        ],
      ),
    );
  }
}
