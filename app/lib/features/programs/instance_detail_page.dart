// B1 소유. PRG-6·8: 진행 중 프로그램 관리(상태·무게·다음 회차·건너뛰기·보조운동·삭제).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../core/ids.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import 'program_common.dart';
import 'programs_providers.dart';

class InstanceDetailPage extends ConsumerWidget {
  const InstanceDetailPage({super.key, required this.instanceId});
  final String instanceId;

  /// 변경을 실행하고 계획 캐시·화면을 갱신한다. 실패하면 스낵바.
  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      await ref.read(planCacheProvider).refresh(instanceId: instanceId);
      ref.invalidate(instanceViewProvider(instanceId));
      ref.invalidate(instanceListProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(l, e, fallback: l.instanceActionFailed))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(instanceViewProvider(instanceId));
    return Scaffold(
      appBar: AppBar(title: Text(async.value?.instance.name ?? l.instanceTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(instanceViewProvider(instanceId))),
        data: (v) => _Body(view: v, run: (a) => _run(context, ref, a)),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.view, required this.run});
  final InstanceView view;
  final Future<void> Function(Future<void> Function()) run;

  Instance get inst => view.instance;

  String _liftName(BuildContext context, String key) => view.lifts[key]?.name(context) ?? key;

  Future<void> _setStatus(BuildContext context, WidgetRef ref, InstanceStatus s) async {
    final l = AppLocalizations.of(context);
    if (s == InstanceStatus.FINISHED) {
      final ok = await confirmDialog(
        context,
        title: l.instanceFinishConfirmTitle,
        body: l.instanceFinishConfirmBody,
        action: l.instanceFinish,
      );
      if (!ok) return;
    }
    await run(() async {
      await ref.read(programRepositoryProvider).patchInstance(inst.id, InstancePatch(status: s));
    });
  }

  Future<void> _skipNext(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final next = view.plan.firstOrNull;
    if (next == null) return;
    final fixed = inst.skipPolicy == SkipPolicy.FIXED_DATE;
    final ok = await confirmDialog(
      context,
      title: l.instanceSkipConfirmTitle,
      body: fixed ? l.instanceSkipConfirmFixed(next.dayName) : l.instanceSkipConfirmShift(next.dayName),
      action: l.instanceSkipNext,
    );
    if (!ok) return;
    final planSeq = (inst.state.seq ?? 0) + 1;
    await run(() async {
      await ref.read(programRepositoryProvider).skip(inst.id, planSeq);
    });
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmDialog(
      context,
      title: l.instanceDeleteConfirmTitle,
      body: l.instanceDeleteConfirmBody,
      action: l.commonDelete,
    );
    if (!ok) return;
    var done = false;
    await run(() async {
      await ref.read(programRepositoryProvider).deleteInstance(inst.id);
      done = true;
    });
    if (done && context.mounted) context.pop();
  }

  Future<void> _adjust(BuildContext context, WidgetRef ref) async {
    final unit = ref.read(settingsProvider).weightUnit;
    final res = await showDialog<({Map<String, double> tm, Map<String, double> working})>(
      context: context,
      builder: (_) => _AdjustDialog(state: inst.state, unit: unit, nameOf: (k) => _liftName(context, k)),
    );
    if (res == null || (res.tm.isEmpty && res.working.isEmpty)) return;
    await run(() async {
      await ref.read(programRepositoryProvider).patchInstance(
        inst.id,
        InstancePatch(
          adjustTm: res.tm.isEmpty ? null : res.tm,
          adjustWorking: res.working.isEmpty ? null : res.working,
        ),
      );
    });
  }

  List<Map<String, Object?>> get _days => programDays(view.program.definition);

  Future<void> _addAccessory(BuildContext context, WidgetRef ref, String dayKey) async {
    final exerciseId = await context.push<String>(Routes.pickExercise);
    if (exerciseId == null || !context.mounted) return;
    final unit = ref.read(settingsProvider).weightUnit;
    final res = await showDialog<({int sets, int reps, double? weightKg})>(
      context: context,
      builder: (_) => _AccessoryDialog(unit: unit),
    );
    if (res == null) return;
    final same = view.accessories.where((a) => a.dayKey == dayKey).length;
    final list = [
      ...view.accessories,
      Accessory(
        id: newId(),
        dayKey: dayKey,
        exerciseId: exerciseId,
        position: same,
        sets: res.sets,
        reps: res.reps,
        weightKg: res.weightKg,
      ),
    ];
    await run(() async {
      await ref.read(programRepositoryProvider).putAccessories(inst.id, list);
    });
  }

