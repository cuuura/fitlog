// 전송 계층 회귀 테스트: 잠든 서버(콜드 스타트) 대응, 응답 형식 불일치, 로그아웃 Bearer, 가져오기 무한 로딩.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/server_wake.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/auth/auth_interceptor.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/importing/import_controller.dart';
import 'package:fitlog/features/session/session_controller.dart' show deviceTimezoneProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../b1/helpers.dart';

Dio _wakeDio(FakeAdapter a, ServerWake wake) {
  final dio = Dio(BaseOptions(
    baseUrl: 'http://test',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (s) => s != null && s < 400,
  ))..httpClientAdapter = a;
  dio.interceptors.add(WakeRetryInterceptor(
    dio: dio,
    wake: wake,
    coldDelays: List.filled(4, Duration.zero),
    warmDelays: List.filled(2, Duration.zero),
    connectionErrorDelays: const [Duration.zero],
  ));
  return dio;
}

ResponseBody _html(int status) => ResponseBody.fromString('<html>waking</html>', status, headers: {
      Headers.contentTypeHeader: ['text/html'],
    });

void main() {
  group('콜드 스타트: WakeRetryInterceptor', () {
    test('깨는 동안 502/503을 몇 번 받아도 GET은 결국 성공한다', () async {
      var n = 0;
      final a = FakeAdapter((o) => ++n <= 3 ? _html(n == 1 ? 502 : 503) : json({'ok': true}));
      final dio = _wakeDio(a, ServerWake());
      final r = await dio.get('/v1/auth/methods');
      expect(r.statusCode, 200);
      expect(a.log.length, 4);
    });

    test('끝까지 안 깨면 마지막 오류를 돌려준다(시도 횟수 상한)', () async {
      final a = FakeAdapter((o) => _html(503));
      final dio = _wakeDio(a, ServerWake());
      await expectLater(dio.get('/v1/me'), throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', 503)));
      expect(a.log.length, 1 + 4); // 첫 시도 + 콜드 재시도 4번
    });

    test('첫 요청(콜드)은 타임아웃이 길고, 응답을 받은 뒤에는 평소 값이다', () async {
      final a = FakeAdapter((o) => json({'ok': true}));
      final dio = _wakeDio(a, ServerWake());
      await dio.get('/v1/a');
      await dio.get('/v1/b');
      expect(a.log[0].receiveTimeout, const Duration(seconds: 75));
      expect(a.log[0].connectTimeout, const Duration(seconds: 75));
      expect(a.log[1].receiveTimeout, const Duration(seconds: 20));
      expect(a.log[1].connectTimeout, const Duration(seconds: 10));
    });

    test('서버가 10분 넘게 조용하면 다시 콜드로 본다', () async {
      var now = DateTime(2026, 1, 1, 12);
      final a = FakeAdapter((o) => json({'ok': true}));
      final dio = _wakeDio(a, ServerWake(now: () => now));
      await dio.get('/v1/a');
      now = now.add(const Duration(minutes: 11));
      await dio.get('/v1/b');
      expect(a.log[1].receiveTimeout, const Duration(seconds: 75));
    });

    test('앱이 4xx로 응답하면 깨어 있는 것이고 재시도하지 않는다', () async {
      final a = FakeAdapter((o) => errorBody(409, 'CONFLICT'));
      final wake = ServerWake();
      final dio = _wakeDio(a, wake);
      await expectLater(dio.post('/v1/x'), throwsA(isA<DioException>()));
      expect(a.log.length, 1);
      expect(wake.isCold, isFalse);
    });

    test('POST는 서버에 닿지 않은 게 확실한 경우(연결 오류·502/503)만 다시 보낸다', () async {
      final a = FakeAdapter((o) => throw DioException.receiveTimeout(timeout: const Duration(seconds: 20), requestOptions: o));
      final dio = _wakeDio(a, ServerWake());
      await expectLater(dio.post('/v1/me/consents', data: {}), throwsA(isA<DioException>()));
      expect(a.log.length, 1, reason: '수신 타임아웃은 서버가 처리했을 수 있어 POST는 재시도 금지');

      var n = 0;
      final b = FakeAdapter((o) => ++n == 1 ? _html(503) : json({'ok': true}));
      final dio2 = _wakeDio(b, ServerWake());
      expect((await dio2.post('/v1/me/consents', data: {})).statusCode, 200);
      expect(b.log.length, 2);
    });

    test('수신 타임아웃은 GET이면 다시 시도한다', () async {
      var n = 0;
      final a = FakeAdapter((o) {
        if (++n == 1) throw DioException.receiveTimeout(timeout: const Duration(seconds: 20), requestOptions: o);
        return json({'ok': true});
      });
      final dio = _wakeDio(a, ServerWake());
      expect((await dio.get('/v1/me')).statusCode, 200);
    });

    test('기기가 오프라인(연결 오류)이면 오래 붙잡지 않고 한 번만 다시 해 본다', () async {
      final a = FakeAdapter((o) => throw DioException.connectionError(requestOptions: o, reason: 'offline'));
      final dio = _wakeDio(a, ServerWake());
      await expectLater(dio.get('/v1/me'), throwsA(isA<DioException>()));
      expect(a.log.length, 2);
    });

    test('첫 요청이 길어지면 waking 이 켜지고, 응답이 오면 꺼진다', () async {
      final gate = Completer<void>();
      final a = FakeAdapter((o) async {
        await gate.future;
        return json({'ok': true});
      });
      final wake = ServerWake(showAfter: const Duration(milliseconds: 20));
      final dio = _wakeDio(a, wake);
      final seen = <bool>[];
      wake.waking.addListener(() => seen.add(wake.waking.value));
      final f = dio.get('/v1/me');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(wake.waking.value, isTrue);
      gate.complete();
      await f;
      expect(wake.waking.value, isFalse);
      expect(seen, [true, false]);
    });

    test('빠른 응답이면 waking 은 켜지지 않는다', () async {
      final a = FakeAdapter((o) => json({'ok': true}));
      final wake = ServerWake(showAfter: const Duration(milliseconds: 20));
      final dio = _wakeDio(a, wake);
      await dio.get('/v1/me');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(wake.waking.value, isFalse);
    });
  });

  group('ApiClient', () {
    test('응답이 DTO와 안 맞으면 TypeError 대신 ApiException(BAD_RESPONSE)', () async {
      final a = FakeAdapter((o) => json({'id': 5, 'email': 'x'})); // id가 문자열이 아님
      final api = ApiClient(fakeDio(a));
      await expectLater(
        api.getMe(),
        throwsA(isA<ApiException>().having((e) => e.isBadResponse, 'isBadResponse', true).having((e) => e.isNetwork, 'isNetwork', false)),
      );
    });

    test('모르는 enum 값도 ApiException(BAD_RESPONSE)', () async {
      final a = FakeAdapter((o) => json([
            {'kind': 'NEW_KIND', 'version': 'v', 'granted': true}
          ]));
      await expectLater(ApiClient(fakeDio(a)).getConsents(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BAD_RESPONSE')));
    });

    test('서버 오류 JSON의 code·message·field·details 가 그대로 올라온다', () async {
      final a = FakeAdapter((o) => json({
            'error': {
              'code': 'VALIDATION_FAILED',
              'message': 'bad',
              'field': 'version',
              'details': [
                {'path': '/a', 'message': 'm'}
              ],
            }
          }, 400));
      try {
        await ApiClient(fakeDio(a)).postConsent(const ConsentInput(kind: ConsentKind.TERMS, version: '', granted: true));
        fail('throw');
      } on ApiException catch (e) {
        expect([e.statusCode, e.code, e.message, e.field, e.details.single.path], [400, 'VALIDATION_FAILED', 'bad', 'version', '/a']);
      }
    });
  });

  group('로그아웃', () {
    test('/v1/auth/logout 에는 Bearer 가 붙고(서버가 요구), 다른 /v1/auth/* 에는 안 붙는다', () async {
      final store = MemoryTokenStore(tokens: StoredTokens(accessToken: 'acc', refreshToken: 'r0', expiresAt: DateTime.utc(2030)));
      final a = FakeAdapter((o) => json({'ok': true}));
      final dio = fakeDio(a);
      dio.interceptors.add(AuthInterceptor(
        dio: dio,
        store: store,
        refresh: ApiClient(fakeDio(FakeAdapter((o) => json(tokensJson())))).authRefresh,
        onSessionExpired: () {},
      ));
      await dio.post('/v1/auth/logout', data: {'refreshToken': 'r0'});
      await dio.post('/v1/auth/refresh', data: {'refreshToken': 'r0'});
      await dio.post('/v1/auth/password/login', data: {});
      expect(a.log[0].headers['Authorization'], 'Bearer acc');
      expect(a.log[1].headers.containsKey('Authorization'), isFalse);
      expect(a.log[2].headers.containsKey('Authorization'), isFalse);
    });
  });

  group('앱 시작(토큰 복원)', () {
    test('서버가 잠들어 getMe 가 늦어도 스플래시에 묶이지 않고, 응답이 오면 동의 필요로 바뀐다', () async {
      final gate = Completer<void>();
      final a = FakeAdapter((o) async {
        await gate.future;
        return json(meJson(required: ['TERMS']));
      });
      final c = authContainer(
        adapter: a,
        store: MemoryTokenStore(tokens: StoredTokens(accessToken: 'a', refreshToken: 'r', expiresAt: DateTime.utc(2030))),
        extra: [authControllerProvider.overrideWith(_QuickGraceAuth.new)],
      );
      c.read(authControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.read(authControllerProvider), AuthStatus.signedIn);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(authControllerProvider), AuthStatus.needsConsent);
    });
  });

  group('가져오기 화면', () {
    test('저장소가 ApiException 이 아닌 오류를 던져도 처리 중에 멈추지 않고 입력 화면으로 돌아온다', () async {
      final c = ProviderContainer(overrides: [
        importRepositoryProvider.overrideWithValue(_ThrowingRepo()),
        deviceTimezoneProvider.overrideWithValue(() async => 'Asia/Seoul'),
      ]);
      addTearDown(c.dispose);
      final sub = c.listen(importControllerProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(importControllerProvider.notifier).start({'schemaVersion': 1}, 'Claude');
      final s = c.read(importControllerProvider);
      expect(s.step, ImportStep.input);
      expect(s.error, isNotNull);
    });
  });
}

class _QuickGraceAuth extends AuthController {
  @override
  Duration get restoreGrace => const Duration(milliseconds: 40);
}

class _ThrowingRepo extends MemoryImportRepository {
  @override
  Future<ImportPreview> preview(ImportRequest request) async => throw StateError('boom');
}
