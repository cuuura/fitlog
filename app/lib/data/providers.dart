// 저장소 Provider. 화면은 이 Provider만 읽는다. 테스트는 overrideWithValue로
// data/memory 구현을 끼운다. 실제 구현은 drift 로컬 DB + outbox 동기화(data/local, data/sync).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/repositories.dart';
import '../core/api/api_providers.dart';
import 'local/local_providers.dart';
import 'plan_cache/plan_cache_providers.dart';
import 'remote/remote_repositories.dart';

final exerciseRepositoryProvider = Provider<ExerciseRepository>((ref) => ref.watch(driftExerciseRepositoryProvider));
final sessionRepositoryProvider = Provider<SessionRepository>((ref) => ref.watch(driftSessionRepositoryProvider));
final scheduledWorkoutRepositoryProvider = Provider<ScheduledWorkoutRepository>(
  (ref) => ref.watch(driftScheduledWorkoutRepositoryProvider),
);
final bodyRepositoryProvider = Provider<BodyRepository>((ref) => ref.watch(driftBodyRepositoryProvider));
final syncServiceProvider = Provider<SyncService>((ref) => ref.watch(syncEngineProvider));
final localDataStoreProvider = Provider<LocalDataStore>((ref) => ref.watch(driftLocalDataStoreProvider));

// v0.2
final programRepositoryProvider = Provider<ProgramRepository>(
  (ref) => RemoteProgramRepository(ref.watch(apiClientProvider)),
);
final recordsRepositoryProvider = Provider<RecordsRepository>(
  (ref) => RemoteRecordsRepository(ref.watch(apiClientProvider)),
);
final planCacheProvider = Provider<PlanCache>((ref) => ref.watch(planCacheImplProvider));

// v0.3
Future<void> _afterServerChange(Ref ref) async {
  await ref.read(syncServiceProvider).syncNow();
  await ref.read(planCacheProvider).refresh();
}

final importRepositoryProvider = Provider<ImportRepository>(
  (ref) => RemoteImportRepository(ref.watch(apiClientProvider), afterChange: () => _afterServerChange(ref)),
);
final deletionRequestRepositoryProvider = Provider<DeletionRequestRepository>(
  (ref) => RemoteDeletionRequestRepository(ref.watch(apiClientProvider), afterChange: () => _afterServerChange(ref)),
);
final aiConnectionRepositoryProvider = Provider<AiConnectionRepository>(
  (ref) => RemoteAiConnectionRepository(ref.watch(apiClientProvider)),
);
final exportRepositoryProvider = Provider<ExportRepository>(
  (ref) => RemoteExportRepository(ref.watch(apiClientProvider)),
);

// v1.0
final statsRepositoryProvider = Provider<StatsRepository>((ref) => RemoteStatsRepository(ref.watch(apiClientProvider)));
