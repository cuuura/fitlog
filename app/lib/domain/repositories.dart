// 앱 WP 사이의 경계. 트랙 리드 소유.
// - B3가 drift(로컬 DB) + outbox 동기화로 구현한다 (data/local, data/sync).
// - B1·B2 화면은 이 인터페이스만 쓴다. 테스트는 data/memory 구현을 쓴다.
// 모든 쓰기는 로컬에 먼저 저장되고, 동기화는 구현이 알아서 예약한다(sync.md).
// 반환하는 시각은 모두 UTC.

import '../core/api/ai_dto.dart';
import '../core/api/dto.dart';
import '../core/api/program_dto.dart';
import '../core/api/stats_dto.dart';

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

  /// startedAt이 [fromUtc, toUtc) 안인 끝난(삭제 안 된) 세션 요약, 시작 시각 오름차순. 달력·주간 표시용.
  Stream<List<SessionSummary>> watchSessionsBetween(DateTime fromUtc, DateTime toUtc);

  /// 세션 시작. 이미 진행 중 세션이 있으면 그것을 돌려준다(plan은 무시). tz는 기기의 IANA 시간대.
  /// plan이 있으면(v0.2) 프로그램 회차 세션: programInstanceId·planSeq·planDayKey를 채우고, 계획 종목을
  /// 순서대로 만들며(liftKey=key, accessory) 계획 세트마다 세트를 만든다:
  /// plannedSetKey·targetReps·targetWeightKg·isAmrap·isWarmup을 복사하고, 기록 값 weightKg=targetWeightKg,
  /// reps=targetReps로 미리 채운다(미완료). 무게 없는 계획(NONE)은 weightKg=null로 두고 화면이 지난 기록으로 채운다.
  Future<Session> startSession({required String tz, PlannedWorkout? plan});
  Future<void> endSession(String sessionId);
  Future<void> updateSessionNote(String sessionId, String? note);

  /// 소프트 삭제.
  Future<void> deleteSession(String sessionId);

  /// 세션 끝에 종목을 붙인다(position 자동). 프로그램 세션에 즉석으로 붙이는 보조운동이면 accessory=true(LOG-11).
  Future<SessionExercise> addExercise(String sessionId, String exerciseId, {bool accessory = false});

  /// 종목 순서 변경. ids는 그 세션의 (삭제 안 된) 종목 id 전체를 새 순서로. position을 0부터 다시 매긴다.
  Future<void> reorderExercises(String sessionId, List<String> sessionExerciseIds);

  /// 세트 순서 변경(LOG-3). ids는 그 종목의 세트 id 전체를 새 순서로.
  Future<void> reorderSets(String sessionExerciseId, List<String> setIds);

  /// 지난 세션 시각 수정(LOG-10). null이면 그대로.
  Future<void> updateSessionTimes(String sessionId, {DateTime? startedAt, DateTime? endedAt});

  /// 이 인스턴스에 연결된(삭제 안 된) 로컬 세션들의 planSeq. 오프라인 계획 선택용(sync.md v0.2).
  Future<Set<int>> planSeqsUsed(String instanceId);

  /// 같은 인스턴스·같은 dayKey로 끝난 가장 최근 세션(지난 같은 세션 비교용). 없으면 null.
  Future<Session?> lastSessionForDay(String instanceId, String dayKey, {String? excludeSessionId});
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

/// v0.2 프로그램·인스턴스(REST 전용, 온라인에서만 변경. 동기화 대상 아님). 실패는 ApiException.
abstract interface class ProgramRepository {
  Future<List<ProgramSummary>> listPrograms({ProgramListSource? source});
  Future<Program> getProgram(String id);
  Future<Program> createProgram(String id, Map<String, Object?> definition);
  Future<Program> validateProgram(Map<String, Object?> definition);
  Future<void> deleteProgram(String id);
  Future<List<SuggestItem>> suggest(String programId);

