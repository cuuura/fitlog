// 하루짜리 예정 운동 만들기·수정(LOG-13). 날짜, 제목, 메모, 종목(휴식 초)과 세트 목표(무게·횟수·최대 횟수·RIR).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/ui/bottom_action_bar.dart';
import '../../core/ui/unsaved_guard.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../calendar/calendar_logic.dart';
import '../exercise_picker/exercise_labels.dart';
import '../session/session_controller.dart' show exerciseMapProvider;
import 'scheduled_logic.dart';

/// 서버 한도(scheduled-workout.md §2).
const kScheduledMaxItems = 30;
const kScheduledMaxSets = 50;
const kScheduledMaxRestSec = 3600;

class _SetDraft {
  _SetDraft({
    this.base = const ScheduledSet(),
    String weight = '',
    String reps = '',
    String repsMax = '',
    String rir = '',
  }) : warmup = base.isWarmup,
       weight = TextEditingController(text: weight),
       reps = TextEditingController(text: reps),
       repsMax = TextEditingController(text: repsMax),
       rir = TextEditingController(text: rir);

  /// 화면에 없는 필드(targetRpe·targetDurationSec)를 고쳐 쓸 때 그대로 보존하려고 둔다.
  final ScheduledSet base;
  bool warmup;
  final TextEditingController weight, reps, repsMax, rir;

  _SetDraft copyValues() => _SetDraft(
    weight: weight.text,
    reps: reps.text,
    repsMax: repsMax.text,
    rir: rir.text,
  );

  void dispose() {
    for (final c in [weight, reps, repsMax, rir]) {
      c.dispose();
    }
  }
}

class _ItemDraft {
  _ItemDraft(this.exerciseId, {String note = '', String rest = '', List<_SetDraft>? sets})
    : uid = UniqueKey(),
      note = TextEditingController(text: note),
      rest = TextEditingController(text: rest),
      sets = sets ?? [_SetDraft()];

  final Key uid;
  final String exerciseId;
  final TextEditingController note, rest;
  final List<_SetDraft> sets;

  void dispose() {
    note.dispose();
    rest.dispose();
    for (final s in sets) {
      s.dispose();
    }
  }
}

class ScheduledEditPage extends ConsumerStatefulWidget {
  const ScheduledEditPage({super.key, this.scheduledId, this.initialDate});

  /// null이면 새로 만든다.
  final String? scheduledId;

  /// 새로 만들 때 기본 날짜(YYYY-MM-DD). 없으면 오늘.
  final String? initialDate;

  @override
  ConsumerState<ScheduledEditPage> createState() => _ScheduledEditPageState();
}

