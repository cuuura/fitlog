// 예정 운동(LOG-13) 데이터층: 저장소(메모리·drift), 시작 시 목표 복사, 동기화 payload·순서·왕복, 계산 상태.
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:fitlog/data/local/drift_repositories.dart';
import 'package:fitlog/data/local/local_mappers.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/sync/sync_engine.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:fitlog/features/scheduled/scheduled_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import '../b3/fake_server.dart';

ScheduledWorkout sample({String id = 'sw1', String date = '2026-11-28', String title = 'B-2 하체 2'}) => ScheduledWorkout(
  id: id,
  plannedDate: date,
  title: title,
  note: 'RIR 3~4',
  items: const [
    ScheduledItem(
      exerciseId: 'ex-squat',
      note: '벨트',
      restSec: 180,
      sets: [
        ScheduledSet(isWarmup: true, targetWeightKg: 40, targetReps: 8),
        ScheduledSet(targetWeightKg: 80, targetReps: 12, targetRepsMax: 15, targetRir: 3),
        ScheduledSet(targetReps: 10),
      ],
    ),
    ScheduledItem(
      exerciseId: 'ex-bench',
      sets: [ScheduledSet(targetWeightKg: 60, targetReps: 8, targetRpe: 8, targetDurationSec: 30)],
    ),
  ],
);

