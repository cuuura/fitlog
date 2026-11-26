import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/ids.dart';
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
    final input = await showModalBottomSheet<ExerciseInput>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _CustomExerciseSheet(editing: editing),
    );
    if (input == null || !mounted) return;
    final ctrl = ref.read(exerciseControllerProvider);
    if (editing == null) {
      final e = await ctrl.createCustom(input);
      if (mounted) context.pop(e.id);
    } else {
      await ctrl.updateCustom(input);
    }
  }

  Future<void> _longPress(Exercise e) async {
    final l = AppLocalizations.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              key: const Key('custom-edit'),
              leading: const Icon(Icons.edit_outlined),
              title: Text(l.exerciseEdit),
              onTap: () => Navigator.pop(c, 'edit')),
          ListTile(
              key: const Key('custom-delete'),
              leading: const Icon(Icons.delete_outline),
              title: Text(l.commonDelete),
              onTap: () => Navigator.pop(c, 'delete')),
        ]),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      await _openForm(editing: e);
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(l.exerciseDeleteConfirm(exerciseDisplayName(context, e))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.commonCancel)),
            FilledButton(key: const Key('custom-delete-confirm'), onPressed: () => Navigator.pop(c, true), child: Text(l.commonDelete)),
          ],
        ),
      );
      if (ok == true) await ref.read(exerciseControllerProvider).deleteCustom(e.id);
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
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: l.exerciseSearchHint, border: const OutlineInputBorder(), isDense: true),
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
                        trailing: e.builtIn ? null : Chip(label: Text(l.exerciseCustomBadge)),
                        onTap: () => context.pop(e.id),
                        onLongPress: e.builtIn ? null : () => _longPress(e),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 내 종목 추가/수정 시트(EXR-2). 결과는 ExerciseInput.
class _CustomExerciseSheet extends StatefulWidget {
  const _CustomExerciseSheet({this.editing});
  final Exercise? editing;

  @override
  State<_CustomExerciseSheet> createState() => _CustomExerciseSheetState();
}

class _CustomExerciseSheetState extends State<_CustomExerciseSheet> {
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

  void _submit() {
    if (!_nameOk || _nameEn.text.trim().length > 60) {
      setState(() => _showError = true);
      return;
    }
    final en = _nameEn.text.trim();
    Navigator.pop(
      context,
      ExerciseInput(
        id: widget.editing?.id ?? newId(),
        nameKo: _nameKo.text.trim(),
        nameEn: en.isEmpty ? null : en,
        type: _type,
        primaryMuscle: _primary,
        secondaryMuscles: _secondary.where((m) => m != _primary).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.editing == null ? l.exerciseAddCustom : l.exerciseEditCustom, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              key: const Key('custom-name-ko'),
              controller: _nameKo,
              maxLength: 60,
              decoration: InputDecoration(labelText: l.exerciseNameKo, errorText: _showError && !_nameOk ? l.exerciseNameInvalid : null),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const Key('custom-name-en'),
              controller: _nameEn,
              maxLength: 60,
              decoration: InputDecoration(labelText: l.exerciseNameEn),
            ),
            const SizedBox(height: 8),
            Text(l.exerciseTypeLabel, style: Theme.of(context).textTheme.labelLarge),
            Wrap(spacing: 8, children: [
              for (final t in v01ExerciseTypes)
                ChoiceChip(
                  key: Key('custom-type-${t.name}'),
                  label: Text(typeLabel(l, t)),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ]),
            const SizedBox(height: 12),
            Text(l.exercisePrimaryMuscle, style: Theme.of(context).textTheme.labelLarge),
            Wrap(spacing: 8, children: [
              for (final m in Muscle.values)
                ChoiceChip(
                  key: Key('custom-primary-${m.name}'),
                  label: Text(muscleLabel(l, m)),
                  selected: _primary == m,
                  onSelected: (_) => setState(() => _primary = m),
                ),
            ]),
            const SizedBox(height: 12),
            Text(l.exerciseSecondaryMuscles, style: Theme.of(context).textTheme.labelLarge),
            Wrap(spacing: 8, children: [
              for (final m in Muscle.values.where((m) => m != _primary))
                FilterChip(
                  key: Key('custom-secondary-${m.name}'),
                  label: Text(muscleLabel(l, m)),
                  selected: _secondary.contains(m),
                  onSelected: (v) => setState(() => v ? _secondary.add(m) : _secondary.remove(m)),
                ),
            ]),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(key: const Key('custom-save'), onPressed: _submit, child: Text(l.commonSave)),
            ),
          ],
        ),
      ),
    );
  }
}
