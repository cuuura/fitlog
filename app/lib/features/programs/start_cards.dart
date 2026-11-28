// P2 소유. 맞추기 화면(program_start_page)의 카드·칸 위젯.
// 입력 중에는 칸 하나(와 그 칸을 보는 요약)만 다시 그린다: 값은 TextEditingController·ValueNotifier로만 흐른다.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../l10n/gen/app_localizations.dart';
import 'program_common.dart';
import 'programs_providers.dart';

String startDateText(AppLocalizations l, DateTime d) =>
    l.programStartDateLabel(d.month, d.day, weekdayLabel(l, programWeekdayCodes[d.weekday - 1]));

String weekdaysText(AppLocalizations l, Iterable<String> days) => days.map((d) => weekdayLabel(l, d)).join('·');

/// 이 프로그램과 겹치는 기존 인스턴스(같은 프로그램이거나 운동 요일이 하나라도 같음).
class StartOverlap {
  const StartOverlap(this.running, this.days, this.same);
  final RunningProgram running;
  final List<String> days;
  final bool same;
  bool get paused => running.instance.status == InstanceStatus.PAUSED;
}

List<StartOverlap> computeOverlaps(StartView v) {
  final mine = programWeekdays(v.program.definition);
  return [
    for (final r in v.running)
      if (r.instance.programId == v.program.id || r.weekdays.any(mine.contains))
        StartOverlap(r, [for (final d in r.weekdays) if (mine.contains(d)) d], r.instance.programId == v.program.id),
  ];
}

enum StartChipTone { ok, warn, neutral }

class StartChip extends StatelessWidget {
  const StartChip(this.text, this.tone, {super.key});
  final String text;
  final StartChipTone tone;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (bg, fg) = switch (tone) {
      StartChipTone.ok => (c.accentSoft, c.accentStrong),
      StartChipTone.warn => (c.warnSoft, c.warn),
      StartChipTone.neutral => (null, c.fg2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        border: bg == null ? Border.all(color: c.line) : null,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg)),
    );
  }
}

/// 접히는 설정 카드: 제목 + 요약 한 줄 + 상태 칩.
class StartCard extends StatelessWidget {
  const StartCard({
    super.key,
    required this.title,
    required this.summary,
    this.chip,
    required this.expanded,
    required this.child,
  });
  final String title;
  final Widget summary;
  final Widget? chip;
  final ValueNotifier<bool> expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: ValueListenableBuilder<bool>(
        valueListenable: expanded,
        builder: (context, open, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              expanded: open,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.md),
                onTap: () => expanded.value = !open,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [Text(title, style: theme.textTheme.titleSmall), ?chip],
                              ),
                              DefaultTextStyle.merge(
                                style: theme.textTheme.bodySmall?.copyWith(color: c.fg2),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                child: summary,
                              ),
                            ],
                          ),
                        ),
                        Icon(open ? Icons.expand_less : Icons.expand_more, color: c.fg2),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (open) Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 14), child: child),
          ],
        ),
      ),
    );
  }
}

/// 맨 위 "첫 운동 · 날짜 · 그날 종목". 세트·무게는 계산하지 않는다(서버 미리 계산이 생기면 이 자리에 붙인다).
class FirstWorkoutBanner extends StatelessWidget {
  const FirstWorkoutBanner({
    super.key,
    required this.view,
    required this.startDate,
    required this.policy,
  });
  final StartView view;
  final ValueListenable<DateTime> startDate;
  final ValueListenable<SkipPolicy> policy;

