import 'package:material_ui/material_ui.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme.dart';

/// 짧은 입력용 바텀시트를 연다. builder는 보통 [FormSheet]를 돌려준다.
Future<T?> showFormSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: builder,
  );
}

class FormSheet<T> extends StatefulWidget {
  const FormSheet({
    super.key,
    required this.title,
    required this.children,
    required this.submitLabel,
    required this.onSubmit,
    this.failureMessage,
    this.submitKey,
    this.enabled = true,
  });

  final String title;

  /// 입력 칸들.
  final List<Widget> children;

  /// 새로 만들면 l.commonAdd, 고치면 l.commonSave.
  final String submitLabel;

  /// 검증 실패면 null(시트 유지, 호출 쪽이 칸 오류를 표시). 성공이면 결과를 돌려주고 시트가 그 값으로 닫힌다.
  /// 예외가 나면 시트를 닫지 않고 입력을 그대로 둔 채 오류 문구를 버튼 위에 보여 준다.
  final Future<T?> Function() onSubmit;

  /// 기본 l.commonError.
  final String Function(Object error)? failureMessage;

  /// 기본 Key('sheet-submit').
  final Key? submitKey;

  /// false면 버튼 비활성.
  final bool enabled;

  @override
  State<FormSheet<T>> createState() => _FormSheetState<T>();
}

class _FormSheetState<T> extends State<FormSheet<T>> {
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    T? result;
    try {
      result = await widget.onSubmit();
    } catch (e) {
      if (!mounted) return;
      final msg = widget.failureMessage?.call(e) ?? AppLocalizations.of(context).commonError;
      setState(() {
        _busy = false;
        _error = msg;
      });
      return;
    }
    if (!mounted) return;
    if (result == null) {
      setState(() => _busy = false);
      return;
    }
    // 닫히는 동안에도 _busy를 유지해 중복 제출을 막는다.
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final fail = AppColors.of(context).fail;
    final kids = <Widget>[];
    for (var i = 0; i < widget.children.length; i++) {
      if (i > 0) kids.add(const SizedBox(height: 12));
      kids.add(widget.children[i]);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Flexible(
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, key: const Key('sheet-error'), style: TextStyle(color: fail)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: widget.submitKey ?? const Key('sheet-submit'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: (widget.enabled && !_busy) ? _submit : null,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(widget.submitLabel),
          ),
        ],
      ),
    );
  }
}
