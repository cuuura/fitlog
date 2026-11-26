import 'package:dio/dio.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/auth/auth_interceptor.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late MemoryTokenStore store;
  late FakeAdapter api;
  late FakeAdapter authApi;
  late Dio dio;
  late int expired;

  setUp(() {
    expired = 0;
    store = MemoryTokenStore(
      tokens: StoredTokens(accessToken: 'old', refreshToken: 'r0', expiresAt: DateTime.utc(2030)),
    );
    // 서버: 'new' 토큰만 통과.
    api = FakeAdapter((o) => o.headers['Authorization'] == 'Bearer new' ? json({'ok': true}) : errorBody(401, 'UNAUTHENTICATED'));
    authApi = FakeAdapter((o) async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return json(tokensJson(access: 'new', refresh: 'r1'));
    });
    dio = fakeDio(api);
    final refreshClient = ApiClient(fakeDio(authApi));
    dio.interceptors.add(AuthInterceptor(
      dio: dio,
      store: store,
      refresh: refreshClient.authRefresh,
      onSessionExpired: () => expired++,
      now: () => DateTime.utc(2026, 1, 1),
    ));
  });

  test('Bearer 헤더를 붙이고, /v1/auth/* 에는 붙이지 않는다', () async {
    store.tokens = StoredTokens(accessToken: 'new', refreshToken: 'r0', expiresAt: DateTime.utc(2030));
    api.handler = (o) => json({'ok': true});
    await dio.get('/v1/me');
    await dio.post('/v1/auth/google', data: {'idToken': 'x'});
    expect(api.log[0].headers['Authorization'], 'Bearer new');
    expect(api.log[1].headers.containsKey('Authorization'), isFalse);
  });

  test('401 -> refresh -> 재시도, 새 토큰(회전된 refresh 포함) 저장', () async {
    final r = await dio.get('/v1/me');
    expect(r.statusCode, 200);
    expect(authApi.count('POST', '/v1/auth/refresh'), 1);
    expect(authApi.log.single.data, {'refreshToken': 'r0'});
    expect(store.tokens?.accessToken, 'new');
    expect(store.tokens?.refreshToken, 'r1');
    expect(store.tokens?.expiresAt, DateTime.utc(2026, 1, 1, 0, 15));
    expect(api.count('GET', '/v1/me'), 2);
  });

  test('동시에 401이 나도 refresh는 한 번', () async {
    final rs = await Future.wait([dio.get('/v1/me'), dio.get('/v1/exercises'), dio.get('/v1/sessions')]);
    expect(rs.map((r) => r.statusCode), [200, 200, 200]);
    expect(authApi.count('POST', '/v1/auth/refresh'), 1);
  });

  test('refresh가 거부되면 토큰 삭제 + 세션 만료 알림 + 원래 401', () async {
    authApi.handler = (o) => errorBody(401, 'UNAUTHENTICATED');
    await expectLater(
      dio.get('/v1/me'),
      throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', 401)),
    );
    expect(store.tokens, isNull);
    expect(expired, 1);
  });

  test('refresh 중 네트워크 오류면 세션 유지', () async {
    authApi.handler = (o) => throw DioException(requestOptions: o, type: DioExceptionType.connectionError);
    await expectLater(dio.get('/v1/me'), throwsA(isA<DioException>()));
    expect(store.tokens?.refreshToken, 'r0');
    expect(expired, 0);
  });

  test('재시도도 401이면 무한 루프 없이 실패', () async {
    api.handler = (o) => errorBody(401, 'UNAUTHENTICATED');
    await expectLater(dio.get('/v1/me'), throwsA(isA<DioException>()));
    expect(authApi.count('POST', '/v1/auth/refresh'), 1);
    expect(api.count('GET', '/v1/me'), 2);
  });

  test('토큰이 없으면 세션 만료 알림', () async {
    store.tokens = null;
    await expectLater(dio.get('/v1/me'), throwsA(isA<DioException>()));
    expect(expired, 1);
    expect(authApi.log, isEmpty);
  });
}
