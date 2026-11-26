// 규모가 큰 데이터에서 화면이 만들어지는지, 리스트가 필요한 만큼만 그리는지(lazy) 확인한다.
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/crash/crash_reporting.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_env.dart';

void main() {
  testWidgets('종목 10 x 세트 10 세션이 그려지고 끝까지 스크롤된다', (t) async {
    final e = AppEnv();
    final s = await e.sessions.startSession(tz: 'Asia/Seoul');
    final ids = [squat, bench, pullUp, dbPress];
    for (var i = 0; i < 10; i++) {
      final se = await e.sessions.addExercise(s.id, ids[i % ids.length].id);
      for (var j = 0; j < 10; j++) {
        await e.sessions.addSet(
          se.id,
          WorkoutSet(id: newId(), position: j, weightKg: 60 + j * 2.5, reps: 8, completedAt: j.isEven ? e.now : null),
        );
      }
    }
    await e.pump(t, initial: Routes.session, size: const Size(360, 640));
    expect(t.takeException(), isNull);
    expect(find.byKey(const Key('end-session')), findsOneWidget);

    // 바깥 목록은 builder라 화면 밖 종목 카드는 아직 만들지 않았다
    final firstBuilt = find.byType(TextField).evaluate().length;
    expect(firstBuilt, lessThan(10 * 10 * 2), reason: '세트 입력칸 200개가 한꺼번에 만들어지면 lazy가 아님');
    await t.drag(find.byType(Scrollable).first, const Offset(0, -20000));
    await settle(t);
    expect(t.takeException(), isNull);
  });

  testWidgets('히스토리 200개: 한 번에 다 그리지 않는다', (t) async {
    final e = AppEnv();
    for (var i = 0; i < 200; i++) {
      await finishedSession(
        e,
        DateTime.utc(2026, 1, 1).add(Duration(days: i)),
        lifts: [
          (squat.id, [(100.0, 5)]),
        ],
      );
    }
    await e.pump(t, initial: Routes.history, size: const Size(360, 640));
    expect(t.takeException(), isNull);
    expect(find.byKey(const Key('history-list')), findsOneWidget);
    final built = find.byType(ListTile).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(40), reason: '화면에 보이는 만큼만 만들어야 한다');
    // 아래로 내려가며 더 불러와도 예외 없음
    for (var i = 0; i < 5; i++) {
      await t.drag(find.byKey(const Key('history-list')), const Offset(0, -3000));
      await settle(t, 3);
    }
    expect(t.takeException(), isNull);
  });

  group('설정의 오류 보고 토글', () {
    testWidgets('DSN이 있는 빌드에서만 보이고, 끄면 저장된다', (t) async {
      final e = AppEnv();
      SharedPreferences.setMockInitialValues({});
      await e.pump(t, initial: Routes.settings, size: const Size(800, 2400));
      // 기본(테스트)은 DSN 없음 -> 숨김
      expect(find.byKey(const Key('crashReport')), findsNothing);

      final e2 = AppEnv();
      await t.pumpWidget(const SizedBox());
      await e2.pump(
        t,
        initial: Routes.settings,
        size: const Size(800, 2400),
        extraOverrides: [crashReportingAvailableProvider.overrideWithValue(true)],
      );
      expect(find.byKey(const Key('crashReport')), findsOneWidget);
      expect(t.widget<SwitchListTile>(find.byKey(const Key('crashReport'))).value, isTrue);
      await t.ensureVisible(find.byKey(const Key('crashReport')));
      await t.tap(find.byKey(const Key('crashReport')));
      await settle(t);
      expect(t.widget<SwitchListTile>(find.byKey(const Key('crashReport'))).value, isFalse);
      expect(await loadCrashReportingEnabled(), isFalse);
      expect(
        ProviderScope.containerOf(t.element(find.byKey(const Key('crashReport')))).read(crashReportingEnabledProvider),
        isFalse,
      );
    });
  });
}