  Future<List<Instance>> listInstances({InstanceStatus? status});
  Future<Instance> getInstance(String id);
  Future<Instance> startInstance(StartInstance start);
  Future<Instance> patchInstance(String id, InstancePatch patch);
  Future<void> deleteInstance(String id);
  Future<List<PlannedWorkout>> plan(String instanceId, {int count = 3});
  Future<Instance> skip(String instanceId, int planSeq);
  Future<List<Accessory>> accessories(String instanceId);
  Future<List<Accessory>> putAccessories(String instanceId, List<Accessory> list);

  /// 인스턴스가 바뀔 때(시작·일시정지·재개·종료·건너뛰기·조정·삭제) 알린다. 계획 캐시가 듣고 갱신한다.
  Stream<String> get instanceChanges;
}

/// v0.2 PR·1RM(REST 전용).
abstract interface class RecordsRepository {
  Future<ExerciseRecords> records(String exerciseId);
  Future<List<OneRmMeasurement>> oneRms(String exerciseId);
  Future<OneRmMeasurement> addOneRm(String exerciseId, OneRmMeasurement m);
  Future<void> deleteOneRm(String id);
}

/// 활성 인스턴스와 그 다음 계획(오프라인 캐시 포함).
class InstancePlan {
  final Instance instance;

  /// 다음에 할 회차. 캐시도 없으면 null.
  final PlannedWorkout? next;

  /// true면 오프라인 캐시에서 고른 예상 계획.
  final bool fromCache;
  const InstancePlan({required this.instance, this.next, this.fromCache = false});
}

/// v0.2 계획 캐시(sync.md "계획 캐시"). B2가 data/plan_cache에 구현한다.
/// v1.0 STA-4 그래프 데이터. 서버 집계 전용(온라인). 실패는 ApiException(오프라인이면 isNetwork).
abstract interface class StatsRepository {
  Future<ExerciseProgress> progress(String exerciseId, {DateTime? from, DateTime? to, int? limit});
  Future<SessionComparison> comparison(String sessionId);
}

abstract interface class PlanCache {
  /// 활성(ACTIVE) 인스턴스와 다음 계획. 오프라인이면 캐시 기준.
  Stream<List<InstancePlan>> watchActive();

  /// 서버에서 인스턴스 목록과 계획(count=3)을 다시 받는다. instanceId를 주면 그것만. 오프라인이면 조용히 끝낸다.
  Future<void> refresh({String? instanceId});

  /// 이 인스턴스로 지금 세션을 시작할 때 쓸 계획. 온라인이면 확정 계획, 오프라인이면 아직 안 쓴 가장 앞 planSeq.
  Future<PlannedWorkout?> nextPlan(String instanceId);
}

/// v0.3 가져오기(AI-1, AI-6). REST 전용. 저장·되돌리기가 성공하면 구현이 동기화(pull)와 계획 캐시 갱신을 건다.
abstract interface class ImportRepository {
  Future<ImportPreview> preview(ImportRequest request);

  /// 충돌이 없거나 모두 해결됐으면 saved, 아니면 needsResolution(새 충돌 목록).
  Future<ImportOutcome> submit(ImportRequest request);
  Future<List<ImportBatch>> history({DateTime? before, int limit = 20});
  Future<ImportBatchDetail> detail(String batchId);
  Future<ImportBatch> revert(String batchId);

  /// 프롬프트 복사용 공개 스키마 주소.
  String get importSchemaUrl;
  String get programSchemaUrl;
}

/// v0.3 AI 삭제 요청 승인(AI-5).
abstract interface class DeletionRequestRepository {
  Future<List<DeletionRequest>> list({DeletionStatus? status});
  Future<int> pendingCount();

  /// 승인하면 서버가 삭제하고, 구현이 동기화를 건다. 409(이미 결정)·410(만료)은 ApiException.
  Future<DeletionRequest> approve(String id);
  Future<DeletionRequest> reject(String id);
}

/// v0.3 AI 연결(AI-3)과 내보내기(DAT-1, DAT-2).
abstract interface class AiConnectionRepository {
  Future<McpInfo> mcpInfo();
  Future<List<AiConnection>> connections();
  Future<void> disconnect(String connectionId);
}

abstract interface class ExportRepository {
  Future<String> exportJson();
  Future<String> exportCsv(CsvKind kind);
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
