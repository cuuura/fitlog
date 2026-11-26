// ignore_for_file: curly_braces_in_flow_control_structures
// B2 소유. 세션 끝난 뒤 요약(LOG-9 일부): 총 세트·볼륨·시간, 종목별 성공/실패, 다음 회차 무게.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import 'plan_logic.dart';
import 'session_controller.dart';
import 'session_format.dart';

class SessionSummaryPage extends ConsumerWidget {
  const SessionSummaryPage({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(sessionByIdProvider(sessionId));
    final session = async.value;
    final exercises =
        ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};
    final unit = ref.watch(settingsProvider).weightUnit;

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
      final judged = [
        for (final se in session.exercises)
          if (exerciseVerdict(se) != null) se,
      ];
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: l.sessionSummarySets,
                  value: '${sets.length}',
                  k: 'summary-sets',
                ),
              ),
              Expanded(
                child: _Stat(
                  label: l.sessionSummaryVolume,
                  value: formatVolume(volume, unit),
                  k: 'summary-volume',
                ),
              ),
              Expanded(
                child: _Stat(
                  label: l.sessionSummaryDuration,
                  value: sessionDuration(session),
                  k: 'summary-duration',
                ),
              ),
            ],
          ),
          if (judged.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              l.sessionSummaryResults,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final se in judged)
              _ResultTile(
                se: se,
                name: exercises[se.exerciseId] == null
                    ? '…'
                    : exerciseDisplayName(context, exercises[se.exerciseId]!),
              ),
          ],
          if (session.isProgram) ...[
            const SizedBox(height: 24),
            Text(
              l.sessionSummaryNext,
              style: Theme.of(context).textTheme.titleMedium,
            ),
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
      ),
      body: body,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            key: const Key('summary-done'),
            onPressed: () => context.go(Routes.home),
            child: Text(l.sessionSummaryDone),
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
      Text(value, key: Key(k), style: Theme.of(context).textTheme.titleLarge),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.se, required this.name});
  final SessionExercise se;
  final String name;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ok = exerciseVerdict(se) == ExerciseVerdict.success;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: Key('result-${se.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ok ? Icons.check_circle_outline : Icons.cancel_outlined,
        color: ok ? scheme.primary : scheme.error,
      ),
      title: Text(name),
      trailing: Text(
        ok ? l.sessionSummarySuccess : l.sessionSummaryFailure,
        style: TextStyle(
          color: ok ? scheme.primary : scheme.error,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final id = widget.session.programInstanceId!;
    PlannedWorkout? plan;
    try {
      try {
        await ref.read(syncServiceProvider).syncNow();
      } catch (_) {}
      final cache = ref.read(planCacheProvider);
      await cache.refresh(instanceId: id);
      final p = await cache.nextPlan(id);
      // 서버가 방금 끝낸 회차를 아직 반영하지 못했거나(같은 planSeq) 예상치면 확정 값이 아니다.
      if (p != null && p.confirmed && p.planSeq > (widget.session.planSeq ?? 0))
        plan = p;
    } catch (_) {
      plan = null;
    }
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (_loading) {
      return Row(
        key: const Key('summary-next-loading'),
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(l.sessionSummaryNextLoading),
        ],
      );
    }
    final plan = _plan;
    if (plan == null)
      return Text(
        l.sessionSummaryNextPending,
        key: const Key('summary-next-pending'),
      );
    final unit = ref.watch(settingsProvider).weightUnit;
    final names =
        ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};
    return Card(
      key: const Key('summary-next'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.sessionSummaryNextTitle(plan.dayName, plan.week),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            for (final e in plan.exercises.where((e) => !e.accessory))
              Text(
                planExerciseLine(
                  names[e.exerciseId] == null
                      ? e.key
                      : exerciseDisplayName(context, names[e.exerciseId]!),
                  e,
                  unit,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
