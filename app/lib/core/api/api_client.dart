import 'package:dio/dio.dart';

import 'dto.dart';

/// 계약의 에러 형식 `{ "error": { code, message, field } }`.
class ApiException implements Exception {
  final int? statusCode;

  /// VALIDATION_FAILED, UNAUTHENTICATED, FORBIDDEN, NOT_FOUND, CONFLICT, RATE_LIMITED, PARENT_MISSING.
  /// 네트워크 오류면 `NETWORK`.
  final String code;
  final String message;
  final String? field;
  const ApiException({this.statusCode, required this.code, required this.message, this.field});

  bool get isNetwork => code == 'NETWORK';
  bool get isUnauthenticated => statusCode == 401;

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
      );
    }
    return ApiException(statusCode: res.statusCode, code: 'HTTP_${res.statusCode}', message: res.statusMessage ?? '');
  }

  @override
  String toString() => 'ApiException($statusCode $code: $message${field == null ? '' : ' @$field'})';
}

/// openapi.yaml 엔드포인트를 손으로 옮긴 클라이언트.
/// 인증 헤더와 토큰 갱신은 [Dio] 인터셉터(core/auth)가 붙인다. 이 클래스는 상태가 없다.
class ApiClient {
  final Dio dio;
  ApiClient(this.dio);

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Map<String, Object?> _map(Response r) => (r.data as Map).cast<String, Object?>();
  List<Map<String, Object?>> _list(Response r) => [for (final e in r.data as List) (e as Map).cast<String, Object?>()];

  // auth (security: [])
  Future<AuthTokens> authGoogle(String idToken) =>
      _call(() async => AuthTokens.fromJson(_map(await dio.post('/v1/auth/google', data: {'idToken': idToken}))));
  Future<AuthTokens> authRefresh(String refreshToken) =>
      _call(() async => AuthTokens.fromJson(_map(await dio.post('/v1/auth/refresh', data: {'refreshToken': refreshToken}))));
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
  Future<List<Exercise>> getExercises({String? q, Muscle? muscle, ExerciseType? type}) => _call(() async => [
        for (final j in _list(await dio.get('/v1/exercises', queryParameters: {
          'q': ?q,
          'muscle': ?muscle?.name,
          'type': ?type?.name,
        })))
          Exercise.fromJson(j)
      ]);
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
  Future<List<SessionSummary>> getSessions({DateTime? before, int limit = 20}) => _call(() async => [
        for (final j in _list(await dio.get('/v1/sessions', queryParameters: {
          'before': ?before?.toUtc().toIso8601String(),
          'limit': limit,
        })))
          SessionSummary.fromJson(j)
      ]);
  Future<Session> getSession(String id) => _call(() async => Session.fromJson(_map(await dio.get('/v1/sessions/$id'))));
  Future<Session> putSession(Session s) =>
      _call(() async => Session.fromJson(_map(await dio.put('/v1/sessions/${s.id}', data: s.toJson()))));
  Future<void> deleteSession(String id) => _call(() async => dio.delete('/v1/sessions/$id'));

  // body
  Future<List<BodyMeasurement>> getMeasurements({DateTime? from, DateTime? to}) => _call(() async => [
        for (final j in _list(await dio.get('/v1/body/measurements', queryParameters: {
          'from': ?from?.toUtc().toIso8601String(),
          'to': ?to?.toUtc().toIso8601String(),
        })))
          BodyMeasurement.fromJson(j)
      ]);
  Future<BodyMeasurement> postMeasurement(BodyMeasurement m) =>
      _call(() async => BodyMeasurement.fromJson(_map(await dio.post('/v1/body/measurements', data: m.toJson()))));
  Future<void> deleteMeasurement(String id) => _call(() async => dio.delete('/v1/body/measurements/$id'));

  // sync
  Future<List<ChangeResult>> syncPush(List<Change> changes) {
    assert(changes.length <= 200, 'push는 최대 200개');
    return _call(() async {
      final r = _map(await dio.post('/v1/sync/push', data: {'changes': [for (final c in changes) c.toJson()]}));
      return [for (final j in (r['results'] as List? ?? const [])) ChangeResult.fromJson((j as Map).cast())];
    });
  }

  Future<PullResult> syncPull(int since) =>
      _call(() async => PullResult.fromJson(_map(await dio.get('/v1/sync/pull', queryParameters: {'since': since}))));
}
