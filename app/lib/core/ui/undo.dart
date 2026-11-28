import 'package:material_ui/material_ui.dart';

import '../../l10n/gen/app_localizations.dart';

/// 한 줄짜리 항목을 지운 뒤 "되돌리기"를 보여 준다. 지우기 자체는 호출 쪽이 먼저 한다.
/// BuildContext가 사라진 뒤에도 안전하도록 messenger와 l을 미리 받아 둔다.
void showUndoSnack(
  ScaffoldMessengerState messenger,
  AppLocalizations l, {
  required String message,
  required Future<void> Function() onUndo,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 5),
        persist: false, // 액션이 있어도 자동으로 닫힌다
        action: SnackBarAction(
          label: l.commonUndo,
          onPressed: () async {
            try {
              await onUndo();
            } catch (_) {
              messenger
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text(l.commonError)));
            }
          },
        ),
      ),
    );
}
