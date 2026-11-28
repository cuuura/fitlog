// 날 하나의 편집: 이름·요일, 종목 목록, 종목별 세트 줄. 정의 Map을 바로 고치고 [onChanged]로 알린다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../core/ui/row_menu.dart';
import '../../core/ui/undo.dart';
import '../../core/widgets/reorder.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import 'editor_common.dart';
import 'editor_fields.dart';
import 'editor_sheets.dart';
import 'editor_text.dart';
import 'program_definition.dart';

class DayEditorPage extends ConsumerStatefulWidget {
  const DayEditorPage({
    super.key,
    required this.def,
    required this.dayIndex,
    required this.names,
    required this.errors,
    required this.onChanged,
  });
  final ProgramDef def;
  final int dayIndex;
  final LiftNames names;
  final EditorErrors errors;
  final VoidCallback onChanged;

  @override
  ConsumerState<DayEditorPage> createState() => _DayEditorPageState();
}

class _DayEditorPageState extends ConsumerState<DayEditorPage> {
  ProgramDef get def => widget.def;
  int get d => widget.dayIndex;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  Future<String?> _pickExerciseId() async {
    final id = await context.push<String>(Routes.pickExercise);
    if (id == null || !mounted) return null;
    try {
      final e = await ref.read(exerciseRepositoryProvider).byId(id);
      if (e != null) widget.names.put(id, e.nameKo);
      _lastKeyName = e == null ? null : keyNameOf(e);
    } catch (_) {
      _lastKeyName = null;
    }
    return id;
  }

  String? _lastKeyName;

  Future<void> _addExercise() async {
    final id = await _pickExerciseId();
    if (id == null) return;
    def.addExercise(d, exerciseId: id, nameForKey: _lastKeyName);
    _changed();
  }

  Future<void> _swap(int j) async {
    final id = await _pickExerciseId();
    if (id == null) return;
    final key = def.exercise(d, j)['lift'] as String;
    final lift = (def.lifts[key] ??= <String, dynamic>{}) as Json;
    lift['exercise'] = {'id': id};
    _changed();
  }

  Future<void> _settings(int j) async {
    final r = await showExerciseSheet(context, exercise: def.exercise(d, j), liftLabels: widget.names.labels(def));
    if (r == null) return;
    final ex = r.exercise;
    if (r.newKey) {
      final old = def.exercise(d, j)['lift'] as String;
      final key = def.newLiftKey(old);
      def.lifts[key] = deepCopy(def.lifts[old] ?? <String, dynamic>{});
      ex['lift'] = key;
    }
    def.exercises(d)[j] = ex;
    _changed();
  }

  void _removeExercise(int j) {
    final removed = def.exercises(d).removeAt(j);
    _changed();
    showUndoSnack(
      ScaffoldMessenger.of(context),
      AppLocalizations.of(context),
      message: ET.exerciseDeleted,
      onUndo: () async {
        def.exercises(d).insert(j.clamp(0, def.exercises(d).length), removed);
        if (mounted) _changed();
      },
    );
  }

  Future<void> _addSet(int j) async {
    final sets = def.sets(d, j);
    final base = sets.isEmpty ? ProgramDef.defaultSet() : deepCopy(sets.last as Json)
      ..remove('weekly');
    final r = await showSetSheet(context, set: base, isNew: true);
    if (r == null) return;
    sets.add(r);
    _changed();
  }

  Future<void> _editSet(int j, int k) async {
    final sets = def.sets(d, j);
    final r = await showSetSheet(context, set: sets[k] as Json, isNew: false);
    if (r == null) return;
    sets[k] = r;
    _changed();
  }

