// ignore_for_file: curly_braces_in_flow_control_structures
// B2 소유. 세션 끝난 뒤 요약(LOG-9 일부): 시간·볼륨·세트, PR, 목표 미달, 다음 회차 무게.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart' hide formatDate;
import '../../core/api/stats_dto.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../programs/program_common.dart' show loadLiftRefs, LiftRef;
import '../progress/session_comparison_page.dart' show sessionComparisonProvider;
import '../sync_status/sync_status_indicator.dart';
import 'plan_logic.dart';
import 'session_controller.dart';
import 'session_format.dart';

String _thousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return n < 0 ? '-$b' : '$b';
}

class SessionSummaryPage extends ConsumerWidget {
  const SessionSummaryPage({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(sessionByIdProvider(sessionId));
    final session = async.value;
    final exercises = ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};
    final unit = ref.watch(settingsProvider).weightUnit;
    final text = Theme.of(context).textTheme;
    String nameOf(String id) => exercises[id] == null ? '…' : exerciseDisplayName(context, exercises[id]!);

    Widget body;
    if (session == null) {
      body = async.isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(child: Text(l.sessionSummaryNotFound));
    } else {
      final sets = [
        for (final e in session.exercises)
          for (final s in e.sets)
            if (s.isCompleted) s,
      ];
      final volume = [
        for (final s in sets)
          if (!s.isWarmup) setVolumeKg(s),
      ].fold(0.0, (a, b) => a + b);
      final misses = <({String name, int sets, int reps, int target})>[];
      for (final se in session.exercises) {
        if (exerciseVerdict(se) != ExerciseVerdict.failure) continue;
        final failed = [
          for (final s in se.sets)
            if (isJudged(se, s) && (!s.isCompleted || (s.reps ?? 0) < s.targetReps!)) s,
        ];
        if (failed.isEmpty) continue;
        failed.sort((a, b) => ((a.reps ?? 0) - a.targetReps!).compareTo((b.reps ?? 0) - b.targetReps!));
        misses.add((
          name: nameOf(se.exerciseId),
          sets: failed.length,
          reps: failed.first.reps ?? 0,
          target: failed.first.targetReps!,
        ));
      }
      final cmp = ref.watch(sessionComparisonProvider(sessionId)).value;
      final prs = [
        if (cmp != null)
          for (final c in cmp.exercises)
            if (c.isWeightPr || c.isE1rmPr) c,
      ];
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.summaryHeading, key: const Key('summary-heading'), style: text.headlineSmall),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _Stat(label: l.sessionSummaryDuration, value: sessionDuration(session), k: 'summary-duration'),
              ),
              Expanded(
                child: _Stat(
                  label: l.summaryVolumeUnit(unit == WeightUnit.KG ? 'kg' : 'lb'),
                  value: _thousands(Units.toDisplay(volume, unit).round()),
                  k: 'summary-volume',
                ),
              ),
              Expanded(
                child: _Stat(label: l.summarySetsShort, value: '${sets.length}', k: 'summary-sets'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final c in prs) _PrCard(c: c, name: nameOf(c.exerciseId), unit: unit),
          if (misses.isNotEmpty) _MissCard(misses: misses),
          if (session.isProgram) ...[
            const SizedBox(height: 8),
            Text(l.summaryNextHeading, style: text.titleMedium),
            const SizedBox(height: 8),
            _NextPlan(session: session),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l.sessionSummaryTitle),
        automaticallyImplyLeading: false,
        actions: const [SyncStatusIndicator(), SizedBox(width: 8)],
      ),
      body: body,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('summary-compare'),
                  onPressed: () => context.push(Routes.sessionComparison(sessionId)),
                  icon: const Icon(Icons.bar_chart),
                  label: Text(l.summaryCompare),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  key: const Key('summary-done'),
                  onPressed: () => context.go(Routes.home),
                  child: Text(l.summaryClose),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.k});
  final String label;
  final String value;
  final String k;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FittedBox(fit: BoxFit.scaleDown, child: Text(value, key: Key(k), style: AppNum.large(context))),
      Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.of(context).fg2)),
    ],
  );
}

