import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_interceptor.dart';
import '../config.dart';
import '../integrity/integrity.dart';
import 'api_client.dart';
import 'dto.dart';

/// 공용 Dio. 인증 인터셉터가 Bearer 헤더를 붙이고 401이면 refresh 후 재시도한다.
final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      contentType: 'application/json',
    ),
  );
  dio.interceptors.add(AuthInterceptor.fromRef(ref, dio));
  return dio;
});

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(ref.watch(dioProvider), integrity: ref.watch(integrityTokenSourceProvider)),
);

/// 로그인 화면용. 어떤 오류든 Google만 켜진 것으로 본다.
final authMethodsProvider = FutureProvider.autoDispose<AuthMethods>((ref) async {
  try {
    return await ref.watch(apiClientProvider).authMethods();
  } catch (_) {
    return AuthMethods.googleOnly;
  }
});
