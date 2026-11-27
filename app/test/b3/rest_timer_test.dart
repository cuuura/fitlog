import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/features/rest_timer/rest_timer_bar.dart';
import 'package:fitlog/features/rest_timer/rest_timer_controller.dart';
import 'package:fitlog/features/rest_timer/rest_timer_notifier.dart';
import 'package:fitlog/features/rest_timer/session_wakelock.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fixed_providers.dart';

class FakeNotifier implements RestTimerNotifier {
  final calls = <String>[];
  DateTime? lastEndsAt;
  String? lastLabel;
  String? lastBody;
  DateTime? warnAt;
  String? warnBody;
  final warnLog = <String>[];
  void Function(RestTimerAction)? handler;

  @override
  set actionHandler(void Function(RestTimerAction)? h) => handler = h;
  @override
  bool get supportsExactAlarm => false;
  @override
  Future<bool> requestExactAlarmPermission() async => false;
  @override
  Future<void> scheduleWarning({required DateTime at, String? body}) async {
    warnAt = at;
    warnBody = body;
    warnLog.add('warn');
  }

  @override
  Future<void> cancelWarning() async {
    warnAt = null;
    warnLog.add('unwarn');
  }

  @override
  Future<void> cancel() async {
    warnAt = null;
    calls.add('cancel');
  }
  @override
  Future<void> requestPermission() async => calls.add('permission');
  @override
  Future<void> showRunning({
    required DateTime endsAt,
    required int totalSec,
    String? label,
    String? body,
    required DateTime now,
  }) async {
    calls.add('show:$totalSec');
    lastBody = body;
    lastEndsAt = endsAt;
    lastLabel = label;
  }
}

class MemStorage implements RestTimerStorage {
  RestTimerState? saved;
  @override
  Future<void> clear() async => saved = null;
  @override
  Future<RestTimerState?> load() async => saved;
  @override
  Future<void> save(RestTimerState state) async => saved = state;
}

DateTime t(int sec) => DateTime.utc(2026, 11, 26, 10).add(Duration(seconds: sec));

