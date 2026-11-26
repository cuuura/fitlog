/// 화면 경로 이름. WP 사이에서 화면을 열 때는 이 상수를 쓴다(context.push(Routes.settings)).
abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const consent = '/consent';
  static const home = '/';
  static const session = '/session'; // 진행 중 세션
  static String sessionDetail(String id) => '/sessions/$id';
  static const pickExercise = '/session/pick-exercise'; // 결과: 선택한 Exercise.id (context.pop(id))
  static const settings = '/settings';
  static const profile = '/profile';
  static const body = '/body';
}
