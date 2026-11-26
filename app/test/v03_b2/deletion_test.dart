import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/features/deletion_requests/deletion_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

void main() {
  testWidgets('대기·처리됨 탭, 요청한 AI·사유·만료까지 남은 시간', (tester) async {
    final h = V03Harness();
    h.deletions.requests.addAll([
      delReq('d1', h.now),
      delReq('d2', h.now, status: DeletionStatus.APPROVED, label: '끝난 요청'),
    ]);
    await h.pump(tester, Routes.deletionRequests);
    expect(find.text('2026-11-20 세션'), findsOneWidget);
    expect(find.text('세션'), findsOneWidget);
    expect(find.text('요청한 AI: Claude'), findsOneWidget);
    expect(find.text('사유: 중복된 기록'), findsOneWidget);
    expect(find.text('만료까지 5시간 30분'), findsOneWidget);
    expect(find.text('끝난 요청'), findsNothing);

    await tester.tap(find.byKey(const Key('deletion-tab-done')));
    await tester.pumpAndSettle();
    expect(find.text('끝난 요청'), findsOneWidget);
    expect(find.text('승인됨'), findsOneWidget);
    expect(find.byKey(const Key('deletion-approve-d2')), findsNothing);
  });

  testWidgets('승인: 확인 문구 "되돌릴 수 없습니다" 후 삭제되고 목록에서 빠진다', (tester) async {
    final h = V03Harness();
    h.deletions.requests.add(delReq('d1', h.now));
    await h.pump(tester, Routes.deletionRequests);
    await tester.tap(find.byKey(const Key('deletion-approve-d1')));
    await tester.pumpAndSettle();
    expect(find.text('삭제합니다, 되돌릴 수 없습니다'), findsOneWidget);
    await tester.tap(find.byKey(const Key('deletion-approve-confirm')));
    await tester.pumpAndSettle();
    expect(h.deletions.requests.single.status, DeletionStatus.APPROVED);
    expect(find.text('삭제했어요'), findsOneWidget);
    expect(find.byKey(const Key('deletion-approve-d1')), findsNothing);
    expect(find.byKey(const Key('deletion-empty-pending')), findsOneWidget);
  });

  testWidgets('거절', (tester) async {
    final h = V03Harness();
    h.deletions.requests.add(delReq('d1', h.now));
    await h.pump(tester, Routes.deletionRequests);
    await tester.tap(find.byKey(const Key('deletion-reject-d1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('deletion-reject-confirm')));
    await tester.pumpAndSettle();
    expect(h.deletions.requests.single.status, DeletionStatus.REJECTED);
    expect(find.text('거절했어요'), findsOneWidget);
  });

  for (final (code, text) in [(409, '이미 처리된 요청이에요'), (410, '만료된 요청이에요')]) {
    testWidgets('$code 응답은 안내 후 목록을 새로 읽는다', (tester) async {
      final h = V03Harness();
      h.deletions.requests.add(delReq('d1', h.now));
      await h.pump(tester, Routes.deletionRequests);
      h.deletions.failWith = ApiException(statusCode: code, code: 'CONFLICT', message: 'x');
      // 서버에서는 이미 결정된 상태.
      h.deletions.requests[0] = delReq('d1', h.now, status: code == 409 ? DeletionStatus.REJECTED : DeletionStatus.EXPIRED);
      await tester.tap(find.byKey(const Key('deletion-approve-d1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('deletion-approve-confirm')));
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
      expect(find.byKey(const Key('deletion-approve-d1')), findsNothing);
      expect(find.byKey(const Key('deletion-empty-pending')), findsOneWidget);
    });
  }

  testWidgets('홈 배너: 대기 건수가 있으면 보이고 탭하면 삭제 요청 화면, 처리 후 돌아오면 사라진다', (tester) async {
    final h = V03Harness();
    h.deletions.requests.addAll([delReq('d1', h.now), delReq('d2', h.now)]);
    await h.pump(tester, Routes.home);
    expect(find.text('AI가 삭제를 요청했어요 (2건)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-deletion-banner')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('deletion-approve-d1')), findsOneWidget);

    for (final id in ['d1', 'd2']) {
      await tester.tap(find.byKey(Key('deletion-reject-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('deletion-reject-confirm')));
      await tester.pumpAndSettle();
    }
    h.router.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-deletion-banner')), findsNothing);
  });

  testWidgets('홈 배너: 대기가 없거나 서버 오류면 안 보인다', (tester) async {
    final h = V03Harness();
    await h.pump(tester, Routes.home);
    expect(find.byKey(const Key('home-deletion-banner')), findsNothing);
  });

  test('pendingCount가 던지면 0', () async {
    final h = V03Harness();
    h.deletions.requests.add(delReq('d1', h.now));
    final c = ProviderContainer(overrides: h.overrides);
    addTearDown(c.dispose);
    expect(await c.read(pendingDeletionCountProvider.future), 1);
    h.deletions.countFails = true;
    c.invalidate(pendingDeletionCountProvider);
    expect(await c.read(pendingDeletionCountProvider.future), 0);
  });
}