class _PrCard extends StatelessWidget {
  const _PrCard({required this.c, required this.name, required this.unit});
  final ExerciseComparison c;
  final String name;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final top = c.current.topWeightKg;
    var reps = 0;
    for (final s in c.current.sets) {
      if (top != null && (s.weightKg - top).abs() < 1e-9 && s.reps > reps) reps = s.reps;
    }
    final title = top == null ? name : l.summaryPrTitle(name, Units.format(top, unit), reps);
    final sub = c.isE1rmPr && c.current.bestE1rmKg != null
        ? l.summaryPrE1rm(Units.format(c.current.bestE1rmKg!, unit))
        : l.summaryPrWeight;
    return Container(
      key: Key('summary-pr-${c.exerciseId}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: colors.prSoft, borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Row(
        children: [
          Icon(Icons.star, color: colors.pr),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleSmall),
                Text(sub, style: text.bodySmall?.copyWith(color: colors.fg2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MissCard extends StatelessWidget {
  const _MissCard({required this.misses});
  final List<({String name, int sets, int reps, int target})> misses;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final items = [for (final m in misses) l.summaryMissItem(m.name, m.sets, m.reps, m.target)];
    return Container(
      key: const Key('summary-miss'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: colors.failSoft, borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: colors.fail),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: l.summaryMissTitle(misses.length),
                    style: text.titleSmall?.copyWith(color: colors.fail),
                  ),
                  TextSpan(text: ' · ${items.join(' · ')}'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TmRow {
  const _TmRow(this.name, this.before, this.after);
  final String name;
  final double? before;
  final double after;
}

/// 동기화가 끝난 뒤(서버가 replay로 다음 회차를 계산) 계획을 다시 받아 보여준다.
class _NextPlan extends ConsumerStatefulWidget {
  const _NextPlan({required this.session});
  final Session session;

  @override
  ConsumerState<_NextPlan> createState() => _NextPlanState();
}

class _NextPlanState extends ConsumerState<_NextPlan> {
  bool _loading = true;
  PlannedWorkout? _plan;
  List<_TmRow> _tm = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final id = widget.session.programInstanceId!;
    PlannedWorkout? plan;
    var tm = <_TmRow>[];
    try {
      // 서버가 이 세션을 반영하기 전의 TM(있으면)을 먼저 읽어 둔다.
      final repo = ref.read(programRepositoryProvider);
      Map<String, double>? before;
      try {
        before = (await repo.getInstance(id)).state.tm;
      } catch (_) {}
      try {
        await ref.read(syncServiceProvider).syncNow();
      } catch (_) {}
      final cache = ref.read(planCacheProvider);
      await cache.refresh(instanceId: id);
      final p = await cache.nextPlan(id);
      // 서버가 방금 끝낸 회차를 아직 반영하지 못했거나(같은 planSeq) 예상치면 확정 값이 아니다.
      if (p != null && p.confirmed && p.planSeq > (widget.session.planSeq ?? 0)) {
        plan = p;
        try {
          final inst = await repo.getInstance(id);
          final prog = await repo.getProgram(inst.programId);
          final lifts = await loadLiftRefs(ref.read(exerciseRepositoryProvider), prog.definition);
          if (mounted) {
            tm = [
              for (final e in inst.state.tm.entries)
                _TmRow(_liftName(lifts, e.key), before?[e.key], e.value),
            ];
          }
        } catch (_) {
          tm = [];
        }
      }
    } catch (_) {
      plan = null;
    }
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _tm = tm;
      _loading = false;
    });
  }

  String _liftName(Map<String, LiftRef> lifts, String key) => lifts[key]?.name(context) ?? key;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    if (_loading) {
      return Row(
        key: const Key('summary-next-loading'),
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Text(l.sessionSummaryNextLoading),
        ],
      );
    }
    final plan = _plan;
    if (plan == null) {
      final pending = ref.watch(syncStatusProvider).value?.pending ?? 0;
      return CustomPaint(
        painter: _DashedBorder(colors.line),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            key: const Key('summary-next-pending'),
            children: [
              Icon(Icons.cloud_off_outlined, color: colors.fg2),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  pending > 0 ? l.summaryOfflineCount(pending) : l.summaryOffline,
                  style: text.bodyMedium?.copyWith(color: colors.fg2),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final unit = ref.watch(settingsProvider).weightUnit;
    final names = ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};
    // 이전 값이 하나라도 달라졌을 때만 "변동 없음"을 표시한다(이전 값이 이미 서버 반영 후일 수 있어서).
    final anyChanged = _tm.any((r) => r.before != null && (r.before! - r.after).abs() > 1e-9);
    return Card(
      key: const Key('summary-next'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.sessionSummaryNextTitle(plan.dayName, plan.week), style: text.titleSmall),
            const SizedBox(height: 4),
            for (final e in plan.exercises.where((e) => !e.accessory))
              Text(
                planExerciseLine(
                  names[e.exerciseId] == null ? e.key : exerciseDisplayName(context, names[e.exerciseId]!),
                  e,
                  unit,
                ),
              ),
            if (_tm.isNotEmpty) ...[
              const Divider(height: 24),
              for (final r in _tm)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    key: Key('summary-tm-${r.name}'),
                    children: [
                      Expanded(child: Text(l.summaryTmName(r.name))),
                      _tmValue(context, r, unit, anyChanged),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tmValue(BuildContext context, _TmRow r, WeightUnit unit, bool anyChanged) {
    final l = AppLocalizations.of(context);
    final colors = AppColors.of(context);
    final after = Units.format(r.after, unit, withUnit: false);
    final b = r.before;
    if (b == null || (r.after - b).abs() < 1e-9) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (b != null && anyChanged) ...[
            Text(l.summaryTmNoChange, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.fg2)),
            const SizedBox(width: 8),
          ],
          Text(after, style: AppNum.table(context)),
        ],
      );
    }
    final d = r.after - b;
    final delta = '${d > 0 ? '+' : ''}${Units.format(d, unit, withUnit: false)}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${Units.format(b, unit, withUnit: false)} → $after', style: AppNum.table(context)),
        const SizedBox(width: 8),
        Text(delta, style: AppNum.table(context, color: d > 0 ? colors.accent : colors.fail)),
      ],
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(AppRadius.md)));
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 6), paint);
        d += 10;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}
