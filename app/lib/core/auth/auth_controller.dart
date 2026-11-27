// B1 소유. 인증 상태: 저장 토큰 확인 → signedOut / needsConsent / signedIn.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../api/api_client.dart';
import '../api/api_providers.dart';
import '../api/dto.dart';
import '../clock.dart';
import 'google_id_token_source.dart';
import 'token_store.dart';

enum AuthStatus {
  /// 저장된 토큰 확인 중(스플래시).
  unknown,
  signedOut,

  /// 로그인했지만 필수 동의(Me.consentsRequired)가 남음.
  needsConsent,
  signedIn,
}

/// 로그인 화면에 보여줄 실패 종류.
enum AuthFailureKind {
  network,
  server,
  noIdToken,
  other,

  /// 아이디·비밀번호 로그인 전용(401).
  badCredentials,

  /// 5회 실패 잠금(429). [AuthFailure.retryAfter] 참고.
  locked,

  /// 가입 코드 틀림 또는 가입 꺼짐(403).
  signupCodeWrong,

  /// 이미 있는 아이디(409).
  usernameTaken,

  /// 400. [AuthFailure.field]는 username|password 등.
  validation,
}

class AuthFailure implements Exception {
  final AuthFailureKind kind;
  final Object? cause;
  final Duration? retryAfter;
  final String? field;
  const AuthFailure(this.kind, [this.cause, this.retryAfter, this.field]);

  /// 아이디·비밀번호 로그인·가입 응답을 사용자 문구 종류로 바꾼다.
  factory AuthFailure.fromPassword(Object e) {
    if (e is ApiException && !e.isNetwork) {
      switch (e.statusCode) {
        case 401:
          return AuthFailure(AuthFailureKind.badCredentials, e);
        case 429:
          return AuthFailure(AuthFailureKind.locked, e, e.retryAfter);
        case 403:
          return AuthFailure(AuthFailureKind.signupCodeWrong, e);
        case 409:
          return AuthFailure(AuthFailureKind.usernameTaken, e);
        case 400:
          return AuthFailure(AuthFailureKind.validation, e, null, e.field);
      }
    }
    return AuthFailure.from(e);
  }

  factory AuthFailure.from(Object e) {
    if (e is AuthFailure) return e;
    if (e is ApiException) return AuthFailure(e.isNetwork ? AuthFailureKind.network : AuthFailureKind.server, e);
    return AuthFailure(AuthFailureKind.other, e);
  }

  @override
  String toString() => 'AuthFailure($kind, $cause)';
}

class AuthController extends Notifier<AuthStatus> {
  Me? _me;

  /// 마지막으로 확인한 내 정보(로그인 후). signedOut이면 null.
  Me? get me => _me;

  ApiClient get _api => ref.read(apiClientProvider);
  TokenStore get _store => ref.read(tokenStoreProvider);

  @override
  AuthStatus build() {
    Future.microtask(_restore);
    return AuthStatus.unknown;
  }

  Future<void> _restore() async {
    final tokens = await _store.read();
    if (!ref.mounted) return;
    if (tokens == null) {
      state = AuthStatus.signedOut;
      return;
    }
    // 잠든 서버는 깨는 데 1분쯤 걸린다. 그동안 스플래시에 묶어 두지 않고, 잠시 뒤에는 로그인된 것으로 먼저 보여 준다
    // (오프라인 우선 앱). 동의가 더 필요하거나 토큰이 거부되면 응답이 온 뒤에 상태가 바뀐다.
    final grace = Timer(restoreGrace, () {
      if (ref.mounted && state == AuthStatus.unknown) state = AuthStatus.signedIn;
    });
    try {
      await _loadMe();
    } on ApiException catch (e) {
      if (!ref.mounted) return;
      // 오프라인 우선 앱이라 네트워크 오류면 일단 로그인된 것으로 둔다.
      if (e.isUnauthenticated) {
        state = AuthStatus.signedOut;
      } else if (state == AuthStatus.unknown) {
        state = AuthStatus.signedIn;
      }
    } catch (_) {
      if (ref.mounted && state == AuthStatus.unknown) state = AuthStatus.signedIn;
    } finally {
      grace.cancel();
    }
  }

  /// 저장된 토큰이 있을 때 `getMe` 응답을 이만큼만 기다리고 먼저 홈을 보여 준다.
  Duration get restoreGrace => const Duration(seconds: 8);

