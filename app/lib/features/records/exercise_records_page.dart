// B3 소유. STA-2·3·6 종목별 기록(최고 무게·추정 1RM·횟수별 최고) + 1RM 측정 기록. 온라인 전용(REST).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart' show ExerciseRecords, OneRmMeasurement, RecordPoint;
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/ui/form_sheet.dart';
import '../../core/ui/row_menu.dart';
import '../../core/ui/undo.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../session/session_controller.dart' show exerciseMapProvider;
import '../session/session_format.dart';

final exerciseRecordsProvider = FutureProvider.autoDispose.family<ExerciseRecords, String>(
  (ref, id) => ref.watch(recordsRepositoryProvider).records(id),
  retry: (_, _) => null, // 오류는 바로 보여주고 사용자가 다시 시도한다
);

final oneRmListProvider = FutureProvider.autoDispose.family<List<OneRmMeasurement>, String>(
  (ref, id) => ref.watch(recordsRepositoryProvider).oneRms(id),
  retry: (_, _) => null,
);

String formulaLabel(AppLocalizations l, String formula) => switch (formula) {
  'BRZYCKI' => l.settingsE1rmBrzycki,
  'LOMBARDI' => l.settingsE1rmLombardi,
  _ => l.settingsE1rmEpley,
};

class ExerciseRecordsPage extends ConsumerWidget {
  const ExerciseRecordsPage({super.key, required this.exerciseId});
  final String exerciseId;

  void _refresh(WidgetRef ref) {
    ref.invalidate(exerciseRecordsProvider(exerciseId));
    ref.invalidate(oneRmListProvider(exerciseId));
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final saved = await showFormSheet<bool>(
      context,
      builder: (_) => _AddOneRmSheet(exerciseId: exerciseId),
    );
    if (saved == true) _refresh(ref);
  }

