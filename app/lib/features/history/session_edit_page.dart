// B3 소유. LOG-10 끝난 세션 수정. 저장소가 쓰는 즉시 저장하므로 "저장" 버튼이 없다.
// 프로그램 세션이면 서버가 이후 계획을 다시 계산한다(engine.md §6).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/ui/confirm.dart';
import '../../core/units.dart';
import '../../core/widgets/reorder.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../session/session_controller.dart'
    show SetLimits, deleteSetWithUndo, exerciseMapProvider, sessionByIdProvider;
import '../session/session_format.dart';

/// 로컬 시각을 골라 돌려준다. 취소하면 null. 테스트에서 바꿔 끼운다.
typedef DateTimePicker = Future<DateTime?> Function(
  BuildContext context,
  DateTime initialLocal,
);

Future<DateTime?> pickDateTimeDefault(
  BuildContext context,
  DateTime initial,
) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2000),
    lastDate: DateTime(initial.year + 1),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// 종료가 시작보다 앞이면 false.
bool validTimeRange(DateTime start, DateTime? end) =>
    end == null || !end.isBefore(start);

class SessionEditPage extends ConsumerStatefulWidget {
  const SessionEditPage({
    super.key,
    required this.sessionId,
    this.pickDateTime = pickDateTimeDefault,
  });
  final String sessionId;
  final DateTimePicker pickDateTime;

  @override
  ConsumerState<SessionEditPage> createState() => _SessionEditPageState();
}

