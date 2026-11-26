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

  // v0.2
  static const programs = '/programs'; // B1 템플릿·내 프로그램 목록 + 진행 중 인스턴스
  static String programDetail(String id) => '/programs/$id'; // B1 상세
  static String programStart(String id) => '/programs/$id/start'; // B1 TM 입력·시작
  static String instanceDetail(String id) => '/instances/$id'; // B1 인스턴스 관리(일시정지·건너뛰기 방식·보조운동)
  static const history = '/history'; // B3 세션 목록
  static String sessionEdit(String id) => '/sessions/$id/edit'; // B3 지난 세션 수정
  static String sessionSummary(String id) => '/sessions/$id/summary'; // B2 세션 끝난 뒤 요약(다음 회차 무게)
  static String exerciseRecords(String exerciseId) => '/exercises/$exerciseId/records'; // B3 PR·1RM
}
