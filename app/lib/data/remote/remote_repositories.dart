// v0.2 REST 전용 저장소(프로그램·인스턴스·기록). 트랙 리드 소유. 온라인에서만 동작하고 실패는 ApiException.
import 'dart:async';

import '../../core/api/api_client.dart';
import '../../core/api/program_dto.dart';
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