class _SessionEditPageState extends ConsumerState<SessionEditPage> {
  final _note = TextEditingController();
  bool _noteInit = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    final messenger = ScaffoldMessenger.of(context);
    final msg = AppLocalizations.of(context).historyEditSaveFailed;
    try {
      await f();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _editTime(Session s, {required bool start}) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final cur = start ? s.startedAt : (s.endedAt ?? s.startedAt);
    final picked = await widget.pickDateTime(
      context,
      sessionLocalTime(cur, s.tz),
    );
    if (picked == null || !mounted) return;
    final utc = picked.toUtc();
    final newStart = start ? utc : s.startedAt;
    final newEnd = start ? s.endedAt : utc;
    if (!validTimeRange(newStart, newEnd)) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.historyEditEndBeforeStart)),
      );
      return;
    }
    await _run(
      () => ref
          .read(sessionRepositoryProvider)
          .updateSessionTimes(
            s.id,
            startedAt: start ? utc : null,
            endedAt: start ? null : utc,
          ),
    );
  }

  Future<void> _addExercise(Session s) async {
    final id = await context.push<String>(Routes.pickExercise);
    if (id == null || !mounted) return;
    await _run(() async {
      await ref.read(sessionRepositoryProvider).addExercise(s.id, id);
    });
  }

  Future<void> _removeExercise(SessionExercise se) async {
    final l = AppLocalizations.of(context);
    final ex = ref.read(exerciseMapProvider).value?[se.exerciseId];
    final ok = await confirmAction(
      context,
      title: l.historyEditRemoveExerciseTitle(
        ex == null ? '' : exerciseDisplayName(context, ex),
      ),
      body: l.historyEditRemoveExerciseConfirm,
      action: l.commonDelete,
      destructive: true,
      confirmKey: const Key('edit-confirm'),
    );
    if (!ok || !mounted) return;
    await _run(() => ref.read(sessionRepositoryProvider).removeExercise(se.id));
  }

  Future<void> _addSet(Session s, SessionExercise se) async {
    final base = se.sets.isEmpty ? null : se.sets.last;
    final draft = WorkoutSet(
      id: newId(),
      position: se.sets.length,
      weightKg: base?.weightKg,
      addedWeightKg: base?.addedWeightKg,
      reps: base?.reps,
      completedAt:
          s.endedAt ?? ref.read(clockProvider)(), // 끝난 세션에 더한 세트는 한 걸로 센다
    );
    await _run(() async {
      await ref.read(sessionRepositoryProvider).addSet(se.id, draft);
    });
  }

  Future<void> _reorderSets(SessionExercise se, int from, int to) async {
    final ids = movedItem([for (final w in se.sets) w.id], from, to);
    await _run(
      () => ref.read(sessionRepositoryProvider).reorderSets(se.id, ids),
    );
  }

  Future<void> _reorderExercises(Session s, int from, int to) async {
    final ids = movedItem([for (final e in s.exercises) e.id], from, to);
    await _run(
      () => ref.read(sessionRepositoryProvider).reorderExercises(s.id, ids),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(sessionByIdProvider(widget.sessionId));
    final exercises =
        ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};
    final unit = ref.watch(settingsProvider).weightUnit;
    final s = async.value;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.historyEditTitle)),
        body: Center(
          child: async.isLoading
              ? const CircularProgressIndicator()
              : Text(l.historyEditNotFound),
        ),
      );
    }
    if (!_noteInit) {
      _noteInit = true;
      _note.text = s.note ?? '';
    }
    final startLocal = sessionLocalTime(s.startedAt, s.tz);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.historyEditTitle)),
      body: ReorderableListView(
        padding: const EdgeInsets.all(16),
        buildDefaultDragHandles: false,
        onReorderStart: (_) => reorderHaptic(),
        onReorderItem: (o, n) => _reorderExercises(s, o, n),
        proxyDecorator: reorderProxy(
          compact: (i) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              exercises[s.exercises[i].exerciseId] == null
                  ? '…'
                  : exerciseDisplayName(
                      context,
                      exercises[s.exercises[i].exerciseId]!,
                    ),
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.isProgram)
              Card(
                key: const Key('edit-program-notice'),
                color: AppColors.of(context).warnSoft,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: AppColors.of(context).warn,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(l.historyEditProgramNotice)),
                    ],
                  ),
                ),
              ),
            ListTile(
              key: const Key('edit-start'),
              contentPadding: EdgeInsets.zero,
              title: Text(l.historyEditStart),
              trailing: Text(
                '${formatDate(startLocal)} ${formatClock(startLocal)}',
                style: AppNum.table(context),
              ),
              onTap: () => _editTime(s, start: true),
            ),
            if (s.endedAt != null)
              ListTile(
                key: const Key('edit-end'),
                contentPadding: EdgeInsets.zero,
                title: Text(l.historyEditEnd),
                trailing: Builder(
                  builder: (_) {
                    final e = sessionLocalTime(s.endedAt!, s.tz);
                    return Text(
                      '${formatDate(e)} ${formatClock(e)}',
                      style: AppNum.table(context),
                    );
                  },
                ),
                onTap: () => _editTime(s, start: false),
              ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('edit-note'),
              controller: _note,
              maxLines: null,
              decoration: InputDecoration(
                labelText: l.historyEditNote,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) {
                final t = v.trim();
                _run(
                  () => ref
                      .read(sessionRepositoryProvider)
                      .updateSessionNote(s.id, t.isEmpty ? null : t),
                );
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 6),
            OutlinedButton.icon(
              key: const Key('edit-add-exercise'),
              icon: const Icon(Icons.add),
              label: Text(l.historyEditAddExercise),
              onPressed: () => _addExercise(s),
            ),
            const SizedBox(height: 24),
          ],
        ),
        children: [
          for (var ei = 0; ei < s.exercises.length; ei++)
            Builder(
              key: Key('edit-ex-${s.exercises[ei].id}'),
              builder: (context) {
                final se = s.exercises[ei];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ReorderableDragStartListener(
                              index: ei,
                              child: Padding(
                                key: Key('edit-ex-handle-${se.id}'),
                                padding: const EdgeInsets.only(
                                  right: 8,
                                  top: 8,
                                  bottom: 8,
                                ),
                                child: const Icon(Icons.drag_handle),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                exercises[se.exerciseId] == null
                                    ? '…'
                                    : exerciseDisplayName(
                                        context,
                                        exercises[se.exerciseId]!,
                                      ),
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            IconButton(
                              key: Key('edit-ex-delete-${se.id}'),
                              tooltip: l.historyEditRemoveExercise,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _removeExercise(se),
                            ),
                          ],
                        ),
                        ReorderableListView.builder(
                          key: Key('edit-sets-${se.id}'),
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          itemCount: se.sets.length,
                          onReorderStart: (_) => reorderHaptic(),
                          onReorderItem: (o, n) => _reorderSets(se, o, n),
                          proxyDecorator: reorderProxy(),
                          itemBuilder: (context, i) => _EditSetRow(
                            key: ValueKey('row-${se.sets[i].id}'),
                            set: se.sets[i],
                            index: i,
                            type:
                                exercises[se.exerciseId]?.type ??
                                ExerciseType.BARBELL,
                            unit: unit,
                            onSave: (w) => _run(
                              () => ref
                                  .read(sessionRepositoryProvider)
                                  .updateSet(w),
                            ),
                            onDelete: () => _run(
                              () => deleteSetWithUndo(
                                ref.read(sessionRepositoryProvider),
                                ScaffoldMessenger.of(context),
                                l,
                                sessionId: s.id,
                                se: se,
                                set: se.sets[i],
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: Key('edit-set-add-${se.id}'),
                            icon: const Icon(Icons.add),
                            label: Text(l.historyEditAddSet),
                            onPressed: () => _addSet(s, se),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

String _targetText(WorkoutSet w, WeightUnit unit) {
  final reps = '${w.targetReps ?? '-'}${w.isAmrap ? '+' : ''}';
  final wt = w.targetWeightKg;
  return wt == null ? '×$reps' : '${Units.format(wt, unit)}×$reps';
}

class _EditSetRow extends StatefulWidget {
  const _EditSetRow({
    super.key,
    required this.set,
    required this.index,
    required this.type,
    required this.unit,
    required this.onSave,
    required this.onDelete,
  });
  final WorkoutSet set;
  final int index;
  final ExerciseType type;
  final WeightUnit unit;
  final void Function(WorkoutSet) onSave;
  final VoidCallback onDelete;

  @override
  State<_EditSetRow> createState() => _EditSetRowState();
}

class _EditSetRowState extends State<_EditSetRow> {
  final _weight = TextEditingController();
  final _reps = TextEditingController();
  bool _weightBad = false;
  bool _repsBad = false;

  bool get _bodyweight => widget.type == ExerciseType.BODYWEIGHT;
  double? get _modelWeight =>
      _bodyweight ? widget.set.addedWeightKg : widget.set.weightKg;

  @override
  void initState() {
    super.initState();
    _weight.text = _kgText(_modelWeight);
    _reps.text = widget.set.reps?.toString() ?? '';
  }

  @override
  void didUpdateWidget(_EditSetRow old) {
    super.didUpdateWidget(old);
    // 입력창이 뜻하는 값이 모델과 다를 때만 덮어쓴다(타이핑 중·오류 중 보호).
    if (!_weightBad && _parseKg(_weight.text) != _modelWeight) {
      _weight.text = _kgText(_modelWeight);
    }
    if (!_repsBad && int.tryParse(_reps.text.trim()) != widget.set.reps) {
      _reps.text = widget.set.reps?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _weight.dispose();
    _reps.dispose();
    super.dispose();
  }

  String _kgText(double? kg) =>
      kg == null ? '' : Units.format(kg, widget.unit, withUnit: false);

  double? _parseKg(String t) {
    final v = double.tryParse(t.trim().replaceAll(',', '.'));
    return v == null ? null : Units.fromDisplay(v, widget.unit);
  }

  void _commit() {
    double? weight;
    int? reps;
    var wBad = false, rBad = false;
    if (_weight.text.trim().isNotEmpty) {
      weight = _parseKg(_weight.text);
      wBad = weight == null || (!_bodyweight && !SetLimits.validWeight(weight));
    }
    if (_reps.text.trim().isNotEmpty) {
      reps = int.tryParse(_reps.text.trim());
      rBad = reps == null || !SetLimits.validReps(reps);
    }
    setState(() {
      _weightBad = wBad;
      _repsBad = rBad;
    });
    if (wBad || rBad) return;
    widget.onSave(
      widget.set.copyWith(
        weightKg: _bodyweight ? null : () => weight,
        addedWeightKg: _bodyweight ? () => weight : null,
        reps: () => reps,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final w = widget.set;
    final unitName = widget.unit == WeightUnit.KG ? 'kg' : 'lb';
    final id = w.id;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 28,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    w.isWarmup ? l.sessionWarmupShort : '${widget.index + 1}',
                    textAlign: TextAlign.center,
                    style: AppNum.table(
                      context,
                      color: AppColors.of(context).fg2,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  key: Key('edit-weight-$id'),
                  controller: _weight,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: true,
                    signed: _bodyweight,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(_bodyweight ? r'[-0-9.,]' : r'[0-9.,]'),
                    ),
                  ],
                  textAlign: TextAlign.center,
                  style: AppNum.style(context, 20),
                  onChanged: (_) => _commit(),
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    labelText: _bodyweight
                        ? l.historyEditAdded(unitName)
                        : l.historyEditWeight(unitName),
                    errorText: _weightBad ? l.historyEditInvalid : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: Key('edit-reps-$id'),
                  controller: _reps,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  style: AppNum.style(context, 20),
                  onChanged: (_) => _commit(),
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    labelText: l.historyEditReps,
                    errorText: _repsBad ? l.historyEditInvalid : null,
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              ReorderableDragStartListener(
                index: widget.index,
                child: SizedBox(
                  key: Key('edit-set-handle-$id'),
                  width: 32,
                  height: 40,
                  child: const Icon(Icons.drag_handle, size: 20),
                ),
              ),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    FilterChip(
                      key: Key('edit-warmup-$id'),
                      label: Text(l.historyEditWarmup),
                      selected: w.isWarmup,
                      visualDensity: VisualDensity.compact,
                      onSelected: (v) => widget.onSave(w.copyWith(isWarmup: v)),
                    ),
                    if (w.isPlanned)
                      Text(
                        l.historyEditTarget(_targetText(w, widget.unit)),
                        key: Key('edit-target-$id'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              IconButton(
                key: Key('edit-set-delete-$id'),
                tooltip: l.historyEditDeleteSet,
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: widget.onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
