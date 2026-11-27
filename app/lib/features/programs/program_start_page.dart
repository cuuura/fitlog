// B1 소유. PRG-13·14: 시작 무게(TM/작업)·시작일·건너뛰기 방식을 정하고 인스턴스를 만든다.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/session_controller.dart' show deviceTimezoneProvider;
import 'program_common.dart';
import 'programs_providers.dart';

class ProgramStartPage extends ConsumerWidget {
  const ProgramStartPage({super.key, required this.programId});
  final String programId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(startViewProvider(programId));
    return Scaffold(
      appBar: AppBar(title: Text(l.programStartTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(startViewProvider(programId))),
        data: (v) => _StartForm(view: v),
      ),
    );
  }
}

class _StartForm extends ConsumerStatefulWidget {
  const _StartForm({required this.view});
  final StartView view;

  @override
  ConsumerState<_StartForm> createState() => _StartFormState();
}

class _StartFormState extends ConsumerState<_StartForm> {
  final Map<String, TextEditingController> _ctrls = {};
  late DateTime _startDate;
  SkipPolicy _policy = SkipPolicy.SHIFT;
  bool _busy = false;
  bool _submitted = false;
  List<({String path, String message})> _details = const [];
  String? _error;

  String _id(SuggestItem s) => '${s.needs.name}:${s.key}';

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider)().toLocal();
    _startDate = DateTime(now.year, now.month, now.day);
    final unit = ref.read(settingsProvider).weightUnit;
    for (final s in widget.view.suggestions) {
      _ctrls[_id(s)] = TextEditingController(
        text: s.suggestedKg == null ? '' : Units.format(s.suggestedKg!, unit, withUnit: false),
      );
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  double? _valueKg(SuggestItem s) {
    final v = parseNumber(_ctrls[_id(s)]!.text);
    if (v == null || v <= 0) return null;
    return Units.fromDisplay(v, ref.read(settingsProvider).weightUnit);
  }

  bool get _complete => widget.view.suggestions.every((s) => _valueKg(s) != null);

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(_startDate.year - 1),
      lastDate: DateTime(_startDate.year + 1),
    );
    if (d != null) setState(() => _startDate = d);
  }

  List<String> _errorsFor(SuggestItem s) => [
    for (final d in _details)
      if (d.path.endsWith('/${s.key}')) d.message,
  ];

  Future<void> _submit() async {
    setState(() {
      _submitted = true;
      _error = null;
      _details = const [];
    });
    if (!_complete) return;
    final tm = <String, double>{};
    final working = <String, double>{};
    for (final s in widget.view.suggestions) {
      (s.needs == SuggestNeeds.TM ? tm : working)[s.key] = _valueKg(s)!;
    }
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final tz = await ref.read(deviceTimezoneProvider)();
      final id = newId();
      await ref.read(programRepositoryProvider).startInstance(StartInstance(
        id: id,
        programId: widget.view.program.id,
        startDate: _startDate,
        tz: tz,
        skipPolicy: _policy,
        tm: tm,
        working: working,
      ));
      await ref.read(planCacheProvider).refresh(instanceId: id);
      if (!mounted) return;
      context.pushReplacement(Routes.instanceDetail(id));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _details = e.details;
        _error = e.details.isNotEmpty ? l.programStartValidation : errorMessage(l, e, fallback: l.programStartFailed);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l.programStartFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final unitText = unit == WeightUnit.KG ? 'kg' : 'lb';
    final def = widget.view.program.definition;
    final fixedOk = programHasWeekdays(def);
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final unmatched = [
      for (final d in _details)
        if (!widget.view.suggestions.any((s) => d.path.endsWith('/${s.key}'))) d,
    ];

    Widget basis(SuggestItem s) {
      final rm = s.oneRmKg;
      final src = s.oneRmSource;
      if (rm == null || src == null) {
        return s.suggestedKg == null ? Text(l.programStartNoBasis, style: theme.textTheme.bodySmall) : const SizedBox.shrink();
      }
      final measured = src == OneRmSource.MEASURED;
      final tm = s.suggestedKg;
      final String text;
      if (tm == null) {
        text = measured ? l.programStartMeasured(Units.format(rm, unit)) : l.programStartEstimated(Units.format(rm, unit));
      } else if (s.needs == SuggestNeeds.TM) {
        final pct = (tm / rm * 100).round();
        text = measured
            ? l.progStartBasisMeasured(Units.format(rm, unit), Units.format(tm, unit), pct)
            : l.progStartBasisEstimated(Units.format(rm, unit), Units.format(tm, unit), pct);
      } else {
        text = measured
            ? l.progStartBasisWorkingMeasured(Units.format(rm, unit), Units.format(tm, unit))
            : l.progStartBasisWorkingEstimated(Units.format(rm, unit), Units.format(tm, unit));
      }
      return Text(text, style: theme.textTheme.bodySmall?.copyWith(color: colors.fg2));
    }

    Widget sourceChip(SuggestItem s) {
      final src = s.oneRmSource;
      if (src == null) return const SizedBox.shrink();
      final measured = src == OneRmSource.MEASURED;
      return Container(
        key: Key('start-source-${_id(s)}'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: measured ? colors.accentSoft : null,
          border: measured ? null : Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          measured ? l.progStartSourceMeasured : l.progStartSourceEstimated,
          style: theme.textTheme.labelMedium?.copyWith(color: measured ? colors.accentStrong : colors.fg2),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(widget.view.program.name, style: theme.textTheme.titleLarge),
              if (widget.view.suggestions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(l.progStartTmHeader, style: theme.textTheme.titleMedium),
                Text(l.programStartWeightsHelp, style: theme.textTheme.bodySmall?.copyWith(color: colors.fg2)),
                for (final s in widget.view.suggestions) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.line),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.view.lifts[s.key]?.name(context) ?? s.key,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            sourceChip(s),
                          ],
                        ),
                        const SizedBox(height: 2),
                        basis(s),
                        const SizedBox(height: 10),
                        TextField(
                          key: ValueKey('start-${_id(s)}'),
                          controller: _ctrls[_id(s)],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                          onChanged: (_) => setState(() {}),
                          style: AppNum.medium(context),
                          decoration: InputDecoration(
                            labelText: s.needs == SuggestNeeds.TM ? l.progStartTmField : l.progStartWorkingField,
                            suffixText: unitText,
                            errorText: _errorsFor(s).isNotEmpty
                                ? _errorsFor(s).join('\n')
                                : (_submitted && _valueKg(s) == null ? l.programStartRequired : null),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 24),
              Text(l.programStartDate, style: theme.textTheme.titleMedium),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today),
                title: Text(formatDate(_startDate)),
                onTap: _pickDate,
              ),
              const SizedBox(height: 8),
              Text(l.programStartPolicy, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<SkipPolicy>(
                  key: const Key('start-skip-policy'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: SkipPolicy.SHIFT,
                      label: Text(l.progSkipShiftSeg, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    ButtonSegment(
                      value: SkipPolicy.FIXED_DATE,
                      enabled: fixedOk,
                      label: Text(l.progSkipFixedSeg, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                  selected: {_policy},
                  onSelectionChanged: (s) => setState(() => _policy = s.first),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _policy == SkipPolicy.SHIFT
                    ? l.programSkipShiftDesc
                    : (fixedOk ? l.programSkipFixedDesc : l.programSkipFixedUnavailable),
                style: theme.textTheme.bodySmall?.copyWith(color: colors.fg2),
              ),
              if (!fixedOk && _policy == SkipPolicy.SHIFT)
                Text(l.programSkipFixedUnavailable, style: theme.textTheme.bodySmall?.copyWith(color: colors.fg2)),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                for (final d in unmatched) Text('${d.path}: ${d.message}', style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('start-submit'),
                onPressed: _busy || !_complete ? null : _submit,
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l.progStartCta),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
