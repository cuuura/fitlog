import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/ids.dart';
import '../../core/ui/confirm.dart';
import '../../core/ui/form_sheet.dart';
import '../../core/ui/row_menu.dart';
import '../../l10n/gen/app_localizations.dart';
import 'exercise_controller.dart';
import 'exercise_labels.dart';

class ExercisePickerPage extends ConsumerStatefulWidget {
  const ExercisePickerPage({super.key});

  @override
  ConsumerState<ExercisePickerPage> createState() => _ExercisePickerPageState();
}

class _ExercisePickerPageState extends ConsumerState<ExercisePickerPage> {
  String _query = '';
  Muscle? _muscle;
  ExerciseType? _type;
  List<Exercise> _items = const [];
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final my = ++_seq;
    final r = await ref.read(exerciseControllerProvider).search(query: _query, muscle: _muscle, type: _type);
    if (mounted && my == _seq) setState(() => _items = r);
  }

  Future<void> _openForm({Exercise? editing}) async {
    final id = await showFormSheet<String>(context, builder: (_) => _CustomExerciseSheet(editing: editing));
    if (id == null || !mounted) return;
    if (editing == null) context.pop(id);
  }

  Future<void> _delete(Exercise e) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirmAction(
      context,
      title: l.exerciseDeleteConfirm(exerciseDisplayName(context, e)),
      body: l.exerciseDeleteBody,
      action: l.commonDelete,
      destructive: true,
      confirmKey: const Key('custom-delete-confirm'),
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(exerciseControllerProvider).deleteCustom(e.id);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.commonError)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    ref.listen(allExercisesProvider, (_, _) => _reload());

    return Scaffold(
      appBar: AppBar(
        title: Text(l.exercisePickerTitle),
        actions: [
          IconButton(
            key: const Key('add-custom'),
            tooltip: l.exerciseAddCustom,
            icon: const Icon(Icons.add),
            onPressed: () => _openForm(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              key: const Key('exercise-search'),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l.exerciseSearchHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) {
                _query = v;
                _reload();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButton<Muscle?>(
                    key: const Key('filter-muscle'),
                    isExpanded: true,
                    value: _muscle,
                    items: [
                      DropdownMenuItem(value: null, child: Text(l.exerciseAllMuscles)),
                      for (final m in Muscle.values) DropdownMenuItem(value: m, child: Text(muscleLabel(l, m))),
                    ],
                    onChanged: (m) {
                      _muscle = m;
                      _reload();
                      setState(() {});
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<ExerciseType?>(
                    key: const Key('filter-type'),
                    isExpanded: true,
                    value: _type,
                    items: [
                      DropdownMenuItem(value: null, child: Text(l.exerciseAllTypes)),
                      for (final t in v01ExerciseTypes) DropdownMenuItem(value: t, child: Text(typeLabel(l, t))),
                    ],
                    onChanged: (t) {
                      _type = t;
                      _reload();
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? Center(child: Text(l.exerciseEmpty))
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final e = _items[i];
                      return ListTile(
                        key: Key('exercise-${e.id}'),
                        title: Text(exerciseDisplayName(context, e)),
                        subtitle: Text('${typeLabel(l, e.type)} · ${muscleLabel(l, e.primaryMuscle)}'),
                        trailing: e.builtIn
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Chip(label: Text(l.exerciseCustomBadge)),
                                  RowMenu<String>(
                                    key: Key('exercise-menu-${e.id}'),
                                    items: [
                                      RowMenuItem(value: 'edit', label: l.commonEdit, key: const Key('custom-edit')),
                                      RowMenuItem(
                                        value: 'delete',
                                        label: l.commonDelete,
                                        destructive: true,
                                        key: const Key('custom-delete'),
                                      ),
                                    ],
                                    onSelected: (v) => v == 'edit' ? _openForm(editing: e) : _delete(e),
                                  ),
                                ],
                              ),
                        onTap: () => context.pop(e.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 내 종목 추가/수정 시트(EXR-2). 저장은 시트 안에서 하고, 닫힐 때 종목 id를 돌려준다.
class _CustomExerciseSheet extends ConsumerStatefulWidget {
  const _CustomExerciseSheet({this.editing});
  final Exercise? editing;

  @override
  ConsumerState<_CustomExerciseSheet> createState() => _CustomExerciseSheetState();
}

class _CustomExerciseSheetState extends ConsumerState<_CustomExerciseSheet> {
  late final _nameKo = TextEditingController(text: widget.editing?.nameKo ?? '');
  late final _nameEn = TextEditingController(text: widget.editing?.nameEn ?? '');
  late ExerciseType _type = widget.editing?.type ?? ExerciseType.BARBELL;
  late Muscle _primary = widget.editing?.primaryMuscle ?? Muscle.CHEST;
  late final Set<Muscle> _secondary = {...?widget.editing?.secondaryMuscles};
  bool _showError = false;

  @override
  void dispose() {
    _nameKo.dispose();
    _nameEn.dispose();
    super.dispose();
  }

  bool get _nameOk {
    final n = _nameKo.text.trim();
    return n.isNotEmpty && n.length <= 60;
  }

  Future<String?> _submit() async {
    if (!_nameOk || _nameEn.text.trim().length > 60) {
      setState(() => _showError = true);
      return null;
    }
    final en = _nameEn.text.trim();
    final input = ExerciseInput(
      id: widget.editing?.id ?? newId(),
      nameKo: _nameKo.text.trim(),
      nameEn: en.isEmpty ? null : en,
      type: _type,
      primaryMuscle: _primary,
      secondaryMuscles: _secondary.where((m) => m != _primary).toList(),
    );
    final ctrl = ref.read(exerciseControllerProvider);
    if (widget.editing == null) {
      final e = await ctrl.createCustom(input);
      return e.id;
    }
    await ctrl.updateCustom(input);
    return input.id;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final label = Theme.of(context).textTheme.labelLarge;
    return FormSheet<String>(
      title: widget.editing == null ? l.exerciseAddCustom : l.exerciseEditCustom,
      submitLabel: widget.editing == null ? l.commonAdd : l.commonSave,
      submitKey: const Key('custom-save'),
      onSubmit: _submit,
      children: [
        TextField(
          key: const Key('custom-name-ko'),
          controller: _nameKo,
          maxLength: 60,
          decoration: InputDecoration(
            labelText: l.exerciseNameKo,
            errorText: _showError && !_nameOk ? l.exerciseNameInvalid : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          key: const Key('custom-name-en'),
          controller: _nameEn,
          maxLength: 60,
          decoration: InputDecoration(labelText: l.exerciseNameEn),
        ),
        Text(l.exerciseTypeLabel, style: label),
        Wrap(
          spacing: 8,
          children: [
            for (final t in v01ExerciseTypes)
              ChoiceChip(
                key: Key('custom-type-${t.name}'),
                label: Text(typeLabel(l, t)),
                selected: _type == t,
                onSelected: (_) => setState(() => _type = t),
              ),
          ],
        ),
        Text(l.exercisePrimaryMuscle, style: label),
        Wrap(
          spacing: 8,
          children: [
            for (final m in Muscle.values)
              ChoiceChip(
                key: Key('custom-primary-${m.name}'),
                label: Text(muscleLabel(l, m)),
                selected: _primary == m,
                onSelected: (_) => setState(() => _primary = m),
              ),
          ],
        ),
        Text(l.exerciseSecondaryMuscles, style: label),
        Wrap(
          spacing: 8,
          children: [
            for (final m in Muscle.values.where((m) => m != _primary))
              FilterChip(
                key: Key('custom-secondary-${m.name}'),
                label: Text(muscleLabel(l, m)),
                selected: _secondary.contains(m),
                onSelected: (v) => setState(() => v ? _secondary.add(m) : _secondary.remove(m)),
              ),
          ],
        ),
      ],
    );
  }
}