  /// `getMe()`로 필수 동의를 확인하고 상태를 정한다. 다른 계정이면 로컬 데이터를 비운다.
  Future<void> _loadMe() async {
    final me = await _api.getMe();
    if (!ref.mounted) return;
    final last = await _store.readUserId();
    if (last != null && last != me.id) {
      await ref.read(localDataStoreProvider).clearAll();
    }
    await _store.writeUserId(me.id);
    if (!ref.mounted) return;
    _me = me;
    state = me.consentsRequired.isEmpty ? AuthStatus.signedIn : AuthStatus.needsConsent;
  }

  /// 동의 기록 후 등에 서버 상태를 다시 읽는다.
  Future<void> refreshMe() => _loadMe();

  /// Google 로그인. 사용자가 취소하면 아무 일도 없다. 실패하면 [AuthFailure]를 던진다.
  Future<void> signInWithGoogle() async {
    try {
      final idToken = await ref.read(googleIdTokenSourceProvider).fetchIdToken();
      if (idToken == null) return; // 취소
      if (idToken.isEmpty) throw const AuthFailure(AuthFailureKind.noIdToken);
      await _completeSignIn(await _api.authGoogle(idToken));
    } catch (e) {
      throw AuthFailure.from(e);
    }
  }

  /// 테스트용 아이디·비밀번호 로그인. 실패하면 [AuthFailure]를 던진다.
  Future<void> signInWithPassword(String username, String password) async {
    try {
      await _completeSignIn(await _api.authPasswordLogin(username.trim(), password));
    } catch (e) {
      throw AuthFailure.fromPassword(e);
    }
  }

  /// 테스트용 아이디·비밀번호 가입(가입 후 바로 로그인 상태).
  Future<void> registerWithPassword(String username, String password, String signupCode, {String? displayName}) async {
    try {
      await _completeSignIn(
        await _api.authPasswordRegister(username.trim(), password, signupCode, displayName: displayName?.trim()),
      );
    } catch (e) {
      throw AuthFailure.fromPassword(e);
    }
  }

  /// 토큰을 저장하고 내 정보·동의 상태를 읽는다(로그인 방식과 무관한 공통 흐름).
  Future<void> _completeSignIn(AuthTokens t) async {
    await _store.write(
      StoredTokens(
        accessToken: t.accessToken,
        refreshToken: t.refreshToken,
        expiresAt: ref.read(clockProvider)().add(Duration(seconds: t.expiresIn)),
      ),
    );
    try {
      await _loadMe();
    } catch (_) {
      await _store.clear(keepUserId: true);
      rethrow;
    }
  }

  /// 동의 한 건을 기록한다(철회는 granted: false).
  Future<void> recordConsent(ConsentKind kind, {required String version, required bool granted}) async {
    await _api.postConsent(ConsentInput(kind: kind, version: version, granted: granted));
  }

  /// 필수 동의 전체를 기록하고 서버 상태를 다시 읽는다(ACC-6).
  Future<void> acceptConsents(String version) async {
    for (final k in ConsentKind.values) {
      await recordConsent(k, version: version, granted: true);
    }
    await _loadMe();
  }

  /// 로그아웃. 서버 호출이 실패해도 로컬은 정리한다.
  Future<void> signOut() async {
    final tokens = await _store.read();
    if (tokens != null) {
      try {
        await _api.authLogout(tokens.refreshToken);
      } catch (_) {}
    }
    await _cleanup();
  }

  /// 계정 삭제(ACC-5). 서버 삭제에 실패하면 예외를 던지고 로그인 상태를 유지한다.
  Future<void> deleteAccount() async {
    await _api.deleteMe();
    await _cleanup();
  }

  Future<void> _cleanup() async {
    await _store.clear();
    try {
      await ref.read(googleIdTokenSourceProvider).signOut();
    } catch (_) {}
    await ref.read(localDataStoreProvider).clearAll();
    if (!ref.mounted) return;
    _me = null;
    state = AuthStatus.signedOut;
  }

  /// 인터셉터가 refresh 실패를 알릴 때. 토큰은 이미 지워졌다. 로컬 데이터는 남긴다
  /// (다른 계정으로 로그인하면 [_loadMe]가 비운다).
  void sessionExpired() {
    if (state == AuthStatus.signedOut || !ref.mounted) return;
    _me = null;
    state = AuthStatus.signedOut;
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthStatus>(AuthController.new);
