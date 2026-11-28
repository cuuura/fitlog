// B3(v1.2) 운동 알림 다시 예약. 앱 시작·동기화 후·설정 변경·프로그램 시작/일시정지 때 [ReminderService.reschedule]을 부른다.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/dto.dart' show ScheduledStatus;
import '../../core/api/program_dto.dart' show InstanceStatus;
import '../../data/providers.dart';
import '../../domain/repositories.dart';
import '../../features/scheduled/scheduled_logic.dart' show scheduledViews;
import '../auth/auth_controller.dart';
import '../clock.dart';
import 'reminder_logic.dart';
import 'reminder_scheduler.dart';
import 'reminder_settings.dart';

/// 알림 날짜를 만드는 재료.
class ReminderInputs {
  /// 진행 중 프로그램 계획의 scheduledDate들.
  final List<DateTime?> planDates;

  /// 끝나지 않은 예정 운동의 YYYY-MM-DD.
  final List<String> scheduledDates;
  const ReminderInputs({this.planDates = const [], this.scheduledDates = const []});
}

typedef ReminderInputsLoader = Future<ReminderInputs> Function(DateTime now);

class ReminderService {
  ReminderService({
    required this.store,
    required this.scheduler,
    required this.loadInputs,
    required this.clock,
    this.enabledGate,
  });

  final ReminderSettingsStore store;
  final ReminderScheduler scheduler;
  final ReminderInputsLoader loadInputs;
  final DateTime Function() clock;

  /// false를 돌려주면(예: 로그아웃) 설정과 무관하게 모두 취소한다.
  final bool Function()? enabledGate;

  Future<void>? _running;
  bool _rerun = false;

  /// 알림을 다시 예약한다. 겹쳐 부르면 끝난 뒤 한 번 더 돈다. 예외는 밖으로 던지지 않는다.
  Future<void> reschedule() {
    if (_running != null) {
      _rerun = true;
      return _running!;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _rerun = false;
      try {
        await _once();
      } catch (_) {
        // 예약 실패는 다음 기회(앱 시작·동기화)에 다시 맞춘다.
      }
    } while (_rerun);
  }

  Future<void> _once() async {
    final settings = await store.load();
    if (!settings.enabled || !(enabledGate?.call() ?? true)) {
      await scheduler.cancelAll();
      return;
    }
    final now = clock();
    final inputs = await loadInputs(now);
    final dates = collectReminderDates(now: now, planDates: inputs.planDates, scheduledDates: inputs.scheduledDates);
    final entries = buildReminderEntries(now: now, dates: dates, settings: settings);
    await scheduler.cancelAll();
    await scheduler.schedule(entries);
  }
}

/// 실제 저장소에서 재료를 읽는다. 서버 계획을 못 받으면 계획 캐시의 다음 회차로 대신한다.
ReminderInputsLoader _repoLoader(Ref ref) => (now) async {
  final plans = <DateTime?>[];
  try {
    final instances = await ref.read(programRepositoryProvider).listInstances(status: InstanceStatus.ACTIVE);
    for (final i in instances) {
      if (i.status != InstanceStatus.ACTIVE) continue;
      for (final p in await ref.read(programRepositoryProvider).plan(i.id, count: 8)) {
        plans.add(p.scheduledDate);
      }
    }
  } catch (_) {
    plans.clear();
    try {
      final cached = await ref.read(planCacheProvider).watchActive().first.timeout(const Duration(seconds: 2));
      for (final c in cached) {
        plans.add(c.next?.scheduledDate);
      }
    } catch (_) {}
  }

  final today = DateTime(now.year, now.month, now.day);
  final last = DateTime(today.year, today.month, today.day + reminderWindowDays - 1);
  final ws = await ref
      .read(scheduledWorkoutRepositoryProvider)
      .watchBetween(reminderDayKey(today), reminderDayKey(last))
      .first;
  final links = await ref.read(sessionRepositoryProvider).watchScheduledLinks().first;
  return ReminderInputs(
    planDates: plans,
    scheduledDates: [
      for (final v in scheduledViews(ws, links))
        if (v.status == ScheduledStatus.PLANNED) v.workout.plannedDate,
    ],
  );
};

final reminderServiceProvider = Provider<ReminderService>((ref) {
  return ReminderService(
    store: ref.watch(reminderSettingsStoreProvider),
    scheduler: ref.watch(reminderSchedulerProvider),
    loadInputs: _repoLoader(ref),
    clock: () => ref.read(clockProvider)().toLocal(),
    enabledGate: () => ref.read(authControllerProvider) == AuthStatus.signedIn,
  );
});

/// 앱 시작·동기화 후·프로그램 시작/일시정지·로그인·포그라운드 복귀 때 알림을 다시 예약한다. app.dart에서 한 번 감싼다.
class ReminderLifecycle extends ConsumerStatefulWidget {
  const ReminderLifecycle({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ReminderLifecycle> createState() => _ReminderLifecycleState();
}

class _ReminderLifecycleState extends ConsumerState<ReminderLifecycle> {
  final _subs = <StreamSubscription<dynamic>>[];
  late final AppLifecycleListener _lifecycle;
  Timer? _debounce;

  void _trigger() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () {
      if (mounted) unawaited(ref.read(reminderServiceProvider).reschedule());
    });
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _trigger);
    _subs.add(ref.read(programRepositoryProvider).instanceChanges.listen((_) => _trigger(), onError: (_) {}));
    SyncPhase? prev;
    _subs.add(
      ref.read(syncServiceProvider).watchStatus().listen((s) {
        if (prev == SyncPhase.syncing && s.phase == SyncPhase.idle) _trigger();
        prev = s.phase;
      }, onError: (_) {}),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _trigger();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authControllerProvider, (prev, next) {
      if (next != prev) _trigger();
    });
    return widget.child;
  }
}
