// 앱 WP 사이의 경계. 트랙 리드 소유.
// - B3가 drift(로컬 DB) + outbox 동기화로 구현한다 (data/local, data/sync).
// - B1·B2 화면은 이 인터페이스만 쓴다. 테스트는 data/memory 구현을 쓴다.
// 모든 쓰기는 로컬에 먼저 저장되고, 동기화는 구현이 알아서 예약한다(sync.md).
// 반환하는 시각은 모두 UTC.

import '../core/api/dto.dart';

/// 기본 종목(서버에서 내려받아 로컬 캐시) + 내 종목.
abstract interface class ExerciseRepository {
  /// 삭제되지 않은 전체 종목. 이름순.
  Stream<List<Exercise>> watchAll();

  /// 이름(한/영, 부분 일치·대소문자 무시)·부위·유형으로 거른다. 로컬에서 동작한다.
  Future<List<Exercise>> search({String? query, Muscle? muscle, ExerciseType? type});

  Future<Exercise?> byId(String id);

  /// EXR-2 내 종목 추가. id는 호출자가 newId()로 만든다.
  Future<Exercise> createCustom(ExerciseInput input);
  Future<Exercise> updateCustom(ExerciseInput input);
  Future<void> deleteCustom(String id);

  /// 서버의 기본 종목 목록을 다시 받아 캐시를 갱신한다. 오프라인이면 조용히 실패해도 된다.
  Future<void> refreshFromServer();
}

/// LOG-1/2/7 세션 기록. v0.1은 진행 중 세션을 하나만 연다.
abstract interface class SessionRepository {
  /// 진행 중(endedAt == null) 세션. 앱 재시작 후에도 로컬 DB에서 복구된다.
  Stream<Session?> watchActiveSession();
  Stream<Session?> watchSession(String id);

  /// 최근 세션 요약(startedAt 내림차순). 진행 중 세션도 포함.
  Stream<List<SessionSummary>> watchRecentSessions({int limit = 20});

  /// 자유 세션 시작. 이미 진행 중 세션이 있으면 그것을 돌려준다.
  /// tz는 기기의 IANA 시간대.
  Future<Session> startSession({required String tz});
  Future<void> endSession(String sessionId);
  Future<void> updateSessionNote(String sessionId, String? note);

  /// 소프트 삭제.
  Future<void> deleteSession(String sessionId);

  /// 세션 끝에 종목을 붙인다(position 자동).
  Future<SessionExercise> addExercise(String sessionId, String exerciseId);
  Future<void> removeExercise(String sessionExerciseId);
  Future<void> updateExerciseNote(String sessionExerciseId, String? note);

  /// 종목 끝에 세트를 붙인다. draft.position은 무시하고 구현이 매긴다. id는 호출자가 만든다.
  Future<WorkoutSet> addSet(String sessionExerciseId, WorkoutSet draft);

  /// 세트 값 수정(완료 처리 = completedAt 채우기 포함).
  Future<void> updateSet(WorkoutSet set);
  Future<void> deleteSet(String setId);

  /// 이 종목을 한 가장 최근의 "끝난" 세션의 세트들. 없으면 null. 세트 입력 기본값용.
  Future<LastSets?> lastSetsFor(String exerciseId, {String? excludeSessionId});
}

/// BDY-1 체중.
abstract interface class BodyRepository {
  /// measuredAt 내림차순.
  Stream<List<BodyMeasurement>> watchMeasurements();
  Future<void> add(BodyMeasurement m);
  Future<void> delete(String id);
}

enum SyncPhase { idle, syncing, offline, error }

class SyncStatus {
  final SyncPhase phase;

  /// 아직 서버에 못 보낸 변경 수.
  final int pending;
  final DateTime? lastSyncedAt;
  final String? lastError;
  const SyncStatus({this.phase = SyncPhase.idle, this.pending = 0, this.lastSyncedAt, this.lastError});
}

/// LOG-8 동기화.
abstract interface class SyncService {
  Stream<SyncStatus> watchStatus();

  /// 즉시 push → pull. 이미 도는 중이면 그 결과를 기다린다.
  Future<void> syncNow();

  /// 디바운스해서 나중에 동기화한다(세트 완료 후 5초 등).
  void schedule({Duration delay = const Duration(seconds: 5)});
}

/// 로그아웃·계정 삭제 시 로컬 데이터를 지운다.
abstract interface class LocalDataStore {
  Future<void> clearAll();
}