  /// 확인 없이 지우고 되돌리기를 보여 준다. 되돌리기는 새 id로 다시 넣는다.
  Future<void> _delete(BuildContext context, WidgetRef ref, OneRmMeasurement m) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(recordsRepositoryProvider);
    try {
      await repo.deleteOneRm(m.id);
      _refresh(ref);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.recordsActionFailed)));
      return;
    }
    showUndoSnack(
      messenger,
      l,
      message: l.recordsOneRmDeleted,
      onUndo: () async {
        await repo.addOneRm(
          exerciseId,
          OneRmMeasurement(id: newId(), weightKg: m.weightKg, measuredAt: m.measuredAt, note: m.note),
        );
        _refresh(ref);
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final ex = ref.watch(exerciseMapProvider).value?[exerciseId];
    final records = ref.watch(exerciseRecordsProvider(exerciseId));
    final oneRms = ref.watch(oneRmListProvider(exerciseId));
    final theme = Theme.of(context);

    String point(RecordPoint p) =>
        l.recordsPoint(Units.format(p.weightKg, unit), p.reps, formatDate(p.achievedAt.toLocal()));

    final c = AppColors.of(context);
    // PR(최고 무게·추정 1RM)은 호박색 별과 함께, 숫자는 AppNum.
    Widget stat(String key, String title, String? value, {String? sub, bool pr = false}) => ListTile(
      key: Key(key),
      minTileHeight: 64,
      leading: pr ? Icon(Icons.star_rounded, color: c.pr, size: 28) : const SizedBox(width: 28),
      title: Text(title),
      subtitle: sub == null ? null : Text(sub, style: TextStyle(color: c.fg2)),
      trailing: Text(
        value ?? l.recordsNone,
        style: value == null ? theme.textTheme.titleMedium : AppNum.medium(context, color: pr ? c.pr : null),
      ),
    );

    Widget error() => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text(l.recordsLoadFailed, key: const Key('records-error'), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(key: const Key('records-retry'), onPressed: () => _refresh(ref), child: Text(l.commonRetry)),
        ],
      ),
    );

    final children = <Widget>[];
    if (records.hasError) {
      children.add(error());
    } else if (records.value == null) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    } else {
      final r = records.value!;
      final byReps = {for (final e in r.byReps) e.reps: e.point};
      children.addAll([
        stat(
          'records-best-weight',
          l.recordsBestWeight,
          r.bestWeight == null ? null : Units.format(r.bestWeight!.weightKg, unit),
          sub: r.bestWeight == null
              ? null
              : '${l.recordsRepsValue(r.bestWeight!.reps)} · ${formatDate(r.bestWeight!.achievedAt.toLocal())}',
          pr: r.bestWeight != null,
        ),
        stat(
          'records-best-e1rm',
          l.recordsBestE1rm,
          r.bestE1rm?.e1rmKg == null ? null : Units.format(r.bestE1rm!.e1rmKg!, unit),
          sub: r.bestE1rm == null
              ? l.recordsFormulaUsed(formulaLabel(l, r.formula))
              : '${point(r.bestE1rm!)} · ${l.recordsFormulaUsed(formulaLabel(l, r.formula))}',
          pr: r.bestE1rm?.e1rmKg != null,
        ),
        stat(
          'records-latest-measured',
          l.recordsLatestMeasured,
          r.latestMeasured == null ? null : Units.format(r.latestMeasured!.weightKg, unit),
          sub: r.latestMeasured == null ? null : formatDate(r.latestMeasured!.measuredAt.toLocal()),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(l.recordsByReps, style: theme.textTheme.titleSmall?.copyWith(color: c.accentStrong)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            key: const Key('records-by-reps'),
            children: [
              for (var reps = 1; reps <= 10; reps++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    key: Key('reps-row-$reps'),
                    children: [
                      SizedBox(width: 72, child: Text(l.recordsRepsValue(reps))),
                      Expanded(
                        child: byReps[reps] == null
                            ? Text('-', style: TextStyle(color: c.fg2))
                            : Row(
                                children: [
                                  Icon(Icons.star_rounded, size: 16, color: c.pr),
                                  const SizedBox(width: 4),
                                  Text(Units.format(byReps[reps]!.weightKg, unit), style: AppNum.style(context, 20)),
                                  Text(
                                    ' · ${formatDate(byReps[reps]!.achievedAt.toLocal())}',
                                    style: TextStyle(color: c.fg2, fontSize: 13),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ]);
    }

    children.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Text(l.recordsOneRmSection, style: theme.textTheme.titleSmall?.copyWith(color: c.accentStrong)),
      ),
    );
    if (oneRms.value != null) {
      if (oneRms.value!.isEmpty) {
        children.add(Padding(padding: const EdgeInsets.all(16), child: Text(l.recordsOneRmEmpty)));
      }
      for (final m in oneRms.value!) {
        children.add(
          ListTile(
            key: Key('onerm-${m.id}'),
            title: Text(Units.format(m.weightKg, unit), style: AppNum.medium(context)),
            subtitle: Text([formatDate(m.measuredAt.toLocal()), if (m.note != null) m.note!].join(' · ')),
            // 새 ScaffoldMessenger 아래의 context로 스낵바를 띄우려고 Builder를 쓴다.
            trailing: Builder(
              builder: (ctx) => RowMenu<String>(
                key: Key('onerm-menu-${m.id}'),
                items: [
                  RowMenuItem(
                    value: 'delete',
                    label: l.commonDelete,
                    destructive: true,
                    key: Key('onerm-delete-${m.id}'),
                  ),
                ],
                onSelected: (_) => _delete(ctx, ref, m),
              ),
            ),
          ),
        );
      }
    } else if (oneRms.hasError && !records.hasError) {
      children.add(error());
    }

    // 셸(하단 탭) Scaffold가 스낵바를 대신 띄우면 FAB를 가린다. 전용 ScaffoldMessenger로 감싸 FAB가 스낵바 위로 오게 한다.
    return ScaffoldMessenger(
      child: Scaffold(
        appBar: AppBar(
          title: Text(ex == null ? l.recordsTitle : exerciseDisplayName(context, ex)),
          actions: [
            IconButton(
              key: const Key('records-progress'),
              tooltip: l.progressButton,
              icon: const Icon(Icons.show_chart),
              onPressed: () => context.push(Routes.exerciseProgress(exerciseId)),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('records-add-onerm'),
          icon: const Icon(Icons.add),
          label: Text(l.recordsOneRmAdd),
          onPressed: () => _add(context, ref),
        ),
        body: ListView(children: [...children, const SizedBox(height: 88)]),
      ),
    );
  }
}

class _AddOneRmSheet extends ConsumerStatefulWidget {
  const _AddOneRmSheet({required this.exerciseId});
  final String exerciseId;
  @override
  ConsumerState<_AddOneRmSheet> createState() => _AddOneRmSheetState();
}

class _AddOneRmSheetState extends ConsumerState<_AddOneRmSheet> {
  final _weight = TextEditingController();
  final _note = TextEditingController();
  late DateTime _date;
  bool _bad = false;

  @override
  void initState() {
    super.initState();
    _date = ref.read(clockProvider)().toLocal();
  }

  @override
  void dispose() {
    _weight.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(_date.year + 1),
    );
    if (d != null) setState(() => _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute));
  }

  /// 검증 실패면 null(시트 유지). 저장이 실패하면 예외가 FormSheet까지 올라가 입력이 남는다.
  Future<bool?> _submit() async {
    final unit = ref.read(settingsProvider).weightUnit;
    final v = double.tryParse(_weight.text.trim().replaceAll(',', '.'));
    if (v == null || v <= 0) {
      setState(() => _bad = true);
      return null;
    }
    setState(() => _bad = false);
    final note = _note.text.trim();
    await ref.read(recordsRepositoryProvider).addOneRm(
      widget.exerciseId,
      OneRmMeasurement(
        id: newId(),
        weightKg: Units.fromDisplay(v, unit),
        measuredAt: _date.toUtc(),
        note: note.isEmpty ? null : note,
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    return FormSheet<bool>(
      title: l.recordsOneRmAdd,
      submitLabel: l.commonAdd,
      submitKey: const Key('onerm-save'),
      failureMessage: (_) => l.recordsActionFailed,
      onSubmit: _submit,
      children: [
        TextField(
          key: const Key('onerm-weight'),
          controller: _weight,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: InputDecoration(
            labelText: l.recordsOneRmWeight(unit == WeightUnit.KG ? 'kg' : 'lb'),
            errorText: _bad ? l.recordsInvalidWeight : null,
          ),
        ),
        ListTile(
          key: const Key('onerm-date'),
          contentPadding: EdgeInsets.zero,
          title: Text(l.recordsOneRmDate),
          trailing: Text(formatDate(_date)),
          onTap: _pickDate,
        ),
        TextField(
          key: const Key('onerm-note'),
          controller: _note,
          decoration: InputDecoration(labelText: l.recordsOneRmNote),
        ),
      ],
    );
  }
}
