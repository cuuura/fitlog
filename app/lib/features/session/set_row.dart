// ignore_for_file: curly_braces_in_flow_control_structures
// B2 소유. 세트 한 줄 입력(LOG-2, LOG-5).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/units.dart';
import '../../l10n/gen/app_localizations.dart';
import 'plan_logic.dart';
import 'session_controller.dart';
import 'session_format.dart';

class SetRow extends ConsumerStatefulWidget {
  const SetRow({
    super.key,
    required this.session,
    required this.sessionExercise,
    required this.exerciseName,
    required this.type,
    required this.set,
    required this.index,
    this.previous,
  });

  final Session session;
  final SessionExercise sessionExercise;
  final String exerciseName;
  final ExerciseType type;
  final WorkoutSet set;

  /// 이 종목 안에서 0부터 센 순번.
  final int index;

  /// "지난번" 참고용 세트.
  final WorkoutSet? previous;

  @override
  ConsumerState<SetRow> createState() => _SetRowState();
}

class _SetRowState extends ConsumerState<SetRow> {
  final _weight = TextEditingController();
  final _reps = TextEditingController();
  final _added = TextEditingController();
  final _rpe = TextEditingController();
  final _rir = TextEditingController();
  final _note = TextEditingController();
  bool _expanded = false;

  final _errors = <String, String?>{};

  WeightUnit get _unit => ref.read(settingsProvider).weightUnit;
  bool get _isBodyweight => widget.type == ExerciseType.BODYWEIGHT;

  @override
  void initState() {
    super.initState();
    _syncFrom(widget.set, force: true);
  }

  @override
  void didUpdateWidget(SetRow old) {
    super.didUpdateWidget(old);
    _syncFrom(widget.set);
  }