  Future<void> _removeAccessory(WidgetRef ref, Accessory a) async {
    final rest = [for (final x in view.accessories) if (x.id != a.id) x];
    // 같은 날 안에서 position을 0부터 다시 매긴다.
    final counters = <String, int>{};
    final list = [
      for (final x in rest)
        Accessory(
          id: x.id,
          dayKey: x.dayKey,
          exerciseId: x.exerciseId,
          position: counters.update(x.dayKey, (n) => n + 1, ifAbsent: () => 1) - 1,
          sets: x.sets,
          reps: x.reps,
          weightKg: x.weightKg,
        ),
    ];
    await run(() async {
      await ref.read(programRepositoryProvider).putAccessories(inst.id, list);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final st = inst.state;
    final fixedOk = programHasWeekdays(view.program.definition);
    final next = view.plan.firstOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(label: Text(statusLabel(l, inst.status))),
            if (st.week != null) Text(l.instanceProgress(st.week!, st.cycle ?? 1)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (inst.status == InstanceStatus.ACTIVE)
              OutlinedButton(
                onPressed: () => _setStatus(context, ref, InstanceStatus.PAUSED),
                child: Text(l.instancePause),
              ),
            if (inst.status == InstanceStatus.PAUSED)
              FilledButton(
                onPressed: () => _setStatus(context, ref, InstanceStatus.ACTIVE),
                child: Text(l.instanceResume),
              ),
            const SizedBox(width: 8),
            if (inst.status != InstanceStatus.FINISHED)
              OutlinedButton(
                onPressed: () => _setStatus(context, ref, InstanceStatus.FINISHED),
                child: Text(l.instanceFinish),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Text(l.instanceNextSection, style: theme.textTheme.titleMedium),
        if (view.plan.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(l.instanceNoNext)),
        for (final w in view.plan)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      w.dayName,
                      l.instanceProgress(w.week, w.cycle),
                      if (w.scheduledDate != null) formatDate(w.scheduledDate!),
                    ].join(' · '),
                    style: theme.textTheme.titleSmall,
                  ),
                  for (final e in w.exercises)
                    Text(
                      '${view.exerciseNames[e.exerciseId]?.name(context) ?? e.exerciseId}'
                      '${e.accessory ? ' (${l.instanceAccessories})' : ''}  ${_planSummary(e, unit)}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        if (next != null && inst.status == InstanceStatus.ACTIVE)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _skipNext(context, ref),
              icon: const Icon(Icons.skip_next),
              label: Text(l.instanceSkipNext),
            ),
          ),
        const SizedBox(height: 16),
        Text(l.instanceSkipPolicy, style: theme.textTheme.titleMedium),
        RadioGroup<SkipPolicy>(
          groupValue: inst.skipPolicy,
          onChanged: (p) {
            if (p == null || p == inst.skipPolicy) return;
            run(() async {
              await ref.read(programRepositoryProvider).patchInstance(inst.id, InstancePatch(skipPolicy: p));
            });
          },
          child: Column(
            children: [
              RadioListTile<SkipPolicy>(
                value: SkipPolicy.SHIFT,
                title: Text(l.programSkipShift),
                subtitle: Text(l.programSkipShiftDesc),
              ),
              RadioListTile<SkipPolicy>(
                value: SkipPolicy.FIXED_DATE,
                enabled: fixedOk,
                title: Text(l.programSkipFixed),
                subtitle: Text(fixedOk ? l.programSkipFixedDesc : l.programSkipFixedUnavailable),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(l.instanceWeights, style: theme.textTheme.titleMedium),
        for (final k in {...st.tm.keys, ...st.working.keys})
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(_liftName(context, k)),
            subtitle: Text([
              if (st.tm[k] != null) l.instanceTmLabel(Units.format(st.tm[k]!, unit)),
              if (st.working[k] != null) l.instanceWorkingLabel(Units.format(st.working[k]!, unit)),
            ].join(' · ')),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _adjust(context, ref),
            icon: const Icon(Icons.tune),
            label: Text(l.instanceAdjust),
          ),
        ),
        const SizedBox(height: 16),
        Text(l.instanceAccessories, style: theme.textTheme.titleMedium),
        for (final day in _days) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(child: Text(day['name'] as String, style: theme.textTheme.titleSmall)),
                IconButton(
                  key: ValueKey('add-accessory-${day['key']}'),
                  tooltip: l.instanceAccessoryAdd,
                  icon: const Icon(Icons.add),
                  onPressed: () => _addAccessory(context, ref, day['key'] as String),
                ),
              ],
            ),
          ),
          if (!view.accessories.any((a) => a.dayKey == day['key']))
            Text(l.instanceAccessoryEmpty, style: theme.textTheme.bodySmall),
          for (final a in view.accessories.where((a) => a.dayKey == day['key']))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(view.exerciseNames[a.exerciseId]?.name(context) ?? a.exerciseId),
              subtitle: Text([
                l.instanceAccessorySummary(a.sets, a.reps),
                if (a.weightKg != null) Units.format(a.weightKg!, unit),
              ].join(' · ')),
              trailing: IconButton(
                tooltip: l.instanceAccessoryRemove,
                icon: const Icon(Icons.close),
                onPressed: () => _removeAccessory(ref, a),
              ),
            ),
        ],
        const SizedBox(height: 24),
        TextButton.icon(
          onPressed: () => _delete(context, ref),
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          icon: const Icon(Icons.delete_outline),
          label: Text(l.instanceDelete),
        ),
      ],
    );
  }

  /// "100 kg 5×5" / "60 kg ×8, ×6". 무게가 같고 횟수가 같으면 묶는다.
  String _planSummary(PlannedExercise e, WeightUnit unit) {
    final sets = [for (final s in e.sets) if (!s.isWarmup) s];
    if (sets.isEmpty) return '';
    final w0 = sets.first.targetWeightKg;
    final r0 = sets.first.targetReps;
    final uniform = sets.every((s) => s.targetWeightKg == w0 && s.targetReps == r0 && !s.isAmrap);
    final weight = w0 == null ? '' : '${Units.format(w0, unit)} ';
    if (uniform) return '$weight${sets.length}×$r0';
    return sets
        .map((s) => '${s.targetWeightKg == null ? '' : '${Units.format(s.targetWeightKg!, unit, withUnit: false)}×'}${s.targetReps}${s.isAmrap ? '+' : ''}')
        .join(', ');
  }
}