void main() {
  group('DTO', () {
    test('ScheduledWorkout JSON 왕복(§2), payload는 계산 필드·readOnly 없음', () {
      final j = sample().toJson();
      expect(j.keys.toSet(), {'id', 'plannedDate', 'title', 'note', 'items'});
      final set = ((j['items'] as List).first as Map)['sets'] as List;
      expect(set[1], {
        'isWarmup': false,
        'targetWeightKg': 80.0,
        'targetReps': 12,
        'targetRepsMax': 15,
        'targetRir': 3,
      });
      final back = ScheduledWorkout.fromJson(j);
      expect(back.items[0].restSec, 180);
      expect(back.items[1].sets.single.targetRpe, 8);
      expect(back.items[1].sets.single.targetDurationSec, 30);
      expect(back.setCount, 4);
    });

    test('세션·세트 payload에 새 필드', () {
      final s = Session(id: 's', startedAt: DateTime.utc(2026), tz: 'Asia/Seoul', scheduledWorkoutId: 'sw1');
      expect(s.toJson()['scheduledWorkoutId'], 'sw1');
      expect(Session.fromJson(s.toJson()).scheduledWorkoutId, 'sw1');
      const w = WorkoutSet(id: 'w', position: 0, targetRepsMax: 15, targetRir: 3, targetRestSec: 90);
      final j = w.toJson();
      expect([j['targetRepsMax'], j['targetRir'], j['targetRestSec']], [15, 3, 90]);
      final b = WorkoutSet.fromJson(j);
      expect([b.targetRepsMax, b.targetRir, b.targetRestSec], [15, 3, 90]);
      // copyWith가 목표를 보존한다(세트 완료 처리 때 목표가 사라지면 안 됨).
      final c = b.copyWith(reps: () => 12);
      expect([c.targetRepsMax, c.targetRir, c.targetRestSec], [15, 3, 90]);
    });
  });

  group('계산 상태(§1)', () {
    final w = sample();
    ScheduledLink link(String sid, {DateTime? ended}) =>
        ScheduledLink(scheduledWorkoutId: 'sw1', sessionId: sid, endedAt: ended);

    test('PLANNED / SKIPPED / IN_PROGRESS / DONE', () {
      expect(scheduledView(w, const []).status, ScheduledStatus.PLANNED);
      final skipped = w.copyWith(skippedAt: () => DateTime.utc(2026, 11, 27));
      expect(scheduledView(skipped, const []).status, ScheduledStatus.SKIPPED);
      final prog = scheduledView(w, [link('s1')]);
      expect((prog.status, prog.sessionId), (ScheduledStatus.IN_PROGRESS, 's1'));
      final done = scheduledView(w, [link('s1', ended: DateTime.utc(2026, 11, 28))]);
      expect((done.status, done.sessionId), (ScheduledStatus.DONE, 's1'));
      // 건너뜀 표시가 있어도 세션이 있으면 세션이 이긴다.
      expect(scheduledView(skipped, [link('s1', ended: DateTime.utc(2026, 11, 28))]).status, ScheduledStatus.DONE);
      // 다른 예정의 세션은 무시.
      expect(
        scheduledView(w, [const ScheduledLink(scheduledWorkoutId: 'other', sessionId: 'x')]).status,
        ScheduledStatus.PLANNED,
      );
    });

    test('지난 PLANNED만 "지난 예정"', () {
      final v = scheduledView(w, const []);
      expect(v.isLate('2026-11-28'), isFalse);
      expect(v.isLate('2026-11-29'), isTrue);
      expect(scheduledView(w, [link('s1')]).isLate('2026-11-29'), isFalse);
    });

    test('홈 구성: 오늘 PLANNED·진행 중, 지난 7일 PLANNED. 미래·완료·건너뜀 제외', () {
      ScheduledView v(String id, String date, [ScheduledStatus st = ScheduledStatus.PLANNED]) => ScheduledView(
        workout: sample(id: id, date: date),
        status: st,
      );
      final h = homeScheduled([
        v('today', '2026-11-27'),
        v('late', '2026-11-25'),
        v('future', '2026-11-30'),
        v('done', '2026-11-27', ScheduledStatus.DONE),
        v('skipped', '2026-11-26', ScheduledStatus.SKIPPED),
        v('early', '2026-11-30', ScheduledStatus.IN_PROGRESS),
      ], '2026-11-27');
      expect([for (final x in h.today) x.id], ['today', 'early']);
      expect([for (final x in h.late) x.id], ['late']);
    });
  });

  group('메모리 저장소', () {
    test('upsert·기간 조회·건너뛰기·삭제', () async {
      final r = MemoryScheduledWorkoutRepository(now: () => DateTime.utc(2026, 11, 27));
      await r.upsert(sample(id: 'a', date: '2026-11-28'));
      await r.upsert(sample(id: 'b', date: '2026-12-05'));
      expect([for (final w in await r.watchBetween('2026-11-28', '2026-11-30').first) w.id], ['a']);
      expect([for (final w in await r.watchBetween('2026-11-01', '2026-12-31').first) w.id], ['a', 'b']);
      await r.setSkipped('a', true);
      expect((await r.byId('a'))!.skippedAt, isNotNull);
      await r.setSkipped('a', false);
      expect((await r.byId('a'))!.skippedAt, isNull);
      await r.delete('a');
      expect(await r.byId('a'), isNull);
    });

    test('startSession(scheduled): 목표·휴식 복사, 프로그램 시작과 같이 무게·횟수 미리 채움', () async {
      final repo = MemorySessionRepository(now: () => DateTime.utc(2026, 11, 28, 1));
      final s = await repo.startSession(tz: 'Asia/Seoul', scheduled: sample());
      expect(s.scheduledWorkoutId, 'sw1');
      expect(s.programInstanceId, isNull);
      expect(s.note, isNull);
      expect(s.source, SessionSource.APP);
      _expectCopied(s);
      final links = await repo.watchScheduledLinks().first;
      expect((links.single.scheduledWorkoutId, links.single.isActive), ('sw1', true));
      // 진행 중이면 그것을 돌려준다.
      final again = await repo.startSession(tz: 'Asia/Seoul', scheduled: sample(id: 'sw2'));
      expect(again.id, s.id);
    });
  });

  group('drift 저장소·동기화', () {
    late Env env;
    late SpySync spy;
    late DriftScheduledWorkoutRepository repo;
    late DriftSessionRepository sessions;

    setUp(() {
      env = makeEnv();
      spy = SpySync();
      repo = DriftScheduledWorkoutRepository(env.db, spy, clock: () => env.now);
      sessions = DriftSessionRepository(env.db, spy, clock: () => env.now);
    });
    tearDown(() => env.close());

    Future<List<OutboxRow>> outbox() => (env.db.select(env.db.outbox)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();

    test('upsert: 행·outbox(중첩 items payload)·updatedAt 증가', () async {
      await repo.upsert(sample());
      final ob = (await outbox()).single;
      expect((ob.entity, ob.op, ob.entityId), ('scheduled_workout', 'UPSERT', 'sw1'));
      expect(ob.payload, contains('"items"'));
      expect(ob.payload, isNot(contains('updatedAt')));
      final first = (await env.db.select(env.db.scheduledWorkouts).getSingle()).updatedAt;
      expect(spy.scheduled, 1);

      await repo.upsert(sample(title: '바뀐 제목'));
      expect((await outbox()).length, 1); // 같은 엔티티는 한 줄로 합친다
      final row = await env.db.select(env.db.scheduledWorkouts).getSingle();
      expect(row.title, '바뀐 제목');
      expect(row.updatedAt.isAfter(first), isTrue);
      final back = (await repo.byId('sw1'))!;
      expect(back.items[0].sets[1].targetRepsMax, 15);
      expect(back.items[1].sets.single.targetRpe, 8); // 화면에 없는 필드도 보존
    });

    test('기간 조회는 날짜 경계 포함·삭제 제외·날짜순', () async {
      await repo.upsert(sample(id: 'c', date: '2026-12-01'));
      await repo.upsert(sample(id: 'a', date: '2026-11-28'));
      await repo.upsert(sample(id: 'z', date: '2026-12-02'));
      await repo.delete('z');
      final list = await repo.watchBetween('2026-11-28', '2026-12-01').first;
      expect([for (final w in list) w.id], ['a', 'c']);
    });

    test('건너뛰기·취소·소프트 삭제가 outbox에 쌓인다', () async {
      await repo.upsert(sample());
      await repo.setSkipped('sw1', true);
      var row = await env.db.select(env.db.scheduledWorkouts).getSingle();
      expect(row.skippedAt, isNotNull);
      expect((await outbox()).single.payload, contains('skippedAt'));
      await repo.setSkipped('sw1', false);
      row = await env.db.select(env.db.scheduledWorkouts).getSingle();
      expect(row.skippedAt, isNull);
      expect((await outbox()).single.payload, isNot(contains('skippedAt')));
      await repo.delete('sw1');
      row = await env.db.select(env.db.scheduledWorkouts).getSingle();
      expect(row.deletedAt, isNotNull);
      final ob = (await outbox()).single;
      expect(ob.op, 'DELETE');
      expect(ob.payload, isNull);
      expect(await repo.byId('sw1'), isNull);
      expect(await repo.watchBetween('2026-01-01', '2026-12-31').first, isEmpty);
    });

    test('startSession(scheduled): 행·세트 목표 복사와 outbox(세션 payload에 scheduledWorkoutId)', () async {
      await repo.upsert(sample());
      env.now = t(60);
      final s = await sessions.startSession(tz: 'Asia/Seoul', scheduled: sample());
      expect(s.scheduledWorkoutId, 'sw1');
      expect(s.programInstanceId, isNull);
      expect(s.source, SessionSource.APP);
      _expectCopied(s);

      final rows = await outbox();
      final sess = rows.firstWhere((r) => r.entity == 'workout_session');
      expect(sess.payload, contains('"scheduledWorkoutId":"sw1"'));
      final sets = rows.where((r) => r.entity == 'workout_set').toList();
      expect(sets.length, 4);
      expect(sets.map((r) => r.payload).join(), allOf(contains('"targetRepsMax":15'), contains('"targetRestSec":180')));

      final links = await sessions.watchScheduledLinks().first;
      expect((links.single.scheduledWorkoutId, links.single.isActive), ('sw1', true));
      await sessions.endSession(s.id);
      expect((await sessions.watchScheduledLinks().first).single.isActive, isFalse);
      // 세션을 지우면 연결도 사라져 다시 PLANNED가 된다.
      await sessions.deleteSession(s.id);
      expect(await sessions.watchScheduledLinks().first, isEmpty);
    });

    test('진행 중 세션이 있으면 예정으로 시작해도 그 세션이 돌아온다(연결 없음)', () async {
      final free = await sessions.startSession(tz: 'Asia/Seoul');
      final s = await sessions.startSession(tz: 'Asia/Seoul', scheduled: sample());
      expect(s.id, free.id);
      expect(s.scheduledWorkoutId, isNull);
    });

    test('push 순서: scheduled_workout이 workout_session보다 먼저', () async {
      expect(SyncEngine.entityRank(SyncEntity.exercise), lessThan(SyncEngine.entityRank(SyncEntity.scheduled_workout)));
      expect(
        SyncEngine.entityRank(SyncEntity.scheduled_workout),
        lessThan(SyncEngine.entityRank(SyncEntity.workout_session)),
      );
      // 세션이 먼저 쌓였어도(outbox id가 작아도) 예정이 먼저 나간다.
      await sessions.startSession(tz: 'Asia/Seoul', scheduled: sample());
      await repo.upsert(sample());
      await env.engine.syncNow();
      final sent = env.server.pushes.first;
      expect(sent.first['entity'], 'scheduled_workout');
      expect(sent.map((c) => c['entity']).toList(), [
        'scheduled_workout',
        'workout_session',
        'session_exercise',
        'session_exercise',
        'workout_set',
        'workout_set',
        'workout_set',
        'workout_set',
      ]);
      expect(await outbox(), isEmpty);
    });

    test('왕복: 한 기기에서 올린 예정·세션을 다른 기기가 pull로 받는다', () async {
      await repo.upsert(sample());
      final s = await sessions.startSession(tz: 'Asia/Seoul', scheduled: sample());
      await env.engine.syncNow();
      expect(env.server.rows['sw1']!.payload!['items'], isA<List>());

      final other = makeEnv();
      addTearDown(other.close);
      other.server.rows.addAll(env.server.rows);
      other.server.seq = env.server.seq;
      await other.engine.syncNow();
      final w = await other.db.select(other.db.scheduledWorkouts).getSingle();
      expect(scheduledOf(w).items[0].sets[1].targetRepsMax, 15);
      expect(scheduledOf(w).title, 'B-2 하체 2');
      final srow = await (other.db.select(other.db.sessions)..where((t) => t.id.equals(s.id))).getSingle();
      expect(srow.scheduledWorkoutId, 'sw1');
      final sets = await other.db.select(other.db.workoutSets).get();
      expect(sets.map((r) => r.targetRestSec).toSet(), {180, null});
      expect(sets.where((r) => r.targetRir == 3).length, 1);

      // 서버에서 예정이 삭제되면 pull이 소프트 삭제로 반영하고, 연결된 세션은 남는다.
      env.now = t(500);
      await repo.delete('sw1');
      await env.engine.syncNow();
      other.server.rows.addAll(env.server.rows);
      other.server.seq = env.server.seq;
      await other.engine.syncNow();
      expect((await other.db.select(other.db.scheduledWorkouts).getSingle()).deletedAt, isNotNull);
      expect(await other.db.select(other.db.sessions).get(), hasLength(1));
    });

    test('서버가 중복 연결을 끊어 돌려주면(scheduledWorkoutId=null) 로컬이 덮어쓴다', () async {
      await repo.upsert(sample());
      final s = await sessions.startSession(tz: 'Asia/Seoul', scheduled: sample());
      env.server.forceReject.clear();
      await env.engine.syncNow();
      // 서버가 연결을 끊은 최신 행을 가진 것처럼.
      env.server.seed(
        'workout_session',
        s.id,
        {'id': s.id, 'startedAt': s.startedAt.toIso8601String(), 'tz': 'Asia/Seoul', 'scheduledWorkoutId': null},
        t(9999),
      );
      await env.engine.syncNow();
      final row = await (env.db.select(env.db.sessions)..where((t) => t.id.equals(s.id))).getSingle();
      expect(row.scheduledWorkoutId, isNull);
    });
  });
}

/// 예정 sample()로 시작한 세션이 §5대로 만들어졌는지.
void _expectCopied(Session s) {
  expect(s.exercises.length, 2);
  final a = s.exercises[0];
  expect((a.exerciseId, a.note, a.accessory, a.liftKey), ('ex-squat', '벨트', false, null));
  expect(a.sets.length, 3);
  final w = a.sets[0];
  expect((w.isWarmup, w.targetWeightKg, w.targetReps), (true, 40, 8));
  // 기록 값은 프로그램 시작과 같이 목표로 미리 채운다. 완료 전.
  expect((w.weightKg, w.reps), (40, 8));
  expect(w.completedAt, isNull);
  final m = a.sets[1];
  expect((m.targetWeightKg, m.targetReps, m.targetRepsMax, m.targetRir), (80, 12, 15, 3));
  expect((m.weightKg, m.reps), (80, 12));
  expect(a.sets.map((x) => x.targetRestSec), [180, 180, 180]);
  expect(a.sets[2].weightKg, isNull); // 목표 무게가 없으면 비운다
  expect(a.sets[2].reps, 10);
  final b = s.exercises[1];
  expect(b.note, isNull);
  expect(b.sets.single.targetRestSec, isNull); // item.restSec 없음 -> 기본 휴식
  expect(b.sets.single.plannedSetKey, isNull);
}
