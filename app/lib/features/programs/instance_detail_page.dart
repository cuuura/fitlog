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
import '../../core/theme.dart';
import '../../core/ui/confirm.dart';
import '../../core/ui/form_sheet.dart';
import '../../core/ui/row_menu.dart';
import '../../core/ui/undo.dart';
import '../../core/units.dart';
import '../../core/widgets/reorder.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/current_set.dart' show repsRangeText;
import '../session/start_program_flow.dart';
import '../program_editor/program_editor.dart';
import 'program_common.dart';
import 'programs_providers.dart';

class InstanceDetailPage extends ConsumerWidget {
  const InstanceDetailPage({super.key, required this.instanceId});
  final String instanceId;

  /// 계획 캐시·화면을 갱신한다.
  Future<void> _refresh(WidgetRef ref) async {
    await ref.read(planCacheProvider).refresh(instanceId: instanceId);
    ref.invalidate(instanceViewProvider(instanceId));
    ref.invalidate(instanceListProvider);
  }

  /// 변경을 실행하고 계획 캐시·화면을 갱신한다. 실패하면 스낵바.
  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      await _refresh(ref);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(errorMessage(l, e, fallback: l.instanceActionFailed)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(instanceViewProvider(instanceId));
    return Scaffold(
      appBar: AppBar(
        title: Text(async.value?.instance.name ?? l.instanceTitle),
        actions: [
          if (async.value != null)
            _InstanceMenu(
              view: async.value!,
              run: (a) => _run(context, ref, a),
            ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetry(
          error: e,
          onRetry: () => ref.invalidate(instanceViewProvider(instanceId)),
        ),
        data: (v) => _Body(
          view: v,
          run: (a) => _run(context, ref, a),
          refresh: () => _refresh(ref),
        ),
      ),
    );
  }
}

enum _InstanceAction { pause, resume, finish, delete, editDef }

/// 진행 중 프로그램 상세 AppBar의 ⋮ 메뉴: 일시정지/다시 시작, 끝내기, 삭제.
class _InstanceMenu extends ConsumerWidget {
  const _InstanceMenu({required this.view, required this.run});
  final InstanceView view;
  final Future<void> Function(Future<void> Function()) run;

  Instance get inst => view.instance;

  Future<void> _setStatus(WidgetRef ref, InstanceStatus s) => run(() async {
    await ref
        .read(programRepositoryProvider)
        .patchInstance(inst.id, InstancePatch(status: s));
  });

  Future<void> _finish(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmAction(
      context,
      title: l.instanceFinishConfirmTitle,
      body: l.instanceFinishConfirmBody,
      action: l.instanceFinish,
    );
    if (!ok) return;
    await _setStatus(ref, InstanceStatus.FINISHED);
  }

  Future<void> _editDef(BuildContext context, WidgetRef ref) async {
    await openProgramEditor(context, instanceId: inst.id);
    ref.invalidate(instanceViewProvider(inst.id));
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmAction(
      context,
      title: l.instanceDeleteConfirmTitle(inst.name),
      body: l.instanceDeleteConfirmBody,
      action: l.commonDelete,
      destructive: true,
    );
    if (!ok) return;
    var done = false;
    await run(() async {
      await ref.read(programRepositoryProvider).deleteInstance(inst.id);
      done = true;
    });
    if (done && context.mounted) context.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return RowMenu<_InstanceAction>(
      key: const Key('instance-menu'),
      items: [
        if (inst.status == InstanceStatus.ACTIVE)
          RowMenuItem(
            value: _InstanceAction.pause,
            label: l.instancePause,
            key: const Key('instance-pause'),
          ),
        if (inst.status == InstanceStatus.PAUSED)
          RowMenuItem(
            value: _InstanceAction.resume,
            label: l.instanceResume,
            key: const Key('instance-resume'),
          ),
        if (inst.status != InstanceStatus.FINISHED)
          RowMenuItem(
            value: _InstanceAction.finish,
            label: l.instanceFinish,
            key: const Key('instance-finish'),
          ),
        if (inst.status != InstanceStatus.FINISHED)
          const RowMenuItem(
            value: _InstanceAction.editDef,
            label: '이 진행만 고치기',
            key: Key('instance-edit-def'),
          ),
        RowMenuItem(
          value: _InstanceAction.delete,
          label: l.instanceDelete,
          destructive: true,
          key: const Key('instance-delete'),
        ),
      ],
      onSelected: (a) => switch (a) {
        _InstanceAction.pause => _setStatus(ref, InstanceStatus.PAUSED),
        _InstanceAction.resume => _setStatus(ref, InstanceStatus.ACTIVE),
        _InstanceAction.finish => _finish(context, ref),
        _InstanceAction.delete => _delete(context, ref),
        _InstanceAction.editDef => _editDef(context, ref),
      },
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.view, required this.run, required this.refresh});
  final InstanceView view;
  final Future<void> Function(Future<void> Function()) run;

  /// 시트 안에서 저장한 뒤 계획 캐시·화면을 갱신한다(저장 실패는 시트가 받는다).
  final Future<void> Function() refresh;

  Instance get inst => view.instance;

  String _liftName(BuildContext context, String key) =>
      view.lifts[key]?.name(context) ?? key;

  Future<void> _setStatus(WidgetRef ref, InstanceStatus s) => run(() async {
    await ref
        .read(programRepositoryProvider)
        .patchInstance(inst.id, InstancePatch(status: s));
  });

  Future<void> _skipNext(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final next = view.plan.firstOrNull;
    if (next == null) return;
    final fixed = inst.skipPolicy == SkipPolicy.FIXED_DATE;
    final ok = await confirmAction(
      context,
      title: l.instanceSkipConfirmTitle,
      body: fixed
          ? l.instanceSkipConfirmFixed(next.dayName)
          : l.instanceSkipConfirmShift(next.dayName),
      action: l.instanceSkipNext,
    );
    if (!ok) return;
    final planSeq = (inst.state.seq ?? 0) + 1;
    await run(() async {
      await ref.read(programRepositoryProvider).skip(inst.id, planSeq);
    });
  }

  Future<void> _adjust(BuildContext context, WidgetRef ref) async {
    final unit = ref.read(settingsProvider).weightUnit;
    final repo = ref.read(programRepositoryProvider);
    await showFormSheet<bool>(
      context,
      builder: (_) => _AdjustSheet(
        state: inst.state,
        unit: unit,
        nameOf: (k) => _liftName(context, k),
        save: (tm, working) async {
          await repo.patchInstance(
            inst.id,
            InstancePatch(
              adjustTm: tm.isEmpty ? null : tm,
              adjustWorking: working.isEmpty ? null : working,
            ),
          );
          await refresh();
        },
      ),
    );
  }

  /// 종목 키 행 ⋮ '종목 바꾸기': 종목을 고르면 프로그램의 그 종목을 바꾼다(PRG-7, 온라인).
  Future<void> _swapLift(BuildContext context, WidgetRef ref, String liftKey) async {
    final exerciseId = await context.push<String>(Routes.pickExercise);
    if (exerciseId == null || !context.mounted) return;
    await run(() async {
      await ref.read(programRepositoryProvider).swapLift(inst.id, liftKey, exerciseId);
    });
  }

  List<Map<String, Object?>> get _days => programDays(view.program.definition);

  Future<void> _addAccessory(
    BuildContext context,
    WidgetRef ref,
    String dayKey,
  ) async {
    final exerciseId = await context.push<String>(Routes.pickExercise);
    if (exerciseId == null || !context.mounted) return;
    final unit = ref.read(settingsProvider).weightUnit;
    final repo = ref.read(programRepositoryProvider);
    await showFormSheet<bool>(
      context,
      builder: (_) => AccessorySheet(
        unit: unit,
        save: (res) async {
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
          await repo.putAccessories(inst.id, list);
          await refresh();
        },
      ),
    );
  }

  Future<void> _removeAccessory(
    BuildContext context,
    WidgetRef ref,
    Accessory a,
  ) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(programRepositoryProvider);
    final rest = [
      for (final x in view.accessories)
        if (x.id != a.id) x,
    ];
    // 같은 날 안에서 position을 0부터 다시 매긴다.
    final counters = <String, int>{};
    final list = [
      for (final x in rest)
        Accessory(
          id: x.id,
          dayKey: x.dayKey,
          exerciseId: x.exerciseId,
          position:
              counters.update(x.dayKey, (n) => n + 1, ifAbsent: () => 1) - 1,
          sets: x.sets,
          reps: x.reps,
          weightKg: x.weightKg,
        ),
    ];
    var done = false;
    await run(() async {
      await repo.putAccessories(inst.id, list);
      done = true;
    });
    if (!done) return;
    // 되돌리기: 지우기 전 목록을 다시 넣는다. 지운 줄은 새 id로 넣어 동기화 삭제 표시와 부딪히지 않게 한다.
    final before = [
      for (final x in view.accessories)
        if (x.id == a.id)
          Accessory(
            id: newId(),
            dayKey: x.dayKey,
            exerciseId: x.exerciseId,
            position: x.position,
            sets: x.sets,
            reps: x.reps,
            weightKg: x.weightKg,
          )
        else
          x,
    ];
    showUndoSnack(
      messenger,
      l,
      message: l.instanceAccessoryRemoved,
      onUndo: () async {
        await repo.putAccessories(inst.id, before);
        await refresh();
      },
    );
  }

  /// 같은 요일 안에서 보조운동을 끌어 순서를 바꾼다. 다른 요일은 그대로, 그 요일만 position 0부터 다시 매긴다.
  Future<void> _reorderAccessory(
    WidgetRef ref,
    String dayKey,
    int from,
    int to,
  ) async {
    final dayList = _dayAccessories(dayKey);
    if (from == to ||
        from < 0 ||
        from >= dayList.length ||
        to < 0 ||
        to >= dayList.length) {
      return;
    }
    final moved = movedItem(dayList, from, to);
    final list = [
      for (final x in view.accessories)
        if (x.dayKey != dayKey) x,
      for (var i = 0; i < moved.length; i++)
        Accessory(
          id: moved[i].id,
          dayKey: moved[i].dayKey,
          exerciseId: moved[i].exerciseId,
          position: i,
          sets: moved[i].sets,
          reps: moved[i].reps,
          weightKg: moved[i].weightKg,
        ),
    ];
    await run(() async {
      await ref.read(programRepositoryProvider).putAccessories(inst.id, list);
    });
  }

  List<Accessory> _dayAccessories(String dayKey) {
    final l = [
      for (final a in view.accessories)
        if (a.dayKey == dayKey) a,
    ];
    // 정렬은 안정적이라 position이 같으면 받은 순서를 지킨다.
    return [...l]..sort((a, b) => a.position.compareTo(b.position));
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
            if (st.week != null)
              Text(l.instanceProgress(st.week!, st.cycle ?? 1)),
          ],
        ),
        const SizedBox(height: 8),
        if (inst.status == InstanceStatus.PAUSED) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('instance-resume-button'),
              onPressed: () => _setStatus(ref, InstanceStatus.ACTIVE),
              child: Text(l.instanceResume),
            ),
          ),
        ],
        if (next != null && inst.status == InstanceStatus.ACTIVE) ...[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('instance-start'),
              onPressed: () => startProgramFlow(
                context,
                ref,
                instanceId: inst.id,
                programName: inst.name,
              ),
              child: Text(
                '${l.instanceStartToday} · ${next.dayName} · ${l.instanceProgress(next.week, next.cycle)}',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Text(l.instanceNextSection, style: theme.textTheme.titleMedium),
        if (view.plan.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(l.instanceNoNext),
          ),
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
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<SkipPolicy>(
            key: const Key('instance-skip-policy'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: SkipPolicy.SHIFT,
                label: Text(
                  l.progSkipShiftSeg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ButtonSegment(
                value: SkipPolicy.FIXED_DATE,
                enabled: fixedOk,
                label: Text(
                  l.progSkipFixedSeg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            selected: {inst.skipPolicy},
            onSelectionChanged: (s) {
              final p = s.first;
              if (p == inst.skipPolicy) return;
              run(() async {
                await ref
                    .read(programRepositoryProvider)
                    .patchInstance(inst.id, InstancePatch(skipPolicy: p));
              });
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          inst.skipPolicy == SkipPolicy.SHIFT
              ? l.programSkipShiftDesc
              : (fixedOk
                    ? l.programSkipFixedDesc
                    : l.programSkipFixedUnavailable),
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppColors.of(context).fg2,
          ),
        ),
        if (!fixedOk)
          Text(
            l.programSkipFixedUnavailable,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.of(context).fg2,
            ),
          ),
        const SizedBox(height: 16),
        Text(l.instanceWeights, style: theme.textTheme.titleMedium),
        for (final k in {...st.tm.keys, ...st.working.keys})
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(_liftName(context, k)),
            trailing: k.startsWith('acc:')
                ? null
                : RowMenu<String>(
                    key: ValueKey('lift-menu-$k'),
                    items: [
                      RowMenuItem(
                        value: 'swap',
                        label: l.instanceSwapLift,
                        key: ValueKey('swap-lift-$k'),
                      ),
                    ],
                    onSelected: (_) => _swapLift(context, ref, k),
                  ),
            subtitle: Text(
              [
                if (st.tm[k] != null)
                  l.instanceTmLabel(Units.format(st.tm[k]!, unit)),
                if (st.working[k] != null)
                  l.instanceWorkingLabel(Units.format(st.working[k]!, unit)),
              ].join(' · '),
              style: AppNum.table(context),
            ),
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
                Expanded(
                  child: Text(
                    day['name'] as String,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: ValueKey('add-accessory-${day['key']}'),
                  tooltip: l.instanceAccessoryAdd,
                  icon: const Icon(Icons.add),
                  onPressed: () =>
                      _addAccessory(context, ref, day['key'] as String),
                ),
              ],
            ),
          ),
          if (!view.accessories.any((a) => a.dayKey == day['key']))
            Text(l.instanceAccessoryEmpty, style: theme.textTheme.bodySmall),
          if (view.accessories.any((a) => a.dayKey == day['key']))
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              proxyDecorator: reorderProxy(),
              onReorderStart: (_) => reorderHaptic(),
              onReorderItem: (o, n) =>
                  _reorderAccessory(ref, day['key'] as String, o, n),
              children: [
                for (final (i, a) in _dayAccessories(
                  day['key'] as String,
                ).indexed)
                  ListTile(
                    key: ValueKey('accessory-${a.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      view.exerciseNames[a.exerciseId]?.name(context) ??
                          a.exerciseId,
                    ),
                    subtitle: Text(
                      [
                        l.instanceAccessorySummary(a.sets, a.reps),
                        if (a.weightKg != null) Units.format(a.weightKg!, unit),
                      ].join(' · '),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: l.instanceAccessoryRemove,
                          icon: const Icon(Icons.close),
                          onPressed: () => _removeAccessory(context, ref, a),
                        ),
                        ReorderableDragStartListener(
                          key: ValueKey('accessory-handle-${a.id}'),
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ],
    );
  }

  /// "100 kg 5×5" / "60 kg ×8, ×6". 무게가 같고 횟수가 같으면 묶는다.
  String _planSummary(PlannedExercise e, WeightUnit unit) {
    final sets = [
      for (final s in e.sets)
        if (!s.isWarmup) s,
    ];
    if (sets.isEmpty) return '';
    final w0 = sets.first.targetWeightKg;
    final r0 = sets.first.targetReps;
    final m0 = sets.first.targetRepsMax;
    final uniform = sets.every(
      (s) =>
          s.targetWeightKg == w0 &&
          s.targetReps == r0 &&
          s.targetRepsMax == m0 &&
          !s.isAmrap,
    );
    final weight = w0 == null ? '' : '${Units.format(w0, unit)} ';
    if (uniform) return '$weight${sets.length}×${repsRangeText(r0, m0)}';
    return sets
        .map(
          (s) =>
              '${s.targetWeightKg == null ? '' : '${Units.format(s.targetWeightKg!, unit, withUnit: false)}×'}${s.isAmrap ? '${s.targetReps}+' : repsRangeText(s.targetReps, s.targetRepsMax)}',
        )
        .join(', ');
  }
}

class _AdjustSheet extends StatefulWidget {
  const _AdjustSheet({
    required this.state,
    required this.unit,
    required this.nameOf,
    required this.save,
  });
  final InstanceState state;
  final WeightUnit unit;
  final String Function(String key) nameOf;

  /// 바뀐 값(kg)을 저장한다. 실패하면 예외를 던져 시트가 입력을 유지하게 한다.
  final Future<void> Function(
    Map<String, double> tm,
    Map<String, double> working,
  )
  save;

  @override
  State<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends State<_AdjustSheet> {
  final Map<String, TextEditingController> _tm = {};
  final Map<String, TextEditingController> _working = {};

  @override
  void initState() {
    super.initState();
    for (final e in widget.state.tm.entries) {
      _tm[e.key] = TextEditingController(
        text: Units.format(e.value, widget.unit, withUnit: false),
      );
    }
    for (final e in widget.state.working.entries) {
      _working[e.key] = TextEditingController(
        text: Units.format(e.value, widget.unit, withUnit: false),
      );
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
  Map<String, double> _changed(
    Map<String, TextEditingController> ctrls,
    Map<String, double> old,
  ) {
    final out = <String, double>{};
    for (final e in ctrls.entries) {
      final v = parseNumber(e.value.text);
      if (v == null || v <= 0) continue;
      final kg = Units.fromDisplay(v, widget.unit);
      if ((kg - old[e.key]!).abs() > 0.005) out[e.key] = kg;
    }
    return out;
  }

  Future<bool?> _submit() async {
    final tm = _changed(_tm, widget.state.tm);
    final working = _changed(_working, widget.state.working);
    if (tm.isNotEmpty || working.isNotEmpty) await widget.save(tm, working);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unitText = widget.unit == WeightUnit.KG ? 'kg' : 'lb';
    Widget field(
      String keyPrefix,
      String key,
      String label,
      TextEditingController c,
    ) => TextField(
      key: ValueKey('$keyPrefix-$key'),
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(
        labelText: '$label ($unitText)',
        border: const OutlineInputBorder(),
      ),
    );
    return FormSheet<bool>(
      title: l.instanceAdjust,
      submitLabel: l.commonSave,
      failureMessage: (e) =>
          errorMessage(l, e, fallback: l.instanceActionFailed),
      onSubmit: _submit,
      children: [
        Text(l.instanceAdjustHelp),
        for (final e in _tm.entries)
          field('adjust-tm', e.key, '${widget.nameOf(e.key)} · TM', e.value),
        for (final e in _working.entries)
          field(
            'adjust-working',
            e.key,
            '${widget.nameOf(e.key)} · ${l.programStartWorking}',
            e.value,
          ),
      ],
    );
  }
}

typedef AccessoryInput = ({int sets, int reps, double? weightKg});

class AccessorySheet extends StatefulWidget {
  const AccessorySheet({super.key, required this.unit, required this.save});
  final WeightUnit unit;
  final Future<void> Function(AccessoryInput res) save;

  @override
  State<AccessorySheet> createState() => AccessorySheetState();
}

class AccessorySheetState extends State<AccessorySheet> {
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

  Future<bool?> _submit() async {
    final sets = int.tryParse(_sets.text.trim());
    final reps = int.tryParse(_reps.text.trim());
    if (sets == null || sets <= 0 || reps == null || reps <= 0) return null;
    final w = parseNumber(_weight.text);
    await widget.save((
      sets: sets,
      reps: reps,
      weightKg: w == null || w <= 0 ? null : Units.fromDisplay(w, widget.unit),
    ));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unitText = widget.unit == WeightUnit.KG ? 'kg' : 'lb';
    final sets = int.tryParse(_sets.text.trim());
    final reps = int.tryParse(_reps.text.trim());
    final valid = sets != null && sets > 0 && reps != null && reps > 0;
    return FormSheet<bool>(
      title: l.instanceAccessoryAdd,
      submitLabel: l.commonAdd,
      enabled: valid,
      failureMessage: (e) =>
          errorMessage(l, e, fallback: l.instanceActionFailed),
      onSubmit: _submit,
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
          decoration: InputDecoration(
            labelText: l.instanceAccessoryWeight(unitText),
          ),
        ),
      ],
    );
  }
}
