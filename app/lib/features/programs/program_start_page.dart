// B1·P2 소유. PRG-13·14: 맞추기 화면. 첫 운동·겹침·시작 무게·일정을 한 장에서 정하고 인스턴스를 만든다.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/api/program_dto.dart';
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/ui/bottom_action_bar.dart';
import '../../core/ui/form_sheet.dart';
import '../../core/ui/undo.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/session_controller.dart' show deviceTimezoneProvider;
import 'instance_detail_page.dart' show AccessorySheet;
import 'program_common.dart';
import 'programs_providers.dart';
import 'start_cards.dart';

class ProgramStartPage extends ConsumerWidget {
  const ProgramStartPage({super.key, required this.programId});
  final String programId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(startViewProvider(programId));
    void retry() => ref.invalidate(startViewProvider(programId));
    return Scaffold(
      appBar: AppBar(title: Text(l.programStartTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => e is ApiException && e.isNetwork
            ? StartOffline(onRetry: retry)
            : ErrorRetry(error: e, onRetry: retry),
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
  // 값은 전부 칸별 컨트롤러·notifier에 둔다. 입력 중 이 State의 setState는 부르지 않는다.
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, FocusNode> _focus = {};
  final Map<String, GlobalKey> _rowKeys = {};
  late final ValueNotifier<DateTime> _startDate;
  late final DateTime _today;
  final _policy = ValueNotifier(SkipPolicy.SHIFT);
  final _pauseOthers = ValueNotifier(false);
  final _busy = ValueNotifier(false);
  final _submitted = ValueNotifier(false);
  final _error = ValueNotifier<String?>(null);
  final _details = ValueNotifier<List<StartDetail>>(const []);
  final _weightsOpen = ValueNotifier(true);
  final _optionalOpen = ValueNotifier(false);
  final _scheduleOpen = ValueNotifier(false);
  final _derivedOpen = ValueNotifier(false);
  final _accOpen = ValueNotifier(false);
  final _accessories = ValueNotifier<List<StartAccessory>>(const []);

  /// 날 키 → 현재 요일(정의 값에서 시작, 칩으로 바꾼다).
  late final ValueNotifier<Map<String, String>> _weekdays;
  late final Map<String, String> _origWeekdays;
  late final ValueNotifier<List<StartOverlap>> _overlaps;

  // 미리 계산: 입력이 멈춘 뒤 400ms에 부르고, 최신 요청만 반영한다.
  final _preview = ValueNotifier(const StartPreviewState());
  Timer? _debounce;
  int _seq = 0;
  bool _applying = false;

  /// 자동 계산 종목 칸에 앱이 마지막으로 넣은 글자. 이것과 다르면 사용자가 고친 값이다.
  final Map<String, String> _auto = {};

  String _id(SuggestItem s) => '${s.needs.name}:${s.key}';

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider)().toLocal();
    _today = DateTime(now.year, now.month, now.day);
    _startDate = ValueNotifier(_today);
    _origWeekdays = programDayWeekdays(widget.view.program.definition);
    _weekdays = ValueNotifier({..._origWeekdays});
    _overlaps = ValueNotifier(computeOverlaps(widget.view));
    final unit = ref.read(settingsProvider).weightUnit;
    for (final s in widget.view.suggestions) {
      _ctrls[_id(s)] = TextEditingController(
        text: s.suggestedKg == null ? '' : Units.format(s.suggestedKg!, unit, withUnit: false),
      );
      _focus[_id(s)] = FocusNode();
      _rowKeys[_id(s)] = GlobalKey();
    }
    final sug = widget.view.suggestions;
    // 필수 종목이 없으면 비워도 되는 묶음을 처음부터 펼친다.
    _optionalOpen.value = sug.isNotEmpty && sug.every((s) => s.canSkip && !s.isDerived);
    _weekdays.addListener(() {
      _overlaps.value = computeOverlaps(
        widget.view,
        definitionWithWeekdays(widget.view.program.definition, _weekdays.value),
      );
    });
    _inputs = Listenable.merge([..._ctrls.values, _startDate, _policy, _weekdays]);
    _inputs.addListener(_onInput);
    _onInput();
  }

  late final Listenable _inputs;

  bool _edited(SuggestItem s) {
    final t = _ctrls[_id(s)]!.text.trim();
    return t.isNotEmpty && t != (_auto[_id(s)] ?? '');
  }

  /// 요청에 실을 값. 자동 계산 종목은 사용자가 고쳤을 때만(안 고치면 서버가 계산한다).
  double? _sendKg(SuggestItem s) => s.isDerived && !_edited(s) ? null : _valueKg(s);

  Map<String, String> _changedWeekdays() => {
    for (final e in _weekdays.value.entries)
      if (_origWeekdays[e.key] != e.value) e.key: e.value,
  };

  ({Map<String, double> tm, Map<String, double> working}) _inputValues() {
    final tm = <String, double>{};
    final working = <String, double>{};
    for (final s in widget.view.suggestions) {
      final v = _sendKg(s);
      if (v == null) continue; // 빈칸·고치지 않은 자동 계산 칸은 요청에서 뺀다
      (s.needs == SuggestNeeds.TM ? tm : working)[s.key] = v;
    }
    return (tm: tm, working: working);
  }

  void _onInput() {
    if (_applying) return;
    _debounce?.cancel();
    _seq++;
    final ready = widget.view.suggestions.every((s) => s.canSkip || _valueKg(s) != null);
    if (!ready) {
      if (_preview.value.data != null || _preview.value.loading) _preview.value = const StartPreviewState();
      return;
    }
    final old = _preview.value.data;
    if (old != null) _preview.value = StartPreviewState(data: old, loading: true);
    _debounce = Timer(const Duration(milliseconds: 400), _runPreview);
  }

  Future<void> _runPreview() async {
    final seq = _seq;
    try {
      final tz = await ref.read(deviceTimezoneProvider)();
      final v = _inputValues();
      final r = await ref
          .read(programRepositoryProvider)
          .previewStart(
            widget.view.program.id,
            StartPreviewRequest(
              startDate: _startDate.value,
              tz: tz,
              skipPolicy: _policy.value,
              tm: v.tm,
              working: v.working,
              weekdays: _changedWeekdays(),
            ),
          );
      if (!mounted || seq != _seq) return;
      _preview.value = StartPreviewState(data: r);
      _fillDerived(r);
    } catch (_) {
      // 실패·오프라인이면 기존 표시(날짜·종목)로 돌아간다.
      if (!mounted || seq != _seq) return;
      _preview.value = const StartPreviewState();
    }
  }

  /// 안 고친 자동 계산 칸에 서버가 계산한 값을 보여 준다.
  void _fillDerived(StartPreview r) {
    final unit = ref.read(settingsProvider).weightUnit;
    _applying = true;
    try {
      for (final s in widget.view.suggestions) {
        if (!s.isDerived || _edited(s) || _focus[_id(s)]!.hasFocus) continue;
        final kg = (s.needs == SuggestNeeds.TM ? r.inputsTm : r.inputsWorking)[s.key];
        if (kg == null) continue;
        final text = Units.format(kg, unit, withUnit: false);
        _ctrls[_id(s)]!.text = text;
        _auto[_id(s)] = text;
      }
    } finally {
      _applying = false;
    }
  }

  Future<void> _addAccessory(String dayKey) async {
    final id = await context.push<String>(Routes.pickExercise);
    if (id == null || !mounted) return;
    final ex = await ref.read(exerciseRepositoryProvider).byId(id);
    if (!mounted) return;
    final unit = ref.read(settingsProvider).weightUnit;
    await showFormSheet<bool>(
      context,
      builder: (_) => AccessorySheet(
        unit: unit,
        save: (res) async {
          _accessories.value = [
            ..._accessories.value,
            StartAccessory(
              id: newId(),
              dayKey: dayKey,
              exercise: LiftRef(ex, id),
              sets: res.sets,
              reps: res.reps,
              weightKg: res.weightKg,
            ),
          ];
        },
      ),
    );
  }

  void _removeAccessory(StartAccessory a) {
    final l = AppLocalizations.of(context);
    final before = _accessories.value;
    _accessories.value = [for (final x in before) if (x.id != a.id) x];
    showUndoSnack(
      ScaffoldMessenger.of(context),
      l,
      message: l.programStartAccRemoved,
      onUndo: () async {
        if (mounted) _accessories.value = before;
      },
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _inputs.removeListener(_onInput);
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    for (final n in [_startDate, _policy, _pauseOthers, _busy, _submitted, _error, _details, _weightsOpen, _optionalOpen, _scheduleOpen, _derivedOpen, _accOpen, _accessories, _weekdays, _overlaps, _preview]) {
      n.dispose();
    }
    super.dispose();
  }

  double? _valueKg(SuggestItem s) {
    final v = parseNumber(_ctrls[_id(s)]!.text);
    if (v == null || v <= 0) return null;
    return Units.fromDisplay(v, ref.read(settingsProvider).weightUnit);
  }

  Future<void> _pickDate() async {
    final cur = _startDate.value;
    final d = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(cur.year - 1),
      lastDate: DateTime(cur.year + 1),
    );
    if (d != null) _startDate.value = d;
  }

  /// 빠진 칸이 있는 첫 칸: 카드를 펼치고, 그 칸으로 스크롤하고, 입력창에 초점을 준다.
  void _revealField(SuggestItem s) {
    _weightsOpen.value = true;
    if (s.optional) _optionalOpen.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _rowKeys[_id(s)]?.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250), alignment: 0.1);
      _focus[_id(s)]?.requestFocus();
    });
  }

  Future<void> _submit() async {
    final l = AppLocalizations.of(context);
    _error.value = null;
    _details.value = const [];
    _submitted.value = true;
    final view = widget.view;
    final missing = [for (final s in view.suggestions) if (!s.canSkip && _valueKg(s) == null) s];
    if (missing.isNotEmpty) {
      _error.value = l.programStartWeightsMissing(
        missing.map((s) => view.lifts[s.key]?.name(context) ?? s.key).join(', '),
      );
      _revealField(missing.first);
      return;
    }
    final v = _inputValues();
    _busy.value = true;
    final repo = ref.read(programRepositoryProvider);
    try {
      final tz = await ref.read(deviceTimezoneProvider)();
      final id = newId();
      await repo.startInstance(
        StartInstance(
          id: id,
          programId: view.program.id,
          startDate: _startDate.value,
          tz: tz,
          skipPolicy: _policy.value,
          tm: v.tm,
          working: v.working,
          weekdays: _changedWeekdays(),
        ),
      );
      // 보조 종목은 시작이 성공한 뒤에 저장한다. 실패해도 시작은 그대로 두고 알린다.
      var accFailed = false;
      if (_accessories.value.isNotEmpty) {
        final counters = <String, int>{};
        try {
          await repo.putAccessories(id, [
            for (final a in _accessories.value)
              Accessory(
                id: a.id,
                dayKey: a.dayKey,
                exerciseId: a.exercise.exercise?.id ?? a.exercise.fallback,
                position: counters.update(a.dayKey, (n) => n + 1, ifAbsent: () => 1) - 1,
                sets: a.sets,
                reps: a.reps,
                weightKg: a.weightKg,
              ),
          ]);
        } catch (_) {
          accFailed = true;
        }
      }
      await ref.read(planCacheProvider).refresh(instanceId: id);
      // 시작이 성공한 뒤에만 기존 것을 일시정지한다. 실패해도 시작은 그대로 두고 알린다.
      final failed = <String>[];
      if (_pauseOthers.value) {
        for (final o in _overlaps.value.where((o) => !o.paused)) {
          try {
            await repo.patchInstance(o.running.instance.id, const InstancePatch(status: InstanceStatus.PAUSED));
          } catch (_) {
            failed.add(o.running.instance.name);
          }
        }
      }
      if (!mounted) return;
      if (failed.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.programStartPauseFailed(failed.join(', ')))));
      }
      if (accFailed) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.programStartAccFailed)));
      }
      context.pushReplacement(Routes.instanceDetail(id));
    } on ApiException catch (e) {
      if (!mounted) return;
      _busy.value = false;
      _details.value = e.details;
      final unmatched = [
        for (final d in e.details)
          if (!view.suggestions.any((s) => d.path.endsWith('/${s.key}'))) '${d.path}: ${d.message}',
      ];
      _error.value = e.details.isNotEmpty
          ? [l.programStartValidation, ...unmatched].join('\n')
          : errorMessage(l, e, fallback: l.programStartFailed);
      final bad = view.suggestions.where((s) => e.details.any((d) => d.path.endsWith('/${s.key}')));
      if (bad.isNotEmpty) _revealField(bad.first);
    } catch (_) {
      if (!mounted) return;
      _busy.value = false;
      _error.value = l.programStartFailed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider.select((s) => s.weightUnit));
    final view = widget.view;
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final def = view.program.definition;
    final dayCount = view.program.dayCount;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(view.program.name, style: theme.textTheme.titleLarge),
                if (dayCount > 0)
                  Text(l.programStartDaysInfo(dayCount), style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
                const SizedBox(height: 12),
                if (sessionMinutesText(l, view.program.sessionMinutes) case final t?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      t,
                      key: const Key('program-session-minutes'),
                      style: theme.textTheme.bodySmall?.copyWith(color: c.fg2),
                    ),
                  ),
                FirstWorkoutBanner(
                  view: view,
                  startDate: _startDate,
                  policy: _policy,
                  weekdays: _weekdays,
                  preview: _preview,
                  unit: unit,
                ),
                OverlapNotice(overlaps: _overlaps, pauseOthers: _pauseOthers),
                if (view.suggestions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  WeightsSection(
                    items: view.suggestions,
                    nameOf: (s) => view.lifts[s.key]?.name(context) ?? s.key,
                    controllers: _ctrls,
                    focusNodes: _focus,
                    rowKeys: _rowKeys,
                    unit: unit,
                    stepKg: programStepKg(def),
                    expanded: _weightsOpen,
                    optionalExpanded: _optionalOpen,
                    derivedExpanded: _derivedOpen,
                    nameOfKey: (k) => view.lifts[k]?.name(context) ?? k,
                    submitted: _submitted,
                    details: _details,
                  ),
                ],
                const SizedBox(height: 12),
                ScheduleSection(
                  view: view,
                  overlaps: _overlaps,
                  weekdays: _weekdays,
                  today: _today,
                  startDate: _startDate,
                  policy: _policy,
                  pauseOthers: _pauseOthers,
                  expanded: _scheduleOpen,
                  onPickDate: _pickDate,
                ),
                if (dayCount > 0) ...[
                  const SizedBox(height: 12),
                  AccessoriesSection(
                    view: view,
                    items: _accessories,
                    expanded: _accOpen,
                    unit: unit,
                    onAdd: _addAccessory,
                    onRemove: _removeAccessory,
                  ),
                ],
              ],
            ),
          ),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_error, _busy]),
          builder: (context, _) => BottomActionBar(
            error: _error.value,
            child: FilledButton(
              key: const Key('start-submit'),
              onPressed: _busy.value ? null : _submit,
              child: _busy.value
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.progStartCta),
            ),
          ),
        ),
      ],
    );
  }
}