void main() {
  late DateTime now;
  late FakeNotifier notifier;
  late MemStorage storage;
  late int vibrations;
  late int warnVibrations;

  ProviderContainer make() {
    final c = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(() => now),
        restTimerNotifierProvider.overrideWithValue(notifier),
        restTimerStorageProvider.overrideWithValue(storage),
        restTimerVibrateProvider.overrideWithValue(() async => vibrations++),
        restTimerWarnVibrateProvider.overrideWithValue(() async => warnVibrations++),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    now = t(0);
    notifier = FakeNotifier();
    storage = MemStorage();
    vibrations = 0;
    warnVibrations = 0;
  });

  test('start/addSeconds/stop 상태와 알림 호출', () async {
    final c = make();
    final ctl = c.read(restTimerProvider.notifier);
    ctl.start(90, label: '스쿼트 2세트 후');
    var s = c.read(restTimerProvider);
    expect(s.running, isTrue);
    expect(s.totalSec, 90);
    expect(s.label, '스쿼트 2세트 후');
    expect(s.endsAt, t(90));
    expect(s.remaining(t(30)), const Duration(seconds: 60));
    expect(s.remaining(t(200)), Duration.zero);
    await pumpEventQueue();
    expect(notifier.calls, ['permission', 'show:90']);
    expect(notifier.lastLabel, '스쿼트 2세트 후');
    expect(storage.saved?.endsAt, t(90));

    ctl.addSeconds(30);
    s = c.read(restTimerProvider);
    expect(s.endsAt, t(120));
    expect(s.totalSec, 120);
    await pumpEventQueue();
    expect(notifier.calls.last, 'show:120');
    expect(notifier.calls.where((e) => e == 'permission').length, 1);

    ctl.addSeconds(-15);
    expect(c.read(restTimerProvider).endsAt, t(105));

    ctl.stop();
    expect(c.read(restTimerProvider).running, isFalse);
    await pumpEventQueue();
    expect(notifier.calls.last, 'cancel');
    expect(storage.saved, isNull);
    ctl.addSeconds(10); // 멈춘 상태는 무시
    expect(c.read(restTimerProvider).running, isFalse);
  });

  test('종료 10초 전 경고: 예약, +30초 재예약, 건너뛰기 취소, 짧은 휴식은 생략', () async {
    final c = make();
    final ctl = c.read(restTimerProvider.notifier);
    ctl.start(90, body: '다음 벤치 92.5kg×3');
    await pumpEventQueue();
    expect(notifier.warnAt, t(80));
    expect(notifier.warnBody, '다음 벤치 92.5kg×3');
    expect(notifier.lastBody, '다음 벤치 92.5kg×3');
    ctl.addSeconds(30);
    await pumpEventQueue();
    expect(notifier.warnAt, t(110));
    ctl.stop();
    await pumpEventQueue();
    expect(notifier.warnAt, isNull);

    ctl.start(15);
    await pumpEventQueue();
    expect(notifier.warnAt, isNull);
    expect(notifier.warnLog.last, 'unwarn');
  });

  test('포그라운드 경고 진동은 종료 10초 전에 한 번만', () async {
    final c = make();
    final ctl = c.read(restTimerProvider.notifier);
    ctl.start(60);
    now = t(40);
    ctl.checkWarning();
    expect(warnVibrations, 0);
    now = t(50);
    ctl.checkWarning();
    ctl.checkWarning();
    await pumpEventQueue();
    expect(warnVibrations, 1);
    expect(c.read(restTimerProvider).inWarning(now), isTrue);
    ctl.addSeconds(30); // 새 종료 시각이면 다시 경고할 수 있다
    now = t(80);
    ctl.checkWarning();
    await pumpEventQueue();
    expect(warnVibrations, 2);
    ctl.stop();
  });

  test('남은 시간보다 많이 줄이면 멈춘다', () async {
    final c = make();
    final ctl = c.read(restTimerProvider.notifier);
    ctl.start(10);
    now = t(2);
    ctl.addSeconds(-15);
    expect(c.read(restTimerProvider).running, isFalse);
  });

  test('0초 이하 start는 멈춤', () {
    final c = make();
    c.read(restTimerProvider.notifier).start(0);
    expect(c.read(restTimerProvider).running, isFalse);
  });

  test('끝나면 진동하고 멈춘다; 늦게 깨어나면 진동하지 않는다', () async {
    final c = make();
    final ctl = c.read(restTimerProvider.notifier);
    ctl.start(60);
    now = t(59);
    ctl.checkFinished();
    expect(c.read(restTimerProvider).running, isTrue);
    now = t(61);
    ctl.checkFinished();
    expect(c.read(restTimerProvider).running, isFalse);
    await pumpEventQueue();
    expect(vibrations, 1);

    ctl.start(60);
    now = t(61 + 600);
    ctl.checkFinished();
    await pumpEventQueue();
    expect(vibrations, 1, reason: '10분 늦게 확인 -> 진동 없음');
  });

  test('알림 액션: +30초, 건너뛰기', () async {
    final c = make();
    final ctl = c.read(restTimerProvider.notifier);
    ctl.start(60);
    notifier.handler!(RestTimerAction.add30);
    expect(c.read(restTimerProvider).endsAt, t(90));
    notifier.handler!(RestTimerAction.skip);
    expect(c.read(restTimerProvider).running, isFalse);
  });

  test('앱 재시작 후 남은 타이머를 복구, 끝난 것은 버린다', () async {
    storage.saved = RestTimerState(endsAt: t(100), totalSec: 100, label: 'x');
    var c = make();
    c.read(restTimerProvider);
    await pumpEventQueue();
    expect(c.read(restTimerProvider).endsAt, t(100));
    expect(c.read(restTimerProvider).label, 'x');
    expect(notifier.calls, contains('show:100'));
    c.dispose();

    now = t(500);
    c = make();
    c.read(restTimerProvider);
    await pumpEventQueue();
    expect(c.read(restTimerProvider).running, isFalse);
    expect(storage.saved, isNull);
  });

  test('formatRestRemaining', () {
    expect(formatRestRemaining(const Duration(seconds: 90)), '01:30');
    expect(formatRestRemaining(const Duration(milliseconds: 400)), '00:01');
    expect(formatRestRemaining(Duration.zero), '00:00');
  });

  group('위젯', () {
    Widget app(ProviderContainer c, Widget child) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ko'),
        home: Scaffold(body: child),
      ),
    );

    testWidgets('RestTimerBar: 표시, +30초, 건너뛰기', (tester) async {
      final c = make();
      await tester.pumpWidget(app(c, const RestTimerBar()));
      expect(find.byKey(const Key('restTimerRemaining')), findsNothing);

      c.read(restTimerProvider.notifier).start(60, label: '벤치');
      await tester.pump();
      expect(find.text('01:00'), findsOneWidget);
      expect(find.text('벤치'), findsOneWidget);
      expect(find.text('+30초'), findsOneWidget);
      expect(find.byKey(const Key('restTimerMinus')), findsNothing);

      await tester.tap(find.byKey(const Key('restTimerPlus')));
      await tester.pump();
      expect(find.text('01:30'), findsOneWidget);

      now = t(60);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('00:30'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(find.byKey(const Key('restTimerProgress')));
      expect(bar.value, closeTo(2 / 3, 0.01));

      await tester.tap(find.byKey(const Key('restTimerSkip')));
      await tester.pump();
      expect(find.byKey(const Key('restTimerRemaining')), findsNothing);
      c.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('SessionWakelock: keepScreenOn이면 켜고, 사라지면 끈다', (tester) async {
      final calls = <bool>[];
      final c = ProviderContainer(
        overrides: [
          wakelockToggleProvider.overrideWithValue((e) async => calls.add(e)),
          settingsProvider.overrideWith(FixedSettings.new),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(app(c, const SessionWakelock(child: Text('s'))));
      expect(calls, [true]);

      await c.read(settingsProvider.notifier).update(const Settings(keepScreenOn: false));
      await tester.pump();
      expect(calls, [true, false]);

      await c.read(settingsProvider.notifier).update(const Settings(keepScreenOn: true));
      await tester.pump();
      expect(calls, [true, false, true]);

      await tester.pumpWidget(app(c, const SizedBox()));
      expect(calls.last, false);
    });
  });
}
