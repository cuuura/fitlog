import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/api_providers.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/auth/google_id_token_source.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart' show addTearDown;
import 'package:material_ui/material_ui.dart';

typedef Handler = FutureOr<ResponseBody> Function(RequestOptions o);

/// 네트워크 대신 [handler]가 응답하는 Dio 어댑터. 요청은 [log]에 쌓인다.
class FakeAdapter implements HttpClientAdapter {
  Handler handler;
  final List<RequestOptions> log = [];
  FakeAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    log.add(options);
    return await handler(options);
  }

  @override
  void close({bool force = false}) {}

  int count(String method, String path) => log.where((o) => o.method == method && o.path == path).length;
}

ResponseBody json(Object? body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

ResponseBody noContent() => ResponseBody.fromString('', 204);

ResponseBody errorBody(int status, String code) => json({
      'error': {'code': code, 'message': code}
    }, status);

Dio fakeDio(FakeAdapter a) => Dio(BaseOptions(baseUrl: 'http://test', validateStatus: (s) => s != null && s < 400))
  ..httpClientAdapter = a;

Map<String, Object?> tokensJson({String access = 'a1', String refresh = 'r1'}) =>
    {'accessToken': access, 'refreshToken': refresh, 'expiresIn': 900, 'isNewUser': false};

Map<String, Object?> meJson({List<String> required = const []}) =>
    {'id': 'u1', 'email': 'a@b.c', 'displayName': 'A', 'role': 'MEMBER', 'consentsRequired': required};

class FakeGoogle implements GoogleIdTokenSource {
  String? token;
  bool signedOutCalled = false;
  FakeGoogle(this.token);
  @override
  Future<String?> fetchIdToken() async => token;
  @override
  Future<void> signOut() async => signedOutCalled = true;
}

class RecordingLocalStore implements LocalDataStore {
  int cleared = 0;
  @override
  Future<void> clearAll() async => cleared++;
}

/// 복원 로직 없이 고정 상태로 시작하는 AuthController(복원·동의·로그아웃 메서드는 그대로).
class FixedAuth extends AuthController {
  final AuthStatus initial;
  FixedAuth(this.initial);
  @override
  AuthStatus build() => initial;
}

ProviderContainer authContainer({
  required FakeAdapter adapter,
  TokenStore? store,
  GoogleIdTokenSource? google,
  LocalDataStore? local,
  List<Override> extra = const [],
}) {
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(ApiClient(fakeDio(adapter))),
    tokenStoreProvider.overrideWithValue(store ?? MemoryTokenStore()),
    googleIdTokenSourceProvider.overrideWithValue(google ?? FakeGoogle(null)),
    localDataStoreProvider.overrideWithValue(local ?? RecordingLocalStore()),
    ...extra,
  ]);
  addTearDown(c.dispose);
  return c;
}

/// unknown이 풀릴 때까지 기다린다.
Future<AuthStatus> settled(ProviderContainer c) async {
  c.read(authControllerProvider);
  for (var i = 0; i < 50 && c.read(authControllerProvider) == AuthStatus.unknown; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return c.read(authControllerProvider);
}

Widget _material(Widget home) => MaterialApp(
      locale: const Locale('ko'),
      // flutter_localizations의 GlobalMaterialLocalizations는 flutter/material 타입이라
      // material_ui의 것을 직접 쓴다(app.dart에도 필요, 보고서 참고).
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Widget app(Widget home, {List<Override> overrides = const []}) =>
    ProviderScope(overrides: overrides, child: _material(home));

/// 이미 만든 컨테이너를 쓰는 테스트 앱.
Widget containerApp(ProviderContainer c, Widget home) =>
    UncontrolledProviderScope(container: c, child: _material(home));
