// B1 소유. 충돌 하나를 보여주고 해결을 고르는 카드.
import 'dart:convert';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/ai_dto.dart';
import '../../core/api/dto.dart';
import '../../core/routes.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';

String conflictCodeLabel(AppLocalizations l, ConflictCode? c) => switch (c) {
  ConflictCode.UNKNOWN_EXERCISE => l.importConflictUnknownExercise,
  ConflictCode.SESSION_OVERLAP => l.importConflictSessionOverlap,
  ConflictCode.BODY_SAME_DAY => l.importConflictBodySameDay,
  ConflictCode.PROGRAM_NAME_EXISTS => l.importConflictProgramNameExists,
  ConflictCode.ID_EXISTS => l.importConflictIdExists,
  ConflictCode.PLAN_MISMATCH => l.importConflictPlanMismatch,
  ConflictCode.INSTANCE_NEEDS_VALUE => l.importConflictInstanceNeedsValue,
  null => '',
};

String resolutionActionLabel(AppLocalizations l, ResolutionAction a) => switch (a) {
  ResolutionAction.SKIP => l.importActionSkip,
  ResolutionAction.KEEP_BOTH => l.importActionKeepBoth,
  ResolutionAction.REPLACE => l.importActionReplace,
  ResolutionAction.MAP_TO => l.importActionMapTo,
  ResolutionAction.CREATE => l.importActionCreate,
  ResolutionAction.UNLINK => l.importActionUnlink,
  ResolutionAction.SET => l.importActionSet,
};

String _show(Object? v) => v is Map || v is List ? jsonEncode(v) : '$v';

class ConflictCard extends ConsumerStatefulWidget {
  final Conflict conflict;
  final Resolution? resolution;
  final WeightUnit unit;
  final void Function(Resolution?) onChanged;
  const ConflictCard({
    super.key,
    required this.conflict,
    required this.resolution,
    required this.unit,
    required this.onChanged,
  });

  @override
  ConsumerState<ConflictCard> createState() => _ConflictCardState();
}

class _ConflictCardState extends ConsumerState<ConflictCard> {
  /// 매개변수가 필요한 해결(MAP_TO·CREATE·SET)은 값을 고르기 전에도 선택된 것으로 보여준다.
  ResolutionAction? _pending;

  Conflict get c => widget.conflict;
  ResolutionAction? get _selected => _pending ?? widget.resolution?.action;

