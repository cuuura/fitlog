import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/routes.dart';
import '../../core/ui/confirm.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import 'scheduled_logic.dart';
import 'start_scheduled_flow.dart';

enum ScheduledMenuAction { edit, skip, unskip, delete }

/// 카드·목록 줄의 더보기 메뉴. 상태에 따라 건너뛰기/건너뛰기 취소를 보인다.
class ScheduledMenu extends ConsumerWidget {
  const ScheduledMenu({super.key, required this.view});
  final ScheduledView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final id = view.id;
    return PopupMenuButton<ScheduledMenuAction>(
      key: Key('sched-menu-$id'),
      tooltip: l.schedMenuTooltip,
      onSelected: (a) => runScheduledAction(context, ref, view, a),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: ScheduledMenuAction.edit,
          child: Text(l.schedMenuEdit, key: Key('sched-menu-edit-$id')),
        ),
        if (view.status == ScheduledStatus.PLANNED)
          PopupMenuItem(
            value: ScheduledMenuAction.skip,
            child: Text(l.schedMenuSkip, key: Key('sched-menu-skip-$id')),
          ),
        if (view.status == ScheduledStatus.SKIPPED)
          PopupMenuItem(
            value: ScheduledMenuAction.unskip,
            child: Text(l.schedMenuUnskip, key: Key('sched-menu-unskip-$id')),
          ),
        PopupMenuItem(
          value: ScheduledMenuAction.delete,
          child: Text(l.schedMenuDelete, key: Key('sched-menu-delete-$id')),
        ),
      ],
    );
  }
}

Future<void> runScheduledAction(
  BuildContext context,
  WidgetRef ref,
  ScheduledView view,
  ScheduledMenuAction action,
) async {
  final l = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final repo = ref.read(scheduledWorkoutRepositoryProvider);
  try {
    switch (action) {
      case ScheduledMenuAction.edit:
        context.push(Routes.scheduledEdit(view.id));
      case ScheduledMenuAction.skip:
        await repo.setSkipped(view.id, true);
      case ScheduledMenuAction.unskip:
        await repo.setSkipped(view.id, false);
      case ScheduledMenuAction.delete:
        final ok = await confirmAction(
          context,
          title: l.schedDeleteTitle,
          body: l.schedDeleteBody(view.workout.title),
          action: l.schedMenuDelete,
          destructive: true,
        );
        if (ok) await repo.delete(view.id);
    }
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l.schedActionError)));
  }
}

/// "시작"/"이어서"를 눌렀을 때. 진행 중이면 세션 화면으로, 아니면 시작한다.
Future<void> startOrResume(BuildContext context, WidgetRef ref, ScheduledView view) async {
  if (view.status == ScheduledStatus.IN_PROGRESS) {
    context.push(Routes.session);
    return;
  }
  await startScheduledFlow(context, ref, view.workout);
}
