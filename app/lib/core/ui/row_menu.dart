import 'package:material_ui/material_ui.dart';

import '../../l10n/gen/app_localizations.dart';
import '../theme.dart';

class RowMenuItem<T> {
  const RowMenuItem({required this.value, required this.label, this.destructive = false, this.key, this.enabled = true});
  final T value;
  final String label;
  final bool destructive;
  final Key? key;
  final bool enabled;
}

/// 목록 한 줄 오른쪽의 더보기(⋮) 메뉴.
class RowMenu<T> extends StatelessWidget {
  const RowMenu({super.key, required this.items, required this.onSelected, this.tooltip});
  final List<RowMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final fail = AppColors.of(context).fail;
    return PopupMenuButton<T>(
      icon: const Icon(Icons.more_vert),
      tooltip: tooltip ?? AppLocalizations.of(context).commonMore,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      style: IconButton.styleFrom(minimumSize: const Size(48, 48), tapTargetSize: MaterialTapTargetSize.padded),
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final it in items)
          PopupMenuItem<T>(
            key: it.key,
            value: it.value,
            enabled: it.enabled,
            child: Text(it.label, style: it.destructive ? TextStyle(color: fail) : null),
          ),
      ],
    );
  }
}