  Future<void> _choose(ResolutionAction a) async {
    final cur = widget.resolution;
    switch (a) {
      case ResolutionAction.SKIP:
      case ResolutionAction.KEEP_BOTH:
      case ResolutionAction.REPLACE:
      case ResolutionAction.UNLINK:
        setState(() => _pending = a);
        widget.onChanged(Resolution(a));
      case ResolutionAction.MAP_TO:
        setState(() => _pending = a);
        if (cur?.action != a) widget.onChanged(null);
      case ResolutionAction.CREATE:
        final ex = await showModalBottomSheet<Map<String, Object?>>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => _CreateSheet(initial: cur?.action == a ? cur!.exercise : null),
        );
        if (ex == null || !mounted) return;
        setState(() => _pending = a);
        widget.onChanged(Resolution(a, exercise: ex));
      case ResolutionAction.SET:
        final v = await showModalBottomSheet<Map<String, Object?>>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => _SetSheet(
            suggested: c.suggested,
            unit: widget.unit,
            initial: cur?.action == a ? cur!.value : null,
          ),
        );
        if (v == null || !mounted) return;
        setState(() => _pending = a);
        widget.onChanged(Resolution(a, value: v));
    }
  }

  Future<void> _pickOther() async {
    final id = await context.push<String>(Routes.pickExercise);
    if (id == null || !mounted) return;
    setState(() => _pending = ResolutionAction.MAP_TO);
    widget.onChanged(Resolution(ResolutionAction.MAP_TO, exerciseId: id));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final resolved = widget.resolution != null;
    final actions = c.allowed;
    final existing = c.existing;
    return Card(
      key: ValueKey('conflict-${c.conflictId}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  resolved ? Icons.check_circle : Icons.error_outline,
                  size: 20,
                  color: resolved ? theme.colorScheme.primary : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.code == null ? c.message : conflictCodeLabel(l, c.code),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (c.code != null && c.message.isNotEmpty) Text(c.message),
            if (c.path.isNotEmpty)
              Text(c.path, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            if (existing != null && existing.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(l.importExisting, style: theme.textTheme.labelMedium),
              for (final e in existing.entries.take(6)) Text('${e.key}: ${_show(e.value)}', style: theme.textTheme.bodySmall),
            ],
            RadioGroup<ResolutionAction>(
              groupValue: _selected,
              onChanged: (v) {
                if (v != null) _choose(v);
              },
              child: Column(
                children: [
                  for (final a in actions)
                    RadioListTile<ResolutionAction>(
                      key: ValueKey('action-${c.conflictId}-${a.name}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: a,
                      title: Text(resolutionActionLabel(l, a)),
                      subtitle: _subtitle(l, a),
                    ),
                ],
              ),
            ),
            if (_selected == ResolutionAction.REPLACE)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(l.importReplaceWarning, style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (_selected == ResolutionAction.MAP_TO) _mapTo(l),
          ],
        ),
      ),
    );
  }

  Widget? _subtitle(AppLocalizations l, ResolutionAction a) {
    final r = widget.resolution;
    if (r == null || r.action != a) return null;
    if (a == ResolutionAction.CREATE && r.exercise != null) {
      final t = ExerciseType.values.where((e) => e.name == r.exercise!['type']).firstOrNull;
      final m = Muscle.values.where((e) => e.name == r.exercise!['primaryMuscle']).firstOrNull;
      if (t != null && m != null) return Text(l.importCreatedSummary(typeLabel(l, t), muscleLabel(l, m)));
    }
    if (a == ResolutionAction.SET && r.value != null) {
      final n = ((r.value!['tm'] as Map?)?.length ?? 0) + ((r.value!['working'] as Map?)?.length ?? 0);
      return Text(l.importSetSummary(n));
    }
    return null;
  }

  Widget _mapTo(AppLocalizations l) {
    final chosen = widget.resolution?.exerciseId;
    final inCandidates = c.candidates.any((e) => e.exerciseId == chosen);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c.candidates.isNotEmpty) Text(l.importCandidates, style: Theme.of(context).textTheme.labelMedium),
        RadioGroup<String>(
          groupValue: chosen,
          onChanged: (v) {
            if (v != null) widget.onChanged(Resolution(ResolutionAction.MAP_TO, exerciseId: v));
          },
          child: Column(
            children: [
              for (final e in c.candidates)
                RadioListTile<String>(
                  key: ValueKey('candidate-${e.exerciseId}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: e.exerciseId,
                  title: Text(e.nameKo ?? e.nameEn ?? e.exerciseId),
                  subtitle: e.nameKo != null && e.nameEn != null ? Text(e.nameEn!) : null,
                ),
              if (chosen != null && !inCandidates)
                RadioListTile<String>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: chosen,
                  title: _ExerciseName(id: chosen),
                ),
            ],
          ),
        ),
        OutlinedButton.icon(
          key: ValueKey('pick-other-${c.conflictId}'),
          onPressed: _pickOther,
          icon: const Icon(Icons.search),
          label: Text(l.importPickOtherExercise),
        ),
      ],
    );
  }
}

