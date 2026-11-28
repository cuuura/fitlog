// B1·P2 소유. PRG-13·14: 맞추기 화면. 첫 운동·겹침·시작 무게·일정을 한 장에서 정하고 인스턴스를 만든다.
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
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/session_controller.dart' show deviceTimezoneProvider;
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
  late final List<StartOverlap> _overlaps;

  String _id(SuggestItem s) => '${s.needs.name}:${s.key}';

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider)().toLocal();
    _today = DateTime(now.year, now.month, now.day);
    _startDate = ValueNotifier(_today);
    _overlaps = computeOverlaps(widget.view);
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
    _optionalOpen.value = sug.isNotEmpty && sug.every((s) => s.optional);
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    for (final n in [_startDate, _policy, _pauseOthers, _busy, _submitted, _error, _details, _weightsOpen, _optionalOpen, _scheduleOpen]) {
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
    final missing = [for (final s in view.suggestions) if (!s.optional && _valueKg(s) == null) s];
    if (missing.isNotEmpty) {
      _error.value = l.programStartWeightsMissing(
        missing.map((s) => view.lifts[s.key]?.name(context) ?? s.key).join(', '),
      );
      _revealField(missing.first);
      return;
    }
    final tm = <String, double>{};
    final working = <String, double>{};
    for (final s in view.suggestions) {
      final v = _valueKg(s);
      if (v == null) continue; // optional 빈칸은 요청에서 뺀다
      (s.needs == SuggestNeeds.TM ? tm : working)[s.key] = v;
    }
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
          tm: tm,
          working: working,
        ),
      );
      await ref.read(planCacheProvider).refresh(instanceId: id);
      // 시작이 성공한 뒤에만 기존 것을 일시정지한다. 실패해도 시작은 그대로 두고 알린다.
      final failed = <String>[];
      if (_pauseOthers.value) {
        for (final o in _overlaps.where((o) => !o.paused)) {
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
                FirstWorkoutBanner(view: view, startDate: _startDate, policy: _policy),
                if (_overlaps.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  OverlapNotice(overlaps: _overlaps, pauseOthers: _pauseOthers),
                ],
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
                    submitted: _submitted,
                    details: _details,
                  ),
                ],
                const SizedBox(height: 12),
                ScheduleSection(
                  view: view,
                  overlaps: _overlaps,
                  today: _today,
                  startDate: _startDate,
                  policy: _policy,
                  pauseOthers: _pauseOthers,
                  expanded: _scheduleOpen,
                  onPickDate: _pickDate,
                ),
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
