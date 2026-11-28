// 종목 바꾸기(PRG-7, 8.2): 종목 고르기 -> 프로그램 종목이면 "이번만 / 앞으로 계속" 시트 -> 교체.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/routes.dart';
import '../../core/ui/form_sheet.dart';
import '../../l10n/gen/app_localizations.dart';
import 'session_controller.dart';

/// 진행 중 세션의 종목 [se]를 바꾼다. 일반 종목은 고르면 바로 교체한다.
Future<void> swapSessionExercise(
  BuildContext context,
  WidgetRef ref, {
  required Session session,
  required SessionExercise se,
}) async {
  final ctrl = ref.read(sessionControllerProvider);
  final id = await context.push<String>(Routes.pickExercise);
  if (id == null || id == se.exerciseId || !context.mounted) return;
  if (!ctrl.canSwapPersistently(session, se)) {
    await ctrl.swapThisTime(se.id, id);
    return;
  }
  await showFormSheet<bool>(
    context,
    builder: (_) => SwapChoiceSheet(
      onThisTime: () async {
        await ctrl.swapThisTime(se.id, id);
        return true;
      },
      onPersistent: () async {
        await ctrl.swapPersistent(session, se, id);
        return true;
      },
    ),
  );
}

/// "이번만" / "앞으로 계속" 선택 시트. 실패하면 시트 안에 오류를 보여 준다(FormSheet).
class SwapChoiceSheet extends StatefulWidget {
  const SwapChoiceSheet({super.key, required this.onThisTime, required this.onPersistent});
  final Future<bool> Function() onThisTime;
  final Future<bool> Function() onPersistent;

  @override
  State<SwapChoiceSheet> createState() => _SwapChoiceSheetState();
}

class _SwapChoiceSheetState extends State<SwapChoiceSheet> {
  bool _persistent = false;

  Widget _option(Key key, String title, String desc, bool selected, VoidCallback onTap) => ListTile(
    key: key,
    selected: selected,
    contentPadding: EdgeInsets.zero,
    leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
    title: Text(title),
    subtitle: Text(desc),
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return FormSheet<bool>(
      title: l.sessionSwapTitle,
      submitLabel: l.sessionSwapSubmit,
      submitKey: const Key('swap-submit'),
      failureMessage: (_) => l.sessionSwapOnlineError,
      onSubmit: () => _persistent ? widget.onPersistent() : widget.onThisTime(),
      children: [
        _option(
          const Key('swap-once'),
          l.sessionSwapOnce,
          l.sessionSwapOnceDesc,
          !_persistent,
          () => setState(() => _persistent = false),
        ),
        _option(
          const Key('swap-always'),
          l.sessionSwapAlways,
          l.sessionSwapAlwaysDesc,
          _persistent,
          () => setState(() => _persistent = true),
        ),
      ],
    );
  }
}
