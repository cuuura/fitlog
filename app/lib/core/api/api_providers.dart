import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_interceptor.dart';
import '../config.dart';
import '../integrity/integrity.dart';
import 'api_client.dart';
import 'server_wake.dart';
import 'dto.dart';

/// 공용 Dio. 맨 앞에서 콜드 스타트(잠든 서버)를 기다리고 재시도하며([WakeRetryInterceptor]),
/// 인증 인터셉터가 Bearer 헤더를 붙이고 401이면 refresh 후 재시도한다.
final dioProvider = Provider<Dio>((ref) {
  final dio = createApiDio(baseUrl: AppConfig.apiBaseUrl, wake: ref.watch(serverWakeProvider));
  dio.interceptors.add(AuthInterceptor.fromRef(ref, dio));
  return dio;
});

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(ref.watch(dioProvider), integrity: ref.watch(integrityTokenSourceProvider)),
);

/// 로그인 화면용 로그인 수단.
/// 서버가 잠들어 있으면(무료 호스팅) 깨어나는 데 1분 가까이 걸리므로 넉넉히 기다리고 몇 번 다시 묻는다.
/// 서버가 응답했는데 오류(4xx, 구버전 서버의 404 등)면 Google만 켜진 것으로 본다.
/// 네트워크·5xx 로 끝내 못 받으면 오류로 남겨 화면이 '다시 시도'를 보이게 한다.
final authMethodsProvider = FutureProvider.autoDispose<AuthMethods>((ref) async {
  final api = ref.watch(apiClientProvider);
  const attempts = 3;
  for (var i = 1; ; i++) {
    try {
      return await api.authMethods(timeout: const Duration(seconds: 60));
    } on ApiException catch (e) {
      final transient = e.code == 'NETWORK' || (e.statusCode ?? 0) >= 500;
      if (!transient) return AuthMethods.googleOnly;
      if (i >= attempts) rethrow;
      await Future<void>.delayed(Duration(seconds: 2 * i));
    } catch (_) {
      return AuthMethods.googleOnly;
    }
  }
});
