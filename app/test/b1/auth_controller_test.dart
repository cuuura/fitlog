import 'package:dio/dio.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:fitlog/core/router.dart';
import 'package:fitlog/core/routes.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

StoredTokens _tokens() =>
    StoredTokens(accessToken: 'a0', refreshToken: 'r0', expiresAt: DateTime.utc(2030));

void main() {
  test('토큰이 없으면 signedOut', () async {
    final c = authContainer(adapter: FakeAdapter((_) => noContent()));
    expect(await settled(c), AuthStatus.signedOut);
  });

  test('토큰 + 동의 완료 -> signedIn', () async {
    final a = FakeAdapter((o) => json(meJson()));
    final c = authContainer(adapter: a, store: MemoryTokenStore(tokens: _tokens()));
    expect(await settled(c), AuthStatus.signedIn);
    expect(c.read(authControllerProvider.notifier).me?.email, 'a@b.c');
  });

  test('토큰 + 필수 동의 남음 -> needsConsent', () async {
    final a = FakeAdapter((o) => json(meJson(required: ['TERMS', 'PRIVACY', 'HEALTH_DATA'])));
    final c = authContainer(adapter: a, store: MemoryTokenStore(tokens: _tokens()));
    expect(await settled(c), AuthStatus.needsConsent);
  });

  test('시작 시 네트워크 오류면 오프라인으로 보고 signedIn 유지', () async {
    final a = FakeAdapter((o) => throw DioException(requestOptions: o, type: DioExceptionType.connectionError));
    final c = authContainer(adapter: a, store: MemoryTokenStore(tokens: _tokens()));
    expect(await settled(c), AuthStatus.signedIn);
  });

  test('시작 시 401이면 signedOut', () async {
    final a = FakeAdapter((o) => errorBody(401, 'UNAUTHENTICATED'));
    final c = authContainer(adapter: a, store: MemoryTokenStore(tokens: _tokens()));
    expect(await settled(c), AuthStatus.signedOut);
  });

  test('Google 로그인: 토큰 저장 후 me 확인', () async {
    final store = MemoryTokenStore();
    final a = FakeAdapter((o) => o.path == '/v1/auth/google' ? json(tokensJson()) : json(meJson(required: ['TERMS'])));
    final c = authContainer(adapter: a, store: store, google: FakeGoogle('idtok'));
    expect(await settled(c), AuthStatus.signedOut);

    await c.read(authControllerProvider.notifier).signInWithGoogle();
    expect(c.read(authControllerProvider), AuthStatus.needsConsent);
    expect(store.tokens?.accessToken, 'a1');
    expect(store.tokens?.refreshToken, 'r1');
    expect(a.log.first.data, {'idToken': 'idtok'});
  });

  test('Google 로그인 취소는 상태 변화 없음', () async {
    final a = FakeAdapter((o) => noContent());
    final c = authContainer(adapter: a, google: FakeGoogle(null));
    await settled(c);
    await c.read(authControllerProvider.notifier).signInWithGoogle();
    expect(c.read(authControllerProvider), AuthStatus.signedOut);
    expect(a.log, isEmpty);
  });

  test('Google 로그인 서버 실패는 AuthFailure(server), 토큰 없음', () async {
    final store = MemoryTokenStore();
    final a = FakeAdapter((o) => errorBody(401, 'UNAUTHENTICATED'));
    final c = authContainer(adapter: a, store: store, google: FakeGoogle('bad'));
    await settled(c);
    await expectLater(
      c.read(authControllerProvider.notifier).signInWithGoogle(),
      throwsA(isA<AuthFailure>().having((e) => e.kind, 'kind', AuthFailureKind.server)),
    );
    expect(store.tokens, isNull);
    expect(c.read(authControllerProvider), AuthStatus.signedOut);
  });

  test('동의 기록 후 getMe로 signedIn', () async {
    var consented = false;
    final a = FakeAdapter((o) {
      if (o.path == '/v1/me/consents') {
        consented = true;
        return json({'kind': 'TERMS', 'version': 'v', 'granted': true}, 201);
      }
      return json(meJson(required: consented ? [] : ['TERMS', 'PRIVACY', 'HEALTH_DATA']));
    });
    final c = authContainer(adapter: a, store: MemoryTokenStore(tokens: _tokens()));
    expect(await settled(c), AuthStatus.needsConsent);
    await c.read(authControllerProvider.notifier).acceptConsents('v');
    expect(c.read(authControllerProvider), AuthStatus.signedIn);
    expect(a.count('POST', '/v1/me/consents'), 3);
    expect(a.log.where((o) => o.path == '/v1/me/consents').map((o) => (o.data as Map)['kind']),
        ['TERMS', 'PRIVACY', 'HEALTH_DATA']);
  });

  test('로그아웃: 서버 폐기, 토큰·로컬 데이터 삭제', () async {
    final store = MemoryTokenStore(tokens: _tokens());
    final local = RecordingLocalStore();
    final google = FakeGoogle(null);
    final a = FakeAdapter((o) => o.path == '/v1/auth/logout' ? noContent() : json(meJson()));
    final c = authContainer(adapter: a, store: store, local: local, google: google);
    expect(await settled(c), AuthStatus.signedIn);

    await c.read(authControllerProvider.notifier).signOut();
    expect(c.read(authControllerProvider), AuthStatus.signedOut);
    expect(store.tokens, isNull);
    expect(local.cleared, 1);
    expect(google.signedOutCalled, isTrue);
    expect(a.log.last.path, '/v1/auth/logout');
    expect(a.log.last.data, {'refreshToken': 'r0'});
  });

  test('로그아웃은 서버가 실패해도 로컬을 정리한다', () async {
    final store = MemoryTokenStore(tokens: _tokens());
    final local = RecordingLocalStore();
    final a = FakeAdapter((o) =>
        o.path == '/v1/auth/logout' ? throw DioException(requestOptions: o, type: DioExceptionType.connectionError) : json(meJson()));
    final c = authContainer(adapter: a, store: store, local: local);
    await settled(c);
    await c.read(authControllerProvider.notifier).signOut();
    expect(c.read(authControllerProvider), AuthStatus.signedOut);
    expect(store.tokens, isNull);
    expect(local.cleared, 1);
  });

  test('계정 삭제: deleteMe 후 정리, 실패하면 로그인 유지', () async {
    final store = MemoryTokenStore(tokens: _tokens());
    final local = RecordingLocalStore();
    var fail = true;
    final a = FakeAdapter((o) {
      if (o.method == 'DELETE') return fail ? errorBody(500, 'INTERNAL') : noContent();
      return json(meJson());
    });
    final c = authContainer(adapter: a, store: store, local: local);
    await settled(c);
    final auth = c.read(authControllerProvider.notifier);

    await expectLater(auth.deleteAccount(), throwsA(anything));
    expect(c.read(authControllerProvider), AuthStatus.signedIn);
    expect(local.cleared, 0);

    fail = false;
    await auth.deleteAccount();
    expect(c.read(authControllerProvider), AuthStatus.signedOut);
    expect(store.tokens, isNull);
    expect(local.cleared, 1);
  });

  test('다른 계정으로 로그인하면 로컬 데이터를 비운다', () async {
    final store = MemoryTokenStore(tokens: _tokens(), userId: 'someone-else');
    final local = RecordingLocalStore();
    final c = authContainer(adapter: FakeAdapter((o) => json(meJson())), store: store, local: local);
    await settled(c);
    expect(local.cleared, 1);
    expect(store.userId, 'u1');
  });

  group('authRedirect', () {
    test('상태별 이동', () {
      expect(authRedirect(AuthStatus.unknown, Routes.home), Routes.splash);
      expect(authRedirect(AuthStatus.unknown, Routes.splash), isNull);
      expect(authRedirect(AuthStatus.signedOut, Routes.home), Routes.login);
      expect(authRedirect(AuthStatus.signedOut, Routes.login), isNull);
      expect(authRedirect(AuthStatus.needsConsent, Routes.login), Routes.consent);
      expect(authRedirect(AuthStatus.needsConsent, Routes.consent), isNull);
      expect(authRedirect(AuthStatus.signedIn, Routes.splash), Routes.home);
      expect(authRedirect(AuthStatus.signedIn, Routes.login), Routes.home);
      expect(authRedirect(AuthStatus.signedIn, Routes.consent), Routes.home);
      expect(authRedirect(AuthStatus.signedIn, Routes.settings), isNull);
    });
  });
}