  @override
  void dispose() {
    for (final c in [_weight, _reps, _added, _rpe, _rir, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---- 모델 <-> 텍스트 ----

  double? _parseNum(String t) => double.tryParse(t.trim().replaceAll(',', '.'));
  double? _parseKg(String t) {
    final v = _parseNum(t);
    return v == null ? null : Units.fromDisplay(v, _unit);
  }

  String _kgText(double? kg) =>
      kg == null ? '' : Units.format(kg, _unit, withUnit: false);
  String _numText(num? v) => v == null
      ? ''
      : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());

  void _setText(TextEditingController c, String t) {
    if (c.text != t)
      c.value = TextEditingValue(
        text: t,
        selection: TextSelection.collapsed(offset: t.length),
      );
  }

  /// 모델 값이 입력창이 뜻하는 값과 다를 때만 입력창을 갱신한다(타이핑 중 덮어쓰기 방지).
  void _syncFrom(WorkoutSet s, {bool force = false}) {
    bool stale(String id, bool differs) =>
        force || (differs && !_errors.containsKey(id));
    if (stale('weight', _parseKg(_weight.text) != s.weightKg))
      _setText(_weight, _kgText(s.weightKg));
    if (stale('reps', int.tryParse(_reps.text.trim()) != s.reps))
      _setText(_reps, _numText(s.reps));
    if (stale('added', _parseKg(_added.text) != s.addedWeightKg))
      _setText(_added, _kgText(s.addedWeightKg));
    if (stale('rpe', _parseNum(_rpe.text) != s.rpe))
      _setText(_rpe, _numText(s.rpe));
    if (stale('rir', int.tryParse(_rir.text.trim()) != s.rir))
      _setText(_rir, _numText(s.rir));
    if (force || (_note.text.isEmpty ? null : _note.text) != s.note)
      _setText(_note, s.note ?? '');
  }

  /// 입력창 값을 검증하고, 모두 유효하면 저장한다.
  void _commit() {
    final l = AppLocalizations.of(context);
    final errs = <String, String?>{};

    double? weight;
    if (_weight.text.trim().isNotEmpty) {
      weight = _parseKg(_weight.text);
      if (weight == null || !SetLimits.validWeight(weight))
        errs['weight'] = l.sessionInvalidWeight;
    }
    int? reps;
    if (_reps.text.trim().isNotEmpty) {
      reps = int.tryParse(_reps.text.trim());
      if (reps == null || !SetLimits.validReps(reps))
        errs['reps'] = l.sessionInvalidReps;
    }
    double? added;
    if (_added.text.trim().isNotEmpty) {
      added = _parseKg(_added.text);
      if (added == null) errs['added'] = l.sessionInvalidAdded;
    }
    double? rpe;
    if (_rpe.text.trim().isNotEmpty) {
      rpe = _parseNum(_rpe.text);
      if (rpe == null || !SetLimits.validRpe(rpe))
        errs['rpe'] = l.sessionInvalidRpe;
    }
    int? rir;
    if (_rir.text.trim().isNotEmpty) {
      rir = int.tryParse(_rir.text.trim());
      if (rir == null || !SetLimits.validRir(rir))
        errs['rir'] = l.sessionInvalidRir;
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(errs);
    });
    if (errs.isNotEmpty) return;

    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    final s = widget.set;
    final next = s.copyWith(
      weightKg: _isBodyweight ? null : () => weight,
      addedWeightKg: _isBodyweight ? () => added : null,
      reps: () => reps,
      rpe: () => rpe,
      rir: () => rir,
      note: () => note,
    );
    ref.read(sessionControllerProvider).updateSet(next);
  }

  void _step(
    TextEditingController c,
    double delta, {
    required bool weight,
    bool allowNegative = false,
  }) {
    final cur = _parseNum(c.text) ?? 0;
    var v = cur + delta;
    if (!allowNegative && v < 0) v = 0;
    _setText(
      c,
      weight
          ? Units.format(Units.fromDisplay(v, _unit), _unit, withUnit: false)
          : _numText(v.round()),
    );
    _commit();
  }

  double get _weightStep => _unit == WeightUnit.KG ? 2.5 : 5;

  Future<void> _toggleDone(bool? v) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ctrl = ref.read(sessionControllerProvider);
    final s = widget.set;
    if (v == true) {
      switch (checkComplete(widget.type, s)) {
        case SetCheck.needsReps:
          messenger.showSnackBar(SnackBar(content: Text(l.sessionNeedsReps)));
          return;
        case SetCheck.needsWeight:
          messenger.showSnackBar(SnackBar(content: Text(l.sessionNeedsWeight)));
          return;
        case SetCheck.ok:
      }
      await ctrl.setCompleted(
        widget.session,
        s,
        true,
        timerLabel: l.sessionRestLabel(widget.exerciseName, widget.index + 1),
      );
    } else {
      await ctrl.setCompleted(widget.session, s, false, timerLabel: '');
    }
  }

