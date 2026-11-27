import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:fitlog/core/integrity/integrity.dart';
import 'package:fitlog/core/settings/settings_controller.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/features/ai_connect/ai_connect_page.dart';
import 'package:fitlog/features/auth/login_page.dart';
import 'package:fitlog/features/settings/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../b1/helpers.dart';
import '../b1/pages_test.dart' show FixedSettings;

class _FixedIntegrity implements IntegrityTokenSource {
  String? lastHash;
  @override
  Future<String?> token(String requestHash) async {
    lastHash = requestHash;
    return 'tok';
  }
}

ResponseBody _rateLimited(int seconds) => ResponseBody.fromString(
  '{"error":{"code":"RATE_LIMITED","message":"locked"}}',
  429,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
    'retry-after': ['$seconds'],
  },
);

ResponseBody _validation(String field) => json({
  'error': {'code': 'VALIDATION_FAILED', 'message': 'bad', 'field': field},
}, 400);

/// 로그인 성공 + 지정한 이메일의 me, methods는 [methods].
FakeAdapter _server({
  Map<String, Object?>? methods,
  String email = 'a@b.c',
  FutureOr<ResponseBody> Function(RequestOptions)? auth,
}) {
  return FakeAdapter((o) {
    switch (o.path) {
      case '/v1/auth/methods':
        return methods == null ? errorBody(500, 'INTERNAL') : json(methods);
      case '/v1/auth/password/login':
      case '/v1/auth/password/register':
        return auth != null ? auth(o) : json(tokensJson());
      case '/v1/me':
        return json({...meJson(), 'email': email});
    }
    return errorBody(404, 'NOT_FOUND');
  });
}

class PwAuth extends AuthController {
  final Me? _m;
  PwAuth(this._m);
  @override
  AuthStatus build() => AuthStatus.signedIn;
  @override
  Me? get me => _m;
}

