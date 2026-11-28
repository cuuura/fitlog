import 'package:dio/dio.dart';

import '../integrity/integrity.dart';
import 'ai_dto.dart';
import 'dto.dart';
import 'program_dto.dart';
import 'stats_dto.dart';

/// 계약의 에러 형식 `{ "error": { code, message, field } }`.
class ApiException implements Exception {
  final int? statusCode;

  /// VALIDATION_FAILED, UNAUTHENTICATED, FORBIDDEN, NOT_FOUND, CONFLICT, RATE_LIMITED, PARENT_MISSING.
  /// 네트워크 오류면 `NETWORK`.
  final String code;
  final String message;
  final String? field;

  /// v0.2 프로그램 검증 실패: JSON 포인터 경로별 메시지.
  final List<({String path, String message})> details;

  /// 429 RATE_LIMITED의 Retry-After(초). 없거나 다른 오류면 null.
  final Duration? retryAfter;
  const ApiException({
    this.statusCode,
    required this.code,
    required this.message,
    this.field,
    this.details = const [],
    this.retryAfter,
  });

  /// 서버가 응답했지만 앱 DTO로 읽을 수 없을 때의 [code].
  static const badResponseCode = 'BAD_RESPONSE';

  bool get isNetwork => code == 'NETWORK';
  bool get isBadResponse => code == badResponseCode;
  bool get isUnauthenticated => statusCode == 401;
  bool get isRateLimited => statusCode == 429 || code == 'RATE_LIMITED';

  static Duration? _retryAfter(Response res) {
    final v = res.headers.value('retry-after');
    final s = v == null ? null : int.tryParse(v.trim());
    return s == null ? null : Duration(seconds: s);
  }

  factory ApiException.fromDio(DioException e) {
    final res = e.response;
    if (res == null) {
      return ApiException(code: 'NETWORK', message: e.message ?? e.type.name);
    }
    final data = res.data;
    if (data is Map && data['error'] is Map) {
      final err = (data['error'] as Map).cast<String, Object?>();
      return ApiException(
        statusCode: res.statusCode,
        code: err['code'] as String? ?? 'UNKNOWN',
        message: err['message'] as String? ?? '',
        field: err['field'] as String?,
        retryAfter: _retryAfter(res),
        details: [
          for (final d in (err['details'] as List? ?? const []))
            (path: (d as Map)['path'] as String? ?? '', message: d['message'] as String? ?? ''),
        ],
      );
    }
    return ApiException(
      statusCode: res.statusCode,
      code: res.statusCode == 429 ? 'RATE_LIMITED' : 'HTTP_${res.statusCode}',
      message: res.statusMessage ?? '',
      retryAfter: _retryAfter(res),
    );
  }

  @override
  String toString() => 'ApiException($statusCode $code: $message${field == null ? '' : ' @$field'})';
}

/// openapi.yaml 엔드포인트를 손으로 옮긴 클라이언트.
/// 인증 헤더와 토큰 갱신은 [Dio] 인터셉터(core/auth)가 붙인다. 이 클래스는 상태가 없다.
class ApiClient {
  final Dio dio;

  /// v1.0: 인증 요청에 붙일 Play Integrity 토큰(contracts/v1.0/security.md).
  final IntegrityTokenSource integrity;
  ApiClient(this.dio, {this.integrity = const NoIntegrity()});

