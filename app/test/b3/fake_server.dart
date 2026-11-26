// 테스트용 가짜 서버: Dio HttpClientAdapter로 sync push/pull과 GET /v1/exercises를 흉내 낸다.
// 서버 트랙 해석: 적용된 행의 updatedAt = clientUpdatedAt, 충돌은 서버 updatedAt > clientUpdatedAt일 때만.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:fitlog/data/sync/sync_engine.dart';
import 'package:fitlog/domain/repositories.dart';

class ServerRow {
  String entity;
  String id;
  String op;
  String? parentId;
  Map<String, Object?>? payload;
  DateTime updatedAt;
  int seq;
  ServerRow(this.entity, this.id, this.op, this.parentId, this.payload, this.updatedAt, this.seq);

  Map<String, Object?> toChange() => {
        'entity': entity,
        'id': id,
        'op': op,
        if (parentId != null) 'parentId': parentId,
        if (payload != null && op != 'DELETE') 'payload': payload,
        'clientUpdatedAt': updatedAt.toUtc().toIso8601String(),
        'serverSeq': seq,
      };
}

class FakeServer implements HttpClientAdapter {
  final Map<String, ServerRow> rows = {};
  int seq = 0;
  int pageSize = 500;
  final List<List<Map<String, Object?>>> pushes = [];
  final List<int> pullSinces = [];
  List<Map<String, Object?>> exercises = [];

  /// 다음 요청들을 이 예외로 실패시킨다(횟수만큼).
  int failNetwork = 0;
  int failStatus = 0;
  int statusToFail = 500;

  /// push를 받은 뒤 응답하기 전에 부르는 훅(그 사이 로컬 쓰기를 흉내).
  Future<void> Function()? beforeRespond;

  /// id별로 강제 거절 코드(예: VALIDATION_FAILED).
  final Map<String, String> forceReject = {};

  /// 서버 쪽 변경을 직접 심는다(다른 기기가 올린 것처럼).
  ServerRow seed(String entity, String id, Map<String, Object?>? payload, DateTime at,
      {String? parentId, String op = 'UPSERT'}) {
    final r = ServerRow(entity, id, op, parentId, payload, at, ++seq);
    rows[id] = r;
    return r;
  }

  @override
  void close({bool force = false}) {}

  ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(jsonEncode(body), status,
      headers: {
        Headers.contentTypeHeader: ['application/json']
      });

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (failNetwork > 0) {
      failNetwork--;
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    if (failStatus > 0) {
      failStatus--;
      return _json({
        'error': {'code': statusToFail == 401 ? 'UNAUTHENTICATED' : 'INTERNAL', 'message': 'x'}
      }, statusToFail);
    }
    if (options.path == '/v1/sync/push') {
      final changes = ((options.data as Map)['changes'] as List).cast<Map>().map((m) => m.cast<String, Object?>()).toList();
      pushes.add(changes);
      final results = [for (final c in changes) _push(c)];
      await beforeRespond?.call();
      return _json({'results': results});
    }
    if (options.path == '/v1/sync/pull') {
      final since = options.queryParameters['since'] as int;
      pullSinces.add(since);
      final list = rows.values.where((r) => r.seq > since).toList()..sort((a, b) => a.seq.compareTo(b.seq));
      final page = list.take(pageSize).toList();
      return _json({
        'changes': [for (final r in page) r.toChange()],
        'nextSince': page.isEmpty ? since : page.last.seq,
        'hasMore': list.length > page.length,
      });
    }
    if (options.path == '/v1/exercises') return _json(exercises);
    return _json({
      'error': {'code': 'NOT_FOUND', 'message': options.path}
    }, 404);
  }

  Map<String, Object?> _push(Map<String, Object?> c) {
    final id = c['id'] as String;
    final entity = c['entity'] as String;
    final at = DateTime.parse(c['clientUpdatedAt'] as String).toUtc();
    if (forceReject.containsKey(id)) return {'id': id, 'status': 'rejected', 'code': forceReject[id]};
    final parentId = c['parentId'] as String?;
    if ((entity == 'session_exercise' || entity == 'workout_set') && (parentId == null || !rows.containsKey(parentId))) {
      return {'id': id, 'status': 'rejected', 'code': 'PARENT_MISSING'};
    }
    final cur = rows[id];
    if (cur != null && cur.updatedAt.isAfter(at)) {
      return {'id': id, 'status': 'conflict', 'server': cur.toChange()};
    }
    rows[id] = ServerRow(entity, id, c['op'] as String, parentId, (c['payload'] as Map?)?.cast<String, Object?>(), at, ++seq);
    return {'id': id, 'status': 'applied'};
  }
}

class Env {
  final AppDatabase db;
  final FakeServer server;
  final SyncEngine engine;
  DateTime now;
  Env(this.db, this.server, this.engine, this.now);

  Future<void> close() async {
    await engine.dispose();
    await db.close();
  }
}

DateTime t(int sec) => DateTime.utc(2026, 11, 26, 10, 0, 0).add(Duration(seconds: sec));

/// [env.now]를 바꿔 시간을 흘린다.
Env makeEnv({int batchSize = 200}) {
  final server = FakeServer();
  final dio = Dio(BaseOptions(baseUrl: 'http://test', contentType: 'application/json'))..httpClientAdapter = server;
  final db = AppDatabase(NativeDatabase.memory());
  late Env env;
  final engine = SyncEngine(db: db, api: ApiClient(dio), clock: () => env.now, batchSize: batchSize);
  env = Env(db, server, engine, t(0));
  return env;
}

/// 동기화 호출만 세는 가짜.
class SpySync implements SyncService {
  int scheduled = 0;
  int syncNows = 0;
  @override
  void schedule({Duration delay = const Duration(seconds: 5)}) => scheduled++;
  @override
  Future<void> syncNow() async => syncNows++;
  @override
  Stream<SyncStatus> watchStatus() => Stream.value(const SyncStatus());
}
