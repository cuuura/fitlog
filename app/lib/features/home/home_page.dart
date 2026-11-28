import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../calendar/calendar_logic.dart' show dayKey;
import '../calendar/week_strip.dart';
import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart' hide formatDate;
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../core/ui/confirm.dart';
import '../../data/providers.dart';
import '../../domain/repositories.dart';
import '../../l10n/gen/app_localizations.dart';
import '../deletion_requests/pending_deletion_banner.dart';
import '../exercise_picker/exercise_labels.dart';
import '../scheduled/scheduled_card.dart';
import '../scheduled/scheduled_logic.dart' show HomeScheduled;
import '../scheduled/scheduled_providers.dart';
import '../session/plan_logic.dart';
import '../session/session_controller.dart';
import '../session/session_format.dart';
import '../programs/program_add_sheet.dart';
import '../session/start_program_flow.dart';
import '../sync_status/sync_status_indicator.dart';

/// 하단 탭 '오늘'의 루트. 오늘 할 프로그램 카드, 자유 운동, 최근 세션 한 줄.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(sessionControllerProvider).start();
      router.push(Routes.session);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.homeStartError)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final plansAsync = ref.watch(planItemsProvider);
    final namesAsync = ref.watch(exerciseMapProvider);
    final plans = plansAsync.value ?? const <InstancePlan>[];
    final exerciseNames = namesAsync.value ?? const {};
    final active = ref.watch(activeSessionProvider).value;
    final recent = ref.watch(recentSessionsProvider).value ?? const [];
    final unit = ref.watch(settingsProvider).weightUnit;
    final history = recent.where((s) => s.endedAt != null).toList();
    final now = ref.watch(clockProvider)().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final text = Theme.of(context).textTheme;
    final scheduledAsync = ref.watch(homeScheduledProvider);
    final scheduled = scheduledAsync.value ?? const HomeScheduled();
    // 계획·종목·예정 중 하나라도 불러오지 못하면 "계획이 없다"로 보이지 않게 오류와 다시 시도를 보여 준다.
    final loadFailed = plansAsync.hasError || namesAsync.hasError || scheduledAsync.hasError;
    final loading = !loadFailed && !plansAsync.hasValue;
    final todayKey = dayKey(today);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.homeTodayTitle),
        actions: const [SyncStatusIndicator(), SizedBox(width: 8)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const PendingDeletionBanner(),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              key: const Key('home-date'),
              l.homeDateLabel(
                now.month,
                now.day,
                l.homeWeekdayLong(HomePage.weekdayKey(now.weekday)),
              ),
              style: text.titleMedium,
            ),
          ),
          if (active != null)
            Card(
              key: const Key('home-resume-card'),
              color: Theme.of(context).colorScheme.primaryContainer,
              // ListTile의 trailing에 버튼을 두면 큰 글씨·영어에서 타일 폭을 다 먹어 레이아웃이 깨진다.
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.homeResumeTitle, style: text.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      l.homeSummary(
                        active.exercises.length,
                        active.exercises.fold<int>(
                          0,
                          (a, e) => a + e.sets.length,
                        ),
                        formatVolume(sessionVolumeKg(active), unit),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: FilledButton(
                        key: const Key('home-resume'),
                        onPressed: () => context.push(Routes.session),
                        child: Text(l.homeResumeAction),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const WeekStrip(),
          if (loadFailed)
            _LoadError(
              onRetry: () {
                ref.invalidate(planItemsProvider);
                ref.invalidate(exerciseMapProvider);
                ref.invalidate(homeScheduledProvider);
                ref.invalidate(scheduledLinksProvider);
                ref.invalidate(scheduledRangeProvider);
              },
            )
          else if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator(key: Key('home-plan-loading'))),
            ),
          for (final p in plans)
            _PlanCard(
              key: Key('plan-card-${p.instance.id}'),
              plan: p,
              today: today,
              unit: unit,
              exerciseNames: exerciseNames,
              onStart: () => startProgramFlow(
                context,
                ref,
                instanceId: p.instance.id,
                programName: p.instance.name,
              ),
              onSkip: () => _skip(context, ref, p),
            ),
          if (scheduled.today.isNotEmpty) ...[
            _SectionTitle(key: const Key('sched-today-title'), text: l.schedTodayTitle),
            for (final v in scheduled.today)
              ScheduledCard(view: v, exercises: exerciseNames, todayKey: todayKey),
          ],
          if (scheduled.late.isNotEmpty) ...[
            _SectionTitle(key: const Key('sched-late-title'), text: l.schedLateTitle),
            for (final v in scheduled.late)
              ScheduledCard(view: v, exercises: exerciseNames, todayKey: todayKey),
          ],
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              TextButton(
                key: const Key('sched-create-entry'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => context.push(Routes.scheduledNew),
                child: Text(l.schedCreateEntry),
              ),
              TextButton(
                key: const Key('sched-view-all'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => context.push(Routes.scheduled),
                child: Text(l.schedViewAll),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (active == null && plans.isNotEmpty)
            Center(
              child: TextButton(
                key: const Key('home-start'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => _start(context, ref),
                child: Text(l.homeStartFreeLink),
              ),
            )
          else if (active == null) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('home-start'),
                onPressed: () => _start(context, ref),
                child: Text(l.homeStartFree, textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(height: 8),
            Column(
              key: const Key('home-program-hint'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.homeStartProgramHint, style: text.bodySmall),
                TextButton(
                  key: const Key('home-program-hint-action'),
                  onPressed: () => showProgramAddSheet(context),
                  child: Text(l.homeStartProgramAction),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          if (history.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text(l.homeEmpty)),
            )
          else
            _RecentTile(session: history.first, today: today, unit: unit),
        ],
      ),
    );
  }

  static String weekdayKey(int w) =>
      const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'][w - 1];

  Future<void> _skip(
    BuildContext context,
    WidgetRef ref,
    InstancePlan p,
  ) async {
    final next = p.next;
    if (next == null) return;
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final fixed = p.instance.skipPolicy == SkipPolicy.FIXED_DATE;
    final ok = await confirmAction(
      context,
      title: l.instanceSkipConfirmTitle,
      body: fixed
          ? l.instanceSkipConfirmFixed(next.dayName)
          : l.instanceSkipConfirmShift(next.dayName),
      action: l.homeSkip,
    );
    if (!ok) return;
    try {
      await ref
          .read(programRepositoryProvider)
          .skip(p.instance.id, next.planSeq);
      await ref.read(planCacheProvider).refresh(instanceId: p.instance.id);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.instanceActionFailed)));
    }
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    return Container(
      key: const Key('home-load-error'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.failSoft, borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: c.fail),
          const SizedBox(width: 8),
          Expanded(child: Text(l.homePlanLoadError)),
          TextButton(
            key: const Key('home-load-retry'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onRetry,
            child: Text(l.homeRetry),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    super.key,
    required this.plan,
    required this.today,
    required this.unit,
    required this.exerciseNames,
    required this.onStart,
    required this.onSkip,
  });
  final InstancePlan plan;
  final DateTime today;
  final WeightUnit unit;
  final Map<String, Exercise> exerciseNames;
  final VoidCallback onStart;
  final VoidCallback onSkip;

  String _name(BuildContext context, PlannedExercise e) {
    final ex = exerciseNames[e.exerciseId];
    return ex == null ? e.key : exerciseDisplayName(context, ex);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final id = plan.instance.id;
    final next = plan.next;

    int lateDays = 0;
    final sd = next?.scheduledDate?.toLocal();
    if (sd != null) {
      final d = DateTime(sd.year, sd.month, sd.day);
      if (d.isBefore(today)) lateDays = today.difference(d).inDays;
    }
    final late = lateDays > 0;

    final exs = next?.exercises ?? const <PlannedExercise>[];
    final lifts = [
      for (final e in exs)
        if (!e.accessory) e,
    ];
    final main = lifts.isEmpty ? null : lifts.first;
    final aux = lifts.length > 1 ? lifts[1] : null;
    final more = exs.length - (main == null ? 0 : 1) - (aux == null ? 0 : 1);
    final mainW = main == null ? null : topWeight(main);
    final auxW = aux == null ? null : topWeight(aux);
    int workSets(PlannedExercise e) => e.sets.where((s) => !s.isWarmup).length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(plan.instance.name, style: text.titleMedium),
                      if (next != null)
                        Text(
                          late
                              ? l.homePlanSubLate(next.week, next.dayName)
                              : l.homePlanSubToday(next.week, next.dayName),
                          style: text.bodySmall?.copyWith(color: c.fg2),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (next != null) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.start,
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (late)
                    _PlanChip(
                      key: Key('plan-late-$id'),
                      label: l.homeChipLate(lateDays),
                      bg: c.warnSoft,
                      fg: c.warn,
                      icon: Icons.schedule,
                    )
                  else
                    _PlanChip(
                      label: l.homeChipDue,
                      bg: c.accentSoft,
                      fg: c.accentStrong,
                    ),
                  if (plan.fromCache)
                    _PlanChip(
                      key: Key('plan-estimated-$id'),
                      label: l.homePlanEstimated,
                      bg: c.surface3,
                      fg: c.fg2,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            if (next == null)
              Text(l.homePlanUnavailable)
            else ...[
              if (main != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_name(context, main), style: text.titleSmall),
                            Text(
                              l.homeMainMeta(workSets(main)),
                              style: text.bodySmall?.copyWith(color: c.fg2),
                            ),
                          ],
                        ),
                      ),
                      if (mainW != null)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text.rich(
                              key: Key('plan-main-weight-$id'),
                              TextSpan(
                                text: Units.format(
                                  mainW,
                                  unit,
                                  withUnit: false,
                                ),
                                style: AppNum.large(context),
                                children: [
                                  TextSpan(
                                    text: unit == WeightUnit.KG ? 'kg' : 'lb',
                                    style: text.bodySmall?.copyWith(
                                      color: c.fg2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (aux != null || more > 0) ...[
                const SizedBox(height: 8),
                if (aux != null)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.homeAuxName(_name(context, aux)),
                          style: text.bodyMedium?.copyWith(color: c.fg2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          auxW == null
                              ? l.homeAuxSets(workSets(aux))
                              : l.homeAuxSetsWeight(
                                  workSets(aux),
                                  Units.format(auxW, unit),
                                ),
                          style: AppNum.table(context),
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                if (more > 0)
                  Text(
                    l.homeAuxMore(more),
                    style: text.bodySmall?.copyWith(color: c.fg2),
                  ),
              ],
            ],
            const SizedBox(height: 12),
            if (late)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: Key('plan-start-$id'),
                      onPressed: next == null ? null : onStart,
                      child: Text(l.homeStartShort),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: Key('plan-skip-$id'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: c.fg2,
                    ),
                    onPressed: next == null ? null : onSkip,
                    child: Text(l.homeSkip),
                  ),
                ],
              )
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: Key('plan-start-$id'),
                  onPressed: next == null ? null : onStart,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.play_arrow),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          l.homeStartWorkout,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlanChip extends StatelessWidget {
  const _PlanChip({
    super.key,
    required this.label,
    required this.bg,
    required this.fg,
    this.icon,
  });
  final String label;
  final Color bg, fg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
        ),
      ],
    ),
  );
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    required this.session,
    required this.today,
    required this.unit,
  });
  final SessionSummary session;
  final DateTime today;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final local = sessionLocalTime(session.startedAt, session.tz);
    final day = DateTime(local.year, local.month, local.day);
    final diff = today.difference(day).inDays;
    final when = diff == 0
        ? l.homeRecentToday
        : diff == 1
        ? l.homeRecentYesterday
        : l.homeDateLabel(local.month, local.day, l.homeWeekdayLong(HomePage.weekdayKey(local.weekday)));
    return Material(
      color: c.surface2,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        key: Key('home-session-${session.id}'),
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => context.push(Routes.sessionDetail(session.id)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(when, style: text.titleSmall),
                      Text(
                        l.homeSummary(
                          session.exerciseCount,
                          session.setCount,
                          formatVolume(session.totalVolumeKg, unit),
                        ),
                        style: text.bodySmall?.copyWith(color: c.fg2),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
