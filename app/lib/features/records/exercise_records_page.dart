// B3 소유. STA-2·3·6 종목별 기록(최고 무게·추정 1RM·횟수별 최고) + 1RM 측정 기록. 온라인 전용(REST).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart' show ExerciseRecords, OneRmMeasurement, RecordPoint;
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/settings/settings_controller.dart';
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
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final m = await showDialog<OneRmMeasurement>(context: context, builder: (_) => const _AddOneRmDialog());
    if (m == null) return;
    try {
      await ref.read(recordsRepositoryProvider).addOneRm(exerciseId, m);
      _refresh(ref);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.recordsActionFailed)));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, OneRmMeasurement m) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(l.recordsOneRmDeleteConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.commonCancel)),
          TextButton(
            key: const Key('records-delete-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: Text(l.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(recordsRepositoryProvider).deleteOneRm(m.id);
      _refresh(ref);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.recordsActionFailed)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final ex = ref.watch(exerciseMapProvider).value?[exerciseId];
    final records = ref.watch(exerciseRecordsProvider(exerciseId));
    final oneRms = ref.watch(oneRmListProvider(exerciseId));
    final theme = Theme.of(context);

    String point(RecordPoint p) => l.recordsPoint(
      Units.format(p.weightKg, unit),
      p.reps,
      formatDate(p.achievedAt.toLocal()),
    );

    Widget stat(String key, String title, String? value, {String? sub}) => ListTile(
      key: Key(key),
      title: Text(title),
      subtitle: sub == null ? null : Text(sub),
      trailing: Text(value ?? l.recordsNone, style: theme.textTheme.titleMedium),
    );

    Widget error() => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text(l.recordsLoadFailed, key: const Key('records-error'), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const Key('records-retry'),
            onPressed: () => _refresh(ref),
            child: Text(l.commonRetry),
          ),
        ],
      ),
    );

    final children = <Widget>[];
    if (records.hasError) {
      children.add(error());
    } else if (records.value == null) {
      children.add(const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())));
    } else {
      final r = records.value!;
      final byReps = {for (final e in r.byReps) e.reps: e.point};
      children.addAll([
        stat(
          'records-best-weight',
          l.recordsBestWeight,
          r.bestWeight == null ? null : Units.format(r.bestWeight!.weightKg, unit),
          sub: r.bestWeight == null ? null : '${l.recordsRepsValue(r.bestWeight!.reps)} · ${formatDate(r.bestWeight!.achievedAt.toLocal())}',
        ),
        stat(
          'records-best-e1rm',
          l.recordsBestE1rm,
          r.bestE1rm?.e1rmKg == null ? null : Units.format(r.bestE1rm!.e1rmKg!, unit),
          sub: r.bestE1rm == null
              ? l.recordsFormulaUsed(formulaLabel(l, r.formula))
              : '${point(r.bestE1rm!)} · ${l.recordsFormulaUsed(formulaLabel(l, r.formula))}',
        ),
        stat(
          'records-latest-measured',
          l.recordsLatestMeasured,
          r.latestMeasured == null ? null : Units.format(r.latestMeasured!.weightKg, unit),
          sub: r.latestMeasured == null ? null : formatDate(r.latestMeasured!.measuredAt.toLocal()),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(l.recordsByReps, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
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
                        child: Text(
                          byReps[reps] == null
                              ? '-'
                              : '${Units.format(byReps[reps]!.weightKg, unit)} · ${formatDate(byReps[reps]!.achievedAt.toLocal())}',
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
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(l.recordsOneRmSection, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
            ),
            TextButton.icon(
              key: const Key('records-add-onerm'),
              icon: const Icon(Icons.add),
              label: Text(l.recordsOneRmAdd),
              onPressed: () => _add(context, ref),
            ),
          ],
        ),
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
            title: Text(Units.format(m.weightKg, unit)),
            subtitle: Text([formatDate(m.measuredAt.toLocal()), if (m.note != null) m.note!].join(' · ')),
            trailing: IconButton(
              key: Key('onerm-delete-${m.id}'),
              tooltip: l.commonDelete,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(context, ref, m),
            ),
          ),
        );
      }
    } else if (oneRms.hasError && !records.hasError) {
      children.add(error());
    }

    return Scaffold(
      appBar: AppBar(title: Text(ex == null ? l.recordsTitle : exerciseDisplayName(context, ex))),
      body: ListView(children: [...children, const SizedBox(height: 24)]),
    );
  }
}

class _AddOneRmDialog extends ConsumerStatefulWidget {
  const _AddOneRmDialog();
  @override
  ConsumerState<_AddOneRmDialog> createState() => _AddOneRmDialogState();
}

class _AddOneRmDialogState extends ConsumerState<_AddOneRmDialog> {
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

  void _submit() {
    final unit = ref.read(settingsProvider).weightUnit;
    final v = double.tryParse(_weight.text.trim().replaceAll(',', '.'));
    if (v == null || v <= 0) {
      setState(() => _bad = true);
      return;
    }
    final note = _note.text.trim();
    Navigator.pop(
      context,
      OneRmMeasurement(
        id: newId(),
        weightKg: Units.fromDisplay(v, unit),
        measuredAt: _date.toUtc(),
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    return AlertDialog(
      title: Text(l.recordsOneRmAdd),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const SizedBox(height: 8),
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
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(key: const Key('onerm-save'), onPressed: _submit, child: Text(l.commonSave)),
      ],
    );
  }
}
