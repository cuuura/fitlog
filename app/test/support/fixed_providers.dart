// 앱 전역 Provider를 테스트에서 고정하는 대역. 저장소·서버 없이 동작한다.
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/settings/settings_controller.dart';

class FixedAuthStatus extends AuthController {
  final AuthStatus initial;
  FixedAuthStatus(this.initial);
  @override
  AuthStatus build() => initial;
}

class FixedSettings extends SettingsController {
  final Settings initial;
  FixedSettings([this.initial = const Settings()]);
  @override
  Settings build() => initial;
  @override
  Future<void> update(Settings next) async => state = next;
}
