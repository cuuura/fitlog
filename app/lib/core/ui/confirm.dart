import 'package:material_ui/material_ui.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme.dart';

/// 되돌릴 수 없는 일을 확인하는 창. 앱의 모든 확인창은 이것만 쓴다.
///
/// [title]은 무엇을 하는지(대상 이름 포함), [body]는 하면 어떻게 되는지,
/// [action]은 확인 버튼 말. 삭제류는 [destructive]=true.
/// 확인하면 true, 취소·바깥 탭·뒤로가기면 false.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? body,
  required String action,
  bool destructive = false,
  Key? confirmKey,
  Key? cancelKey,
  Key? dialogKey,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (c) {
      final l = AppLocalizations.of(c);
      void ok() => Navigator.of(c).pop(true);
      final Widget confirm;
      if (destructive) {
        final fail = AppColors.of(c).fail;
        confirm = OutlinedButton(
          key: confirmKey ?? const Key('confirm-ok'),
          style: OutlinedButton.styleFrom(foregroundColor: fail, side: BorderSide(color: fail)),
          onPressed: ok,
          child: Text(action),
        );
      } else {
        confirm = FilledButton(key: confirmKey ?? const Key('confirm-ok'), onPressed: ok, child: Text(action));
      }
      return AlertDialog(
        key: dialogKey,
        title: Text(title),
        content: body == null ? null : Text(body),
        actions: [
          TextButton(key: cancelKey, onPressed: () => Navigator.of(c).pop(false), child: Text(l.commonCancel)),
          confirm,
        ],
      );
    },
  );
  return result ?? false;
}
