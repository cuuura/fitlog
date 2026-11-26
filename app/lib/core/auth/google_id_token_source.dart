import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config.dart';

/// Google 로그인에서 서버로 보낼 ID 토큰을 얻는 부분. 테스트에서 바꿔 끼운다.
abstract interface class GoogleIdTokenSource {
  /// 사용자가 취소하면 null.
  Future<String?> fetchIdToken();
  Future<void> signOut();
}

class GoogleSignInIdTokenSource implements GoogleIdTokenSource {
  Future<void>? _init;

  Future<void> _ensureInit() => _init ??= GoogleSignIn.instance.initialize(
        serverClientId: AppConfig.googleServerClientId.isEmpty ? null : AppConfig.googleServerClientId,
      );

  @override
  Future<String?> fetchIdToken() async {
    await _ensureInit();
    try {
      final account = await GoogleSignIn.instance.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    await _ensureInit();
    await GoogleSignIn.instance.signOut();
  }
}

final googleIdTokenSourceProvider = Provider<GoogleIdTokenSource>((ref) => GoogleSignInIdTokenSource());
