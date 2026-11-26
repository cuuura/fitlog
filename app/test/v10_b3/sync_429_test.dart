import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:fitlog/data/local/drift_repositories.dart';
import 'package:fitlog/data/sync/sync_engine.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../b3/fake_server.dart';

/// 처음 [limited]번의 요청을 429(+Retry-After)로 거절하는 서버.
class _RateLimitedServer extends FakeServer {
  int limited;
  String? retryAfter;
  int requests = 0;
  _RateLimitedServer({this.limited = 1, this.retryAfter});

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests++;
    if (limited > 0) {
      limited--;
      return Future.value(
        ResponseBody.fromString(
          jsonEncode({
            'error': {'code': 'RATE_LIMITED', 'message': 'slow down'},
          }),
          429,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
            if (retryAfter != null) 'retry-after': [retryAfter!],
          },
        ),
      );
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}

void main() {
  late _RateLimitedServer server;
  late AppDatabase db;
  late SyncEngine engine;
  late DriftSessionRepository sessions;
  var now = t(0);

  void build({int limited = 1, String? retryAfter}) {
    now = t(0);
    server = _RateLimitedServer(limited: limited, retryAfter: retryAfter);
    final dio = Dio(BaseOptions(baseUrl: 'http://test', contentType: 'application/json'))..httpClientAdapter = server;
    db = AppDatabase(NativeDatabase.memory());
    engine = SyncEngine(db: db, api: ApiClient(dio), clock: () => now);
    sessions = DriftSessionRepository(db, engine, clock: () => now);
  }

  tearDown(() async {
    await engine.dispose();
    await db.close();
  });

  Future<void> seed() async {
    final s = await sessions.startSession(tz: 'Asia/Seoul');
    final se = await sessions.addExercise(s.id, 'ex1');
    await sessions.addSet(se.id, WorkoutSet(id: newId(), position: 0, weightKg: 100, reps: 5));
  }

  test('429: 실패 카운터는 그대로, 30초(Retry-After 없음) 동안 서버를 다시 부르지 않는다', () async {
    build();
    await seed();
    await engine.syncNow();
    expect(server.requests, 1);
    expect(engine.failures, 0);
    expect(engine.rateLimitedUntil, now.add(const Duration(seconds: 30)));

    // 미루는 동안 기록이 더 생겨 syncNow가 여러 번 불려도 요청은 늘지 않는다
    await engine.syncNow();
    await engine.syncNow();
    expect(server.requests, 1);
    expect((await db.select(db.outbox).get()), isNotEmpty);

    // 시간이 지나면 다시 시도하고, 성공하면 outbox가 비고 지연 해제
    now = now.add(const Duration(seconds: 31));
    await engine.syncNow();
    expect(server.pushes.length, 1);
    expect(await db.select(db.outbox).get(), isEmpty);
    expect(engine.rateLimitedUntil, isNull);
    expect(engine.failures, 0);
  });

  test('429 Retry-After 헤더 값을 쓴다', () async {
    build(retryAfter: '90');
    await seed();
    await engine.syncNow();
    expect(engine.rateLimitedUntil, now.add(const Duration(seconds: 90)));
    expect(engine.failures, 0);
  });

  test('도는 중에 쓰기가 생겨도(_rerun) 429면 무한 반복하지 않는다', () async {
    build(limited: 100);
    await seed();
    server.beforeRespond = null;
    final first = engine.syncNow();
    final second = engine.syncNow(); // 실행 중 재호출 -> rerun 표시
    await Future.wait([first, second]);
    expect(server.requests, 1);
    expect(engine.failures, 0);
  });

  test('429는 다른 오류의 백오프 카운터를 건드리지 않는다', () async {
    build(limited: 0);
    await seed();
    server.failStatus = 1;
    server.statusToFail = 500;
    await engine.syncNow();
    expect(engine.failures, 1);
    server.limited = 1;
    await engine.syncNow();
    expect(engine.failures, 1);
    expect(engine.rateLimitedUntil, isNotNull);
  });
}
