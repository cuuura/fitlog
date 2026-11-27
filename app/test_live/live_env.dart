// 실제 서버를 상대로 앱의 진짜 API 계층(Dio 인터셉터·ApiClient·DTO·drift 저장소·동기화 엔진)을 조립한다.
// 가짜·목 없음. 서버 주소는 환경변수 FITLOG_LIVE_BASE_URL, 가입 코드는 FITLOG_LIVE_SIGNUP_CODE.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/api_providers.dart';
import 'package:fitlog/core/api/server_wake.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/auth/auth_interceptor.dart';
import 'package:fitlog/core/auth/google_id_token_source.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:fitlog/data/local/app_database.dart';
import 'package:fitlog/data/local/drift_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/data/remote/remote_repositories.dart';
import 'package:fitlog/data/sync/sync_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const liveSkipReason =
    'FITLOG_LIVE_BASE_URL(과 FITLOG_LIVE_SIGNUP_CODE)가 없어 건너뜁니다. '
    '예: FITLOG_LIVE_BASE_URL=http://localhost:8091 FITLOG_LIVE_SIGNUP_CODE=e2e-code flutter test test_live';

String? get liveBaseUrl {
  final v = Platform.environment['FITLOG_LIVE_BASE_URL']?.trim();
  return v == null || v.isEmpty ? null : v.replaceAll(RegExp(r'/+$'), '');
}

String get liveSignupCode => Platform.environment['FITLOG_LIVE_SIGNUP_CODE']?.trim() ?? '';

/// 한 기기(로컬 DB 하나)분의 앱 구성.
class LiveApp {
  LiveApp._(this.container, this.api, this.dio, this.tokens, this.db, this.engine);

  final ProviderContainer container;
  final ApiClient api;
  final Dio dio;
  final MemoryTokenStore tokens;
  final AppDatabase db;
  final SyncEngine engine;

  late final DriftSessionRepository sessions = DriftSessionRepository(db, engine);
  late final DriftBodyRepository body = DriftBodyRepository(db, engine);
  late final DriftExerciseRepository exercises = DriftExerciseRepository(db, engine, api);
  late final programs = RemoteProgramRepository(api);
  late final records = RemoteRecordsRepository(api);
  late final stats = RemoteStatsRepository(api);
  late final imports = RemoteImportRepository(api, afterChange: engine.syncNow);
  late final deletions = RemoteDeletionRequestRepository(api, afterChange: engine.syncNow);
  late final ai = RemoteAiConnectionRepository(api);
  late final export = RemoteExportRepository(api);

  AuthController get auth => container.read(authControllerProvider.notifier);
  AuthStatus get authStatus => container.read(authControllerProvider);

  /// 앱과 같은 구성: createApiDio(콜드 스타트 재시도) + AuthInterceptor(401 → refresh) + ApiClient.
  /// [tokens]를 넘기면 같은 로그인 상태를 다른 기기처럼 쓴다(다른 로컬 DB).
  factory LiveApp.create({MemoryTokenStore? tokens}) {
    final base = liveBaseUrl!;
    final store = tokens ?? MemoryTokenStore();
    final wake = ServerWake();
    final dio = createApiDio(baseUrl: base, wake: wake);
    final db = AppDatabase(NativeDatabase.memory());
    late final ProviderContainer container;
    final refreshClient = ApiClient(createApiDio(baseUrl: base, wake: wake));
    dio.interceptors.add(
      AuthInterceptor(
        dio: dio,
        store: store,
        refresh: refreshClient.authRefresh,
        onSessionExpired: () => container.read(authControllerProvider.notifier).sessionExpired(),
      ),
    );
    final api = ApiClient(dio);
    final engine = SyncEngine(db: db, api: api);
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        tokenStoreProvider.overrideWithValue(store),
        googleIdTokenSourceProvider.overrideWithValue(_NoGoogle()),
        localDataStoreProvider.overrideWithValue(DriftLocalDataStore(db, engine: engine)),
      ],
    );
    return LiveApp._(container, api, dio, store, db, engine);
  }

  Future<void> dispose() async {
    await engine.dispose();
    container.dispose();
    await db.close();
  }
}

class _NoGoogle implements GoogleIdTokenSource {
  @override
  Future<String?> fetchIdToken() async => null;
  @override
  Future<void> signOut() async {}
}
