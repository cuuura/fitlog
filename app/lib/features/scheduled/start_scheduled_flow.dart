import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/routes.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/session_controller.dart';
import '../session/start_program_flow.dart' show prepareToStartSession;

/// 예정 운동 "시작"(scheduled-workout.md §5). 진행 중 세션이 있을 때는 프로그램 시작과 같이 동작한다
/// (비어 있는 자유 세션이면 버리고 시작할지 묻고, 그 밖이면 안내만 하고 멈춘다).
Future<void> startScheduledFlow(BuildContext context, WidgetRef ref, ScheduledWorkout workout) async {
  final l = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
  final controller = ref.read(sessionControllerProvider);
  try {
    if (!await prepareToStartSession(context, ref)) return;
    final s = await controller.startScheduled(workout);
    if (s.scheduledWorkoutId != workout.id) {
      // 다른 세션이 그대로 돌아온 경우.
      messenger.showSnackBar(SnackBar(content: Text(l.homeStartFinishFirst)));
      return;
    }
    router.push(Routes.session);
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l.schedStartError)));
  }
}
