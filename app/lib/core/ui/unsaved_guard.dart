import 'package:material_ui/material_ui.dart';

import '../../l10n/gen/app_localizations.dart';
import 'confirm.dart';

/// 저장 버튼이 있는 "화면"에서 고친 채로 나가려 하면 묻는다.
class UnsavedGuard extends StatelessWidget {
  const UnsavedGuard({super.key, required this.dirty, required this.child});
  final bool dirty;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final l = AppLocalizations.of(context);
        final leave = await confirmAction(
          context,
          title: l.commonDiscardTitle,
          body: l.commonDiscardBody,
          action: l.commonDiscard,
          destructive: true,
          confirmKey: const Key('discard-confirm'),
        );
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      child: child,
    );
  }
}