  Future<Options> _integrityOptions(String bodyToken) async {
    final t = await integrity.token(integrityRequestHash(bodyToken));
    return Options(headers: {integrityHeader: ?t});
  }

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    } on TypeError catch (e) {
      // 응답이 DTO와 안 맞을 때(필드 누락·타입 다름). 화면이 '로딩 중'에 멈추지 않게 같은 오류 형식으로 올린다.
      throw ApiException(code: ApiException.badResponseCode, message: e.toString());
    } on FormatException catch (e) {
      throw ApiException(code: ApiException.badResponseCode, message: e.message);
    }
  }

  Map<String, Object?> _map(Response r) => (r.data as Map).cast<String, Object?>();
  List<Map<String, Object?>> _list(Response r) => [for (final e in r.data as List) (e as Map).cast<String, Object?>()];

  // auth (security: [])
  Future<AuthTokens> authGoogle(String idToken) => _call(
    () async => AuthTokens.fromJson(
      _map(await dio.post('/v1/auth/google', data: {'idToken': idToken}, options: await _integrityOptions(idToken))),
    ),
  );
  /// [timeout]: 무료 서버가 잠에서 깨는 동안(최대 1분) 기다릴 수 있게 응답 대기 시간을 늘린다.
  Future<AuthMethods> authMethods({Duration? timeout}) => _call(
    () async => AuthMethods.fromJson(
      _map(await dio.get('/v1/auth/methods', options: timeout == null ? null : Options(receiveTimeout: timeout))),
    ),
  );
  Future<AuthTokens> authPasswordLogin(String username, String password) => _call(
    () async => AuthTokens.fromJson(
      _map(
        await dio.post(
          '/v1/auth/password/login',
          data: {'username': username, 'password': password},
          options: await _integrityOptions(username),
        ),
      ),
    ),
  );
  Future<AuthTokens> authPasswordRegister(String username, String password, String signupCode, {String? displayName}) =>
      _call(
        () async => AuthTokens.fromJson(
          _map(
            await dio.post(
              '/v1/auth/password/register',
              data: {
                'username': username,
                'password': password,
                'signupCode': signupCode,
                if (displayName != null && displayName.isNotEmpty) 'displayName': displayName,
              },
              options: await _integrityOptions(username),
            ),
          ),
        ),
      );
  Future<AuthTokens> authRefresh(String refreshToken) => _call(
    () async => AuthTokens.fromJson(
      _map(
        await dio.post(
          '/v1/auth/refresh',
          data: {'refreshToken': refreshToken},
          options: await _integrityOptions(refreshToken),
        ),
      ),
    ),
  );
  Future<void> authLogout(String refreshToken) =>
      _call(() async => dio.post('/v1/auth/logout', data: {'refreshToken': refreshToken}));

  // account
  Future<Me> getMe() => _call(() async => Me.fromJson(_map(await dio.get('/v1/me'))));
  Future<void> deleteMe() => _call(() async => dio.delete('/v1/me'));
  Future<Settings> getSettings() => _call(() async => Settings.fromJson(_map(await dio.get('/v1/me/settings'))));
  Future<Settings> putSettings(Settings s) =>
      _call(() async => Settings.fromJson(_map(await dio.put('/v1/me/settings', data: s.toJson()))));
  Future<List<Consent>> getConsents() =>
      _call(() async => [for (final j in _list(await dio.get('/v1/me/consents'))) Consent.fromJson(j)]);
  Future<Consent> postConsent(ConsentInput c) =>
      _call(() async => Consent.fromJson(_map(await dio.post('/v1/me/consents', data: c.toJson()))));

  // exercise
  Future<List<Exercise>> getExercises({String? q, Muscle? muscle, ExerciseType? type}) => _call(
    () async => [
      for (final j in _list(
        await dio.get('/v1/exercises', queryParameters: {'q': ?q, 'muscle': ?muscle?.name, 'type': ?type?.name}),
      ))
        Exercise.fromJson(j),
    ],
  );
  Future<Exercise> postExercise(ExerciseInput e) =>
      _call(() async => Exercise.fromJson(_map(await dio.post('/v1/exercises', data: e.toJson()))));
  Future<Exercise> putExercise(ExerciseInput e) =>
      _call(() async => Exercise.fromJson(_map(await dio.put('/v1/exercises/${e.id}', data: e.toJson()))));
  Future<void> deleteExercise(String id) => _call(() async => dio.delete('/v1/exercises/$id'));
  Future<LastSets?> getLastSets(String exerciseId) => _call(() async {
    try {
      return LastSets.fromJson(_map(await dio.get('/v1/exercises/$exerciseId/last')));
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  });

  // session
  Future<List<SessionSummary>> getSessions({DateTime? before, int limit = 20}) => _call(
    () async => [
      for (final j in _list(
        await dio.get('/v1/sessions', queryParameters: {'before': ?before?.toUtc().toIso8601String(), 'limit': limit}),
      ))
        SessionSummary.fromJson(j),
    ],
  );
  Future<Session> getSession(String id) => _call(() async => Session.fromJson(_map(await dio.get('/v1/sessions/$id'))));
  Future<Session> putSession(Session s) =>
      _call(() async => Session.fromJson(_map(await dio.put('/v1/sessions/${s.id}', data: s.toJson()))));
  Future<void> deleteSession(String id) => _call(() async => dio.delete('/v1/sessions/$id'));

  // body
  Future<List<BodyMeasurement>> getMeasurements({DateTime? from, DateTime? to}) => _call(
    () async => [
      for (final j in _list(
        await dio.get(
          '/v1/body/measurements',
          queryParameters: {'from': ?from?.toUtc().toIso8601String(), 'to': ?to?.toUtc().toIso8601String()},
        ),
      ))
        BodyMeasurement.fromJson(j),
    ],
  );
  Future<BodyMeasurement> postMeasurement(BodyMeasurement m) =>
      _call(() async => BodyMeasurement.fromJson(_map(await dio.post('/v1/body/measurements', data: m.toJson()))));
  Future<void> deleteMeasurement(String id) => _call(() async => dio.delete('/v1/body/measurements/$id'));

  // sync
  Future<List<ChangeResult>> syncPush(List<Change> changes) {
    assert(changes.length <= 200, 'push는 최대 200개');
    return _call(() async {
      final r = _map(
        await dio.post(
          '/v1/sync/push',
          data: {
            'changes': [for (final c in changes) c.toJson()],
          },
        ),
      );
      return [for (final j in (r['results'] as List? ?? const [])) ChangeResult.fromJson((j as Map).cast())];
    });
  }

  Future<PullResult> syncPull(int since) =>
      _call(() async => PullResult.fromJson(_map(await dio.get('/v1/sync/pull', queryParameters: {'since': since}))));

  // ---------- v0.2: 프로그램 ----------

  Future<List<ProgramSummary>> getPrograms({ProgramListSource? source}) => _call(
    () async => [
      for (final j in _list(await dio.get('/v1/programs', queryParameters: {'source': ?source?.name})))
        ProgramSummary.fromJson(j),
    ],
  );
  Future<Program> getProgram(String id) => _call(() async => Program.fromJson(_map(await dio.get('/v1/programs/$id'))));
  Future<Program> postProgram(String id, Map<String, Object?> definition) => _call(
    () async => Program.fromJson(_map(await dio.post('/v1/programs', data: {'id': id, 'definition': definition}))),
  );

  /// 저장 없이 검증. 실패면 ApiException(VALIDATION_FAILED, details).
  Future<Program> validateProgram(Map<String, Object?> definition) =>
      _call(() async => Program.fromJson(_map(await dio.post('/v1/programs/validate', data: definition))));
  Future<void> deleteProgram(String id) => _call(() async => dio.delete('/v1/programs/$id'));
  Future<List<SuggestItem>> suggest(String programId) => _call(
    () async => [for (final j in _list(await dio.get('/v1/programs/$programId/suggest'))) SuggestItem.fromJson(j)],
  );

  /// v1.1: 시작 전 미리 계산(저장 안 함).
  Future<StartPreview> previewStart(String programId, StartPreviewRequest r) => _call(
    () async => StartPreview.fromJson(_map(await dio.post('/v1/programs/$programId/preview', data: r.toJson()))),
  );

  // ---------- v0.2: 인스턴스 ----------

  Future<List<Instance>> getInstances({InstanceStatus? status}) => _call(
    () async => [
      for (final j in _list(await dio.get('/v1/program-instances', queryParameters: {'status': ?status?.name})))
        Instance.fromJson(j),
    ],
  );
  Future<Instance> getInstance(String id) =>
      _call(() async => Instance.fromJson(_map(await dio.get('/v1/program-instances/$id'))));
  Future<Instance> startInstance(StartInstance s) =>
      _call(() async => Instance.fromJson(_map(await dio.post('/v1/program-instances', data: s.toJson()))));
  Future<Instance> patchInstance(String id, InstancePatch p) =>
      _call(() async => Instance.fromJson(_map(await dio.patch('/v1/program-instances/$id', data: p.toJson()))));
  Future<void> deleteInstance(String id) => _call(() async => dio.delete('/v1/program-instances/$id'));
  Future<List<PlannedWorkout>> getPlan(String instanceId, {int count = 3}) => _call(
    () async => [
      for (final j in _list(await dio.get('/v1/program-instances/$instanceId/plan', queryParameters: {'count': count})))
        PlannedWorkout.fromJson(j),
    ],
  );
  Future<Instance> skip(String instanceId, int planSeq) => _call(
    () async =>
        Instance.fromJson(_map(await dio.post('/v1/program-instances/$instanceId/skip', data: {'planSeq': planSeq}))),
  );
  Future<List<Accessory>> getAccessories(String instanceId) => _call(
    () async => [
      for (final j in _list(await dio.get('/v1/program-instances/$instanceId/accessories'))) Accessory.fromJson(j),
    ],
  );
  Future<List<Accessory>> putAccessories(String instanceId, List<Accessory> list) => _call(
    () async => [
      for (final j in _list(
        await dio.put('/v1/program-instances/$instanceId/accessories', data: [for (final a in list) a.toJson()]),
      ))
        Accessory.fromJson(j),
    ],
  );

  // ---------- v0.2: 기록 ----------

  Future<ExerciseRecords> getRecords(String exerciseId) =>
      _call(() async => ExerciseRecords.fromJson(_map(await dio.get('/v1/exercises/$exerciseId/records'))));
  Future<List<OneRmMeasurement>> getOneRms(String exerciseId) => _call(
    () async => [
      for (final j in _list(await dio.get('/v1/exercises/$exerciseId/one-rm'))) OneRmMeasurement.fromJson(j),
    ],
  );
  Future<OneRmMeasurement> postOneRm(String exerciseId, OneRmMeasurement m) => _call(
    () async => OneRmMeasurement.fromJson(_map(await dio.post('/v1/exercises/$exerciseId/one-rm', data: m.toJson()))),
  );
  Future<void> deleteOneRm(String id) => _call(() async => dio.delete('/v1/one-rm/$id'));

  // ---------- v0.3: 가져오기 ----------

  /// 공개 스키마 주소(프롬프트 복사용, 인증 없음).
  String get importSchemaUrl => '${dio.options.baseUrl}/v1/public/schema/import.json';
  String get programSchemaUrl => '${dio.options.baseUrl}/v1/public/schema/program.json';

  /// 저장 없이 검증·충돌 탐지. 스키마 위반이면 ApiException(VALIDATION_FAILED, details).
  Future<ImportPreview> previewImport(ImportRequest r) =>
      _call(() async => ImportPreview.fromJson(_map(await dio.post('/v1/imports/preview', data: r.toJson()))));

  /// 저장 시도. 201/200이면 saved, 409(CONFLICT_UNRESOLVED)면 needsResolution.
  Future<ImportOutcome> submitImport(ImportRequest r) => _call(() async {
    try {
      return ImportOutcome.saved(ImportBatch.fromJson(_map(await dio.post('/v1/imports', data: r.toJson()))));
    } on DioException catch (e) {
      final res = e.response;
      if (res?.statusCode == 409 && res!.data is Map && (res.data as Map).containsKey('conflicts')) {
        return ImportOutcome.needsResolution(ImportPreview.fromJson((res.data as Map).cast()));
      }
      rethrow;
    }
  });
  Future<List<ImportBatch>> getImports({DateTime? before, int limit = 20}) => _call(
    () async => [
      for (final j in _list(
        await dio.get('/v1/imports', queryParameters: {'before': ?before?.toUtc().toIso8601String(), 'limit': limit}),
      ))
        ImportBatch.fromJson(j),
    ],
  );
  Future<ImportBatchDetail> getImport(String id) =>
      _call(() async => ImportBatchDetail.fromJson(_map(await dio.get('/v1/imports/$id'))));
  Future<ImportBatch> revertImport(String id) =>
      _call(() async => ImportBatch.fromJson(_map(await dio.post('/v1/imports/$id/revert'))));

  // ---------- v0.3: 삭제 요청 ----------

  Future<List<DeletionRequest>> getDeletionRequests({DeletionStatus? status}) => _call(
    () async => [
      for (final j in _list(await dio.get('/v1/deletion-requests', queryParameters: {'status': ?status?.name})))
        DeletionRequest.fromJson(j),
    ],
  );
  Future<int> getPendingDeletionCount() =>
      _call(() async => (_map(await dio.get('/v1/deletion-requests/count'))['pending'] as num).toInt());

  /// 409 이미 결정됨, 410 GONE(만료)은 ApiException.
  Future<DeletionRequest> approveDeletion(String id) =>
      _call(() async => DeletionRequest.fromJson(_map(await dio.post('/v1/deletion-requests/$id/approve'))));
  Future<DeletionRequest> rejectDeletion(String id) =>
      _call(() async => DeletionRequest.fromJson(_map(await dio.post('/v1/deletion-requests/$id/reject'))));

  // ---------- v0.3: AI 연결 ----------

  Future<List<AiConnection>> getAiConnections() =>
      _call(() async => [for (final j in _list(await dio.get('/v1/me/ai-connections'))) AiConnection.fromJson(j)]);
  Future<void> deleteAiConnection(String id) => _call(() async => dio.delete('/v1/me/ai-connections/$id'));
  Future<McpInfo> getMcpInfo() => _call(() async => McpInfo.fromJson(_map(await dio.get('/v1/mcp-info'))));

  // ---------- v0.3: 내보내기 ----------

  /// 가져오기 묶음 형식 JSON 원문.
  Future<String> exportJson() => _call(() async {
    final r = await dio.get<String>('/v1/export.json', options: Options(responseType: ResponseType.plain));
    return r.data ?? '';
  });

  /// CSV 원문. 디코딩 과정에서 BOM이 빠지므로 다시 붙인다(엑셀 한글 깨짐 방지).
  Future<String> exportCsv(CsvKind kind) => _call(() async {
    final r = await dio.get<String>(
      '/v1/export.csv',
      queryParameters: {'kind': kind.name},
      options: Options(responseType: ResponseType.plain),
    );
    final text = r.data ?? '';
    return text.startsWith('\uFEFF') ? text : '\uFEFF$text';
  });

  // ---------- v1.0: 그래프(STA-4) ----------

  Future<ExerciseProgress> getProgress(String exerciseId, {DateTime? from, DateTime? to, int? limit}) => _call(
    () async => ExerciseProgress.fromJson(
      _map(
        await dio.get(
          '/v1/exercises/$exerciseId/progress',
          queryParameters: {
            'from': ?from?.toUtc().toIso8601String(),
            'to': ?to?.toUtc().toIso8601String(),
            'limit': ?limit,
          },
        ),
      ),
    ),
  );
  Future<SessionComparison> getComparison(String sessionId) =>
      _call(() async => SessionComparison.fromJson(_map(await dio.get('/v1/sessions/$sessionId/comparison'))));
}
