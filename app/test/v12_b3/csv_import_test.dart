import 'dart:async';
import 'dart:convert';

import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/csv_import_dto.dart';
import 'package:fitlog/core/api/dto.dart' show WeightUnit;
import 'package:fitlog/core/routes.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/csv_import/csv_import_controller.dart';
import 'package:fitlog/features/csv_import/csv_import_page.dart';
import 'package:fitlog/features/session/session_controller.dart' show deviceTimezoneProvider;
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

Map<String, Object?> _previewJson({int chunks = 2, List<Map<String, Object?>> conflicts = const []}) => {
  'csv': {
    'format': 'STRONG',
    'sessions': 12,
    'sets': 240,
    'matchedExercises': 7,
    'newExercises': ['Cable Fly (Cable)', 'Zercher Squat'],
    'skippedRows': [
      {'line': 5, 'reason': '날짜를 읽을 수 없어요'},
      {'line': 9, 'reason': '세트 번호 없음'},
    ],
  },
  'chunks': [
    for (var i = 0; i < chunks; i++)
      {
        'bundle': {
          'schemaVersion': 1,
          'sessions': [
            {'n': i},
          ],
        },
        'preview': {
          'valid': true,
          'counts': {
            'sessions': {'NEW': 1},
          },
          'conflicts': i == 0 ? conflicts : const [],
          'unresolved': const [],
        },
      },
  ],
};

class _CsvRepo implements CsvImportRepository {
  Object? error;
  Map<String, Object?> json = _previewJson();
  final calls = <({CsvFormat format, WeightUnit? unit, String csv})>[];
  @override
  Future<CsvPreview> preview({
    required CsvFormat format,
    required String csv,
    WeightUnit? weightUnit,
    required String tz,
  }) async {
    calls.add((format: format, unit: weightUnit, csv: csv));
    if (error != null) throw error!;
    return CsvPreview.fromJson(json);
  }
}

class _ImportRepo extends MemoryImportRepository {
  /// 이 번호(0부터)의 submit 호출에서 예외를 던진다.
  int? failOn;
  int calls = 0;
  @override
  Future<ImportOutcome> submit(ImportRequest request) async {
    final n = calls++;
    if (n == failOn) {
      failOn = null;
      throw const ApiException(code: 'NETWORK', message: 'x');
    }
    return super.submit(request);
  }
}

Map<String, Object?> _conflictJson() => {
  'conflictId': 'c1',
  'code': 'SESSION_EXISTS',
  'path': '/sessions/0',
  'message': '이미 있어요',
  'allowed': ['SKIP', 'REPLACE'],
};

ProviderContainer _container(_CsvRepo csv, _ImportRepo imp) {
  final c = ProviderContainer(
    overrides: [
      csvImportRepositoryProvider.overrideWithValue(csv),
      importRepositoryProvider.overrideWithValue(imp),
      deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
    ],
  );
  addTearDown(c.dispose);
  c.listen(csvImportControllerProvider, (_, _) {});
  return c;
}

