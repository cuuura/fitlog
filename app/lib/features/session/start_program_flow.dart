import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/routes.dart';
import '../../core/ui/confirm.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import 'session_controller.dart';

/// 새 세션을 시작해도 되는지 확인한다(프로그램 회차·예정 운동 시작이 같이 쓴다).
/// 진행 중 세션이 비어 있는 자유 세션이면 버리고 시작할지 묻고, 그 밖의 진행 중 세션이 있으면
/// 안내만 하고 false를 돌려준다. (startSession이 기존 활성 세션을 그대로 돌려주는 것을 막는다.)
/// 시작해도 되면 true(필요하면 비어 있는 자유 세션을 지운 뒤).
Future<bool> prepareToStartSession(BuildContext context, WidgetRef ref) async {
  final l = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final controller = ref.read(sessionControllerProvider);
  final active = await ref.read(sessionRepositoryProvider).watchActiveSession().first;
  if (active == null) return true;
  final emptyFree = active.programInstanceId == null && active.exercises.every((e) => e.sets.isEmpty);
  if (!emptyFree) {
    messenger.showSnackBar(SnackBar(content: Text(l.homeStartFinishFirst)));
    return false;
  }
  if (!context.mounted) return false;
  final ok = await confirmAction(
    context,
    title: l.homeStartDiscardTitle,
    body: l.homeStartDiscardBody,
    action: l.homeStartDiscardAction,
    destructive: true,
    dialogKey: const Key('discard-free-dialog'),
    cancelKey: const Key('discard-free-cancel'),
    confirmKey: const Key('discard-free-confirm'),
  );
  if (!ok) return false;
  await controller.deleteSession(active.id);
  return true;
}

/// 프로그램 회차를 시작하는 공통 진입점(홈·프로그램 상세).
Future<void> startProgramFlow(
  BuildContext context,
  WidgetRef ref, {
  required String instanceId,
  required String programName,
}) async {
  final l = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
  final controller = ref.read(sessionControllerProvider);
  try {
    if (!await prepareToStartSession(context, ref)) return;
    final s = await controller.startProgram(instanceId, programName: programName);
    if (s.programInstanceId != instanceId) {
      // 다른 세션이 그대로 돌아온 경우: 계획이 없는 화면으로 보내지 않는다.
      messenger.showSnackBar(SnackBar(content: Text(l.homeStartFinishFirst)));
      return;
    }
    router.push(Routes.session);
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l.homePlanStartError)));
  }
}
