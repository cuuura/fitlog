// 세트 표 머리글: 세트 | 계획 | kg | 회 | 완료. 열 너비는 SetRow의 접힌 줄과 맞춘다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import 'set_row.dart';

class SetTableHeader extends ConsumerWidget {
  const SetTableHeader({super.key, required this.type});
  final ExerciseType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider.select((s) => s.weightUnit));
    final unitName = unit == WeightUnit.KG ? 'kg' : 'lb';
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    Widget h(String t, {TextAlign align = TextAlign.start}) => Text(
      t,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
    );
    // 완료 열은 IconButton(48)과 같은 폭.
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          key: const Key('set-table-header'),
          children: [
            SizedBox(
              width: kSetColWidth,
              child: h(l.sessionTableColSet, align: TextAlign.center),
            ),
            Expanded(flex: 3, child: h(l.sessionTableColPlan)),
            Expanded(
              flex: 2,
              child: h(
                type == ExerciseType.BODYWEIGHT ? '+$unitName' : unitName,
              ),
            ),
            Expanded(flex: 2, child: h(l.sessionTableColReps)),
            SizedBox(
              width: 48,
              child: h(l.sessionTableColDone, align: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
