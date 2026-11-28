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
  static const me = '/me'; // 하단 내비 '나' 탭

  // v0.2
  static const programs = '/programs'; // B1 템플릿·내 프로그램 목록 + 진행 중 인스턴스
  static String programDetail(String id) => '/programs/$id'; // B1 상세
  static String programStart(String id) => '/programs/$id/start'; // B1 TM 입력·시작
  static String instanceDetail(String id) => '/instances/$id'; // B1 인스턴스 관리(일시정지·건너뛰기 방식·보조운동)
  static const history = '/history'; // B3 세션 목록
  static String sessionEdit(String id) => '/sessions/$id/edit'; // B3 지난 세션 수정
  static String sessionSummary(String id) => '/sessions/$id/summary'; // B2 세션 끝난 뒤 요약(다음 회차 무게)
  static String exerciseRecords(String exerciseId) => '/exercises/$exerciseId/records'; // B3 PR·1RM

  // v0.3
  static const ai = '/ai'; // B3 AI 연동 허브(연결 안내·연결 목록·가져오기·이력·삭제 요청·내보내기 진입)
  static const importJson = '/ai/import'; // B1 붙여넣기·파일 → 미리보기 → 충돌 해결 → 결과
  static const aiHistory = '/ai/history'; // B2 가져오기 이력
  static String aiHistoryDetail(String batchId) => '/ai/history/$batchId'; // B2 묶음 상세·되돌리기
  static const deletionRequests = '/ai/deletions'; // B2 삭제 요청 승인·거절
  static const aiConnect = '/ai/connect'; // B3 MCP 연결 안내·연결된 AI
  static const export = '/export'; // B3 내보내기

  // v1.2
  static const csvImport = '/import/csv'; // B3 다른 앱(Strong·Hevy) CSV 가져오기

  // v1.0
  static String exerciseProgress(String exerciseId) => '/exercises/$exerciseId/progress'; // B1 종목 추이 꺾은선
  static String sessionComparison(String sessionId) => '/sessions/$sessionId/comparison'; // B1 오늘 vs 지난·PR 막대

  // v1.0 LOG-13 하루짜리 예정 운동(오늘 탭 아래, 하단 내비 유지)
  static const scheduled = '/scheduled'; // 목록
  static const scheduledNew = '/scheduled/new'; // 만들기 (?date=YYYY-MM-DD 로 날짜 지정)
  static String scheduledEdit(String id) => '/scheduled/$id/edit'; // 수정

  // v1.2 프로그램 편집기(PRG-2). 새로 만들기는 인자 없이, 고치기는 programId, 복사는 copyFrom, 진행만은 instanceId.
  static const programEditor = '/program-editor';
  static String programEditorFor({String? programId, String? copyFromProgramId, String? instanceId}) => Uri(
    path: programEditor,
    queryParameters: {'programId': ?programId, 'copyFrom': ?copyFromProgramId, 'instanceId': ?instanceId},
  ).toString();
}