  void _removeSet(int j, int k) {
    final sets = def.sets(d, j);
    final removed = sets.removeAt(k);
    _changed();
    showUndoSnack(
      ScaffoldMessenger.of(context),
      AppLocalizations.of(context),
      message: ET.setDeleted,
      onUndo: () async {
        sets.insert(k.clamp(0, sets.length), removed);
        if (mounted) _changed();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final day = def.day(d);
    final prefix = '/days/$d';
    final exs = def.exercises(d);
    final dayErrs = [...widget.errors.at('$prefix/name'), ...widget.errors.at('$prefix/weekday'), ...widget.errors.at('$prefix/exercises')];
    return Scaffold(
      appBar: AppBar(title: Text('${day['name'] ?? ''}')),
      body: ReorderableListView(
        padding: const EdgeInsets.all(16),
        buildDefaultDragHandles: false,
        onReorderStart: (_) => reorderHaptic(),
        onReorderItem: (from, to) {
          def.moveExercise(d, from, to);
          _changed();
        },
        proxyDecorator: reorderProxy(
          compact: (i) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text(widget.names.labelFor(def, (exs[i] as Json)['lift'] as String), style: theme.textTheme.titleMedium),
          ),
        ),
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MapTextField(
              key: const Key('day-name'),
              map: day,
              field: 'name',
              label: ET.dayName,
              maxLength: 40,
              errorText: widget.errors.textAt('$prefix/name'),
              onChanged: _changed,
            ),
            const SizedBox(height: 4),
            MapDropdown(
              key: const Key('day-weekday'),
              map: day,
              field: 'weekday',
              label: ET.weekday,
              options: {for (final w in kWeekdays) w: ET.weekdayName(w)},
              noneLabel: ET.weekdayNone,
              errorText: widget.errors.textAt('$prefix/weekday'),
              onChanged: _changed,
            ),
            if (dayErrs.isNotEmpty && exs.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(dayErrs.join('\n'), style: TextStyle(color: c.fail)),
              ),
            if (exs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(ET.noExercises, textAlign: TextAlign.center, style: TextStyle(color: c.fg2)),
              ),
          ],
        ),
        footer: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            key: const Key('day-add-exercise'),
            onPressed: _addExercise,
            icon: const Icon(Icons.add),
            label: const Text(ET.addExercise),
          ),
        ),
        children: [
          for (var j = 0; j < exs.length; j++)
            _ExerciseCard(
              key: ObjectKey(exs[j]),
              index: j,
              def: def,
              day: d,
              names: widget.names,
              errors: widget.errors,
              onSettings: () => _settings(j),
              onSwap: () => _swap(j),
              onRemove: () => _removeExercise(j),
              onAddSet: () => _addSet(j),
              onEditSet: (k) => _editSet(j, k),
              onRemoveSet: (k) => _removeSet(j, k),
              onReorderSets: (from, to) {
                final sets = def.sets(d, j);
                sets.insert(to, sets.removeAt(from));
                _changed();
              },
              onDuplicateSet: (k) {
                final sets = def.sets(d, j);
                sets.insert(k + 1, deepCopy(sets[k] as Json));
                _changed();
              },
            ),
        ],
      ),
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({
    super.key,
    required this.index,
    required this.def,
    required this.day,
    required this.names,
    required this.errors,
    required this.onSettings,
    required this.onSwap,
    required this.onRemove,
    required this.onAddSet,
    required this.onEditSet,
    required this.onRemoveSet,
    required this.onReorderSets,
    required this.onDuplicateSet,
  });
  final int index, day;
  final ProgramDef def;
  final LiftNames names;
  final EditorErrors errors;
  final VoidCallback onSettings, onSwap, onRemove, onAddSet;
  final void Function(int) onEditSet, onRemoveSet, onDuplicateSet;
  final void Function(int, int) onReorderSets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final ex = def.exercise(day, index);
    final key = ex['lift'] as String? ?? '';
    final sets = def.sets(day, index);
    final prefix = '/days/$day/exercises/$index';
    final own = [...errors.at(prefix), ...errors.at('$prefix/lift'), ...errors.at('$prefix/sets'), ...errors.at('$prefix/superset'), ...errors.at('$prefix/restSec')];
    final tags = [
      key,
      if (ex['accessory'] == true) ET.accessory,
      if (ex['countsForProgression'] == false) '판정 제외',
      if (ex['superset'] is String) '슈퍼세트 ${ex['superset']}',
      if (ex['restSec'] is num) '휴식 ${fmtNum(ex['restSec'] as num)}초',
    ];
    return Card(
      key: Key('ex-card-$index'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    key: Key('ex-handle-$index'),
                    padding: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
                    child: const Icon(Icons.drag_handle),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(names.labelFor(def, key), style: theme.textTheme.titleMedium),
                      Text(tags.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
                    ],
                  ),
                ),
                RowMenu<String>(
                  key: Key('ex-menu-$index'),
                  items: [
                    RowMenuItem(value: 'settings', label: ET.exerciseSettings, key: Key('ex-settings-$index')),
                    RowMenuItem(value: 'swap', label: ET.exerciseSwap, key: Key('ex-swap-$index')),
                    RowMenuItem(value: 'delete', label: ET.exerciseDelete, destructive: true, key: Key('ex-delete-$index')),
                  ],
                  onSelected: (v) => switch (v) {
                    'settings' => onSettings(),
                    'swap' => onSwap(),
                    _ => onRemove(),
                  },
                ),
              ],
            ),
            if (own.isNotEmpty) Text(own.join('\n'), style: TextStyle(color: c.fail)),
            ReorderableListView.builder(
              key: Key('ex-sets-$index'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: sets.length,
              onReorderStart: (_) => reorderHaptic(),
              onReorderItem: onReorderSets,
              proxyDecorator: reorderProxy(),
              itemBuilder: (context, k) {
                final s = sets[k] as Json;
                final errs = errors.under('$prefix/sets/$k');
                return InkWell(
                  key: ObjectKey(s),
                  onTap: () => onEditSet(k),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: k,
                          child: Padding(
                            key: Key('set-handle-$index-$k'),
                            padding: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
                            child: const Icon(Icons.drag_handle, size: 20),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(setSummary(s), key: Key('set-line-$index-$k')),
                              if (ProgramDef.hasWeekly(s))
                                Text(ET.weeklyKept, style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
                              if (errs.isNotEmpty)
                                Text(errs.join('\n'), style: theme.textTheme.bodySmall?.copyWith(color: c.fail)),
                            ],
                          ),
                        ),
                        RowMenu<String>(
                          key: Key('set-menu-$index-$k'),
                          items: [
                            RowMenuItem(value: 'dup', label: ET.setDuplicate, key: Key('set-dup-$index-$k')),
                            RowMenuItem(value: 'del', label: ET.setDelete, destructive: true, key: Key('set-del-$index-$k')),
                          ],
                          onSelected: (v) => v == 'dup' ? onDuplicateSet(k) : onRemoveSet(k),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: Key('ex-add-set-$index'),
                onPressed: onAddSet,
                icon: const Icon(Icons.add),
                label: const Text(ET.addSet),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
