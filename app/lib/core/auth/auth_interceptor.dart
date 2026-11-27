import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/dto.dart';
import '../api/server_wake.dart';
import '../config.dart';
import '../integrity/integrity.dart';
import 'auth_controller.dart';
import 'token_store.dart';

/// `/v1/auth/*` 외 요청에 Bearer 헤더를 붙이고, 401이면 refresh 한 번 후 재시도한다.
/// QueuedInterceptor라 401이 동시에 여러 개 와도 갱신은 한 번만 일어난다
/// (뒤 요청은 이미 새 토큰이 저장된 것을 보고 갱신 없이 재시도).
class AuthInterceptor extends QueuedInterceptor {
  final Dio dio;
  final TokenStore store;

  /// 인터셉터 없는 별도 클라이언트로 refresh를 호출한다(순환 방지).
  final Future<AuthTokens> Function(String refreshToken) refresh;

  /// refresh를 서버가 거부했거나 토큰이 없을 때.
  final void Function() onSessionExpired;
  final DateTime Function() now;

  AuthInterceptor({
    required this.dio,
    required this.store,
    required this.refresh,
    required this.onSessionExpired,
    DateTime Function()? now,
  }) : now = now ?? (() => DateTime.now().toUtc());

  /// `dioProvider`에서 `dio.interceptors.add(AuthInterceptor.fromRef(ref, dio))`.
  factory AuthInterceptor.fromRef(Ref ref, Dio dio) {
    final refreshClient = ApiClient(
      createApiDio(baseUrl: AppConfig.apiBaseUrl, wake: ref.watch(serverWakeProvider)),
      integrity: ref.watch(integrityTokenSourceProvider),
    );
    return AuthInterceptor(
      dio: dio,
      store: ref.watch(tokenStoreProvider),
      refresh: refreshClient.authRefresh,
      // 지연 read: 빌드 중 순환 의존을 만들지 않는다.
      onSessionExpired: () => ref.read(authControllerProvider.notifier).sessionExpired(),
    );
  }

  static bool _isAuthPath(RequestOptions o) => o.path.contains('/v1/auth/');

  /// 로그아웃만 Bearer가 필요하다(서버 accountRoutes: authenticate 블록 안). 나머지 /v1/auth/*는 인증 없이 부른다.
  static bool _needsBearer(RequestOptions o) => !_isAuthPath(o) || o.path.endsWith('/v1/auth/logout');

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (_needsBearer(options)) {
      final t = await store.read();
      if (t != null) options.headers['Authorization'] = 'Bearer ${t.accessToken}';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final req = err.requestOptions;
    if (err.response?.statusCode != 401 || _isAuthPath(req)) {
      return handler.next(err);
    }
    final tokens = await store.read();
    if (tokens == null) {
      onSessionExpired();
      return handler.next(err);
    }

    var current = tokens;
    // 이 요청이 실패한 토큰과 저장된 토큰이 같으면 아직 갱신 전이다.
    if (req.headers['Authorization'] == 'Bearer ${tokens.accessToken}') {
      try {
        final fresh = await refresh(tokens.refreshToken);
        current = StoredTokens(
          accessToken: fresh.accessToken,
          refreshToken: fresh.refreshToken,
          expiresAt: now().add(Duration(seconds: fresh.expiresIn)),
        );
        await store.write(current);
      } on ApiException catch (e) {
        // 네트워크 오류·호출 제한(429)·무결성 실패(403 INTEGRITY_FAILED)면 세션은 유지하고 원래 오류를 돌려준다.
        // 무결성 실패로 로그아웃시키면 로그인도 같은 이유로 막혀 기록에 접근할 수 없게 된다.
        if (!e.isNetwork && !e.isRateLimited && e.code != 'INTEGRITY_FAILED') {
          await store.clear(keepUserId: true);
          onSessionExpired();
        }
        return handler.next(err);
      } catch (_) {
        return handler.next(err);
      }
    }

    try {
      req.headers['Authorization'] = 'Bearer ${current.accessToken}';
      // 같은 dio로 재시도하면 이 에러 큐가 자기 자신을 기다려 교착한다. 인터셉터 없는 Dio로 보낸다.
      final plain = Dio()..httpClientAdapter = dio.httpClientAdapter;
      handler.resolve(await plain.fetch<dynamic>(req));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