Me _me(String email, {String? name}) =>
    Me(id: 'u1', email: email, displayName: name, role: UserRole.MEMBER, consentsRequired: const []);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ApiClient', () {
    test('authMethods 파싱', () async {
      final a = _server(methods: {'google': true, 'password': true, 'passwordSignup': false});
      final m = await ApiClient(fakeDio(a)).authMethods();
      expect(m.google, isTrue);
      expect(m.password, isTrue);
      expect(m.passwordSignup, isFalse);
    });

    test('login: 본문과 X-Integrity-Token(requestHash = 입력 아이디의 SHA-256)', () async {
      final a = _server();
      final integ = _FixedIntegrity();
      final t = await ApiClient(fakeDio(a), integrity: integ).authPasswordLogin('Jae', 'pw123456');
      expect(t.accessToken, 'a1');
      final o = a.log.single;
      expect(o.path, '/v1/auth/password/login');
      expect(o.data, {'username': 'Jae', 'password': 'pw123456'});
      expect(o.headers[integrityHeader], 'tok');
      expect(integ.lastHash, integrityRequestHash('Jae'));
    });

    test('register: displayName은 있을 때만 보낸다', () async {
      final a = _server();
      final c = ApiClient(fakeDio(a));
      await c.authPasswordRegister('jae', 'pw123456', 'code');
      await c.authPasswordRegister('jae', 'pw123456', 'code', displayName: '재성');
      expect(a.log[0].data, {'username': 'jae', 'password': 'pw123456', 'signupCode': 'code'});
      expect((a.log[1].data as Map)['displayName'], '재성');
      expect(a.log[0].path, '/v1/auth/password/register');
    });

    test('Integrity 토큰이 없으면 헤더 없음', () async {
      final a = _server();
      await ApiClient(fakeDio(a)).authPasswordLogin('jae', 'pw123456');
      expect(a.log.single.headers.containsKey(integrityHeader), isFalse);
    });
  });

  group('AuthController 오류 매핑', () {
    Future<AuthFailure> fail(FakeAdapter a, {bool register = false}) async {
      final c = authContainer(adapter: a);
      final ctl = c.read(authControllerProvider.notifier);
      try {
        register
            ? await ctl.registerWithPassword('jae', 'pw123456', 'code')
            : await ctl.signInWithPassword('jae', 'pw123456');
      } on AuthFailure catch (e) {
        return e;
      }
      throw TestFailure('no failure');
    }

    test('성공하면 토큰 저장 후 signedIn, 비밀번호 계정 인식', () async {
      final store = MemoryTokenStore();
      final c = authContainer(
        adapter: _server(email: 'jae@password.local'),
        store: store,
      );
      await settled(c);
      await c.read(authControllerProvider.notifier).signInWithPassword(' jae ', 'pw123456');
      expect(c.read(authControllerProvider), AuthStatus.signedIn);
      expect(await store.read(), isNotNull);
      final me = c.read(authControllerProvider.notifier).me!;
      expect(me.isPasswordAccount, isTrue);
      expect(me.username, 'jae');
    });

    test('아이디 앞뒤 공백은 잘라서 보낸다', () async {
      final a = _server();
      final c = authContainer(adapter: a);
      await c.read(authControllerProvider.notifier).signInWithPassword('  jae ', 'pw123456');
      expect((a.log.firstWhere((o) => o.path.endsWith('/login')).data as Map)['username'], 'jae');
    });

    test('401 -> badCredentials', () async {
      final e = await fail(_server(auth: (_) => errorBody(401, 'UNAUTHENTICATED')));
      expect(e.kind, AuthFailureKind.badCredentials);
    });

    test('429 -> locked, retryAfter 보존', () async {
      final e = await fail(_server(auth: (_) => _rateLimited(900)));
      expect(e.kind, AuthFailureKind.locked);
      expect(e.retryAfter, const Duration(minutes: 15));
    });

    test('403 -> signupCodeWrong, 409 -> usernameTaken', () async {
      expect(
        (await fail(_server(auth: (_) => errorBody(403, 'FORBIDDEN')), register: true)).kind,
        AuthFailureKind.signupCodeWrong,
      );
      expect(
        (await fail(_server(auth: (_) => errorBody(409, 'CONFLICT')), register: true)).kind,
        AuthFailureKind.usernameTaken,
      );
    });

    test('400 -> validation + field', () async {
      final e = await fail(_server(auth: (_) => _validation('password')), register: true);
      expect(e.kind, AuthFailureKind.validation);
      expect(e.field, 'password');
    });

    test('연결 실패 -> network, 500 -> server', () async {
      final net = FakeAdapter((o) => throw DioException(requestOptions: o, type: DioExceptionType.connectionError));
      expect((await fail(net)).kind, AuthFailureKind.network);
      expect((await fail(_server(auth: (_) => errorBody(500, 'INTERNAL')))).kind, AuthFailureKind.server);
    });
  });

  group('LoginPage', () {
    Future<void> pump(WidgetTester tester, FakeAdapter a, {MemoryTokenStore? store}) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = authContainer(
        adapter: a,
        store: store,
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      await tester.pumpWidget(containerApp(c, const LoginPage()));
      await tester.pumpAndSettle();
    }

    testWidgets('methods 실패 -> Google만', (tester) async {
      await pump(tester, _server());
      expect(find.byKey(const Key('googleSignIn')), findsOneWidget);
      expect(find.byKey(const Key('pwUsername')), findsNothing);
    });

    testWidgets('google만 켜짐 -> 폼 없음', (tester) async {
      await pump(tester, _server(methods: {'google': true, 'password': false, 'passwordSignup': false}));
      expect(find.byKey(const Key('pwUsername')), findsNothing);
    });

    testWidgets('password 켜짐 -> Google과 로그인 폼, 가입 토글 없음', (tester) async {
      await pump(tester, _server(methods: {'google': true, 'password': true, 'passwordSignup': false}));
      expect(find.byKey(const Key('googleSignIn')), findsOneWidget);
      expect(find.byKey(const Key('pwUsername')), findsOneWidget);
      expect(find.byKey(const Key('pwPassword')), findsOneWidget);
      expect(find.byKey(const Key('pwModeToggle')), findsNothing);
      expect(find.byKey(const Key('pwConfirm')), findsNothing);
    });

    testWidgets('google 꺼짐 + password -> Google 버튼 숨김', (tester) async {
      await pump(tester, _server(methods: {'google': false, 'password': true, 'passwordSignup': false}));
      expect(find.byKey(const Key('googleSignIn')), findsNothing);
      expect(find.byKey(const Key('pwUsername')), findsOneWidget);
    });

    testWidgets('로그인: 검증 실패 시 요청 없음, 성공 시 signedIn', (tester) async {
      final a = _server(methods: {'google': true, 'password': true, 'passwordSignup': false});
      await pump(tester, a);
      await tester.tap(find.byKey(const Key('pwSubmit')));
      await tester.pump();
      expect(find.text('아이디는 3~32자, 영문·숫자·. _ - 만 쓸 수 있어요.'), findsOneWidget);
      expect(a.count('POST', '/v1/auth/password/login'), 0);

      await tester.enterText(find.byKey(const Key('pwUsername')), 'jae');
      await tester.enterText(find.byKey(const Key('pwPassword')), 'pw123456');
      await tester.tap(find.byKey(const Key('pwSubmit')));
      await tester.pumpAndSettle();
      expect(a.count('POST', '/v1/auth/password/login'), 1);
      expect(find.byKey(const Key('loginError')), findsNothing);
    });

    testWidgets('로그인 실패 문구: 401, 429(분)', (tester) async {
      var code = 401;
      final a = _server(
        methods: {'google': true, 'password': true, 'passwordSignup': false},
        auth: (_) => code == 401 ? errorBody(401, 'UNAUTHENTICATED') : _rateLimited(900),
      );
      await pump(tester, a);
      await tester.enterText(find.byKey(const Key('pwUsername')), 'jae');
      await tester.enterText(find.byKey(const Key('pwPassword')), 'wrongwrong');
      await tester.tap(find.byKey(const Key('pwSubmit')));
      await tester.pumpAndSettle();
      expect(find.text('아이디 또는 비밀번호가 맞지 않아요.'), findsOneWidget);

      code = 429;
      await tester.tap(find.byKey(const Key('pwSubmit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('15분'), findsOneWidget);
    });

    testWidgets('비밀번호 보기 토글', (tester) async {
      await pump(tester, _server(methods: {'google': true, 'password': true, 'passwordSignup': false}));
      bool obscured() => tester
          .widget<EditableText>(
            find.descendant(of: find.byKey(const Key('pwPassword')), matching: find.byType(EditableText)),
          )
          .obscureText;
      expect(obscured(), isTrue);
      await tester.tap(find.byKey(const Key('pwToggle')));
      await tester.pump();
      expect(obscured(), isFalse);
    });

    testWidgets('가입 모드: 필드 노출, 검증, 요청 본문', (tester) async {
      final a = _server(methods: {'google': true, 'password': true, 'passwordSignup': true});
      await pump(tester, a);
      await tester.tap(find.byKey(const Key('pwModeToggle')));
      await tester.pumpAndSettle();
      for (final k in ['pwUsername', 'pwPassword', 'pwConfirm', 'pwCode', 'pwDisplayName']) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }

      await tester.enterText(find.byKey(const Key('pwUsername')), 'ab');
      await tester.enterText(find.byKey(const Key('pwPassword')), 'short');
      await tester.enterText(find.byKey(const Key('pwConfirm')), 'other');
      await tester.tap(find.byKey(const Key('pwSubmit')));
      await tester.pump();
      expect(find.text('아이디는 3~32자, 영문·숫자·. _ - 만 쓸 수 있어요.'), findsOneWidget);
      expect(find.text('비밀번호는 8~128자로 입력해 주세요.'), findsOneWidget);
      expect(find.text('비밀번호가 서로 달라요.'), findsOneWidget);
      expect(find.text('가입 코드를 입력해 주세요.'), findsOneWidget);
      expect(a.count('POST', '/v1/auth/password/register'), 0);

      await tester.enterText(find.byKey(const Key('pwUsername')), 'jae.park');
      await tester.enterText(find.byKey(const Key('pwPassword')), 'pw123456');
      await tester.enterText(find.byKey(const Key('pwConfirm')), 'pw123456');
      await tester.enterText(find.byKey(const Key('pwCode')), ' secret ');
      await tester.tap(find.byKey(const Key('pwSubmit')));
      await tester.pumpAndSettle();
      final o = a.log.firstWhere((o) => o.path == '/v1/auth/password/register');
      expect(o.data, {'username': 'jae.park', 'password': 'pw123456', 'signupCode': 'secret'});
    });

    testWidgets('2배 글자 크기에서도 스크롤로 접근 가능', (tester) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = authContainer(
        adapter: _server(methods: {'google': true, 'password': true, 'passwordSignup': true}),
        extra: [authControllerProvider.overrideWith(() => FixedAuth(AuthStatus.signedOut))],
      );
      await tester.pumpWidget(
        containerApp(
          c,
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const LoginPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pwModeToggle')), warnIfMissed: false);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const Key('pwSubmit')),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('pwSubmit')), findsOneWidget);
    });
  });

  group('계정 표시', () {
    testWidgets('설정: 비밀번호 계정은 아이디 + 라벨', (tester) async {
      final c = authContainer(
        adapter: _server(),
        extra: [
          authControllerProvider.overrideWith(() => PwAuth(_me('jae@password.local', name: '재성'))),
          settingsProvider.overrideWith(() => FixedSettings(const Settings())),
        ],
      );
      await tester.pumpWidget(containerApp(c, const SettingsPage()));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('accountTile')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('jae'), findsOneWidget);
      expect(find.textContaining('아이디 로그인'), findsOneWidget);
      expect(find.textContaining('password.local'), findsNothing);
    });

    testWidgets('설정: Google 계정은 이메일 그대로', (tester) async {
      final c = authContainer(
        adapter: _server(),
        extra: [
          authControllerProvider.overrideWith(() => PwAuth(_me('a@b.c'))),
          settingsProvider.overrideWith(() => FixedSettings(const Settings())),
        ],
      );
      await tester.pumpWidget(containerApp(c, const SettingsPage()));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('accountTile')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('a@b.c'), findsOneWidget);
      expect(find.textContaining('아이디 로그인'), findsNothing);
    });

    for (final (email, shown) in [('jae@password.local', true), ('a@b.c', false)]) {
      testWidgets('AI 연결 안내: $email -> $shown', (tester) async {
        final c = authContainer(
          adapter: _server(),
          extra: [
            authControllerProvider.overrideWith(() => PwAuth(_me(email))),
            aiConnectionRepositoryProvider.overrideWithValue(MemoryAiConnectionRepository()),
          ],
        );
        await tester.pumpWidget(containerApp(c, const AiConnectPage()));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('aiPasswordNote')), shown ? findsOneWidget : findsNothing);
      });
    }
  });
}