  Widget _field(
    String id,
    TextEditingController c,
    String label, {
    required bool decimal,
    bool signed = false,
    String? helper,
    VoidCallback? onMinus,
    VoidCallback? onPlus,
  }) {
    return TextField(
      key: Key('$id-${widget.set.id}'),
      controller: c,
      keyboardType: TextInputType.numberWithOptions(
        decimal: decimal,
        signed: signed,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          RegExp(signed ? r'[-0-9.,]' : (decimal ? r'[0-9.,]' : r'[0-9]')),
        ),
      ],
      textAlign: TextAlign.center,
      onChanged: (_) => _commit(),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        helperText: helper,
        errorText: _errors[id],
        errorMaxLines: 2,
        border: const OutlineInputBorder(),
        prefixIcon: onMinus == null
            ? null
            : IconButton(
                key: Key('$id-minus-${widget.set.id}'),
                visualDensity: VisualDensity.compact,
                tooltip: AppLocalizations.of(context).qaStepDecrease,
                icon: const Icon(Icons.remove, size: 18),
                onPressed: onMinus,
              ),
        suffixIcon: onPlus == null
            ? null
            : IconButton(
                key: Key('$id-plus-${widget.set.id}'),
                visualDensity: VisualDensity.compact,
                tooltip: AppLocalizations.of(context).qaStepIncrease,
                icon: const Icon(Icons.add, size: 18),
                onPressed: onPlus,
              ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 36,
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 36,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final unitName = settings.weightUnit == WeightUnit.KG ? 'kg' : 'lb';
    final s = widget.set;
    final type = widget.type;

    final scheme = Theme.of(context).colorScheme;
    final failed = isSetFailed(widget.sessionExercise, s);
    final weightLabel = type == ExerciseType.DUMBBELL
        ? l.sessionWeightPerSide(unitName)
        : l.sessionWeight(unitName);

    final weightField = _field(
      'weight',
      _weight,
      weightLabel,
      decimal: true,
      onMinus: () => _step(_weight, -_weightStep, weight: true),
      onPlus: () => _step(_weight, _weightStep, weight: true),
    );
    final addedField = _field(
      'added',
      _added,
      l.sessionAddedWeight(unitName),
      decimal: true,
      signed: true,
      helper: l.sessionAddedWeightHelp,
      onMinus: () =>
          _step(_added, -_weightStep, weight: true, allowNegative: true),
      onPlus: () =>
          _step(_added, _weightStep, weight: true, allowNegative: true),
    );
    final repsField = _field(
      'reps',
      _reps,
      l.sessionReps,
      decimal: false,
      onMinus: () => _step(_reps, -1, weight: false),
      onPlus: () => _step(_reps, 1, weight: false),
    );

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ReorderableDragStartListener(
                index: widget.index,
                child: Tooltip(
                  message: l.sessionReorderHandle,
                  child: SizedBox(
                    key: Key('drag-${s.id}'),
                    width: 28,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        s.isWarmup
                            ? l.sessionWarmupShort
                            : '${widget.index + 1}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(color: failed ? scheme.error : null),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(child: _isBodyweight ? addedField : weightField),
              const SizedBox(width: 6),
              Expanded(child: repsField),
              Checkbox(
                key: Key('done-${s.id}'),
                value: s.isCompleted,
                semanticLabel: l.sessionSetComplete,
                onChanged: _toggleDone,
              ),
              IconButton(
                key: Key('more-${s.id}'),
                tooltip: l.sessionSetMore,
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ],
          ),
          if (s.targetReps != null)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 2),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _targetText(l, s, settings.weightUnit),
                    key: Key('target-${s.id}'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (differsFromPlan(s))
                    Text(
                      l.sessionPlanDiffers,
                      key: Key('differs-${s.id}'),
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: scheme.tertiary),
                    ),
                  if (failed)
                    Text(
                      l.sessionSetFailed,
                      key: Key('failed-${s.id}'),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
            ),
          if (widget.previous != null)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 2),
              child: Text(
                l.sessionLast(
                  formatSetBrief(widget.previous!, type, settings.weightUnit),
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 8, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    key: Key('warmup-${s.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.sessionWarmup),
                    value: s.isWarmup,
                    onChanged: (v) => ref
                        .read(sessionControllerProvider)
                        .updateSet(s.copyWith(isWarmup: v)),
                  ),
                  if (settings.rpeInputEnabled)
                    Row(
                      children: [
                        Expanded(
                          child: _field(
                            'rpe',
                            _rpe,
                            l.sessionRpe,
                            decimal: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _field(
                            'rir',
                            _rir,
                            l.sessionRir,
                            decimal: false,
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    key: Key('note-${s.id}'),
                    controller: _note,
                    onChanged: (_) => _commit(),
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: l.sessionSetNote,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: Key('delete-${s.id}'),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(l.sessionSetDelete),
                      onPressed: () =>
                          ref.read(sessionControllerProvider).deleteSet(s.id),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    return Dismissible(
      key: ValueKey('dismiss-${s.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete_outline),
      ),
      onDismissed: (_) => ref.read(sessionControllerProvider).deleteSet(s.id),
      child: failed
          ? ColoredBox(
              color: scheme.errorContainer.withValues(alpha: 0.4),
              child: row,
            )
          : row,
    );
  }

  static String _targetText(AppLocalizations l, WorkoutSet s, WeightUnit unit) {
    final w = s.targetWeightKg;
    final reps = s.targetReps!;
    if (w == null)
      return s.isAmrap
          ? l.sessionTargetAmrapReps(reps)
          : l.sessionTargetReps(reps);
    final ws = Units.format(w, unit);
    return s.isAmrap
        ? l.sessionTargetAmrap(reps, ws)
        : l.sessionTarget(reps, ws);
  }
}
