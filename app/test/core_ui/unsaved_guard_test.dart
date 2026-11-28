import 'package:fitlog/core/ui/unsaved_guard.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

Widget _editor(bool dirty) => UnsavedGuard(
  dirty: dirty,
  child: Scaffold(
    appBar: AppBar(title: const Text('편집')),
    body: const SizedBox(),
  ),
);

void main() {
  Widget navApp(bool dirty) => host(Scaffold(
    body: Builder(builder: (c) => TextButton(
      key: const Key('open'),
      onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => _editor(dirty))),
      child: const Text('open'),
    )),
  ));

  testWidgets('dirty: 묻고, 취소하면 남음, 나가기하면 나감', (t) async {
    await t.pumpWidget(navApp(true));
    await open(t);
    expect(find.text('편집'), findsOneWidget);

    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('저장하지 않고 나갈까요?'), findsOneWidget);
    expect(find.text('고친 내용이 사라져요.'), findsOneWidget);
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    expect(find.text('편집'), findsOneWidget);
    expect(find.text('저장하지 않고 나갈까요?'), findsNothing);

    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('discard-confirm')));
    await t.pumpAndSettle();
    expect(find.text('편집'), findsNothing);
    expect(find.byKey(const Key('open')), findsOneWidget);
  });

  testWidgets('시스템 뒤로가기도 같은 경로', (t) async {
    await t.pumpWidget(navApp(true));
    await open(t);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('저장하지 않고 나갈까요?'), findsOneWidget);
  });

  testWidgets('dirty 아니면 바로 나감', (t) async {
    await t.pumpWidget(navApp(false));
    await open(t);
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('편집'), findsNothing);
    expect(find.text('저장하지 않고 나갈까요?'), findsNothing);
  });

  testWidgets('go_router(push)와 함께 동작', (t) async {
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (c, _) => Scaffold(body: TextButton(key: const Key('open'), onPressed: () => c.push('/edit'), child: const Text('open'))),
      ),
      GoRoute(path: '/edit', builder: (_, _) => _editor(true)),
    ]);
    addTearDown(router.dispose);
    await t.pumpWidget(MaterialApp.router(
      routerConfig: router,
      locale: const Locale('ko'),
      localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
      supportedLocales: AppLocalizations.supportedLocales,
    ));
    await open(t);
    expect(find.text('편집'), findsOneWidget);
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('저장하지 않고 나갈까요?'), findsOneWidget);
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    expect(find.text('편집'), findsOneWidget);
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('discard-confirm')));
    await t.pumpAndSettle();
    expect(find.text('편집'), findsNothing);
    expect(find.byKey(const Key('open')), findsOneWidget);
  });
}
