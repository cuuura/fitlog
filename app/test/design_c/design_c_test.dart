// C 담당 화면(기록·그래프 비교·가져오기·충돌/삭제 승인)의 새 UI 위젯 테스트.
import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart' show RecordPoint;
import 'package:fitlog/core/api/stats_dto.dart';
import 'package:fitlog/core/clock.dart';
import 'package:fitlog/core/theme.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/ai_connect/ai_avatar.dart';
import 'package:fitlog/features/ai_connect/ai_hub_page.dart';
import 'package:fitlog/features/importing/conflict_card.dart';
import 'package:fitlog/features/importing/import_page.dart';
import 'package:fitlog/features/progress/compare_charts.dart';
import 'package:fitlog/features/progress/progress_logic.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../v02_b3/harness.dart';

Widget _app(Widget child, {List<Override> overrides = const [], Brightness brightness = Brightness.light, bool page = false}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
        localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ko'),
        home: page ? child : Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

RecordPoint _rp(double w, int reps) =>
    RecordPoint(weightKg: w, reps: reps, sessionId: 'x', setId: 'y', achievedAt: DateTime.utc(2026, 10, 1));

Snap _snap(List<SnapSet> sets) => Snap(
  sessionId: 's',
  startedAt: DateTime.utc(2026, 11, 20),
  sets: sets,
  setCount: sets.length,
  topWeightKg: 100,
  bestE1rmKg: 117,
  volumeKg: 500,
);

void main() {
  group('progress_logic', () {
    test('setComparisons: 횟수 차이·미달·PR', () {
      final c = ExerciseComparison(
        exerciseId: 'e',
        current: _snap(const [SnapSet(77.5, 8), SnapSet(87.5, 5), SnapSet(97.5, 4), SnapSet(90, 3)]),
        previous: _snap(const [SnapSet(75, 7), SnapSet(85, 6), SnapSet(95, 3)]),
        bestWeight: _rp(95, 3),
      );
      final rows = setComparisons(c);
      expect(rows.map((r) => r.diffReps), [1, -1, 1, null]);
      expect(rows.map((r) => r.fail), [false, true, false, false]);
      expect(rows.map((r) => r.pr), [false, false, true, false]); // 95 초과는 97.5뿐
    });

    test('recentE1rmPoints: 추정 1RM이 있는 점만, 최근 12개', () {
      final pts = [
        for (var i = 1; i <= 15; i++)
          ProgressPoint(
            sessionId: 's$i',
            startedAt: DateTime.utc(2026, 11, i),
            topWeightKg: 100,
            topReps: 5,
            bestE1rmKg: i == 3 ? null : 100.0 + i,
            volumeKg: 1,
            workSetCount: 1,
          ),
      ];
      final r = recentE1rmPoints(pts);
      expect(r.length, 12);
      expect(r.last.sessionId, 's15');
      expect(r.first.sessionId, 's4');
    });
  });

  group('차트', () {
    for (final b in Brightness.values) {
      testWidgets('RepsBarChart·E1rmTrendChart·범례가 ${b.name} 테마에서 그려진다', (tester) async {
        await tester.pumpWidget(
          _app(
            Column(
              children: [
                RepsBarChart(
                  today: const [8, 5, 4, 3, 3],
                  last: const [7, 6, 3, 3, null],
                  prReps: 3,
                  setLabel: (n) => '$n세트',
                  prLabel: 'PR 3회',
                  axisLabel: '횟수',
                  semantics: '막대',
                ),
                E1rmTrendChart(
                  points: [
                    for (var i = 0; i < 12; i++) TrendPoint(95 + i * 1.2, '11/${i + 1}', i == 9 || i == 11),
                  ],
                  valueLabel: (v) => v.toStringAsFixed(1),
                  unitLabel: 'kg',
                  semantics: '추이',
                ),
                Row(children: [for (final k in LegendKind.values) LegendSwatch(k)]),
              ],
            ),
            brightness: b,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(CustomPaint), findsWidgets);
      });
    }

    testWidgets('데이터가 하나뿐이어도 추이 차트가 깨지지 않는다', (tester) async {
      await tester.pumpWidget(
        _app(
          E1rmTrendChart(
            points: const [TrendPoint(100, '11/27 오늘', true)],
            valueLabel: (v) => '$v',
            unitLabel: 'kg',
            semantics: '추이',
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('기록 탭', () {
    testWidgets('행: 큰 날짜 숫자, 자유 운동, 종목 요약, 큰 볼륨, 월 머리말 통계', (tester) async {
      final h = B3Harness();
      final s = await h.finished(DateTime.utc(2026, 11, 15, 12), lifts: [
        ('ex-squat', [(100.0, 5)]),
        ('ex-bench', [(60.0, 8)]),
        ('ex-pullup', [(0.0, 5)]),
      ]);
      await h.pump(tester, '/history');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(Key('history-day-${s.id}')), findsOneWidget);
      expect(find.text('15'), findsOneWidget);
      expect(find.text('자유 운동'), findsOneWidget);
      expect(find.text('스쿼트 · 벤치 프레스 외 1'), findsOneWidget);
      expect(find.byKey(Key('history-volume-${s.id}')), findsOneWidget);
      expect(find.text('980'), findsOneWidget);
      expect(find.text('세션 1회 · 980kg'), findsOneWidget);
    });
  });

  group('AI 가져오기', () {
    test('aiInitials', () {
      expect(aiInitials('Claude'), 'Cl');
      expect(aiInitials('ChatGPT'), 'GP');
      expect(aiInitials('Gemini'), 'Ge');
      expect(aiInitials('perplexity'), 'Pe');
    });

    test('bundleCounts·previewCounts·previewSaveNow·incomingAt', () {
      final b = {
        'programs': [{}],
        'sessions': [{'date': 'a'}, {'date': 'b'}, {}],
        'bodyMeasurements': [{}, {}],
      };
      expect(bundleCounts(b), (programs: 1, sessions: 3, body: 2, scheduled: 0));
      final counts = {
        'sessions': {'NEW': 2, 'REPLACE': 1},
        'bodyMeasurements': {'NEW': 2},
      };
      expect(previewCounts(counts), (programs: 0, sessions: 3, body: 2, scheduled: 0));
      expect(previewSaveNow(counts), 4);
      expect(incomingAt(b, '/sessions/1'), {'date': 'b'});
      expect(incomingAt(b, '/sessions/9'), isNull);
      expect(incomingAt(b, '/nope'), isNull);
    });

    testWidgets('허브: 연결된 AI 이니셜 원형과 "연결됨 · 마지막 사용 n일 전"', (tester) async {
      final repo = MemoryAiConnectionRepository();
      repo.list.addAll([
        AiConnection(
          id: 'c1',
          clientName: 'Claude',
          scopes: const ['fitlog.read'],
          createdAt: DateTime.utc(2026, 11, 1),
          lastUsedAt: DateTime.utc(2026, 11, 25, 12),
        ),
        AiConnection(id: 'c2', clientName: 'Gemini', scopes: const [], createdAt: DateTime.utc(2026, 11, 1)),
      ]);
      await tester.pumpWidget(
        _app(
          const AiHubPage(),
          page: true,
          overrides: [
            aiConnectionRepositoryProvider.overrideWithValue(repo),
            deletionRequestRepositoryProvider.overrideWithValue(MemoryDeletionRequestRepository()),
            clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 27, 12)),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cl'), findsOneWidget);
      expect(find.text('Ge'), findsOneWidget);
      expect(find.text('연결됨 · 마지막 사용 2일 전'), findsOneWidget);
      expect(find.text('연결됨 · 아직 사용 안 함'), findsOneWidget);
    });
  });

  group('충돌·삭제 승인', () {
    testWidgets('충돌 카드: 기존/가져온 값 두 열 + 세그먼트 선택', (tester) async {
      Resolution? chosen;
      final c = Conflict(
        conflictId: 'SESSION_OVERLAP:/sessions/0',
        code: ConflictCode.SESSION_OVERLAP,
        path: '/sessions/0',
        message: '',
        allowed: const [ResolutionAction.KEEP_BOTH, ResolutionAction.REPLACE, ResolutionAction.SKIP],
        existing: const {'볼륨': '1,800kg'},
      );
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => ConflictCard(
              conflict: c,
              incoming: const {'볼륨': '1,875kg'},
              clientName: 'Claude',
              resolution: chosen,
              unit: WeightUnit.KG,
              onChanged: (r) => setState(() => chosen = r),
            ),
          ),
        ),
      );
      expect(find.text('기존'), findsOneWidget);
      expect(find.text('가져온 값 (Claude)'), findsOneWidget);
      expect(find.text('볼륨: 1,800kg'), findsOneWidget);
      expect(find.text('볼륨: 1,875kg'), findsOneWidget);
      for (final t in ['둘 다 저장', '바꾸기', '건너뛰기']) {
        expect(find.text(t), findsOneWidget);
      }
      // 두 열은 같은 높이 줄에 나란히.
      final l = tester.getTopLeft(find.byKey(Key('existing-${c.conflictId}'))).dy;
      final r = tester.getTopLeft(find.byKey(Key('incoming-${c.conflictId}'))).dy;
      expect(l, r);
      // 터치 영역 48 이상
      expect(tester.getSize(find.byKey(ValueKey('action-${c.conflictId}-REPLACE'))).height, greaterThanOrEqualTo(48));

      await tester.tap(find.text('둘 다 저장'));
      await tester.pump();
      expect(chosen?.action, ResolutionAction.KEEP_BOTH);
      expect(find.byIcon(Icons.check), findsOneWidget); // 선택은 아이콘으로도 표시
    });
  });
}
