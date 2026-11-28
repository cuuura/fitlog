import 'package:fitlog/core/reminders/reminder_logic.dart';
import 'package:fitlog/core/reminders/reminder_scheduler.dart';
import 'package:fitlog/core/reminders/reminder_service.dart';
import 'package:fitlog/core/reminders/reminder_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeReminderScheduler implements ReminderScheduler {
  final log = <String>[];
  List<ReminderEntry> scheduled = [];
  int permissionRequests = 0;
  @override
  Future<void> requestPermission() async => permissionRequests++;
  @override
  Future<void> cancelAll() async {
    log.add('cancel');
    scheduled = [];
  }

  @override
  Future<void> schedule(List<ReminderEntry> entries) async {
    log.add('schedule ${entries.length}');
    scheduled = entries;
  }
}

// 2026-11-28 09:30 현지 시각.
final _now = DateTime(2026, 11, 28, 9, 30);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('collectReminderDates', () {
    test('계획·예정 날짜를 합치고 중복을 없애 날짜순으로 정렬한다', () {
      final dates = collectReminderDates(
        now: _now,
        planDates: [DateTime(2026, 11, 30), DateTime(2026, 11, 29), null, DateTime(2026, 11, 30)],
        scheduledDates: ['2026-11-29', '2026-12-02'],
      );
      expect(dates, ['2026-11-29', '2026-11-30', '2026-12-02']);
    });

    test('오늘부터 14일 창 안만 남긴다(오늘 포함, 15번째 날부터 제외, 지난 날 제외)', () {
      final dates = collectReminderDates(
        now: _now,
        planDates: [DateTime(2026, 11, 27), DateTime(2026, 11, 28), DateTime(2026, 12, 11), DateTime(2026, 12, 12)],
      );
      expect(dates, ['2026-11-28', '2026-12-11']);
    });

    test('월·연 경계를 넘는다', () {
      final dates = collectReminderDates(now: DateTime(2026, 12, 25, 1), scheduledDates: ['2027-01-02', '2027-01-08']);
      expect(dates, ['2027-01-02']);
    });
  });

  group('buildReminderEntries', () {
    test('당일 모드: 그날 설정 시각, 이미 지난 시각은 뺀다', () {
      const s = ReminderSettings(enabled: true, hour: 8, minute: 15);
      final e = buildReminderEntries(now: _now, dates: ['2026-11-28', '2026-11-29'], settings: s);
      // 오늘 08:15는 이미 지남
      expect(e, hasLength(1));
      expect(e.single.at, DateTime(2026, 11, 29, 8, 15));
      expect(e.single.tomorrow, isFalse);
      expect(e.single.id, reminderIdBase + 1);
    });

    test('오늘이 늦은 시각 설정이면 오늘 알림이 남는다', () {
      const s = ReminderSettings(enabled: true, hour: 18);
      final e = buildReminderEntries(now: _now, dates: ['2026-11-28'], settings: s);
      expect(e.single.at, DateTime(2026, 11, 28, 18));
      expect(e.single.id, reminderIdBase);
    });

    test('전날 저녁 모드: 전날 20:00, 오늘 일정은 시각이 지나 제외', () {
      const s = ReminderSettings(enabled: true, hour: 6, when: ReminderWhen.eveBefore);
      final e = buildReminderEntries(now: _now, dates: ['2026-11-28', '2026-11-29', '2026-12-01'], settings: s);
      expect(e.map((x) => x.at), [DateTime(2026, 11, 28, 20), DateTime(2026, 11, 30, 20)]);
      expect(e.every((x) => x.tomorrow), isTrue);
    });

    test('알림 id는 휴식 타이머(7001~7003)와 겹치지 않는다', () {
      const s = ReminderSettings(enabled: true, hour: 23);
      final e = buildReminderEntries(
        now: _now,
        dates: collectReminderDates(now: _now, scheduledDates: [for (var i = 0; i < 14; i++) reminderDayKey(DateTime(2026, 11, 28 + i))]),
        settings: s,
      );
      expect(e, hasLength(14));
      expect(e.map((x) => x.id).toSet(), hasLength(14));
      expect(e.every((x) => x.id >= 7100 && x.id < 7100 + reminderIdCount), isTrue);
    });
  });

  group('ReminderService', () {
    late FakeReminderScheduler sched;
    late ReminderSettingsStore store;
    var loads = 0;

    ReminderService svc({bool signedIn = true, ReminderInputs? inputs}) => ReminderService(
      store: store,
      scheduler: sched,
      clock: () => _now,
      enabledGate: () => signedIn,
      loadInputs: (now) async {
        loads++;
        return inputs ??
            ReminderInputs(planDates: [DateTime(2026, 11, 29), DateTime(2026, 12, 1)], scheduledDates: const ['2026-11-29', '2026-12-03']);
      },
    );

    setUp(() {
      sched = FakeReminderScheduler();
      store = ReminderSettingsStore();
      loads = 0;
    });

    test('꺼져 있으면(기본) 예약을 모두 취소하고 데이터를 읽지 않는다', () async {
      await svc().reschedule();
      expect(sched.log, ['cancel']);
      expect(loads, 0);
    });

    test('켜면 이전 예약을 지운 뒤 날짜별로 한 번씩 예약한다(중복 날짜 한 번)', () async {
      await store.save(const ReminderSettings(enabled: true, hour: 7, minute: 30));
      await svc().reschedule();
      expect(sched.log, ['cancel', 'schedule 3']);
      expect(sched.scheduled.map((e) => e.dateKey), ['2026-11-29', '2026-12-01', '2026-12-03']);
      expect(sched.scheduled.first.at, DateTime(2026, 11, 29, 7, 30));
    });

    test('전날 저녁 모드', () async {
      await store.save(const ReminderSettings(enabled: true, when: ReminderWhen.eveBefore));
      await svc().reschedule();
      expect(sched.scheduled.first.at, DateTime(2026, 11, 28, 20));
      expect(sched.scheduled.first.tomorrow, isTrue);
    });

    test('끄면 다시 모두 취소한다', () async {
      await store.save(const ReminderSettings(enabled: true));
      final s = svc();
      await s.reschedule();
      expect(sched.scheduled, isNotEmpty);
      await store.save(const ReminderSettings(enabled: false));
      await s.reschedule();
      expect(sched.scheduled, isEmpty);
      expect(sched.log.last, 'cancel');
    });

    test('로그아웃 상태면 켜져 있어도 취소한다', () async {
      await store.save(const ReminderSettings(enabled: true));
      await svc(signedIn: false).reschedule();
      expect(sched.log, ['cancel']);
    });

    test('데이터 읽기가 실패해도 예외를 던지지 않고 기존 예약을 건드리지 않는다', () async {
      await store.save(const ReminderSettings(enabled: true));
      final s = ReminderService(
        store: store,
        scheduler: sched,
        clock: () => _now,
        loadInputs: (_) async => throw Exception('offline'),
      );
      await s.reschedule();
      expect(sched.log, isEmpty);
    });

    test('겹쳐 부르면 끝난 뒤 한 번 더 돌고 최신 설정을 반영한다', () async {
      await store.save(const ReminderSettings(enabled: true));
      final s = svc();
      final a = s.reschedule();
      final b = s.reschedule();
      await Future.wait([a, b]);
      expect(loads, 2);
    });
  });

  group('설정 저장', () {
    test('기본값: 꺼짐, 08:00, 당일', () async {
      final s = await ReminderSettingsStore().load();
      expect(s, const ReminderSettings());
      expect(s.enabled, isFalse);
      expect((s.hour, s.minute), (8, 0));
      expect(s.when, ReminderWhen.sameDay);
    });

    test('저장한 값을 다시 읽는다', () async {
      await ReminderSettingsStore().save(const ReminderSettings(enabled: true, hour: 19, minute: 45, when: ReminderWhen.eveBefore));
      final s = await ReminderSettingsStore().load();
      expect(s, const ReminderSettings(enabled: true, hour: 19, minute: 45, when: ReminderWhen.eveBefore));
    });

    test('컨트롤러: 시작하면 저장값을 읽고, 바꾸면 저장·다시 예약한다', () async {
      SharedPreferences.setMockInitialValues({'reminder.enabled': true, 'reminder.hour': 6, 'reminder.minute': 5});
      final sched = FakeReminderScheduler();
      final c = ProviderContainer(
        overrides: [
          reminderServiceProvider.overrideWithValue(
            ReminderService(
              store: ReminderSettingsStore(),
              scheduler: sched,
              clock: () => _now,
              loadInputs: (_) async => const ReminderInputs(scheduledDates: ['2026-11-30']),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen(reminderSettingsProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(reminderSettingsProvider), const ReminderSettings(enabled: true, hour: 6, minute: 5));

      await c.read(reminderSettingsProvider.notifier).update(const ReminderSettings(enabled: true, hour: 9, minute: 0));
      expect(c.read(reminderSettingsProvider).hour, 9);
      expect(sched.scheduled.single.at, DateTime(2026, 11, 30, 9));
      final p = await SharedPreferences.getInstance();
      expect(p.getInt('reminder.hour'), 9);

      await c.read(reminderSettingsProvider.notifier).update(const ReminderSettings(enabled: false));
      expect(sched.scheduled, isEmpty);
      expect((await SharedPreferences.getInstance()).getBool('reminder.enabled'), isFalse);
    });
  });
}