class _ScheduledEditPageState extends ConsumerState<ScheduledEditPage> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  final _items = <_ItemDraft>[];
  DateTime? _date;
  ScheduledWorkout? _existing;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;
  String _initial = '';
  String? _error;

  bool get _isNew => widget.scheduledId == null;

  /// 입력 전체를 한 줄로 요약한다. 불러온 직후 값과 다르면 고친 것으로 본다.
  String _snapshot() => [
    _date == null ? '' : dayKey(_date!),
    _title.text,
    _note.text,
    for (final it in _items)
      [
        it.exerciseId,
        it.note.text,
        it.rest.text,
        for (final s in it.sets) [s.warmup, s.weight.text, s.reps.text, s.repsMax.text, s.rir.text].join('\u0001'),
      ].join('\u0002'),
  ].join('\u0003');

  bool get _dirty => !_loading && !_saved && _snapshot() != _initial;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    for (final i in _items) {
      i.dispose();
    }
    super.dispose();
  }

  String _numText(num? v) => v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());

  Future<void> _load() async {
    final unit = ref.read(settingsProvider).weightUnit;
    final today = dateOnly(ref.read(clockProvider)().toLocal());
    if (_isNew) {
      _date = (widget.initialDate == null ? null : parsePlannedDate(widget.initialDate!)) ?? today;
      _initial = _snapshot();
      if (mounted) setState(() => _loading = false);
      return;
    }
    final w = await ref.read(scheduledWorkoutRepositoryProvider).byId(widget.scheduledId!);
    if (!mounted) return;
    setState(() {
      _existing = w;
      if (w != null) {
        _date = parsePlannedDate(w.plannedDate) ?? today;
        _title.text = w.title;
        _note.text = w.note ?? '';
        for (final i in w.items) {
          _items.add(
            _ItemDraft(
              i.exerciseId,
              note: i.note ?? '',
              rest: _numText(i.restSec),
              sets: [
                for (final s in i.sets)
                  _SetDraft(
                    base: s,
                    weight: s.targetWeightKg == null ? '' : Units.format(s.targetWeightKg!, unit, withUnit: false),
                    reps: _numText(s.targetReps),
                    repsMax: _numText(s.targetRepsMax),
                    rir: _numText(s.targetRir),
                  ),
              ],
            ),
          );
        }
      }
      _initial = _snapshot();
      _loading = false;
    });
  }

  Future<void> _pickDate() async {
    final cur = _date ?? dateOnly(ref.read(clockProvider)().toLocal());
    final d = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(cur.year - 5),
      lastDate: DateTime(cur.year + 5),
    );
    if (d != null && mounted) setState(() => _date = dateOnly(d));
  }

  Future<void> _addExercise() async {
    if (_items.length >= kScheduledMaxItems) return;
    final id = await context.push<String>(Routes.pickExercise);
    if (id == null || !mounted) return;
    setState(() => _items.add(_ItemDraft(id)));
  }

  void _addSet(_ItemDraft item) {
    if (item.sets.length >= kScheduledMaxSets) return;
    setState(() => item.sets.add(item.sets.isEmpty ? _SetDraft() : item.sets.last.copyValues()));
  }

  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _items.length) return;
    setState(() {
      final it = _items.removeAt(i);
      _items.insert(j, it);
    });
  }

  void _removeItem(int i) {
    setState(() => _items.removeAt(i).dispose());
  }

  void _removeSet(_ItemDraft item, int j) {
    setState(() => item.sets.removeAt(j).dispose());
  }

  /// 입력을 검증해 예정으로 만든다. 문제가 있으면 null과 함께 [_error]를 채운다.
  ScheduledWorkout? _build(AppLocalizations l) {
    final unit = ref.read(settingsProvider).weightUnit;
    String? fail(String m) {
      _error = m;
      return null;
    }

    final title = _title.text.trim();
    if (title.isEmpty) {
      fail(l.schedErrTitle);
      return null;
    }
    if (_items.isEmpty) {
      fail(l.schedErrNoItems);
      return null;
    }
    final items = <ScheduledItem>[];
    for (final it in _items) {
      if (it.sets.isEmpty) {
        fail(l.schedErrNoSets);
        return null;
      }
      int? rest;
      if (it.rest.text.trim().isNotEmpty) {
        rest = int.tryParse(it.rest.text.trim());
        if (rest == null || rest < 0 || rest > kScheduledMaxRestSec) {
          fail(l.schedErrNumber);
          return null;
        }
      }
      final sets = <ScheduledSet>[];
      for (final s in it.sets) {
        double? w;
        if (s.weight.text.trim().isNotEmpty) {
          final v = double.tryParse(s.weight.text.trim().replaceAll(',', '.'));
          if (v == null || v < 0) {
            fail(l.schedErrNumber);
            return null;
          }
          w = Units.fromDisplay(v, unit);
        }
        int parseInt(String t, {int max = 1000}) {
          if (t.trim().isEmpty) return -1;
          final v = int.tryParse(t.trim());
          return v == null || v < 0 || v > max ? -2 : v;
        }

        final r = parseInt(s.reps.text);
        final rm = parseInt(s.repsMax.text);
        final rir = parseInt(s.rir.text, max: 10);
        if (r == -2 || rm == -2 || rir == -2) {
          fail(l.schedErrNumber);
          return null;
        }
        if (rm != -1 && r == -1) {
          fail(l.schedErrRepsMaxNeedsReps);
          return null;
        }
        if (rm != -1 && r != -1 && rm < r) {
          fail(l.schedErrRepsRange);
          return null;
        }
        sets.add(
          ScheduledSet(
            isWarmup: s.warmup,
            targetWeightKg: w,
            targetReps: r == -1 ? null : r,
            targetRepsMax: rm == -1 ? null : rm,
            targetRir: rir == -1 ? null : rir,
            targetRpe: s.base.targetRpe,
            targetDurationSec: s.base.targetDurationSec,
          ),
        );
      }
      final note = it.note.text.trim();
      items.add(ScheduledItem(exerciseId: it.exerciseId, note: note.isEmpty ? null : note, restSec: rest, sets: sets));
    }
    final note = _note.text.trim();
    final date = _date ?? dateOnly(ref.read(clockProvider)().toLocal());
    final old = _existing;
    return ScheduledWorkout(
      id: old?.id ?? widget.scheduledId ?? newId(),
      plannedDate: dayKey(date),
      title: title,
      note: note.isEmpty ? null : note,
      items: items,
      skippedAt: old?.skippedAt,
      source: old?.source,
      importBatchId: old?.importBatchId,
    );
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final w = _build(l);
    if (w == null) {
      setState(() {});
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(scheduledWorkoutRepositoryProvider).upsert(w);
      if (!mounted) return;
      _saved = true;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(Routes.home);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(l.schedSaveError)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final names = ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};
    final date = _date;

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!_isNew && _existing == null) {
      body = Center(child: Text(l.schedActionError));
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          OutlinedButton.icon(
            key: const Key('sched-date'),
            onPressed: _pickDate,
            icon: const Icon(Icons.event),
            label: Text('${l.schedFieldDate}  ${date == null ? '' : dayKey(date)}'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('sched-title'),
            controller: _title,
            onChanged: (_) => setState(() {}),
            maxLength: 100,
            decoration: InputDecoration(labelText: l.schedFieldTitle, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 4),
          TextField(
            key: const Key('sched-note'),
            controller: _note,
            onChanged: (_) => setState(() {}),
            maxLength: 1000,
            maxLines: null,
            decoration: InputDecoration(labelText: l.schedFieldNote, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _items.length; i++)
            _ItemCard(
              key: _items[i].uid,
              index: i,
              item: _items[i],
              name: names[_items[i].exerciseId] == null
                  ? _items[i].exerciseId
                  : exerciseDisplayName(context, names[_items[i].exerciseId]!),
              unit: unit,
              isFirst: i == 0,
              isLast: i == _items.length - 1,
              onUp: () => _move(i, -1),
              onDown: () => _move(i, 1),
              onRemove: () => _removeItem(i),
              onAddSet: () => _addSet(_items[i]),
              onRemoveSet: (j) => _removeSet(_items[i], j),
              onChanged: () => setState(() {}),
            ),
          OutlinedButton.icon(
            key: const Key('sched-add-exercise'),
            onPressed: _items.length >= kScheduledMaxItems ? null : _addExercise,
            icon: const Icon(Icons.add),
            label: Text(l.schedAddExercise),
          ),
        ],
      );
    }

    final editable = !_loading && (_isNew || _existing != null);
    return UnsavedGuard(
      dirty: _dirty,
      child: Scaffold(
        appBar: AppBar(title: Text(_isNew ? l.schedEditNewTitle : l.schedEditEditTitle)),
        body: body,
        bottomNavigationBar: editable
            ? BottomActionBar(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _error!,
                          key: const Key('sched-error'),
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                        ),
                      ),
                    FilledButton(
                      key: const Key('sched-save'),
                      onPressed: _saving ? null : _save,
                      child: Text(l.schedSave),
                    ),
                  ],
                ),
              )
            : null,
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    super.key,
    required this.index,
    required this.item,
    required this.name,
    required this.unit,
    required this.isFirst,
    required this.isLast,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
    required this.onAddSet,
    required this.onRemoveSet,
    required this.onChanged,
  });
  final int index;
  final _ItemDraft item;
  final String name;
  final WeightUnit unit;
  final bool isFirst, isLast;
  final VoidCallback onUp, onDown, onRemove, onAddSet, onChanged;
  final void Function(int) onRemoveSet;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unitName = unit == WeightUnit.KG ? 'kg' : 'lb';
    return Card(
      key: Key('sched-item-$index'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(name, style: theme.textTheme.titleMedium)),
                IconButton(
                  key: Key('sched-up-$index'),
                  tooltip: l.schedMoveUp,
                  onPressed: isFirst ? null : onUp,
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  key: Key('sched-down-$index'),
                  tooltip: l.schedMoveDown,
                  onPressed: isLast ? null : onDown,
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  key: Key('sched-remove-$index'),
                  tooltip: l.schedRemoveExercise,
                  onPressed: onRemove,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 4),
            TextField(
              key: Key('sched-rest-$index'),
              controller: item.rest,
              onChanged: (_) => onChanged(),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                isDense: true,
                labelText: l.schedRestLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            for (var j = 0; j < item.sets.length; j++)
              _SetEditor(
                key: ValueKey(item.sets[j]),
                item: item.sets[j],
                itemIndex: index,
                setIndex: j,
                weightLabel: l.schedFieldWeight(unitName),
                canRemove: item.sets.length > 1,
                onRemove: () => onRemoveSet(j),
                onChanged: onChanged,
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: Key('sched-add-set-$index'),
                onPressed: item.sets.length >= kScheduledMaxSets ? null : onAddSet,
                icon: const Icon(Icons.add),
                label: Text(l.schedAddSet),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetEditor extends StatelessWidget {
  const _SetEditor({
    super.key,
    required this.item,
    required this.itemIndex,
    required this.setIndex,
    required this.weightLabel,
    required this.canRemove,
    required this.onRemove,
    required this.onChanged,
  });
  final _SetDraft item;
  final int itemIndex, setIndex;
  final String weightLabel;
  final bool canRemove;
  final VoidCallback onRemove, onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final k = '$itemIndex-$setIndex';
    Widget field(String id, TextEditingController c, String label, {bool decimal = false, int flex = 1}) => Expanded(
      flex: flex,
      child: TextField(
        key: Key('sched-$id-$k'),
        controller: c,
        onChanged: (_) => onChanged(),
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        decoration: InputDecoration(isDense: true, labelText: label, border: const OutlineInputBorder()),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                item.warmup ? l.schedWarmup : l.sessionTableSetLabel(setIndex + 1),
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(width: 8),
              FilterChip(
                key: Key('sched-warmup-$k'),
                label: Text(l.schedWarmup),
                selected: item.warmup,
                onSelected: (v) {
                  item.warmup = v;
                  onChanged();
                },
              ),
              const Spacer(),
              IconButton(
                key: Key('sched-remove-set-$k'),
                tooltip: l.schedRemoveSet,
                onPressed: canRemove ? onRemove : null,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Row(
            children: [
              field('w', item.weight, weightLabel, decimal: true, flex: 3),
              const SizedBox(width: 6),
              field('r', item.reps, l.schedFieldReps, flex: 2),
              const SizedBox(width: 6),
              field('rm', item.repsMax, l.schedFieldRepsMax, flex: 2),
              const SizedBox(width: 6),
              field('rir', item.rir, l.schedFieldRir, flex: 2),
            ],
          ),
        ],
      ),
    );
  }
}