class _AdjustDialog extends StatefulWidget {
  const _AdjustDialog({required this.state, required this.unit, required this.nameOf});
  final InstanceState state;
  final WeightUnit unit;
  final String Function(String key) nameOf;

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final Map<String, TextEditingController> _tm = {};
  final Map<String, TextEditingController> _working = {};

  @override
  void initState() {
    super.initState();
    for (final e in widget.state.tm.entries) {
      _tm[e.key] = TextEditingController(text: Units.format(e.value, widget.unit, withUnit: false));
    }
    for (final e in widget.state.working.entries) {
      _working[e.key] = TextEditingController(text: Units.format(e.value, widget.unit, withUnit: false));
    }
  }

  @override
  void dispose() {
    for (final c in [..._tm.values, ..._working.values]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 바뀐 값만 kg로.
  Map<String, double> _changed(Map<String, TextEditingController> ctrls, Map<String, double> old) {
    final out = <String, double>{};
    for (final e in ctrls.entries) {
      final v = parseNumber(e.value.text);
      if (v == null || v <= 0) continue;
      final kg = Units.fromDisplay(v, widget.unit);
      if ((kg - old[e.key]!).abs() > 0.005) out[e.key] = kg;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unitText = widget.unit == WeightUnit.KG ? 'kg' : 'lb';
    Widget field(String keyPrefix, String key, String label, TextEditingController c) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        key: ValueKey('$keyPrefix-$key'),
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        decoration: InputDecoration(labelText: '$label ($unitText)', border: const OutlineInputBorder()),
      ),
    );
    return AlertDialog(
      title: Text(l.instanceAdjust),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.instanceAdjustHelp),
            for (final e in _tm.entries) field('adjust-tm', e.key, '${widget.nameOf(e.key)} · TM', e.value),
            for (final e in _working.entries)
              field('adjust-working', e.key, '${widget.nameOf(e.key)} · ${l.programStartWorking}', e.value),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            tm: _changed(_tm, widget.state.tm),
            working: _changed(_working, widget.state.working),
          )),
          child: Text(l.commonSave),
        ),
      ],
    );
  }
}

class _AccessoryDialog extends StatefulWidget {
  const _AccessoryDialog({required this.unit});
  final WeightUnit unit;

  @override
  State<_AccessoryDialog> createState() => _AccessoryDialogState();
}

class _AccessoryDialogState extends State<_AccessoryDialog> {
  final _sets = TextEditingController(text: '3');
  final _reps = TextEditingController(text: '10');
  final _weight = TextEditingController();

  @override
  void dispose() {
    _sets.dispose();
    _reps.dispose();
    _weight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unitText = widget.unit == WeightUnit.KG ? 'kg' : 'lb';
    final sets = int.tryParse(_sets.text.trim());
    final reps = int.tryParse(_reps.text.trim());
    final valid = sets != null && sets > 0 && reps != null && reps > 0;
    return AlertDialog(
      title: Text(l.instanceAccessoryAdd),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('acc-sets'),
            controller: _sets,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: l.instanceAccessorySets),
          ),
          TextField(
            key: const ValueKey('acc-reps'),
            controller: _reps,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: l.instanceAccessoryReps),
          ),
          TextField(
            key: const ValueKey('acc-weight'),
            controller: _weight,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: l.instanceAccessoryWeight(unitText)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(
          onPressed: !valid
              ? null
              : () {
                  final w = parseNumber(_weight.text);
                  Navigator.pop(context, (
                    sets: sets,
                    reps: reps,
                    weightKg: w == null || w <= 0 ? null : Units.fromDisplay(w, widget.unit),
                  ));
                },
          child: Text(l.commonSave),
        ),
      ],
    );
  }
}
