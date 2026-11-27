/// 빌드 시 `--dart-define`으로 넣는 설정.
/// 예: flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080 --dart-define=GOOGLE_SERVER_CLIENT_ID=xxx.apps.googleusercontent.com
abstract final class AppConfig {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8080');

  /// Google Sign-In이 서버용 ID 토큰을 받기 위한 웹 클라이언트 ID.
  static const googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  /// 동의 문서 버전(ACC-6). 문서가 바뀌면 올린다.
  /// 서버 CURRENT_CONSENT_VERSION(server/.../account/AccountRoutes.kt)과 같아야 한다. 다르면 동의해도 계속 동의 화면에 남는다.
  static const consentVersion = '2026-11-01';
}
