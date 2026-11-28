// v0.2 REST 전용 저장소(프로그램·인스턴스·기록). 트랙 리드 소유. 온라인에서만 동작하고 실패는 ApiException.
import 'dart:async';

import '../../core/api/ai_dto.dart';
import '../../core/api/api_client.dart';
import '../../core/api/program_dto.dart';
import '../../core/api/stats_dto.dart';
import '../../domain/repositories.dart';

class RemoteProgramRepository implements ProgramRepository {
  final ApiClient api;
  final _changes = StreamController<String>.broadcast();
  RemoteProgramRepository(this.api);

  Future<T> _notify<T>(String id, Future<T> f) async {
    final r = await f;
    _changes.add(id);
    return r;
  }

  @override
  Stream<String> get instanceChanges => _changes.stream;

  @override
  Future<List<ProgramSummary>> listPrograms({ProgramListSource? source}) => api.getPrograms(source: source);
  @override
  Future<Program> getProgram(String id) => api.getProgram(id);
  @override
  Future<Program> createProgram(String id, Map<String, Object?> definition) => api.postProgram(id, definition);
  @override
  Future<Program> validateProgram(Map<String, Object?> definition) => api.validateProgram(definition);
  @override
  Future<void> deleteProgram(String id) => api.deleteProgram(id);
  @override
  Future<List<SuggestItem>> suggest(String programId) => api.suggest(programId);
  @override
  Future<StartPreview> previewStart(String programId, StartPreviewRequest request) =>
      api.previewStart(programId, request);

  @override
  Future<List<Instance>> listInstances({InstanceStatus? status}) => api.getInstances(status: status);
  @override
  Future<Instance> getInstance(String id) => api.getInstance(id);
  @override
  Future<Instance> startInstance(StartInstance start) => _notify(start.id, api.startInstance(start));
  @override
  Future<Instance> patchInstance(String id, InstancePatch patch) => _notify(id, api.patchInstance(id, patch));
  @override
  Future<void> deleteInstance(String id) => _notify(id, api.deleteInstance(id));
  @override
  Future<List<PlannedWorkout>> plan(String instanceId, {int count = 3}) => api.getPlan(instanceId, count: count);
  @override
  Future<Instance> skip(String instanceId, int planSeq) => _notify(instanceId, api.skip(instanceId, planSeq));
  @override
  Future<List<Accessory>> accessories(String instanceId) => api.getAccessories(instanceId);
  @override
  Future<List<Accessory>> putAccessories(String instanceId, List<Accessory> list) =>
      _notify(instanceId, api.putAccessories(instanceId, list));
  @override
  Future<Instance> swapLift(String instanceId, String liftKey, String exerciseId) =>
      _notify(instanceId, api.swapLift(instanceId, liftKey, exerciseId));
  @override
  Future<Map<String, List<int>>> putDayOrder(String instanceId, String dayKey, List<int> order) =>
      _notify(instanceId, api.putDayOrder(instanceId, dayKey, order));
}

class RemoteRecordsRepository implements RecordsRepository {
  final ApiClient api;
  RemoteRecordsRepository(this.api);

  @override
  Future<ExerciseRecords> records(String exerciseId) => api.getRecords(exerciseId);
  @override
  Future<List<OneRmMeasurement>> oneRms(String exerciseId) => api.getOneRms(exerciseId);
  @override
  Future<OneRmMeasurement> addOneRm(String exerciseId, OneRmMeasurement m) => api.postOneRm(exerciseId, m);
  @override
  Future<void> deleteOneRm(String id) => api.deleteOneRm(id);
}

class RemoteStatsRepository implements StatsRepository {
  final ApiClient api;
  RemoteStatsRepository(this.api);

  @override
  Future<ExerciseProgress> progress(String exerciseId, {DateTime? from, DateTime? to, int? limit}) =>
      api.getProgress(exerciseId, from: from, to: to, limit: limit);
  @override
  Future<SessionComparison> comparison(String sessionId) => api.getComparison(sessionId);
}

/// 서버 데이터가 바뀐 뒤 앱이 할 일(동기화 pull, 계획 캐시 갱신). providers에서 연결한다.
typedef AfterServerChange = Future<void> Function();

class RemoteImportRepository implements ImportRepository {
  final ApiClient api;
  final AfterServerChange afterChange;
  RemoteImportRepository(this.api, {required this.afterChange});

  @override
  String get importSchemaUrl => api.importSchemaUrl;
  @override
  String get programSchemaUrl => api.programSchemaUrl;

  @override
  Future<ImportPreview> preview(ImportRequest request) => api.previewImport(request);

  @override
  Future<ImportOutcome> submit(ImportRequest request) async {
    final r = await api.submitImport(request);
    if (r.saved) await afterChange();
    return r;
  }

  @override
  Future<List<ImportBatch>> history({DateTime? before, int limit = 20}) => api.getImports(before: before, limit: limit);
  @override
  Future<ImportBatchDetail> detail(String batchId) => api.getImport(batchId);

  @override
  Future<ImportBatch> revert(String batchId) async {
    final r = await api.revertImport(batchId);
    await afterChange();
    return r;
  }
}

class RemoteDeletionRequestRepository implements DeletionRequestRepository {
  final ApiClient api;
  final AfterServerChange afterChange;
  RemoteDeletionRequestRepository(this.api, {required this.afterChange});

  @override
  Future<List<DeletionRequest>> list({DeletionStatus? status}) => api.getDeletionRequests(status: status);
  @override
  Future<int> pendingCount() => api.getPendingDeletionCount();

  @override
  Future<DeletionRequest> approve(String id) async {
    final r = await api.approveDeletion(id);
    await afterChange();
    return r;
  }

  @override
  Future<DeletionRequest> reject(String id) => api.rejectDeletion(id);
}

class RemoteAiConnectionRepository implements AiConnectionRepository {
  final ApiClient api;
  RemoteAiConnectionRepository(this.api);
  @override
  Future<McpInfo> mcpInfo() => api.getMcpInfo();
  @override
  Future<List<AiConnection>> connections() => api.getAiConnections();
  @override
  Future<void> disconnect(String connectionId) => api.deleteAiConnection(connectionId);
}

class RemoteExportRepository implements ExportRepository {
  final ApiClient api;
  RemoteExportRepository(this.api);
  @override
  Future<String> exportJson() => api.exportJson();
  @override
  Future<String> exportCsv(CsvKind kind) => api.exportCsv(kind);
}