void main() {
  group('CsvImportController', () {
    test('미리보기: 형식·무게 단위·본문을 보내고 요약을 받는다', () async {
      final csv = _CsvRepo();
      final c = _container(csv, _ImportRepo());
      final ctl = c.read(csvImportControllerProvider.notifier);
      ctl.setFormat(CsvFormat.STRONG);
      ctl.setWeightUnit(WeightUnit.LB);
      ctl.setFile('strong.csv', 'Date,Workout Name\n', 20);
      await ctl.loadPreview();
      final s = c.read(csvImportControllerProvider);
      expect(s.step, CsvStep.preview);
      expect(csv.calls.single.format, CsvFormat.STRONG);
      expect(csv.calls.single.unit, WeightUnit.LB);
      expect(s.preview!.csv.sessions, 12);
      expect(s.preview!.csv.newExercises, hasLength(2));
      expect(s.preview!.csv.skippedRows.first.line, 5);
      expect(s.totalChunks, 2);
    });

    test('Hevy·자동에서는 무게 단위를 보내지 않는다', () async {
      final csv = _CsvRepo();
      final c = _container(csv, _ImportRepo());
      final ctl = c.read(csvImportControllerProvider.notifier);
      ctl.setFormat(CsvFormat.HEVY);
      ctl.setFile('h.csv', 'title,start_time\n', 10);
      await ctl.loadPreview();
      expect(csv.calls.single.unit, isNull);
    });

    test('확정: 조각을 순서대로 저장하고 겹치는 항목은 건너뛰기로 보낸다', () async {
      final csv = _CsvRepo()..json = _previewJson(conflicts: [_conflictJson()]);
      final imp = _ImportRepo();
      final c = _container(csv, imp);
      final ctl = c.read(csvImportControllerProvider.notifier);
      ctl.setFile('a.csv', 'x', 1);
      await ctl.loadPreview();
      await ctl.confirm();
      final s = c.read(csvImportControllerProvider);
      expect(s.step, CsvStep.done);
      expect(s.batches, hasLength(2));
      expect(imp.submitted, hasLength(2));
      expect(imp.submitted[0].bundle['sessions'], [
        {'n': 0},
      ]);
      expect(imp.submitted[1].bundle['sessions'], [
        {'n': 1},
      ]);
      expect(imp.submitted[0].resolutions['c1']!.action, ResolutionAction.SKIP);
      expect(imp.submitted[0].tz, 'Asia/Seoul');
    });

    test('확정 중 실패하면 그 조각에서 멈추고 다시 누르면 이어서 저장한다', () async {
      final csv = _CsvRepo()..json = _previewJson(chunks: 3);
      final imp = _ImportRepo()..failOn = 1;
      final c = _container(csv, imp);
      final ctl = c.read(csvImportControllerProvider.notifier);
      ctl.setFile('a.csv', 'x', 1);
      await ctl.loadPreview();
      await ctl.confirm();
      var s = c.read(csvImportControllerProvider);
      expect(s.step, CsvStep.preview);
      expect(s.error!.kind, CsvErrorKind.network);
      expect(s.batches, hasLength(1));
      expect(s.index, 1);
      expect(s.partiallySaved, isTrue);

      await ctl.confirm();
      s = c.read(csvImportControllerProvider);
      expect(s.step, CsvStep.done);
      expect(s.batches, hasLength(3));
      expect(imp.submitted.map((r) => (r.bundle['sessions'] as List).first['n']), [0, 1, 2]);
    });

    test('413은 파일이 너무 크다는 오류', () async {
      final csv = _CsvRepo()..error = const ApiException(statusCode: 413, code: 'PAYLOAD_TOO_LARGE', message: 'big');
      final c = _container(csv, _ImportRepo());
      final ctl = c.read(csvImportControllerProvider.notifier);
      ctl.setFile('a.csv', 'x', 1);
      await ctl.loadPreview();
      final s = c.read(csvImportControllerProvider);
      expect(s.step, CsvStep.input);
      expect(s.error!.kind, CsvErrorKind.tooLarge);
    });

    test('400은 형식 오류이고 서버 문구를 덧붙인다', () async {
      final csv = _CsvRepo()..error = const ApiException(statusCode: 400, code: 'VALIDATION_FAILED', message: '머리글 없음');
      final c = _container(csv, _ImportRepo());
      final ctl = c.read(csvImportControllerProvider.notifier);
      ctl.setFile('a.csv', 'x', 1);
      await ctl.loadPreview();
      final e = c.read(csvImportControllerProvider).error!;
      expect(e.kind, CsvErrorKind.badFormat);
      expect(e.detail, '머리글 없음');
    });

    test('4MB를 넘는 파일은 요청 없이 막는다', () async {
      final csv = _CsvRepo();
      final c = _container(csv, _ImportRepo());
      final ctl = c.read(csvImportControllerProvider.notifier);
      ctl.setFile('big.csv', '', csvMaxBytes + 1);
      final s = c.read(csvImportControllerProvider);
      expect(s.hasFile, isFalse);
      expect(s.error!.kind, CsvErrorKind.tooLarge);
      expect(csv.calls, isEmpty);
    });
  });

  group('CsvImportPage', () {
    late _CsvRepo csv;
    late _ImportRepo imp;
    PickedCsv? picked;

    Future<void> pump(WidgetTester tester) async {
      csv = _CsvRepo();
      imp = _ImportRepo();
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final overrides = <Override>[
        csvImportRepositoryProvider.overrideWithValue(csv),
        importRepositoryProvider.overrideWithValue(imp),
        deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
        csvFilePickerProvider.overrideWithValue(() async => picked),
      ];
      final router = GoRouter(
        initialLocation: Routes.home,
        routes: [
          GoRoute(path: Routes.home, builder: (_, _) => const Scaffold(body: Text('home-page'))),
          GoRoute(path: Routes.csvImport, builder: (_, _) => const CsvImportPage()),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('ko'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(router.push(Routes.csvImport));
      await tester.pumpAndSettle();
    }

    PickedCsv file() => (name: 'strong.csv', bytes: Uint8List.fromList(utf8.encode('Date,Workout Name\n2026-01-01,A\n')));

    testWidgets('파일 고르기 → 미리보기 요약 → 확정 → 결과', (tester) async {
      picked = file();
      await pump(tester);
      // 파일 없으면 미리보기 비활성
      expect(tester.widget<FilledButton>(find.byKey(const Key('csv-preview'))).onPressed, isNull);
      // Strong일 때만 무게 단위가 보인다
      expect(find.byKey(const Key('csv-unit')), findsNothing);
      await tester.tap(find.text('Strong'));
      await tester.pump();
      expect(find.byKey(const Key('csv-unit')), findsOneWidget);

      await tester.tap(find.byKey(const Key('csv-pick')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('csv-file')), findsOneWidget);

      await tester.tap(find.byKey(const Key('csv-preview')));
      await tester.pumpAndSettle();
      expect(find.text('세션 12개'), findsOneWidget);
      expect(find.text('세트 240개'), findsOneWidget);
      expect(find.text('새로 만들 종목 2개'), findsOneWidget);
      expect(find.text('Zercher Squat'), findsOneWidget);
      expect(find.text('건너뛴 줄 2개'), findsOneWidget);
      // 펼치면 사유가 보인다
      expect(find.text('5번째 줄: 날짜를 읽을 수 없어요'), findsNothing);
      await tester.tap(find.text('건너뛴 줄 2개'));
      await tester.pumpAndSettle();
      expect(find.text('5번째 줄: 날짜를 읽을 수 없어요'), findsOneWidget);

      await tester.tap(find.byKey(const Key('csv-confirm')));
      await tester.pumpAndSettle();
      expect(imp.submitted, hasLength(2));
      expect(find.text('가져오기 완료'), findsOneWidget);
      expect(find.byKey(const Key('csv-result')), findsOneWidget);

      await tester.tap(find.byKey(const Key('csv-done')));
      await tester.pumpAndSettle();
      expect(find.text('home-page'), findsOneWidget);
    });

    testWidgets('서버가 400이면 입력 화면에 오류를 보여 준다', (tester) async {
      picked = file();
      await pump(tester);
      csv.error = const ApiException(statusCode: 400, code: 'VALIDATION_FAILED', message: '');
      await tester.tap(find.byKey(const Key('csv-pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('csv-preview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('csv-preview')), findsOneWidget);
      expect(find.text(AppLocalizations.of(tester.element(find.byType(CsvImportPage))).csvErrBadFormat), findsOneWidget);
    });

    testWidgets('확정 중 실패하면 화면에 오류와 이어서 가져오기가 보인다', (tester) async {
      picked = file();
      await pump(tester);
      imp.failOn = 1;
      await tester.tap(find.byKey(const Key('csv-pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('csv-preview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('csv-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('네트워크 연결을 확인해 주세요.'), findsOneWidget);
      expect(find.text('이어서 가져오기'), findsOneWidget);
      await tester.tap(find.byKey(const Key('csv-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('가져오기 완료'), findsOneWidget);
    });
  });
}
