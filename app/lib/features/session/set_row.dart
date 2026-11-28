// ignore_for_file: curly_braces_in_flow_control_structures
// B2 소유. 세트 한 줄 입력(LOG-2, LOG-5).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/units.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import 'current_set.dart';
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
    required this.label,
    this.expanded = false,
    this.isCurrent = false,
    this.onSelect,
    this.previous,
  });

  final Session session;
  final SessionExercise sessionExercise;
  final String exerciseName;
  final ExerciseType type;
  final WorkoutSet set;

  /// 이 종목 안에서 0부터 센 순번.
  final int index;

  /// 세트 열에 보일 짧은 이름: "1", "W1".
  final String label;

  /// 펼친 패널로 보이는지(화면에서 한 번에 하나).
  final bool expanded;

  /// 세션의 현재 세트(첫 미완료)인지.
  final bool isCurrent;

  /// 접힌 줄을 눌렀을 때.
  final VoidCallback? onSelect;

  /// "지난번" 참고용 세트.
  final WorkoutSet? previous;

  @override
  ConsumerState<SetRow> createState() => _SetRowState();
}

class _SetRowState extends ConsumerState<SetRow> {
  final _weight = TextEditingController();
  final _reps = TextEditingController();
  final _added = TextEditingController();
  final _note = TextEditingController();
  bool _details = false;
  bool? _showRir;

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
    for (final c in [_weight, _reps, _added, _note]) {
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

  Future<void> _toggleDone(bool? v) => completeSetChecked(
    context,
    ref,
    session: widget.session,
    se: widget.sessionExercise,
    set: widget.set,
    type: widget.type,
    exerciseName: widget.exerciseName,
    done: v == true,
    n: widget.index + 1,
  );

  Widget _field(
    String id,
    TextEditingController c,
    String label, {
    required bool decimal,
    bool signed = false,
    String? helper,
    VoidCallback? onMinus,
    VoidCallback? onPlus,
    bool big = false,
  }) {
    final iconSize = big ? 24.0 : 18.0;
    final box = big ? 48.0 : 36.0;
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
      style: big
          ? Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
            )
          : null,
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
                visualDensity: big ? null : VisualDensity.compact,
                tooltip: AppLocalizations.of(context).qaStepDecrease,
                icon: Icon(Icons.remove, size: iconSize),
                onPressed: onMinus,
              ),
        suffixIcon: onPlus == null
            ? null
            : IconButton(
                key: Key('$id-plus-${widget.set.id}'),
                visualDensity: big ? null : VisualDensity.compact,
                tooltip: AppLocalizations.of(context).qaStepIncrease,
                icon: Icon(Icons.add, size: iconSize),
                onPressed: onPlus,
              ),
        prefixIconConstraints: BoxConstraints(minWidth: box, minHeight: box),
        suffixIconConstraints: BoxConstraints(minWidth: box, minHeight: box),
      ),
    );
  }

  Widget _doneButton(AppLocalizations l, ColorScheme scheme, bool failed) {
    final s = widget.set;
    final IconData icon;
    Color? color;
    if (failed) {
      icon = Icons.error_outline;
      color = scheme.error;
    } else if (s.isCompleted) {
      icon = Icons.check_circle;
      color = scheme.primary;
    } else {
      icon = Icons.radio_button_unchecked;
    }
    return IconButton(
      key: Key('done-${s.id}'),
      tooltip: l.sessionSetComplete,
      isSelected: s.isCompleted,
      icon: Icon(icon, color: color),
      onPressed: () => _toggleDone(!s.isCompleted),
    );
  }

  Widget _numberCell(
    AppLocalizations l,
    ColorScheme scheme,
    bool failed, {
    bool bold = false,
  }) {
    final s = widget.set;
    return SizedBox(
      key: Key('drag-${s.id}'),
      width: kSetColWidth,
      height: 40,
      child: Center(
        child: Text(
          widget.label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: failed ? scheme.error : null,
            fontWeight: bold ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }

  static const _rpeValues = <double>[7, 7.5, 8, 8.5, 9, 9.5, 10];
  static const _rirValues = <int>[0, 1, 2, 3, 4, 5];

  /// RPE 칩 한 줄(7~10) 또는 RIR 칩(0~5). 선택한 칩을 다시 누르면 해제.
  Widget _rpeSection(AppLocalizations l, ColorScheme scheme) {
    final s = widget.set;
    final rir = _showRir ?? (s.rpe == null && s.rir != null);
    final labelId = rir ? 'rir' : 'rpe';
    Widget chip(
      String text,
      String keySuffix,
      bool selected,
      VoidCallback onTap,
    ) => ChoiceChip(
      key: Key('$labelId-${s.id}-$keySuffix'),
      label: Text(text),
      selected: selected,
      onSelected: (_) => onTap(),
    );
    final ctrl = ref.read(sessionControllerProvider);
    final chips = rir
        ? [
            for (final v in _rirValues)
              chip('$v', '$v', s.rir == v, () {
                ctrl.updateSet(s.copyWith(rir: () => s.rir == v ? null : v));
              }),
          ]
        : [
            for (final v in _rpeValues)
              chip(_numText(v), _numText(v), s.rpe == v, () {
                ctrl.updateSet(s.copyWith(rpe: () => s.rpe == v ? null : v));
              }),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              rir ? l.sessionCurRirLabel : l.sessionCurRpeLabel,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            TextButton(
              key: Key('rpe-toggle-${s.id}'),
              onPressed: () => setState(() => _showRir = !rir),
              child: Text(rir ? l.sessionCurShowRpe : l.sessionCurShowRir),
            ),
          ],
        ),
        Wrap(
          key: Key('$labelId-${s.id}'),
          spacing: 6,
          runSpacing: 4,
          children: chips,
        ),
      ],
    );
  }

  Widget _failedBadge(ColorScheme scheme, AppLocalizations l, WorkoutSet s) {
    return Row(
      key: Key('failed-${s.id}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, size: 14, color: scheme.error),
        const SizedBox(width: 2),
        Text(
          l.sessionTableFailed,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: scheme.error, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _differsBadge(ColorScheme scheme, AppLocalizations l, WorkoutSet s) {
    return Text(
      l.sessionPlanDiffers,
      key: Key('differs-${s.id}'),
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: scheme.tertiary),
    );
  }

  /// 접힌 한 줄: 세트 | 계획 | kg | 회 | 완료.
  Widget _compactRow(
    AppLocalizations l,
    ColorScheme scheme,
    Settings settings,
    bool failed,
  ) {
    final s = widget.set;
    final theme = Theme.of(context);
    final unit = settings.weightUnit;
    final cellStyle = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final dim = s.isCompleted && !failed
        ? cellStyle?.copyWith(color: scheme.onSurfaceVariant)
        : cellStyle;
    final w = _isBodyweight ? s.addedWeightKg : s.weightKg;
    var wText = w == null ? '–' : Units.format(w, unit, withUnit: false);
    if (_isBodyweight && w != null && w > 0) wText = '+$wText';
    final repsText = s.reps == null
        ? '–'
        : (failed ? '${s.reps}/${s.targetReps}' : '${s.reps}');
    Widget cell(String t, {Key? key, TextStyle? style}) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(t, key: key, style: style ?? dim, maxLines: 1),
    );
    return ReorderableDelayedDragStartListener(
      index: widget.index,
      child: InkWell(
        key: Key('row-${s.id}'),
        onTap: widget.onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _numberCell(l, scheme, failed),
                  Expanded(
                    flex: 3,
                    child: cell(
                      planCellText(s, unit),
                      key: Key('plan-${s.id}'),
                      style: cellStyle?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(flex: 2, child: cell(wText)),
                  Expanded(
                    flex: 2,
                    child: cell(
                      repsText,
                      style: failed
                          ? cellStyle?.copyWith(
                              color: scheme.error,
                              fontWeight: FontWeight.bold,
                            )
                          : null,
                    ),
                  ),
                  _doneButton(l, scheme, failed),
                ],
              ),
              if (failed || differsFromPlan(s))
                Padding(
                  padding: const EdgeInsets.only(left: kSetColWidth, bottom: 4),
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (failed) _failedBadge(scheme, l, s),
                      if (differsFromPlan(s)) _differsBadge(scheme, l, s),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 펼친 패널: 큰 숫자 + 스테퍼, 목표, 휴식 시간, 세부 입력.
  Widget _panel(
    AppLocalizations l,
    ColorScheme scheme,
    Settings settings,
    bool failed,
  ) {
    final s = widget.set;
    final type = widget.type;
    final unitName = settings.weightUnit == WeightUnit.KG ? 'kg' : 'lb';
    final theme = Theme.of(context);
    // 예정 운동 세션은 "80kg × 12~15 · RIR 3"(판정 없음), 프로그램 세션은 기존 목표 문구.
    final scheduledSession =
        widget.session.scheduledWorkoutId != null &&
        widget.session.programInstanceId == null;
    final String? targetLine = scheduledSession
        ? scheduledTargetText(l, s, settings.weightUnit)
        : (s.targetReps != null
              ? _targetText(l, s, settings.weightUnit)
              : null);
    final weightLabel = type == ExerciseType.DUMBBELL
        ? l.sessionWeightPerSide(unitName)
        : l.sessionWeight(unitName);

    final weightField = _field(
      'weight',
      _weight,
      weightLabel,
      decimal: true,
      big: true,
      onMinus: () => _step(_weight, -_weightStep, weight: true),
      onPlus: () => _step(_weight, _weightStep, weight: true),
    );
    final addedField = _field(
      'added',
      _added,
      l.sessionAddedWeight(unitName),
      decimal: true,
      signed: true,
      big: true,
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
      big: true,
      onMinus: () => _step(_reps, -1, weight: false),
      onPlus: () => _step(_reps, 1, weight: false),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Material(
        color: widget.isCurrent
            ? scheme.primaryContainer.withValues(alpha: 0.5)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: failed
                ? scheme.error
                : (widget.isCurrent ? scheme.primary : scheme.outlineVariant),
            width: widget.isCurrent ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _numberCell(l, scheme, failed, bold: true),
                  if (widget.isCurrent)
                    Container(
                      key: Key('current-${s.id}'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        l.sessionCurNow,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                  const Spacer(),
                  _doneButton(l, scheme, failed),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (targetLine != null)
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            targetLine,
                            key: Key('target-${s.id}'),
                            style: theme.textTheme.titleSmall,
                          ),
                          if (s.isAmrap)
                            Text(
                              l.sessionCurAmrapHint,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.primary,
                              ),
                            ),
                          if (differsFromPlan(s)) _differsBadge(scheme, l, s),
                          if (failed) _failedBadge(scheme, l, s),
                        ],
                      ),
                    if (widget.previous != null)
                      Text(
                        l.sessionLast(
                          formatSetBrief(
                            widget.previous!,
                            type,
                            settings.weightUnit,
                          ),
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 8),
                    _isBodyweight ? addedField : weightField,
                    const SizedBox(height: 8),
                    repsField,
                    if (settings.rpeInputEnabled) _rpeSection(l, scheme),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          l.sessionCurRest(
                            formatRestSec(
                              restSecFor(s, settings.defaultRestSec),
                            ),
                          ),
                          key: Key('rest-len-${s.id}'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: Key('more-${s.id}'),
                        icon: Icon(
                          _details ? Icons.expand_less : Icons.expand_more,
                        ),
                        label: Text(l.sessionSetMore),
                        onPressed: () => setState(() => _details = !_details),
                      ),
                    ),
                    if (_details) ...[
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
                          onPressed: () => ref
                              .read(sessionControllerProvider)
                              .deleteSet(s.id),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final s = widget.set;
    final scheme = Theme.of(context).colorScheme;
    final failed = isSetFailed(widget.session, widget.sessionExercise, s);

    final row = widget.expanded
        ? _panel(l, scheme, settings, failed)
        : _compactRow(l, scheme, settings, failed);

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
      child: failed && !widget.expanded
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

/// 세트 열 너비(표 머리글과 줄이 같이 쓴다).
const double kSetColWidth = 44;

/// 완료 체크 전 검증(`checkComplete`)을 거쳐 세트를 완료/해제한다. 체크박스와 하단 "N세트 완료"가 같이 쓴다.
/// 완료됐으면 true.
Future<bool> completeSetChecked(
  BuildContext context,
  WidgetRef ref, {
  required Session session,
  required SessionExercise se,
  required WorkoutSet set,
  required ExerciseType type,
  required String exerciseName,
  required bool done,
  required int n,
}) async {
  final l = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final ctrl = ref.read(sessionControllerProvider);
  if (!done) {
    await ctrl.setCompleted(session, set, false, timerLabel: '');
    return false;
  }
  switch (checkComplete(type, set)) {
    case SetCheck.needsReps:
      messenger.showSnackBar(SnackBar(content: Text(l.sessionNeedsReps)));
      return false;
    case SetCheck.needsWeight:
      messenger.showSnackBar(SnackBar(content: Text(l.sessionNeedsWeight)));
      return false;
    case SetCheck.ok:
  }
  final unit = ref.read(settingsProvider).weightUnit;
  String? nextText;
  final next = currentSetOf(session, excluding: set.id);
  if (next != null) {
    final ex = next.se.id == se.id
        ? null
        : ref.read(exerciseMapProvider).value?[next.se.exerciseId];
    final nextName = next.se.id == se.id
        ? exerciseName
        : (ex == null ? null : exerciseDisplayName(context, ex));
    if (nextName != null) {
      nextText = l.sessionCurNextNotif(
        nextName,
        formatSetBrief(next.set, ex?.type ?? type, unit),
      );
    }
  }
  await ctrl.setCompleted(
    session,
    set,
    true,
    timerLabel: l.sessionRestLabel(exerciseName, n),
    nextText: nextText,
  );
  return true;
}