  @override
  Widget build(BuildContext context) {
    final first = programFirstDay(view.program.definition);
    if (first == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final names = [for (final k in first.lifts) view.lifts[k]?.name(context) ?? k];
    return ListenableBuilder(
      listenable: Listenable.merge([startDate, policy]),
      builder: (context, _) {
        final date = firstWorkoutDate(view.program.definition, startDate.value, policy.value);
        return Container(
          key: const Key('start-first'),
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(AppRadius.md)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.programStartFirstTitle(startDateText(l, date)), style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                [if (first.name.isNotEmpty) first.name, ...names].join(' · '),
                style: theme.textTheme.bodyMedium?.copyWith(color: c.fg2),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 겹침 알림 + "같이 진행 / 기존 것 일시정지".
class OverlapNotice extends StatelessWidget {
  const OverlapNotice({super.key, required this.overlaps, required this.pauseOthers});
  final List<StartOverlap> overlaps;
  final ValueNotifier<bool> pauseOthers;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final hasActive = overlaps.any((o) => !o.paused);
    return Container(
      key: const Key('start-overlap'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.warnSoft,
        border: Border.all(color: c.warn),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final o in overlaps)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                o.same || o.days.isEmpty
                    ? l.programStartOverlapSame(o.running.instance.name)
                    : l.programStartOverlapDays(o.running.instance.name, weekdaysText(l, o.days)),
                style: theme.textTheme.titleSmall,
              ),
            ),
          ValueListenableBuilder<bool>(
            valueListenable: pauseOthers,
            builder: (context, pause, _) => Text(
              !hasActive
                  ? l.programStartOverlapPaused
                  : (pause ? l.programStartOverlapPause : l.programStartOverlapBoth),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (hasActive) ...[
            const SizedBox(height: 10),
            ValueListenableBuilder<bool>(
              valueListenable: pauseOthers,
              builder: (context, pause, _) => SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  key: const Key('start-keep'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(l.programStartKeepBoth, maxLines: 2, textAlign: TextAlign.center),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(l.programStartKeepPause, maxLines: 2, textAlign: TextAlign.center),
                    ),
                  ],
                  selected: {pause},
                  onSelectionChanged: (s) => pauseOthers.value = s.first,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────── 시작 무게 ─────────────────────────

enum _SrcKind { measured, estimated }

/// 모르는 출처 값(앞으로 "3대에서 유추" 등이 추가돼도)은 null로 보고 칩·근거 없이 그린다.
_SrcKind? _sourceKind(SuggestItem s) => switch (s.oneRmSource?.name) {
  'MEASURED' => _SrcKind.measured,
  'ESTIMATED' => _SrcKind.estimated,
  _ => null,
};

String _itemId(SuggestItem s) => '${s.needs.name}:${s.key}';

typedef StartDetail = ({String path, String message});

class WeightsSection extends StatelessWidget {
  const WeightsSection({
    super.key,
    required this.items,
    required this.nameOf,
    required this.controllers,
    required this.focusNodes,
    required this.rowKeys,
    required this.unit,
    required this.stepKg,
    required this.expanded,
    required this.optionalExpanded,
    required this.submitted,
    required this.details,
  });

  final List<SuggestItem> items;
  final String Function(SuggestItem) nameOf;
  final Map<String, TextEditingController> controllers;
  final Map<String, FocusNode> focusNodes;
  final Map<String, GlobalKey> rowKeys;
  final WeightUnit unit;
  final double stepKg;
  final ValueNotifier<bool> expanded;
  final ValueNotifier<bool> optionalExpanded;
  final ValueListenable<bool> submitted;
  final ValueListenable<List<StartDetail>> details;

  Listenable get _all => Listenable.merge(controllers.values.toList());
  List<SuggestItem> get _required => [for (final s in items) if (!s.optional) s];
  List<SuggestItem> get _optional => [for (final s in items) if (s.optional) s];

  double? _kg(SuggestItem s) {
    final v = parseNumber(controllers[_itemId(s)]!.text);
    return v == null || v <= 0 ? null : Units.fromDisplay(v, unit);
  }

  void _setKg(SuggestItem s, double kg) =>
      controllers[_itemId(s)]!.text = Units.format(kg, unit, withUnit: false);

  double _light(double sug) => roundToStep(sug * 0.9, stepKg);

  int? _selectedPreset() {
    final withSug = [for (final s in items) if (s.suggestedKg != null) s];
    if (withSug.isEmpty) return null;
    bool all(double Function(double) f) => withSug.every((s) {
      final v = _kg(s);
      return v != null && (v - f(s.suggestedKg!)).abs() < 0.011;
    });
    if (all((x) => x)) return 0;
    if (all(_light)) return 1;
    return null;
  }

  void _applyPreset(int p) {
    for (final s in items) {
      final sug = s.suggestedKg;
      if (sug != null) _setKg(s, p == 0 ? sug : _light(sug));
    }
  }

  /// 빈 봉(20kg, 데드리프트류는 원판 포함 40kg)으로 비어 있는 필수 칸을 채운다.
  void _fillBar() {
    for (final s in _required) {
      if (_kg(s) != null) continue;
      final name = '${s.key} ${nameOf(s)}'.toLowerCase();
      _setKg(s, name.contains('deadlift') || name.contains('데드') ? 40 : 20);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final req = _required;
    final opt = _optional;
    final anyTm = items.any((s) => s.needs == SuggestNeeds.TM);
    final anySug = items.any((s) => s.suggestedKg != null);
    final anyNoSug = req.any((s) => s.suggestedKg == null);

    Widget row(SuggestItem s) => WeightRow(
      key: rowKeys[_itemId(s)],
      item: s,
      name: nameOf(s),
      controller: controllers[_itemId(s)]!,
      focus: focusNodes[_itemId(s)]!,
      unit: unit,
      stepKg: stepKg,
      submitted: submitted,
      details: details,
    );

    return StartCard(
      key: const Key('start-weights-card'),
      title: l.programStartWeightsTitle,
      expanded: expanded,
      summary: ListenableBuilder(
        listenable: _all,
        builder: (context, _) {
          final filled = [for (final s in req) if (_kg(s) != null) s];
          if (filled.length < req.length) {
            final missing = [for (final s in req) if (_kg(s) == null) nameOf(s)];
            return Text(l.programStartWeightsMissing(missing.join(', ')));
          }
          final text = filled.map((s) => '${nameOf(s)} ${Units.format(_kg(s)!, unit, withUnit: false)}').join(' · ');
          return Text('$text ${unit == WeightUnit.KG ? 'kg' : 'lb'}');
        },
      ),
      chip: req.isEmpty
          ? null
          : ListenableBuilder(
              listenable: _all,
              builder: (context, _) {
                final need = req.where((s) => _kg(s) == null).length;
                return need == 0
                    ? StartChip(l.programStartWeightsReady(req.length), StartChipTone.ok, key: const Key('start-weights-chip'))
                    : StartChip(l.programStartWeightsNeed(need), StartChipTone.warn, key: const Key('start-weights-chip'));
              },
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (anyTm) ...[
            Text(l.programStartWeightsHelp, style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
            const SizedBox(height: 10),
          ],
          if (anySug) ...[
            ListenableBuilder(
              listenable: _all,
              builder: (context, _) {
                final sel = _selectedPreset();
                return SegmentedButton<int>(
                  key: const Key('start-preset'),
                  showSelectedIcon: false,
                  emptySelectionAllowed: true,
                  segments: [
                    ButtonSegment(value: 0, label: Text(l.programStartPresetSuggest, maxLines: 2, textAlign: TextAlign.center)),
                    ButtonSegment(value: 1, label: Text(l.programStartPresetLight, maxLines: 2, textAlign: TextAlign.center)),
                  ],
                  selected: {?sel},
                  onSelectionChanged: (s) {
                    if (s.isNotEmpty) _applyPreset(s.first);
                  },
                );
              },
            ),
            const SizedBox(height: 10),
          ],
          for (final s in req) ...[row(s), const SizedBox(height: 10)],
          if (anyNoSug) ...[
            Text(l.programStartNoRecordHint, style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const Key('start-fill-bar'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _fillBar,
                child: Text(l.programStartFillBar),
              ),
            ),
          ],
          if (opt.isNotEmpty)
            ValueListenableBuilder<bool>(
              valueListenable: optionalExpanded,
              builder: (context, open, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const Key('start-optional-toggle'),
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => optionalExpanded.value = !open,
                      icon: Icon(open ? Icons.expand_less : Icons.expand_more),
                      label: Text(l.programStartOptionalGroup(opt.length)),
                    ),
                  ),
                  if (open) ...[for (final s in opt) ...[row(s), const SizedBox(height: 10)]],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 종목 하나의 무게 칸. 이 칸 안의 변화만 이 위젯에서 다시 그린다.
class WeightRow extends StatefulWidget {
  const WeightRow({
    super.key,
    required this.item,
    required this.name,
    required this.controller,
    required this.focus,
    required this.unit,
    required this.stepKg,
    required this.submitted,
    required this.details,
  });
  final SuggestItem item;
  final String name;
  final TextEditingController controller;
  final FocusNode focus;
  final WeightUnit unit;
  final double stepKg;
  final ValueListenable<bool> submitted;
  final ValueListenable<List<StartDetail>> details;

  @override
  State<WeightRow> createState() => _WeightRowState();
}

class _WeightRowState extends State<WeightRow> {
  final _calcW = TextEditingController();
  final _calcR = TextEditingController();
  bool _calcOpen = false;
  bool _calcBad = false;

  SuggestItem get s => widget.item;

  @override
  void dispose() {
    _calcW.dispose();
    _calcR.dispose();
    super.dispose();
  }

  double? _kg() {
    final v = parseNumber(widget.controller.text);
    return v == null || v <= 0 ? null : Units.fromDisplay(v, widget.unit);
  }

  void _set(double kg) => widget.controller.text = Units.format(kg, widget.unit, withUnit: false);

  void _step(int dir) {
    final cur = _kg();
    if (cur == null && dir < 0) return;
    final next = roundToStep((cur ?? 0) + dir * widget.stepKg, widget.stepKg);
    if (next <= 0) return;
    _set(next > 500 ? 500 : next);
  }

  void _calc() {
    final w = parseNumber(_calcW.text);
    final r = int.tryParse(_calcR.text.trim());
    final rm = (w == null || r == null) ? null : epleyOneRm(Units.fromDisplay(w, widget.unit), r);
    if (rm == null) {
      setState(() => _calcBad = true);
      return;
    }
    _set(roundToStep(rm * (s.needs == SuggestNeeds.TM ? 0.9 : 0.7), widget.stepKg));
    setState(() {
      _calcOpen = false;
      _calcBad = false;
    });
  }

  String? _basis(AppLocalizations l) {
    final rm = s.oneRmKg;
    final kind = _sourceKind(s);
    final sug = s.suggestedKg;
    if (rm == null || kind == null) return sug == null ? l.programStartNoBasis : null;
    final measured = kind == _SrcKind.measured;
    String f(double v) => Units.format(v, widget.unit);
    if (sug == null) return measured ? l.programStartMeasured(f(rm)) : l.programStartEstimated(f(rm));
    if (s.needs == SuggestNeeds.TM) {
      final pct = (sug / rm * 100).round();
      return measured ? l.progStartBasisMeasured(f(rm), f(sug), pct) : l.progStartBasisEstimated(f(rm), f(sug), pct);
    }
    return measured ? l.progStartBasisWorkingMeasured(f(rm), f(sug)) : l.progStartBasisWorkingEstimated(f(rm), f(sug));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final unitText = widget.unit == WeightUnit.KG ? 'kg' : 'lb';
    final stepText = Units.format(widget.stepKg, widget.unit);
    final kind = _sourceKind(s);
    final id = _itemId(s);
    final isTm = s.needs == SuggestNeeds.TM;

    Widget stepButton(bool up) => IconButton(
      key: Key('start-${up ? 'up' : 'down'}-$id'),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      tooltip: up ? l.programStartStepUp(widget.name, stepText) : l.programStartStepDown(widget.name, stepText),
      icon: Icon(up ? Icons.add : Icons.remove),
      onPressed: () => _step(up ? 1 : -1),
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.name, style: theme.textTheme.titleSmall)),
              if (kind != null) ...[
                const SizedBox(width: 8),
                StartChip(
                  kind == _SrcKind.measured ? l.progStartSourceMeasured : l.progStartSourceEstimated,
                  kind == _SrcKind.measured ? StartChipTone.ok : StartChipTone.neutral,
                  key: Key('start-source-$id'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final sug = s.suggestedKg;
              final v = _kg();
              if (sug != null && v != null && (v - sug).abs() / sug > 0.4) {
                return Text(
                  l.programStartFar(Units.format(sug, widget.unit)),
                  key: Key('start-far-$id'),
                  style: theme.textTheme.bodySmall?.copyWith(color: c.warn),
                );
              }
              final b = _basis(l);
              return b == null ? const SizedBox.shrink() : Text(b, style: theme.textTheme.bodySmall?.copyWith(color: c.fg2));
            },
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              stepButton(false),
              Expanded(
                child: ListenableBuilder(
                  listenable: Listenable.merge([widget.controller, widget.submitted, widget.details]),
                  builder: (context, _) {
                    final errors = [
                      for (final d in widget.details.value)
                        if (d.path.endsWith('/${s.key}')) d.message,
                    ];
                    final required = widget.submitted.value && !s.optional && _kg() == null;
                    return TextField(
                      key: ValueKey('start-$id'),
                      controller: widget.controller,
                      focusNode: widget.focus,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                      style: AppNum.medium(context),
                      decoration: InputDecoration(
                        labelText: isTm ? l.progStartTmField : l.progStartWorkingField,
                        suffixText: unitText,
                        errorText: errors.isNotEmpty ? errors.join('\n') : (required ? l.programStartRequired : null),
                        errorMaxLines: 3,
                        helperText: s.optional ? l.progStartOptionalHint : null,
                        helperMaxLines: 2,
                        border: const OutlineInputBorder(),
                      ),
                    );
                  },
                ),
              ),
              stepButton(true),
            ],
          ),
          if (s.suggestedKg == null) ...[
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: Key('start-calc-$id'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => setState(() => _calcOpen = !_calcOpen),
                child: Text(l.programStartCalcLink),
              ),
            ),
            if (_calcOpen)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      key: Key('start-calc-w-$id'),
                      controller: _calcW,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                      decoration: InputDecoration(labelText: l.programStartCalcWeight, suffixText: unitText, isDense: true, border: const OutlineInputBorder()),
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      key: Key('start-calc-r-$id'),
                      controller: _calcR,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(labelText: l.programStartCalcReps, isDense: true, border: const OutlineInputBorder()),
                    ),
                  ),
                  FilledButton.tonal(
                    key: Key('start-calc-ok-$id'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _calc,
                    child: Text(l.programStartCalcOk),
                  ),
                  if (_calcBad)
                    Text(l.programStartCalcInvalid, style: theme.textTheme.bodySmall?.copyWith(color: c.warn)),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────── 일정 ─────────────────────────

class ScheduleSection extends StatelessWidget {
  const ScheduleSection({
    super.key,
    required this.view,
    required this.overlaps,
    required this.today,
    required this.startDate,
    required this.policy,
    required this.pauseOthers,
    required this.expanded,
    required this.onPickDate,
  });
  final StartView view;
  final List<StartOverlap> overlaps;
  final DateTime today;
  final ValueNotifier<DateTime> startDate;
  final ValueNotifier<SkipPolicy> policy;
  final ValueNotifier<bool> pauseOthers;
  final ValueNotifier<bool> expanded;
  final VoidCallback onPickDate;

  /// 다른 진행 중(ACTIVE) 프로그램의 운동 요일. "기존 것 일시정지"를 고르면 겹치는 것은 뺀다.
  Set<String> _otherDays(bool pause) {
    final skip = pause ? {for (final o in overlaps) o.running.instance.id} : const <String>{};
    return {
      for (final r in view.running)
        if (r.instance.status == InstanceStatus.ACTIVE && !skip.contains(r.instance.id)) ...r.weekdays,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final mine = programWeekdays(view.program.definition);
    final fixedOk = programHasWeekdays(view.program.definition);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.fg2);
    String policyText(SkipPolicy p) => p == SkipPolicy.SHIFT ? l.progSkipShiftSeg : l.progSkipFixedSeg;

    return StartCard(
      key: const Key('start-schedule-card'),
      title: l.programStartScheduleTitle,
      expanded: expanded,
      summary: ListenableBuilder(
        listenable: Listenable.merge([startDate, policy]),
        builder: (context, _) {
          final d = startDate.value;
          final isToday = d.year == today.year && d.month == today.month && d.day == today.day;
          return Text(
            l.programStartScheduleSummary(
              isToday ? l.programStartDateToday : startDateText(l, d),
              mine.isEmpty ? l.programStartAnyDay : weekdaysText(l, mine),
              policyText(policy.value),
            ),
          );
        },
      ),
      chip: overlaps.isEmpty
          ? null
          : ValueListenableBuilder<bool>(
              valueListenable: pauseOthers,
              builder: (context, pause, _) {
                final other = _otherDays(pause);
                final both = mine.where(other.contains).length;
                return both == 0
                    ? const SizedBox.shrink()
                    : StartChip(l.programStartOverlapChip(both), StartChipTone.warn, key: const Key('start-overlap-chip'));
              },
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.programStartDate, style: theme.textTheme.labelLarge),
          ValueListenableBuilder<DateTime>(
            valueListenable: startDate,
            builder: (context, d, _) => ListTile(
              key: const Key('start-date'),
              contentPadding: EdgeInsets.zero,
              minVerticalPadding: 8,
              leading: const Icon(Icons.calendar_today),
              title: Text(startDateText(l, d)),
              onTap: onPickDate,
            ),
          ),
          if (mine.isNotEmpty)
            ValueListenableBuilder<bool>(
              valueListenable: pauseOthers,
              builder: (context, pause, _) {
                final other = _otherDays(pause);
                final anyBoth = mine.any(other.contains);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      key: const Key('start-weekdays'),
                      children: [
                        for (final code in programWeekdayCodes)
                          Expanded(child: _DayCell(code: code, on: mine.contains(code), other: other.contains(code))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        Text(l.programStartLegendThis, style: muted),
                        if (other.isNotEmpty) Text(l.programStartLegendOther, style: muted),
                        if (anyBoth) Text(l.programStartLegendBoth, style: muted?.copyWith(color: c.warn)),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                );
              },
            ),
          Text(l.programStartPolicy, style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          ValueListenableBuilder<SkipPolicy>(
            valueListenable: policy,
            builder: (context, p, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<SkipPolicy>(
                  key: const Key('start-skip-policy'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: SkipPolicy.SHIFT,
                      label: Text(l.progSkipShiftSeg, maxLines: 2, textAlign: TextAlign.center),
                    ),
                    ButtonSegment(
                      value: SkipPolicy.FIXED_DATE,
                      enabled: fixedOk,
                      label: Text(l.progSkipFixedSeg, maxLines: 2, textAlign: TextAlign.center),
                    ),
                  ],
                  selected: {p},
                  onSelectionChanged: (s) => policy.value = s.first,
                ),
                const SizedBox(height: 6),
                Text(
                  p == SkipPolicy.SHIFT
                      ? l.programSkipShiftDesc
                      : (fixedOk ? l.programSkipFixedDesc : l.programSkipFixedUnavailable),
                  style: muted,
                ),
                if (!fixedOk && p == SkipPolicy.SHIFT) Text(l.programSkipFixedUnavailable, style: muted),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.code, required this.on, required this.other});
  final String code;
  final bool on;
  final bool other;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final day = weekdayLabel(l, code);
    final both = on && other;
    final label = both
        ? l.programStartDayBoth(day)
        : on
        ? l.programStartDayThis(day)
        : other
        ? l.programStartDayOther(day)
        : l.programStartDayNone(day);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        key: Key('start-day-$code'),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: both ? c.warnSoft : (on ? c.accentSoft : null),
          border: Border.all(color: both ? c.warn : (on ? c.accent : c.line)),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(day, style: TextStyle(color: both ? c.warn : (on ? c.accentStrong : c.fg2), fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: other ? c.fg2 : Colors.transparent, shape: BoxShape.circle),
            ),
          ],
        ),
      ),
    );
  }
}

/// 오프라인 안내(프로그램 화면은 온라인 전용).
class StartOffline extends StatelessWidget {
  const StartOffline({super.key, required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    return Center(
      key: const Key('start-offline'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 40, color: c.fg2),
            const SizedBox(height: 12),
            Text(l.programStartOffline, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(l.commonRetry)),
          ],
        ),
      ),
    );
  }
}
