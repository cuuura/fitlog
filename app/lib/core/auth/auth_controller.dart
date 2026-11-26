// B1 소유. 골격 단계에서는 항상 로그인된 것으로 둔다.
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AuthStatus {
  /// 저장된 토큰 확인 중(스플래시).
  unknown,
  signedOut,

  /// 로그인했지만 필수 동의(Me.consentsRequired)가 남음.
  needsConsent,
  signedIn,
}

class AuthController extends Notifier<AuthStatus> {
  @override
  AuthStatus build() => AuthStatus.signedIn;
}

final authControllerProvider = NotifierProvider<AuthController, AuthStatus>(AuthController.new);
