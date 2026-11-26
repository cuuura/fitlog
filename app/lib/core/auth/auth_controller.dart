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
enum AuthFailureKind { network, server, noIdToken, other }

class AuthFailure implements Exception {
  final AuthFailureKind kind;
  final Object? cause;
  const AuthFailure(this.kind, [this.cause]);

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
    }
  }

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
      final t = await _api.authGoogle(idToken);
      await _store.write(StoredTokens(
        accessToken: t.accessToken,
        refreshToken: t.refreshToken,
        expiresAt: ref.read(clockProvider)().add(Duration(seconds: t.expiresIn)),
      ));
      try {
        await _loadMe();
      } catch (_) {
        await _store.clear(keepUserId: true);
        rethrow;
      }
    } catch (e) {
      throw AuthFailure.from(e);
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
