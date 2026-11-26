import 'package:drift/drift.dart' show OrderingTerm;
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:fitlog/data/local/drift_repositories.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

import '../b3/fake_server.dart';

void main() {
  late Env env;
  late DriftSessionRepository sessions;

  setUp(() {
    env = makeEnv();
    sessions = DriftSessionRepository(env.db, env.engine, clock: () => env.now);
  });
  tearDown(() => env.close());

  Future<List<OutboxRow>> outbox() =>
      (env.db.select(env.db.outbox)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();

  Future<({String s, String se, String set})> seed() async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, 'ex1');
    final w = await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 100, reps: 5));
    return (s: s.id, se: se.id, set: w.id);
  }

  test('SERVER_ERROR(변경별 거절)도 attempts를 늘리고 상한에서 멈춘다', () async {
    final ids = await seed();
    env.server.forceReject[ids.set] = 'SERVER_ERROR';
    for (var i = 0; i < 8; i++) {
      await env.engine.syncNow();
    }
    final row = (await outbox()).single;
    expect(row.entityId, ids.set);
    expect(row.attempts, env.engine.maxAttempts);
    expect(row.lastError, 'SERVER_ERROR');
    final sends = env.server.pushes.where((p) => p.any((c) => c['id'] == ids.set)).length;
    expect(sends, env.engine.maxAttempts);
    final st = await env.engine.watchStatus().firstWhere((s) => s.pending == 1);
    expect(st.phase, SyncPhase.error);
    expect(st.lastError, contains('SERVER_ERROR'));
  });

  test('UPSERT의 PARENT_MISSING이 계속되면(부모가 서버에서 삭제됨) 상한에서 멈추고 dead letter로 남는다', () async {
    final ids = await seed();
    await env.engine.syncNow();
    expect(await outbox(), isEmpty);
    // 다른 기기가 종목을 지웠다 -> 서버에 부모가 없다
    env.server.rows.remove(ids.se);
    env.now = t(30);
    final extra = await sessions.addSet(ids.se, WorkoutSet(id: newId(), position: 1, weightKg: 90, reps: 5));
    for (var i = 0; i < 10; i++) {
      await env.engine.syncNow();
    }
    final row = (await outbox()).single;
    expect(row.entityId, extra.id);
    expect(row.attempts, env.engine.maxAttempts);
    expect(row.lastError, 'PARENT_MISSING');
    final sends = env.server.pushes.where((p) => p.any((c) => c['id'] == extra.id)).length;
    expect(sends, env.engine.maxAttempts, reason: '상한 이후에는 더 보내지 않는다');
    final st = await env.engine.watchStatus().firstWhere((s) => s.pending == 1);
    expect(st.phase, SyncPhase.error);
    expect(st.lastError, contains('PARENT_MISSING'));
  });

  test('UPSERT PARENT_MISSING은 부모가 곧 오면 상한 전에 해결된다', () async {
    final ids = await seed();
    env.server.forceReject[ids.s] = 'VALIDATION_FAILED';
    await env.engine.syncNow();
    await env.engine.syncNow();
    env.server.forceReject.clear();
    await env.engine.syncNow();
    expect(await outbox(), isEmpty);
  });
}