class _ExerciseName extends ConsumerWidget {
  final String id;
  const _ExerciseName({required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<Exercise?>(
    future: ref.read(exerciseRepositoryProvider).byId(id),
    builder: (context, snap) => Text(snap.data == null ? id : exerciseDisplayName(context, snap.data!)),
  );
}

class _CreateSheet extends StatefulWidget {
  final Map<String, Object?>? initial;
  const _CreateSheet({this.initial});

  @override
  State<_CreateSheet> createState() => _CreateSheetState();
}

class _CreateSheetState extends State<_CreateSheet> {
  ExerciseType? _type;
  Muscle? _muscle;

  @override
  void initState() {
    super.initState();
    _type = ExerciseType.values.where((e) => e.name == widget.initial?['type']).firstOrNull;
    _muscle = Muscle.values.where((e) => e.name == widget.initial?['primaryMuscle']).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.importCreateSheetTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(l.importCreateType, style: theme.textTheme.labelLarge),
          Wrap(
            spacing: 8,
            children: [
              for (final t in ExerciseType.values)
                ChoiceChip(
                  key: ValueKey('create-type-${t.name}'),
                  label: Text(typeLabel(l, t)),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(l.importCreateMuscle, style: theme.textTheme.labelLarge),
          Wrap(
            spacing: 8,
            children: [
              for (final m in Muscle.values)
                ChoiceChip(
                  key: ValueKey('create-muscle-${m.name}'),
                  label: Text(muscleLabel(l, m)),
                  selected: _muscle == m,
                  onSelected: (_) => setState(() => _muscle = m),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('create-confirm'),
              onPressed: _type == null || _muscle == null
                  ? null
                  : () => Navigator.of(context).pop(<String, Object?>{'type': _type!.name, 'primaryMuscle': _muscle!.name}),
              child: Text(l.importCreateConfirm),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetSheet extends StatefulWidget {
  final Map<String, Object?>? suggested;
  final Map<String, Object?>? initial;
  final WeightUnit unit;
  const _SetSheet({required this.suggested, required this.unit, this.initial});

  @override
  State<_SetSheet> createState() => _SetSheetState();
}

class _SetSheetState extends State<_SetSheet> {
  /// 'tm' 또는 'working' → 키 → 입력칸.
  final Map<String, Map<String, TextEditingController>> _fields = {'tm': {}, 'working': {}};
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    for (final group in _fields.keys) {
      final sug = (widget.suggested?[group] as Map?)?.cast<String, Object?>() ?? const {};
      final ini = (widget.initial?[group] as Map?)?.cast<String, Object?>() ?? const {};
      for (final k in {...sug.keys, ...ini.keys}) {
        final kg = ((ini[k] ?? sug[k]) as num?)?.toDouble();
        _fields[group]![k] = TextEditingController(text: kg == null ? '' : Units.format(kg, widget.unit, withUnit: false));
      }
    }
  }

  @override
  void dispose() {
    for (final g in _fields.values) {
      for (final c in g.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  void _confirm() {
    final out = <String, Object?>{};
    var bad = false;
    for (final e in _fields.entries) {
      final m = <String, Object?>{};
      for (final f in e.value.entries) {
        final raw = f.value.text.trim().replaceAll(',', '.');
        final v = double.tryParse(raw);
        if (v == null || v <= 0) {
          bad = true;
        } else {
          m[f.key] = Units.fromDisplay(v, widget.unit);
        }
      }
      if (m.isNotEmpty) out[e.key] = m;
    }
    if (bad || out.isEmpty) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unit = widget.unit == WeightUnit.KG ? 'kg' : 'lb';
    final empty = _fields.values.every((g) => g.isEmpty);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.importSetSheetTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (empty) Text(l.importSetNoKeys),
          for (final group in const ['tm', 'working'])
            for (final f in _fields[group]!.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: TextField(
                  key: ValueKey('set-$group-${f.key}'),
                  controller: f.value,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: '${f.key} · ${group == 'tm' ? l.importSetTm(unit) : l.importSetWorking(unit)}',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
          if (_invalid) Text(l.importSetInvalid, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('set-confirm'),
              onPressed: empty ? null : _confirm,
              child: Text(l.importCreateConfirm),
            ),
          ),
        ],
      ),
    );
  }
}
