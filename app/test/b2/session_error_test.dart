import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

class _FailingSessions extends MemorySessionRepository {
  _FailingSessions({required super.now});
  bool fail = true;
  int calls = 0;

  @override
  Stream<Session?> watchActiveSession() {
    calls++;
    if (fail) return Stream<Session?>.error(StateError('boom'));
    return super.watchActiveSession();
  }
}

class _ErrHarness extends Harness {
  late final _FailingSessions failing = _FailingSessions(now: () => now);

  @override
  SessionRepository get sessionRepo => failing;
}

void main() {
  testWidgets('활성 세션 오류 -> 오류 화면, 스피너 없음', (t) async {
    final h = _ErrHarness();
    await h.pump(t, initial: Routes.session);
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('session-error')), findsOneWidget);
    expect(find.text('세션을 불러오지 못했어요'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('다시 시도는 provider를 무효화해 다시 구독한다', (t) async {
    final h = _ErrHarness();
    await h.pump(t, initial: Routes.session);
    await t.pump(const Duration(milliseconds: 100));
    final before = h.failing.calls;
    await t.tap(find.byKey(const Key('session-retry')));
    await t.pump(const Duration(milliseconds: 100));
    expect(h.failing.calls, greaterThan(before));
    expect(find.byKey(const Key('session-error')), findsOneWidget);
  });

  testWidgets('홈으로 버튼은 홈으로 이동한다', (t) async {
    final h = _ErrHarness();
    await h.pump(t, initial: Routes.session);
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.byKey(const Key('session-error-home')));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('session-error')), findsNothing);
    expect(find.byKey(const Key('home-start')), findsOneWidget);
  });
}
